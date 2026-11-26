extends RefCounted

const AsyncInputs = preload("res://scripts/simulation/climate/climate_async_inputs.gd")

const RuntimeFinalization = preload("res://scripts/simulation/climate/climate_runtime_finalization.gd")

## ClimateDailySystem runtime helpers. The host owns all mutable state.

func _get_soak_dump_instance(host):
	return RuntimeFinalization._get_soak_dump_instance(host)


func _should_sync_runtime_terrain_views(host, reason: String) -> bool:
	return RuntimeFinalization._should_sync_runtime_terrain_views(host, reason)


func _sync_runtime_terrain_views_for_reason(host, reason: String) -> Dictionary:
	return RuntimeFinalization._sync_runtime_terrain_views_for_reason(host, reason)


func _standalone_sea_ice_enabled(host) -> bool:
	return RuntimeFinalization._standalone_sea_ice_enabled(host)


func _sync_runtime_terrain_views(host, reason: String) -> Dictionary:
	return RuntimeFinalization._sync_runtime_terrain_views(host, reason)


static func _percentile_from_sorted(values, p: float) -> float:
	return RuntimeFinalization._percentile_from_sorted(values, p)


func _calendar_days_per_year(host) -> int:
	return RuntimeFinalization._calendar_days_per_year(host)


func _is_annual_log_tick(host, counter: int) -> bool:
	return RuntimeFinalization._is_annual_log_tick(host, counter)


static func _build_finalizer_diag_from_worker(poll: Dictionary) -> Dictionary:
	return RuntimeFinalization._build_finalizer_diag_from_worker(poll)


func _async_finalizer_fallback_reason(host, poll: Dictionary) -> String:
	return RuntimeFinalization._async_finalizer_fallback_reason(host, poll)


func _apply_daily_climate_finalizer(host) -> Dictionary:
	return RuntimeFinalization._apply_daily_climate_finalizer(host)


static func _climate_diag_terrain_water(t: int) -> bool:
	return RuntimeFinalization._climate_diag_terrain_water(t)


static func _climate_diag_ocean_water(t: int) -> bool:
	return RuntimeFinalization._climate_diag_ocean_water(t)


func _climate_diag_corr(host, a: PackedFloat32Array, b: PackedFloat32Array, limit: int) -> float:
	return RuntimeFinalization._climate_diag_corr(host, a, b, limit)


func _climate_diag_p95(host, arr: PackedFloat32Array, limit: int) -> float:
	return RuntimeFinalization._climate_diag_p95(host, arr, limit)


static func _climate_diag_push_sample(samples: PackedStringArray, text: String) -> void:
	RuntimeFinalization._climate_diag_push_sample(samples, text)


func _debug_climate_integrity(host, stage_name: String, force: bool = false) -> void:
	RuntimeFinalization._debug_climate_integrity(host, stage_name, force)


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
	return AsyncInputs._build_async_kick_input(host, season_phase)


func _build_async_static_knobs(host) -> Dictionary:
	return AsyncInputs._build_async_static_knobs(host)


func _handle_async_sea_ice_flips(host, poll_result: Dictionary) -> void:
	AsyncInputs._handle_async_sea_ice_flips(host, poll_result)
