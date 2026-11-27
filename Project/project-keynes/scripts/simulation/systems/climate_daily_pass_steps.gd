extends RefCounted

## Coordinates the individual climate passes and transpiration slices.


static func _run_pass(owner: ClimateDailySystem, pass_id: int) -> bool:
	var token: int = owner._active_pass_token
	var t_us0: int = Time.get_ticks_usec()
	# refresh-consolidation-2026-06：跨 pass 边界处理 climate_daily round 守门员。
	# 凡是依赖前序 pass 写入 MapData 的 pass，进入前 mark stale 让 ensure 真实 refresh。
	# - PASS_A：round 入口已 mark stale，不需要再 mark
	# - PASS_B / OCEAN_LAND / SEA_ICE / TRANSP：读前序 pass flush 到 MapData 的输出
	# - WIND_AIR / WIND_SURFACE：仅读已 sync 的 C++ slot 内的 temp/wind/anomaly，跳过
	# - OCEAN_WATER：紧跟 pass_b 之后；pass_b 已改 moisture/local_anom 并 flush
	if owner.generator != null and owner.generator.has_method("_mark_climate_daily_round_slots_stale"):
		match pass_id:
			owner._PASS_B, owner._PASS_OCEAN_WATER, owner._PASS_OCEAN_LAND, owner._PASS_SEA_ICE, owner._PASS_TRANSP:
				owner.generator._mark_climate_daily_round_slots_stale()
	match pass_id:
		owner._PASS_A:
			owner.generator._climate_pass_a(owner.map, owner._phase_locked)
			owner._round_t_pass_a_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
			var r_a: Dictionary = owner._make_pass_result(true, owner._round_t_pass_a_ms, owner.map.cell_count(), 0, owner.map.cell_count())
			owner._record_pass_result(pass_id, token, r_a, owner._round_t_pass_a_ms, "pass_a", "native_or_gd", "data_core" if owner.data_core_ready() else "data_core_cells_only")
			return true
		owner._PASS_B:
			owner.generator._climate_pass_b(owner.map, owner._phase_locked)
			owner._round_t_pass_b_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
			var r_b: Dictionary = owner._make_pass_result(true, owner._round_t_pass_b_ms, owner.map.cell_count(), 0, owner.map.cell_count())
			var pb_substage: String = "pass_b_%s" % str(owner.generator._last_climate_pass_b_path) if owner.generator != null and "_last_climate_pass_b_path" in owner.generator else "pass_b"
			owner._record_pass_result(pass_id, token, r_b, owner._round_t_pass_b_ms, "pass_b", pb_substage, "data_core" if owner.data_core_ready() else "data_core_cells_only")
			return true
		owner._PASS_OCEAN_WATER:
			if owner.generator.has_method("run_ocean_water_pass_slice"):
				var r_w: Dictionary = owner.generator.run_ocean_water_pass_slice(owner.map, owner._phase_locked)
				owner._round_t_ocean_ms += float(r_w.get("elapsed_ms", 0.0))
				owner._record_pass_result(pass_id, token, r_w, float(r_w.get("elapsed_ms", 0.0)), "ocean_water", "range_cursor", "native_chunk")
				return bool(r_w.get("done", true))
			else:
				owner.generator._ocean_water_pass(owner.map, owner._phase_locked)
				var ow_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
				owner._round_t_ocean_ms += ow_ms
				var r_ow: Dictionary = owner._make_pass_result(true, ow_ms, owner.map.cell_count(), 0, owner.map.cell_count())
				owner._record_pass_result(pass_id, token, r_ow, ow_ms, "ocean_water", "oneshot", "gdscript")
				return true
		owner._PASS_OCEAN_LAND:
			if owner.generator.has_method("run_ocean_land_pass_slice"):
				var r_l: Dictionary = owner.generator.run_ocean_land_pass_slice(owner.map, owner._phase_locked)
				owner._round_t_ocean_ms += float(r_l.get("elapsed_ms", 0.0))
				owner._record_pass_result(pass_id, token, r_l, float(r_l.get("elapsed_ms", 0.0)), "ocean_land", "range_cursor", "native_chunk")
				return bool(r_l.get("done", true))
			else:
				owner.generator._ocean_land_pass(owner.map, owner._phase_locked)
				var ol_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
				owner._round_t_ocean_ms += ol_ms
				var r_ol: Dictionary = owner._make_pass_result(true, ol_ms, owner.map.cell_count(), 0, owner.map.cell_count())
				owner._record_pass_result(pass_id, token, r_ol, ol_ms, "ocean_land", "oneshot", "gdscript")
				return true
		owner._PASS_WIND_AIR:
			# climate-loop-closure Phase 1.1：风温气团段（沿 -wind 回溯混合上风温度）。
			var r_wa: Dictionary
			if owner.generator.has_method("run_wind_air_mass_pass_native"):
				r_wa = owner.generator.run_wind_air_mass_pass_native(owner.map, owner._phase_locked)
			else:
				owner.generator._wind_air_mass_pass(owner.map, owner._phase_locked)
				var wa_fb_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
				r_wa = owner._make_pass_result(true, wa_fb_ms, owner.map.cell_count(), 0, owner.map.cell_count())
				r_wa["path"] = "gdscript"
				r_wa["stage"] = "oneshot"
			var wa_ms: float = float(r_wa.get("elapsed_ms", (Time.get_ticks_usec() - t_us0) / 1000.0))
			owner._round_t_wind_ms += wa_ms
			owner._record_pass_result(pass_id, token, r_wa, wa_ms, "wind_air",
				str(r_wa.get("stage", "oneshot")), str(r_wa.get("path", "gdscript")))
			return true
		owner._PASS_WIND_SURFACE:
			# 必须在 wind_air 之后：读取气团段写入的 air_mass_temp_anomaly 注入地表温度。
			var r_ws: Dictionary
			if owner.generator.has_method("run_wind_surface_pass_native"):
				r_ws = owner.generator.run_wind_surface_pass_native(owner.map, owner._phase_locked)
			else:
				owner.generator._wind_surface_pass(owner.map, owner._phase_locked)
				var ws_fb_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
				r_ws = owner._make_pass_result(true, ws_fb_ms, owner.map.cell_count(), 0, owner.map.cell_count())
				r_ws["path"] = "gdscript"
				r_ws["stage"] = "oneshot"
			var ws_ms: float = float(r_ws.get("elapsed_ms", (Time.get_ticks_usec() - t_us0) / 1000.0))
			owner._round_t_wind_ms += ws_ms
			owner._record_pass_result(pass_id, token, r_ws, ws_ms, "wind_surface",
				str(r_ws.get("stage", "oneshot")), str(r_ws.get("path", "gdscript")))
			return true
		owner._PASS_SEA_ICE:
			if owner.generator.has_method("run_climate_pass_slice"):
				var r_si: Dictionary = owner.generator.run_climate_pass_slice("sea_ice", owner.map, owner._phase_locked)
				owner._round_t_sea_ice_ms += float(r_si.get("elapsed_ms", 0.0))
				owner._sync_runtime_terrain_views("sea_ice_slice")
				owner._record_pass_result(pass_id, token, r_si, float(r_si.get("elapsed_ms", 0.0)), "sea_ice", str(r_si.get("stage", "state_machine")), "climate_chunk_api")
				return bool(r_si.get("done", true))
			else:
				owner.generator._apply_sea_ice_daily_pass(owner.map, owner._phase_locked)
				owner._round_t_sea_ice_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
				var r_si: Dictionary = owner._make_pass_result(true, owner._round_t_sea_ice_ms, owner.map.cell_count(), 0, owner.map.cell_count())
				owner._sync_runtime_terrain_views("sea_ice_fallback")
				owner._record_pass_result(pass_id, token, r_si, owner._round_t_sea_ice_ms, "sea_ice", "oneshot_fallback", "native_or_gd")
				return true
		owner._PASS_TRANSP:
			var r_tr: Dictionary = owner._run_transpiration_pass_slice()
			var tr_ms: float = float(r_tr.get("elapsed_ms", 0.0))
			owner._round_t_transp_ms += tr_ms
			owner._record_pass_result(pass_id, token, r_tr, tr_ms,
				"transp", str(r_tr.get("stage", "sliced")), str(r_tr.get("path", "gdscript_sliced")))
			return bool(r_tr.get("done", true))
	return true



static func _begin_transpiration_sliced(owner: ClimateDailySystem) -> void:
	if owner.map == null:
		owner._transp_stage = owner._TRANSP_STAGE_DONE
		return
	owner._transp_cells = owner.map.iter_cells() if owner.map.has_indices() else owner.map.all_cells()
	owner._transp_n_cells = owner._transp_cells.size()
	owner._transp_neighbor_indices = owner.map.neighbor_indices_packed() if owner.map.has_indices() else PackedInt32Array()
	owner._transp_fast_indexed = owner._transp_neighbor_indices.size() >= owner._transp_n_cells * 6
	owner._transp_landform_arr = owner.map.landform_arr
	owner._transp_vegetation_arr = owner.map.vegetation_arr
	owner._transp_moisture_arr = owner.map.moisture_arr
	if owner.generator != null and owner.generator.has_method("_build_transpiration_donor_table"):
		owner._transp_donor_table = owner.generator._build_transpiration_donor_table()
	else:
		owner._transp_donor_table = PackedFloat32Array()
		owner._transp_donor_table.resize(VegetationType.VEG.size())
		for v in range(owner._transp_donor_table.size()):
			owner._transp_donor_table[v] = VegetationType.transpiration(v)
	owner._transp_deltas = PackedFloat32Array()
	owner._transp_deltas.resize(owner._transp_n_cells)
	owner._transp_cursor = 0
	owner._transp_stage = owner._TRANSP_STAGE_COMPUTE if owner._transp_n_cells > 0 else owner._TRANSP_STAGE_DONE



static func _transp_stage_label(owner: ClimateDailySystem, stage_id: int) -> String:
	match stage_id:
		owner._TRANSP_STAGE_COMPUTE:
			return "compute"
		owner._TRANSP_STAGE_APPLY:
			return "apply"
		owner._TRANSP_STAGE_DONE:
			return "done"
		_:
			return "idle"



static func _transp_should_yield(owner: ClimateDailySystem, t_us0: int, processed: int) -> bool:
	if processed < owner._TRANSP_MIN_CELLS_PER_SLICE:
		return false
	if processed % owner._TRANSP_TIME_CHECK_INTERVAL != 0:
		return false
	var elapsed_ms: float = float(Time.get_ticks_usec() - t_us0) / 1000.0
	return elapsed_ms >= maxf(0.2, owner.slice_budget_ms)



static func _transp_is_water_idx(owner: ClimateDailySystem, idx: int) -> bool:
	if idx >= 0 and idx < owner._transp_landform_arr.size():
		return int(owner._transp_landform_arr[idx]) <= owner._TRANSP_WATER_LANDFORM_MAX
	if idx >= 0 and idx < owner._transp_cells.size():
		var cell: HexCell = owner._transp_cells[idx]
		return cell == null or LandformType.is_water(cell.landform)
	return true



static func _transp_factor_idx(owner: ClimateDailySystem, idx: int) -> float:
	if idx < 0 or idx >= owner._transp_vegetation_arr.size():
		return 0.0
	var veg_id: int = int(owner._transp_vegetation_arr[idx])
	if veg_id < 0 or veg_id >= owner._transp_donor_table.size():
		return 0.0
	return owner._transp_donor_table[veg_id]



static func _transp_moisture_idx(owner: ClimateDailySystem, idx: int) -> float:
	if idx >= 0 and idx < owner._transp_moisture_arr.size():
		return owner._transp_moisture_arr[idx]
	if idx >= 0 and idx < owner._transp_cells.size():
		var cell: HexCell = owner._transp_cells[idx]
		return cell.moisture if cell != null else 0.0
	return 0.0



static func _run_transpiration_pass_slice(owner: ClimateDailySystem) -> Dictionary:
	if owner._transp_stage == owner._TRANSP_STAGE_IDLE:
		if owner.generator != null and owner.generator.has_method("run_transpiration_pass_native"):
			var native_result: Dictionary = owner.generator.run_transpiration_pass_native(owner.map)
			if bool(native_result.get("done", false)) and str(native_result.get("path", "")) == "gdext":
				owner._transp_stage = owner._TRANSP_STAGE_DONE
				owner._transp_cursor = int(native_result.get("processed_cells", owner.map.cell_count() if owner.map != null else 0))
				owner._transp_n_cells = owner._transp_cursor
				native_result["status"] = owner._PASS_RESULT_DONE
				native_result["budget_interrupted"] = false
				return native_result
		owner._begin_transpiration_sliced()
	var t_us0: int = Time.get_ticks_usec()
	var stage_at_start: int = owner._transp_stage
	var cursor_start: int = owner._transp_cursor
	var processed: int = 0

	if owner._transp_stage == owner._TRANSP_STAGE_COMPUTE:
		var cp = owner.generator._c() if owner.generator != null else null
		var outflow_rate: float = 0.025
		var self_rate: float = 0.015
		if cp != null:
			if cp.get("transpiration_outflow_rate") != null:
				outflow_rate = float(cp.transpiration_outflow_rate)
			if cp.get("transpiration_self_rate") != null:
				self_rate = float(cp.transpiration_self_rate)
		var nb_share_factor: float = outflow_rate / 6.0
		while owner._transp_cursor < owner._transp_n_cells:
			var i: int = owner._transp_cursor
			owner._transp_cursor += 1
			processed += 1
			if owner._transp_is_water_idx(i):
				if owner._transp_should_yield(t_us0, processed):
					break
				continue
			var trans: float = owner._transp_factor_idx(i)
			if trans >= 0.01:
				var output: float = trans * owner._transp_moisture_idx(i)
				owner._transp_deltas[i] = owner._transp_deltas[i] + output * self_rate
				var nb_share: float = output * nb_share_factor
				if owner._transp_fast_indexed:
					var base: int = i * 6
					for d_idx in range(6):
						var nb_idx: int = owner._transp_neighbor_indices[base + d_idx]
						if nb_idx < 0 or nb_idx >= owner._transp_n_cells:
							continue
						if owner._transp_is_water_idx(nb_idx):
							continue
						owner._transp_deltas[nb_idx] = owner._transp_deltas[nb_idx] + nb_share
				else:
					var cell: HexCell = owner._transp_cells[i]
					if cell == null:
						if owner._transp_should_yield(t_us0, processed):
							break
						continue
					for nb: HexCell in owner.map.get_neighbors(cell):
						if nb == null or LandformType.is_water(nb.landform):
							continue
						var nb_idx_fallback: int = owner.map.index_of(nb)
						if nb_idx_fallback >= 0 and nb_idx_fallback < owner._transp_n_cells:
							owner._transp_deltas[nb_idx_fallback] = owner._transp_deltas[nb_idx_fallback] + nb_share
			if owner._transp_should_yield(t_us0, processed):
				break
		if owner._transp_cursor >= owner._transp_n_cells:
			owner._transp_stage = owner._TRANSP_STAGE_APPLY
			owner._transp_cursor = 0

	elif owner._transp_stage == owner._TRANSP_STAGE_APPLY:
		var dirty_idx: PackedInt32Array = PackedInt32Array()
		var dirty_val: PackedFloat32Array = PackedFloat32Array()
		var has_moisture_arr: bool = owner.map != null and owner.map.moisture_arr.size() == owner._transp_n_cells
		while owner._transp_cursor < owner._transp_n_cells:
			var i: int = owner._transp_cursor
			owner._transp_cursor += 1
			processed += 1
			var d: float = owner._transp_deltas[i]
			if d != 0.0:
				var cell: HexCell = owner._transp_cells[i]
				if cell != null:
					var new_moist: float = clampf(owner._transp_moisture_idx(i) + d, 0.0, 1.0)
					if i < owner._transp_moisture_arr.size():
						owner._transp_moisture_arr[i] = new_moist
					if has_moisture_arr:
						owner.map.moisture_arr[i] = new_moist
					cell.moisture = new_moist
					dirty_idx.append(i)
					dirty_val.append(new_moist)
			if owner._transp_should_yield(t_us0, processed):
				break
		if owner._world != null and owner._world.is_bound() and dirty_idx.size() > 0:
			var cid_moist: int = int(owner._cid.get(DCComponentIds.CELL_MOISTURE, -1))
			if cid_moist >= 0 and owner._world.has_method("write_f32_indexed"):
				owner._world.write_f32_indexed(cid_moist, dirty_idx, dirty_val)
		if owner._transp_cursor >= owner._transp_n_cells:
			owner._transp_stage = owner._TRANSP_STAGE_DONE

	var elapsed_ms: float = float(Time.get_ticks_usec() - t_us0) / 1000.0
	var done: bool = owner._transp_stage == owner._TRANSP_STAGE_DONE
	var cursor_end: int = owner._transp_cursor
	if stage_at_start == owner._TRANSP_STAGE_COMPUTE and owner._transp_stage == owner._TRANSP_STAGE_APPLY:
		cursor_end = owner._transp_n_cells
	var stage_label: String = owner._transp_stage_label(stage_at_start)
	if stage_at_start == owner._TRANSP_STAGE_COMPUTE:
		stage_label = "compute_fast" if owner._transp_fast_indexed else "compute_fallback"
	return {
		"done": done,
		"status": owner._PASS_RESULT_DONE if done else owner._PASS_RESULT_CONTINUE,
		"elapsed_ms": elapsed_ms,
		"processed_cells": processed,
		"cursor_start": cursor_start,
		"cursor_end": cursor_end,
		"cursor_remaining": maxi(0, owner._transp_n_cells - owner._transp_cursor),
		"budget_interrupted": not done,
		"stage": stage_label,
		"next_stage": owner._transp_stage_label(owner._transp_stage),
		"budget_cells": owner._TRANSP_MIN_CELLS_PER_SLICE,
		"path": "gdscript_sliced",
	}
