extends RefCounted

## Publishes the finished weather field and updates the visible fronts.

static func _ensure_weather_commit_arrays(solver: DCWeatherFieldSolver, map: MapData, n_cells: int) -> void:
	if map == null or n_cells <= 0:
		return
	if map.weather_intensity_arr.size() != n_cells:
		map.weather_intensity_arr.resize(n_cells)
	if map.weather_cloud_arr.size() != n_cells:
		map.weather_cloud_arr.resize(n_cells)
	if map.weather_cloud_water_arr.size() != n_cells:
		map.weather_cloud_water_arr.resize(n_cells)
	if map.weather_precip_arr.size() != n_cells:
		map.weather_precip_arr.resize(n_cells)
	if map.weather_type_arr.size() != n_cells:
		map.weather_type_arr.resize(n_cells)
	if map.weather_prev_type_arr.size() != n_cells:
		map.weather_prev_type_arr.resize(n_cells)
	if map.weather_target_type_arr.size() != n_cells:
		map.weather_target_type_arr.resize(n_cells)
	if map.weather_transition_alpha_arr.size() != n_cells:
		map.weather_transition_alpha_arr.resize(n_cells)
	if map.weather_vapor_arr.size() != n_cells:
		map.weather_vapor_arr.resize(n_cells)
	if map.weather_convergence_arr.size() != n_cells:
		map.weather_convergence_arr.resize(n_cells)
	if map.weather_instability_arr.size() != n_cells:
		map.weather_instability_arr.resize(n_cells)
	if map.weather_field_init_arr.size() != n_cells:
		map.weather_field_init_arr.resize(n_cells)
	if map.weather_dirty_mask.size() != n_cells:
		map.weather_dirty_mask.resize(n_cells)


static func _weather_commit_visible(solver: DCWeatherFieldSolver, map: MapData, n_cells: int, transition_enabled: bool) -> Dictionary:
	var result: Dictionary = {
		"verified": false,
		"init_count": 0,
		"reason": "",
	}
	if map == null:
		result["reason"] = "map_null"
		return result
	if n_cells <= 0:
		result["verified"] = true
		result["reason"] = "empty"
		return result
	var init_arr: PackedByteArray = map.weather_field_init_arr
	if init_arr.size() != n_cells:
		result["reason"] = "field_init_size_%d_expected_%d" % [init_arr.size(), n_cells]
		return result
	var init_count: int = 0
	for i in range(n_cells):
		if init_arr[i] != 0:
			init_count += 1
	result["init_count"] = init_count
	if init_count != n_cells:
		result["reason"] = "field_init_incomplete_%d_of_%d" % [init_count, n_cells]
		return result
	if map.weather_vapor_arr.size() != n_cells \
			or map.weather_cloud_arr.size() != n_cells \
			or map.weather_cloud_water_arr.size() != n_cells \
			or map.weather_precip_arr.size() != n_cells \
			or map.weather_type_arr.size() != n_cells:
		result["reason"] = "visible_weather_array_size_mismatch"
		return result
	if solver._field_slice_next_vapor.size() != n_cells \
			or solver._field_slice_next_cloud.size() != n_cells \
			or solver._field_slice_next_precip.size() != n_cells \
			or solver._field_slice_next_type.size() != n_cells:
		result["reason"] = "next_weather_array_size_mismatch"
		return result
	var vapor_arr: PackedFloat32Array = map.weather_vapor_arr
	var cloud_arr: PackedFloat32Array = map.weather_cloud_arr
	var cloud_water_arr: PackedFloat32Array = map.weather_cloud_water_arr
	var precip_arr: PackedFloat32Array = map.weather_precip_arr
	var type_arr: PackedByteArray = map.weather_type_arr
	var sample_count: int = mini(n_cells, 64)
	var mismatch_count: int = 0
	for sample_i in range(sample_count):
		var idx: int = 0
		if sample_count > 1:
			idx = int(floor(float(sample_i * (n_cells - 1)) / float(sample_count - 1)))
		var mismatch: bool = false
		mismatch = mismatch or absf(vapor_arr[idx] - solver._field_slice_next_vapor[idx]) > 0.015
		mismatch = mismatch or absf(cloud_arr[idx] - solver._field_slice_next_cloud[idx]) > 0.015
		if solver._field_slice_next_cloud_water.size() == n_cells:
			mismatch = mismatch or absf(cloud_water_arr[idx] - solver._field_slice_next_cloud_water[idx]) > 0.015
		mismatch = mismatch or absf(precip_arr[idx] - solver._field_slice_next_precip[idx]) > 0.015
		if not transition_enabled:
			mismatch = mismatch or int(type_arr[idx]) != (int(solver._field_slice_next_type[idx]) & 0xFF)
		if mismatch:
			mismatch_count += 1
	if mismatch_count > 0:
		result["reason"] = "field_sample_mismatch_%d_of_%d" % [mismatch_count, sample_count]
		return result
	result["verified"] = true
	result["reason"] = "ok"
	return result


static func commit(solver: DCWeatherFieldSolver) -> Array[WeatherFront]:
	# dots-monolith-split §1.2 / PR-5：从 weather_system.commit_weather_field_solve
	# 整段搬迁。所有 _field_slice_* 状态字段为本类成员（PR-4 搬过来）；
	# owner 字段（_active_fronts / _hexcell_facade_on / _data_core_world /
	# _apply_frontal_convergence_boost / _distribute_weather_field_to_cells /
	# _build_field_summary_fronts / _cyclone_wake_enabled / _advect /
	# _last_breakdown / _last_map_for_query / _current_map_for_tick /
	# _tick_cell_pos / _tick_cell_neighbors / _clear_weather_field_slice_state）
	# 通过 _weather_system.<field/method> 访问。
	if solver._weather_system == null:
		return [] as Array[WeatherFront]
	if not solver._field_slice_active:
		return solver._weather_system._active_fronts
	var t_commit_total_us: int = Time.get_ticks_usec()
	var map: MapData = solver._field_slice_map
	var world: WorldData = solver._field_slice_world
	var cells: Array = solver._field_slice_cells
	# v9c: 同时写 SoA 镜像数组，修复 flush_soa_to_cells() 用 SoA 反向覆盖 AoS
	# 导致 weather_type 被周期性清回 CLEAR 的问题。SoA 数组已 bind 到 DataCore
	# 的 CELL_WEATHER_INTENSITY/CLOUD/PRECIP/TYPE 4 个 component。
	var soa_intensity: PackedFloat32Array = map.weather_intensity_arr
	var soa_cloud: PackedFloat32Array = map.weather_cloud_arr
	var soa_cloud_water: PackedFloat32Array = map.weather_cloud_water_arr
	var soa_precip: PackedFloat32Array = map.weather_precip_arr
	var soa_type: PackedByteArray = map.weather_type_arr
	var soa_prev_type: PackedByteArray = map.weather_prev_type_arr
	var soa_target_type: PackedByteArray = map.weather_target_type_arr
	var soa_transition_alpha: PackedFloat32Array = map.weather_transition_alpha_arr
	# B-full Step-2：4 个新 SoA（vapor/convergence/instability/field_init）一并写出。
	# 与 weather_intensity/cloud/precip/type 一组，hot loop 自身的 11 个写入字段全部 SoA 化。
	var soa_vapor: PackedFloat32Array = map.weather_vapor_arr
	var soa_convergence: PackedFloat32Array = map.weather_convergence_arr
	var soa_instability: PackedFloat32Array = map.weather_instability_arr
	var soa_field_init: PackedByteArray = map.weather_field_init_arr
	var commit_n: int = cells.size()
	var commit_setup_ms: float = (Time.get_ticks_usec() - t_commit_total_us) / 1000.0
	var weather_dirty: PackedByteArray = map.weather_dirty_mask
	var weather_dirty_count: int = 0
	if weather_dirty.size() == commit_n:
		for di in range(commit_n):
			weather_dirty[di] = 0

	var t_commit_loop_us: int = Time.get_ticks_usec()
	var hexcell_facade_on: bool = solver._weather_system._hexcell_facade_on
	var cp_transition = solver._weather_system._cp_for_front_flag
	var transition_enabled: bool = cp_transition != null \
			and cp_transition.get("weather_transition_enabled") != null \
			and bool(cp_transition.weather_transition_enabled)
	var transition_rate: float = 1.0
	if transition_enabled and cp_transition.get("weather_transition_alpha_rate") != null:
		transition_rate = clampf(float(cp_transition.weather_transition_alpha_rate), 0.0, 1.0)
	# [dt-aware transition 2026-06-28] 镜像 world_ext_weather.cpp：过渡按游戏天数推进而非求解次数。
	# dt_days 取自与 C++ 同一份 native knobs（weather_system 用 _consume_weather_dt_days() 填入），缺省 1.0。
	var transition_dt_days: float = clampf(float(solver._field_slice_native_knobs.get("weather_transition_dt_days", 1.0)), 0.0, 30.0)
	var water_budget_error_acc: float = 0.0
	var commit_path: String = "gdscript"
	var commit_loop_ms: float = 0.0
	var native_commit_done: bool = false
	var native_weather_lut: PackedByteArray = PackedByteArray()
	var native_weather_lut_changed: bool = false
	var native_weather_lut_dirty_count: int = 0
	var native_weather_lut_full_rebuild: bool = false
	var commit_publish_verified: bool = false

	var commit_publish_repaired: bool = false
	var commit_visible_init_count: int = 0
	var commit_publish_reason: String = ""
	var convergence_delta_samples: PackedFloat32Array = PackedFloat32Array()
	var convergence_delta_count: int = 0
	if solver._field_slice_refresh_convergence and commit_n > 0:
		convergence_delta_samples.resize(commit_n)
	var native_wrote_next: bool = bool(solver._field_slice_native_knobs.get("weather_field_wrote_next", false))
	if solver._weather_system._use_gdext_weather_field_commit \
			and solver._weather_system._data_core_world_ext != null \
			and solver._field_slice_fast_indexed \
			and hexcell_facade_on \
			and native_wrote_next \
			and solver._field_slice_next_vapor.size() == commit_n \
			and solver._field_slice_next_cloud.size() == commit_n \
			and solver._field_slice_next_precip.size() == commit_n \
			and solver._field_slice_next_instability.size() == commit_n \
			and solver._field_slice_next_intensity.size() == commit_n \
			and solver._field_slice_next_convergence.size() == commit_n \
			and solver._field_slice_next_type.size() == commit_n:
		var commit_rc: Dictionary = solver._weather_system._try_run_weather_field_commit_gdext(map, commit_n)
		if float(commit_rc.get("elapsed_ms", -1.0)) >= 0.0:
			native_commit_done = true
			solver._field_slice_results_in_soa = true
			commit_path = str(commit_rc.get("path", "gdext_commit"))
			native_weather_lut = commit_rc.get("weather_lut", PackedByteArray())
			native_weather_lut_changed = bool(commit_rc.get("weather_lut_changed", false))
			native_weather_lut_dirty_count = int(commit_rc.get("weather_lut_dirty_count", 0))
			native_weather_lut_full_rebuild = bool(commit_rc.get("weather_lut_full_rebuild", false))
			weather_dirty_count = int(commit_rc.get("weather_dirty_count", 0))

			water_budget_error_acc = float(commit_rc.get("water_budget_error", 0.0)) * float(maxi(commit_n, 1))
			commit_loop_ms = float(commit_rc.get("commit_loop_ms", commit_rc.get("elapsed_ms", 0.0)))
			convergence_delta_count = int(commit_rc.get("weather_convergence_dirty_count", 0))
			if solver._field_slice_refresh_convergence:
				convergence_delta_samples = commit_rc.get("weather_convergence_deltas", PackedFloat32Array())
			var visible_check: Dictionary = solver._weather_commit_visible(map, commit_n, transition_enabled)
			commit_publish_verified = bool(visible_check.get("verified", false))
			commit_visible_init_count = int(visible_check.get("init_count", 0))
			commit_publish_reason = str(visible_check.get("reason", ""))
			if not commit_publish_verified:
				native_commit_done = false
				native_weather_lut = PackedByteArray()
				native_weather_lut_changed = false
				native_weather_lut_dirty_count = 0
				native_weather_lut_full_rebuild = false
				solver._field_slice_results_in_soa = false
				commit_publish_repaired = true

				commit_path = "gdext_commit_repaired_gdscript_publish"
				weather_dirty_count = 0
				water_budget_error_acc = 0.0
				commit_loop_ms = 0.0
				convergence_delta_count = 0
				if solver._field_slice_refresh_convergence:
					convergence_delta_samples = PackedFloat32Array()
					convergence_delta_samples.resize(commit_n)
				solver._ensure_weather_commit_arrays(map, commit_n)
				soa_intensity = map.weather_intensity_arr
				soa_cloud = map.weather_cloud_arr
				soa_cloud_water = map.weather_cloud_water_arr
				soa_precip = map.weather_precip_arr
				soa_type = map.weather_type_arr
				soa_prev_type = map.weather_prev_type_arr
				soa_target_type = map.weather_target_type_arr
				soa_transition_alpha = map.weather_transition_alpha_arr
				soa_vapor = map.weather_vapor_arr
				soa_convergence = map.weather_convergence_arr
				soa_instability = map.weather_instability_arr
				soa_field_init = map.weather_field_init_arr
				weather_dirty = map.weather_dirty_mask
				if weather_dirty.size() == commit_n:
					for repair_di in range(commit_n):
						weather_dirty[repair_di] = 0
				if not solver._weather_system._gdext_field_commit_warned_fallback:
					solver._weather_system._gdext_field_commit_warned_fallback = true
					push_warning("[weather] gdext field commit did not publish visible MapData (%s); repaired with GDScript publish for this tick" % commit_publish_reason)
	if not native_commit_done:
		for i in range(cells.size()):
			if solver._field_slice_results_in_soa and hexcell_facade_on and not transition_enabled:
				break
			var out_cell: HexCell = cells[i]
			var v_cloud: float = solver._field_slice_next_cloud[i]
			var v_cloud_water: float = solver._field_slice_next_cloud_water[i] if solver._field_slice_next_cloud_water.size() > i else v_cloud * 0.5
			var v_precip: float = solver._field_slice_next_precip[i]
			var v_type: int = solver._field_slice_next_type[i]
			var v_intensity: float = solver._field_slice_next_intensity[i]
			var v_vapor: float = solver._field_slice_next_vapor[i]
			var v_convergence: float = solver._field_slice_next_convergence[i]
			var v_instability: float = solver._field_slice_next_instability[i]
			if solver._field_slice_refresh_convergence and soa_convergence.size() > i:
				var conv_delta: float = absf(soa_convergence[i] - v_convergence)
				if conv_delta > 0.0005:
					convergence_delta_samples[convergence_delta_count] = conv_delta
					convergence_delta_count += 1
			var prev_budget_vapor: float = solver._field_slice_prev_vapor[i] if solver._field_slice_prev_vapor.size() > i else (soa_vapor[i] if soa_vapor.size() > i else 0.0)
			var prev_budget_cloud_water: float = soa_cloud_water[i] if soa_cloud_water.size() > i else 0.0
			water_budget_error_acc += absf((v_vapor + v_cloud_water + v_precip) - (prev_budget_vapor + prev_budget_cloud_water))
			var display_type: int = v_type
			var prev_type: int = v_type
			var target_type: int = v_type
			var alpha: float = 1.0
			if transition_enabled and soa_prev_type.size() > i \
					and soa_target_type.size() > i and soa_transition_alpha.size() > i:
				var current_display: int = v_type
				if soa_type.size() > i:
					current_display = int(soa_type[i])
				elif out_cell != null:
					current_display = out_cell.weather_type
				prev_type = int(soa_prev_type[i])
				target_type = int(soa_target_type[i])
				alpha = clampf(soa_transition_alpha[i], 0.0, 1.0)
				if target_type != v_type:
					prev_type = current_display
					target_type = v_type
					alpha = clampf(transition_rate * transition_dt_days, 0.0, 1.0) # [dt-aware] 当前求解即计入
				elif prev_type == target_type or current_display == target_type:
					prev_type = target_type
					alpha = 0.0
				else:
					alpha = clampf(alpha + transition_rate * transition_dt_days, 0.0, 1.0)
				display_type = target_type if alpha >= 1.0 else prev_type
				if alpha >= 1.0:
					prev_type = target_type
					alpha = 0.0
			# 任务 2：facade 开启后跳过 AoS 双写（SoA 由本函数末尾的 batch indexed 写入）。
			# facade=false 时仍保留 AoS 写，让 legacy reader（map_baker / map_generator）能读到值。
			if not hexcell_facade_on:
				out_cell.weather_field_initialized = true
				out_cell.weather_vapor = v_vapor
				out_cell.weather_cloud = v_cloud
				out_cell.weather_precip = v_precip
				out_cell.weather_instability = v_instability
				out_cell.weather_type = display_type
				out_cell.weather_prev_type = prev_type
				out_cell.weather_target_type = target_type
				out_cell.weather_transition_alpha = alpha
				out_cell.weather_intensity = v_intensity
				out_cell.weather_convergence = v_convergence
			# SoA 镜像（与 DCWorld view_f32 同引用；renderer 在 round 末经
			# flush_soa_to_cells() 拿一致快照）
			var weather_changed: bool = false
			if soa_vapor.size() > i:
				weather_changed = weather_changed or absf(soa_vapor[i] - v_vapor) > 0.002
			if soa_cloud.size() > i:
				weather_changed = weather_changed or absf(soa_cloud[i] - v_cloud) > 0.002
			if soa_cloud_water.size() > i:
				weather_changed = weather_changed or absf(soa_cloud_water[i] - v_cloud_water) > 0.002
			if soa_precip.size() > i:
				weather_changed = weather_changed or absf(soa_precip[i] - v_precip) > 0.002
			if soa_type.size() > i:
				weather_changed = weather_changed or int(soa_type[i]) != display_type
			if weather_changed and weather_dirty.size() == commit_n:
				if weather_dirty[i] == 0:
					weather_dirty_count += 1
				weather_dirty[i] = 1
				if solver._field_slice_fast_indexed and solver._field_slice_neighbor_indices.size() >= commit_n * 6:
					var nb_base: int = i * 6
					for nd in range(6):
						var nb_i: int = solver._field_slice_neighbor_indices[nb_base + nd]
						if nb_i >= 0 and nb_i < commit_n:
							if weather_dirty[nb_i] == 0:
								weather_dirty_count += 1
							weather_dirty[nb_i] = 1
			soa_intensity[i] = v_intensity
			soa_cloud[i] = v_cloud
			if soa_cloud_water.size() > i:
				soa_cloud_water[i] = v_cloud_water
			soa_precip[i] = v_precip
			soa_type[i] = display_type & 0xFF
			if soa_prev_type.size() > i:
				soa_prev_type[i] = prev_type & 0xFF
			if soa_target_type.size() > i:
				soa_target_type[i] = target_type & 0xFF
			if soa_transition_alpha.size() > i:
				soa_transition_alpha[i] = alpha
			soa_vapor[i] = v_vapor
			soa_convergence[i] = v_convergence
			soa_instability[i] = v_instability
			soa_field_init[i] = 1
		commit_loop_ms = (Time.get_ticks_usec() - t_commit_loop_us) / 1000.0
		var final_visible_check: Dictionary = solver._weather_commit_visible(map, commit_n, transition_enabled)
		commit_publish_verified = bool(final_visible_check.get("verified", false))
		commit_visible_init_count = int(final_visible_check.get("init_count", 0))
		if commit_publish_repaired:
			if not commit_publish_verified:
				commit_publish_reason = "%s; repair_%s" % [
					commit_publish_reason,
					str(final_visible_check.get("reason", "")),
				]
		else:
			commit_publish_reason = str(final_visible_check.get("reason", ""))
	# Full-field commit 始终覆盖 [0,n)，用 range 写避免构造 idx/value batch。
	var t_commit_dc_us: int = Time.get_ticks_usec()
	var _data_core_world = solver._weather_system._data_core_world
	if _data_core_world != null and commit_n > 0 and not solver._field_slice_results_in_soa:
		var _cid_wi: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_INTENSITY)
		var world_reads_map_arrays: bool = _cid_wi >= 0 \
				and _data_core_world.has_method("is_external_component") \
				and bool(_data_core_world.is_external_component(_cid_wi))
		if commit_publish_repaired or not world_reads_map_arrays:
			if _cid_wi >= 0:
				_data_core_world.write_f32_range(_cid_wi, 0, soa_intensity)
			var _cid_wc: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_CLOUD)
			if _cid_wc >= 0:
				_data_core_world.write_f32_range(_cid_wc, 0, soa_cloud)
			var _cid_wcw: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_CLOUD_WATER)
			if _cid_wcw >= 0:
				_data_core_world.write_f32_range(_cid_wcw, 0, soa_cloud_water)
			var _cid_wp: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_PRECIP)
			if _cid_wp >= 0:
				_data_core_world.write_f32_range(_cid_wp, 0, soa_precip)
			var _cid_wv: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_VAPOR)
			if _cid_wv >= 0:
				_data_core_world.write_f32_range(_cid_wv, 0, soa_vapor)
			var _cid_wcv: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_CONVERGENCE)
			if _cid_wcv >= 0:
				_data_core_world.write_f32_range(_cid_wcv, 0, soa_convergence)
			var _cid_wins: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_INSTABILITY)
			if _cid_wins >= 0:
				_data_core_world.write_f32_range(_cid_wins, 0, soa_instability)
			var _cid_wt: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_TYPE)
			if _cid_wt >= 0:
				_data_core_world.write_u8_range(_cid_wt, 0, soa_type)
			var _cid_wpt: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_PREV_TYPE)
			if _cid_wpt >= 0:
				_data_core_world.write_u8_range(_cid_wpt, 0, soa_prev_type)
			var _cid_wtt: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_TARGET_TYPE)
			if _cid_wtt >= 0:
				_data_core_world.write_u8_range(_cid_wtt, 0, soa_target_type)
			var _cid_wta: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_TRANSITION_ALPHA)
			if _cid_wta >= 0:
				_data_core_world.write_f32_range(_cid_wta, 0, soa_transition_alpha)
			var _cid_wfi: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_FIELD_INIT)
			if _cid_wfi >= 0:
				_data_core_world.write_u8_range(_cid_wfi, 0, soa_field_init)
	var commit_dc_ms: float = (Time.get_ticks_usec() - t_commit_dc_us) / 1000.0
	var commit_convergence_ms: float = 0.0
	if solver._field_slice_refresh_convergence and not solver._field_slice_native_convergence_boost:
		var t_commit_conv_us: int = Time.get_ticks_usec()
		solver._weather_system._apply_frontal_convergence_boost(map, cells, solver._field_slice_climate_anomaly, solver._field_slice_neighbor_indices, solver._field_slice_fast_indexed)
		commit_convergence_ms = (Time.get_ticks_usec() - t_commit_conv_us) / 1000.0
	var commit_total_ms: float = (Time.get_ticks_usec() - t_commit_total_us) / 1000.0
	if convergence_delta_samples.size() > convergence_delta_count:
		convergence_delta_samples.resize(convergence_delta_count)
	var convergence_delta_p95: float = solver._weather_system._percentile_abs_from_array(convergence_delta_samples, 0.95) if convergence_delta_count > 0 else 0.0

	var t_us0_field: int = Time.get_ticks_usec()
	# ─── Weather Hot-Path：dist fast-path（plan/weather-hotpath-cpp 任务 3）──
	# C++ 通路开关启用 + 方法签名 OK 时，先尝试 C++ pass；rc≥0 时跳过 GDScript。
	# 任务 4 实装 C++ 主体之前，C++ 始终返回 -1 → 自动 fallback；本接入点行为
	# 与原版 GDScript 调用完全等价（含 distribute_ms_field 计时口径）。
	var n_cells: int = cells.size()
	var distribute_ms_field: float = 0.0
	var dist_done_by_cpp: bool = false
	if solver._weather_system._use_gdext_weather_distribute and solver._weather_system._data_core_world_ext != null:
		if not solver._weather_system._gdext_dist_first_attempt_logged:
			solver._weather_system._gdext_dist_first_attempt_logged = true
			print("[weather/dist] first fast-path attempt: n_cells=%d ext_bound=%s" % [
				n_cells, str(solver._weather_system._data_core_world_ext != null)
			])
		# 任务 5 verify：开启时先 snapshot 5 个 SoA/AoS 字段，跑完 C++ 后由
		# _verify_gdext_distribute_against_gdscript 复位 + 跑 GDScript + 比对。
		var verify_on: bool = solver._weather_system._distribute_verify_enabled
		var snap_temp: PackedFloat32Array = PackedFloat32Array()
		var snap_moist: PackedFloat32Array = PackedFloat32Array()
		var snap_cover: PackedByteArray = PackedByteArray()
		var snap_acc: PackedInt32Array = PackedInt32Array()
		var snap_pre: PackedInt32Array = PackedInt32Array()
		if verify_on:
			snap_temp = map.temp_arr.duplicate()
			snap_moist = map.moisture_arr.duplicate()
			snap_cover = map.cover_arr.duplicate()
			snap_acc.resize(n_cells)
			snap_pre.resize(n_cells)
			var verify_cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
			for vi in range(n_cells):
				var vc: HexCell = verify_cells[vi]
				snap_acc[vi] = vc.accumulated_snow_days
				snap_pre[vi] = vc.pre_snow_cover
		var dist_rc: Dictionary = solver._weather_system._try_run_weather_distribute_gdext(map, n_cells)
		var dist_elapsed: float = float(dist_rc.get("elapsed_ms", -1.0))
		if dist_elapsed >= 0.0:
			distribute_ms_field = dist_elapsed
			# 把 C++ pass 写好的 cover_dirty 状态同步到 GDScript（dist 主路径
			# 在 GDScript 版里也只通过 _cover_dirty 让下游 cover atlas 决定是否重 bake）。
			solver._weather_system._cover_dirty = bool(dist_rc.get("cover_dirty", false)) or solver._weather_system._cover_dirty
			solver._weather_system._gdext_dist_runs += 1
			solver._weather_system._gdext_dist_total_ms += dist_elapsed
			if solver._weather_system._gdext_dist_runs == 1:
				print("[weather/dist] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 11.6ms; charter target < 1.5ms)" % dist_elapsed)
			dist_done_by_cpp = true
			if verify_on:
				dist_rc["snap_temp"] = snap_temp
				dist_rc["snap_moist"] = snap_moist
				dist_rc["snap_cover"] = snap_cover
				dist_rc["snap_acc"] = snap_acc
				dist_rc["snap_pre"] = snap_pre
				solver._weather_system._verify_gdext_distribute_against_gdscript(map, n_cells, dist_rc)
		else:
			solver._weather_system._gdext_dist_fallbacks += 1
	if not dist_done_by_cpp:
		if solver._weather_system.has_method("_sync_weather_distribute_cache_to_cells"):
			solver._weather_system._sync_weather_distribute_cache_to_cells(map, n_cells)
		solver._weather_system._distribute_weather_field_to_cells(map)
		distribute_ms_field = (Time.get_ticks_usec() - t_us0_field) / 1000.0

	t_us0_field = Time.get_ticks_usec()
	# Weather Hot-Path（plan/weather-hotpath-cpp）任务 6：summary fronts pass
	# fast-path。flag + ext 非空时优先走 C++；rc<0 自动降级到 GDScript（节流告警）。
	# 任务 8：verify on 时先 snapshot C++ state，跑 C++ 取得 fronts_cpp 后，
	# 由 _verify_gdext_summary_against_gdscript 内部 restore + 跑 GDScript +
	# 比较；commit 始终用 fronts_cpp。
	var summary_done_by_cpp: bool = false
	if solver._weather_system._use_gdext_weather_summary and solver._weather_system._data_core_world_ext != null:
		if not solver._weather_system._gdext_summary_first_attempt_logged:
			solver._weather_system._gdext_summary_first_attempt_logged = true
			print("[weather/summary] first fast-path attempt: n_cells=%d ext_bound=%s" % [
				map.cell_count(), str(solver._weather_system._data_core_world_ext != null)
			])
		var summary_verify_on: bool = solver._weather_system._summary_verify_enabled
		if summary_verify_on:
			solver._weather_system._data_core_world_ext.snapshot_weather_summary_state()
		var fronts_v: Variant = solver._weather_system._try_run_weather_summary_fronts_gdext(map, world)
		if fronts_v != null:
			var fronts_cpp: Array[WeatherFront] = fronts_v
			if summary_verify_on:
				solver._weather_system._verify_gdext_summary_against_gdscript(map, world, fronts_cpp)
			solver._weather_system._active_fronts = fronts_cpp
			summary_done_by_cpp = true
	if not summary_done_by_cpp:
		solver._weather_system._active_fronts = solver._weather_system._build_field_summary_fronts(map, world)
	var summary_ms: float = (Time.get_ticks_usec() - t_us0_field) / 1000.0

	var cyclone_ms_field: float = 0.0
	if solver._weather_system._cyclone_wake_enabled:
		t_us0_field = Time.get_ticks_usec()
		# dots-monolith-split §1.1：cyclone_wake 已迁出至 DCWeatherFrontAdvect。
		solver._weather_system._advect.tick_cyclone_wake(map)
		cyclone_ms_field = (Time.get_ticks_usec() - t_us0_field) / 1000.0

	var solve_ms: float = solver._field_slice_solve_ms
	var last_solve_ms: float = solver._field_slice_last_ms
	var breakdown: Dictionary = {
		"advance_ms": last_solve_ms,
		"spawn_ms": summary_ms,
		"distribute_ms": distribute_ms_field,
		"cyclone_ms": cyclone_ms_field,
		"field_solve_ms": last_solve_ms,
		"field_solve_total_ms": solve_ms,
		"field_summary_ms": summary_ms,
		"field_commit_total_ms": commit_total_ms,
		"field_commit_setup_ms": commit_setup_ms,
		"field_commit_loop_ms": commit_loop_ms,
		"field_commit_path": commit_path,
		"field_commit_publish_verified": commit_publish_verified,
		"field_commit_publish_repaired": commit_publish_repaired,
		"field_commit_init_count": commit_visible_init_count,
		"field_commit_publish_reason": commit_publish_reason,
		"field_commit_dc_ms": commit_dc_ms,
		"field_commit_convergence_ms": commit_convergence_ms,
		"field_solve_tick": solver._weather_system._field_solve_tick,
		"field_convergence_refresh_stride": solver._weather_system._field_convergence_refresh_stride,
		"refresh_convergence": solver._field_slice_refresh_convergence,
		"native_convergence_boost": solver._field_slice_native_convergence_boost,
		"weather_convergence_dirty_count": convergence_delta_count,
		"weather_convergence_delta_p95": convergence_delta_p95,
		"convergence_published": solver._field_slice_refresh_convergence \
				and (solver._field_slice_native_convergence_boost or commit_convergence_ms > 0.0 or convergence_delta_count > 0),
		"weather_dirty_count": weather_dirty_count,
		"weather_lut": native_weather_lut,
		"weather_lut_changed": native_weather_lut_changed,
		"weather_lut_dirty_count": native_weather_lut_dirty_count,
		"weather_lut_full_rebuild": native_weather_lut_full_rebuild,
		"water_budget_error": water_budget_error_acc / float(maxi(commit_n, 1)),

		"active_weather_ratio": float(weather_dirty_count) / float(maxi(commit_n, 1)),
		"weather_tick_ms": last_solve_ms + distribute_ms_field + summary_ms + cyclone_ms_field,
	}
	breakdown.merge(solver._weather_system._front_diagnostic_counts(solver._weather_system._active_fronts), true)
	breakdown.merge(solver._weather_system._mark_weather_commit_tick(), true)
	solver._weather_system._last_breakdown = breakdown
	# 任务 9：节流式回归告警（dist/summary 各自门槛 × 2 ring buffer 检测）
	solver._weather_system.push_dist_perf_sample(distribute_ms_field)
	solver._weather_system.push_summary_perf_sample(summary_ms)
	solver._weather_system._last_map_for_query = map
	solver._weather_system._current_map_for_tick = null
	solver._weather_system._tick_cell_pos.clear()
	solver._weather_system._tick_cell_neighbors.clear()
	solver._weather_system._clear_weather_field_slice_state()
	return solver._weather_system._active_fronts


# region PR-1 — neighbor / advect helpers (dots-monolith-split §1.2 / PR-1)
#
# 9 个无状态 helper 已从 weather_system.gd 整体搬迁到 field_solver。weather_system
# 端原同名 `_xxx` 私有方法保留为薄转发，所有 hot-loop / 物理项 helper / owner 自身
# 的内部调用都最终落到下面的实现上。
#
# 依赖（通过 _weather_system 访问）：
#   - _weather_system._field_advect_steps      : int     业务旋钮（保留在 weather_system）
#   - _weather_system._hex_size                : float   网格尺度
#   - _weather_system._cell_neighbors(cell,map): Array   1 环邻居（HexCell）
#   - _weather_system._cell_world_pos(cell)    : Vector2 世界坐标
#   - _weather_system._prev_vapor_cached(...)  : float   PackedFloat32Array 视图取值
#
# 所有跨 helper 调用走 self.xxx（同类内），保证 weather_system 转发后语义不变。
