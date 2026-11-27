extends RefCounted

## Publishes partial and completed climate work and reports the current round.


static func _publish_partial_round(owner: ClimateDailySystem, pass_id: int, slice_elapsed_ms: float, progress: float) -> void:
	if owner.generator == null:
		return
	var pass_name: String = ""
	if pass_id >= 0 and pass_id < owner._PASS_NAMES.size():
		pass_name = owner._PASS_NAMES[pass_id]
	# A.2.1.A5 — partial round 也带上 dirty/visited 指标，便于切片观察
	var dirty_ratio_out: float = 1.0
	var visited_ratio_out: float = 1.0
	var pass_b_path_out: String = "full"
	dirty_ratio_out = float(owner.generator._last_climate_dirty_ratio) if "_last_climate_dirty_ratio" in owner.generator else 1.0
	visited_ratio_out = float(owner.generator._last_climate_visited_ratio) if "_last_climate_visited_ratio" in owner.generator else 1.0
	pass_b_path_out = String(owner.generator._last_climate_pass_b_path) if "_last_climate_pass_b_path" in owner.generator else "full"
	owner.generator._last_climate_breakdown = {
		"pass_a_ms": owner._round_t_pass_a_ms,
		"pass_b_ms": owner._round_t_pass_b_ms,
		"ocean_ms": owner._round_t_ocean_ms,
		"wind_ms": owner._round_t_wind_ms,
		"sea_ice_ms": owner._round_t_sea_ice_ms,
		"ice_bake_ms": 0.0,
		"transp_ms": owner._round_t_transp_ms,
		"total_ms": float(Time.get_ticks_msec() - owner._round_t_round_start_ms),
		"cells": owner.map.cell_count(),
		"partial": true,
		"current_pass": pass_name,
		"slice_ms": slice_elapsed_ms,
		"processed_cells": owner._last_pass_processed_cells,
		"cursor_start": owner._last_pass_cursor_start,
		"cursor_end": owner._last_pass_cursor_end,
		"progress_ratio": progress,
		"budget_interrupted": owner._last_pass_budget_interrupted,
		"pass_status": owner._last_pass_status,
		"pass_token": owner._active_pass_token,
		"pass_diag": owner._last_pass_diag.duplicate(true),
		"transp_native_diag": owner._last_transp_native_diag.duplicate(true),
		"dirty_ratio": dirty_ratio_out,
		"visited_ratio": visited_ratio_out,
		"pass_b_path": pass_b_path_out,
		# 方案 ④ Step 1：写入时打 fast tick 戳，perf_recorder 据此判定 stale 回放
		"_tick_idx": int(owner.generator._current_fast_tick_idx) if "_current_fast_tick_idx" in owner.generator else 0,
	}
	owner._merge_climate_wrapper_diag(owner.generator._last_climate_breakdown)


# ─── 内部：round 结束时把累积埋点写回 generator + 重置游标 ────────────────
static func _finalize_round(owner: ClimateDailySystem, async_poll_result: Dictionary = {}, finalize_tail_boundary_intents: Array = []) -> void:
	var t_finalize_us: int = Time.get_ticks_usec()
	owner._last_finalize_diag = {
		"finalize_total_ms": 0.0,
		"finalize_finalizer_ms": 0.0,
		"finalize_counter_ms": 0.0,
		"finalize_breakdown_ms": 0.0,
		"finalize_annual_log_ms": 0.0,
		"finalize_soa_noop_ms": 0.0,
		"finalize_soak_ms": 0.0,
		"finalize_integrity_ms": 0.0,
		"finalize_finish_pass_ms": 0.0,
		"finalize_reset_transp_ms": 0.0,
		"finalize_flush_dirty_ms": 0.0,
		"finalize_mark_stale_ms": 0.0,
		"finalize_dump_stats_ms": 0.0,
		"finalizer_cpp_worker": false,
		"finalizer_fallback_reason": "",
	}
	if finalize_tail_boundary_intents.is_empty():
		finalize_tail_boundary_intents = owner._default_finalize_tail_boundary_intents(async_poll_result)
	var finalize_exec_diag: Dictionary = owner._execute_finalize_tail_boundary_intents(
		finalize_tail_boundary_intents,
		async_poll_result
	)
	owner._last_finalize_diag["finalize_total_ms"] = float(Time.get_ticks_usec() - t_finalize_us) / 1000.0
	var _async_finalizer_used: bool = bool(finalize_exec_diag.get("finalizer_cpp_worker", false))
	var async_fin_fallback_reason: String = String(finalize_exec_diag.get("finalizer_fallback_reason", ""))
	# Stage 9 / Fix #11 (2026-06-16) STAGE-TOTAL 埋点：观察 C++ worker finalizer 是否启用。
	# 启用时 finalize_total_ms 应 < 3ms（之前 main thread 跑 _apply_*_finalizer 是 13-17ms）。
	# 前 5 round 必打，后续仅 >= 5ms 异常打。
	var _fin_total_ms: float = float(owner._last_finalize_diag["finalize_total_ms"])
	if PKLog.enabled and (owner._fin_stage_log_count < 5 or _fin_total_ms >= 5.0):
		owner._fin_stage_log_count += 1
		print("[climate_finalizer/STAGE-TOTAL] call#%d wall=%.2fms cpp_worker=%s fallback_reason=%s (target: <3ms cpp / 13-17ms gdscript_fallback)" % [
			owner._fin_stage_log_count, _fin_total_ms, str(_async_finalizer_used), async_fin_fallback_reason,
		])
	if owner.generator != null and "_last_climate_breakdown" in owner.generator:
		owner._merge_climate_wrapper_diag(owner.generator._last_climate_breakdown)



static func get_last_pass_diag(owner: ClimateDailySystem) -> Dictionary:
	return owner._last_pass_diag.duplicate(true)



static func climate_round_state_snapshot(owner: ClimateDailySystem) -> Dictionary:
	var current_pass: String = "idle"
	if owner._round_active and owner._pass_cursor >= 0 and owner._pass_cursor < owner._PASS_NAMES.size():
		current_pass = owner._PASS_NAMES[owner._pass_cursor]
	elif owner._finalize_pending:
		current_pass = "round_finalize"
	elif owner._pass_cursor >= owner._PASS_COUNT:
		current_pass = "round_done"
	var active_owner_requested: bool = false
	var cp_owner = owner.generator._c() if owner.generator != null else null
	if cp_owner != null and cp_owner.get("native_climate_round_active_owner_enabled") != null:
		active_owner_requested = bool(cp_owner.native_climate_round_active_owner_enabled)
	var compact_capsule_enabled: bool = cp_owner != null \
			and cp_owner.get("native_daily_compact_state_capsule_enabled") != null \
			and bool(cp_owner.native_daily_compact_state_capsule_enabled)
	var native_state: Dictionary = {}
	var native_ext = owner.generator._data_core_world_ext if owner.generator != null else null
	if native_ext != null and active_owner_requested and compact_capsule_enabled:
		native_state = native_ext.get_native_climate_round_hot_state()
	elif native_ext != null:
		native_state = native_ext.get_native_climate_round_state_report()
	var compact_capsule: bool = bool(native_state.get("compact_state_capsule", false))
	var native_state_for_snapshot: Dictionary = native_state.duplicate(
			not compact_capsule)
	var snapshot_owner: String = "native_ready" if bool(native_state.get("climate_round_authority_ready", false)) else "gdscript_retained"
	if snapshot_owner == "native_ready" and active_owner_requested:
		snapshot_owner = "native_active"
		native_state_for_snapshot["authority"] = "native_active_owner"
		native_state_for_snapshot["simulation_authority"] = true
		native_state_for_snapshot["active_owner_requested"] = true
		native_state_for_snapshot["climate_round_authority_phase"] = "native_active_owner"
		var godot_boundaries: Array = native_state.get("remaining_godot_boundary_authority", [])
		if godot_boundaries.is_empty():
			godot_boundaries = ["godot_mapdata_boundary_execution", "reset_abort_boundary_execution"]
		native_state_for_snapshot["remaining_gdscript_simulation_authority"] = []
		native_state_for_snapshot["remaining_godot_boundary_authority"] = godot_boundaries
		native_state_for_snapshot["remaining_gdscript_authority"] = godot_boundaries
		native_state_for_snapshot["fallback_mode"] = "explicit_failure_only"
		native_state_for_snapshot["single_authority_claim"] = "climate_round_state_machine"
	elif not native_state_for_snapshot.is_empty():
		native_state_for_snapshot["active_owner_requested"] = active_owner_requested
	var native_state_status: String = "native_ready_probe_mirror" if snapshot_owner == "native_ready" else "probe_mirror_only"
	if snapshot_owner == "native_active":
		native_state_status = "native_active_owner_mirror"
	var out: Dictionary = {
		"owner": snapshot_owner,
		"native_state_status": native_state_status,
		"round_active": owner._round_active,
		"pass_cursor": owner._pass_cursor,
		"pass_count": owner._PASS_COUNT,
		"current_pass": current_pass,
		"phase_locked": owner._phase_locked,
		"finalize_pending": owner._finalize_pending,
		"async_round_kicked": owner._async_round_kicked,
		"async_round_poll_attempts": owner._async_round_poll_attempts,
		"async_round_kick_tick": owner._async_round_kick_tick,
		"pass_generation": owner._pass_generation,
		"active_pass_token": owner._active_pass_token,
			"active_pass_state": {} if compact_capsule else owner._active_pass_state.duplicate(true),
			"last_pass_diag": {} if compact_capsule else owner._last_pass_diag.duplicate(true),
		"transp_stage": owner._transp_stage_label(owner._transp_stage),
		"transp_cursor": owner._transp_cursor,
		"transp_n_cells": owner._transp_n_cells,
		"full_sweep_counter": owner._full_sweep_counter,
		"last_phase_int_seen": owner._last_phase_int_seen,
			"reset_owner": "ClimateDailySystem.reset_progress",
			"compact_state_capsule": compact_capsule,
	}
	if not native_state_for_snapshot.is_empty():
		out["native_probe_state"] = native_state_for_snapshot
	return out
