extends RefCounted

## Reports physical and visual stage timing for ocean jobs.


static func _ticks_per_slice_diag(owner: OceanCurrentsJob) -> int:
	if owner._slow_slice_policy != null and owner._slow_slice_policy.has_method("ticks_per_slice"):
		return int(owner._slow_slice_policy.ticks_per_slice())
	if owner.policy != null and owner.policy.has_method("ticks_per_slice"):
		return int(owner.policy.ticks_per_slice())
	return 0



static func _record_phys_diag(owner: OceanCurrentsJob, ctx: SusTickContext, report: Dictionary, done: bool) -> Dictionary:
	owner._sync_legacy_round_state()
	var out: Dictionary = report.duplicate(true)
	out["tick_idx"] = ctx.tick_index
	out["day_index"] = ctx.day_index
	out["daily_wind_due"] = owner._last_daily_wind_tick == ctx.tick_index
	out["phase_locked"] = owner._phase_locked
	out["round_active"] = owner._round_active
	out["phys_solve_done"] = owner._phys_solve_done
	out["need_pixel"] = owner._need_pixel_this_round
	out["run_ocean"] = owner._run_ocean_this_round
	out["phase_int_seen"] = owner._phase_int_seen
	out["pending_commit"] = owner._pending_commit
	out["next_pixel_idx"] = owner._next_pixel_idx
	out["total_pixels"] = owner._total_pixels
	out["phys_round_active"] = owner._phys_round_active
	out["visual_round_active"] = owner._visual_round_active
	out["physical_round_id"] = owner._physical_round_id
	out["visual_round_id"] = owner._visual_round_id
	out["phys_phase_locked"] = owner._phys_phase_locked
	out["visual_phase_locked"] = owner._visual_phase_locked
	out["visual_pending_commit"] = owner._visual_pending_commit
	out["visual_next_pixel_idx"] = owner._visual_next_pixel_idx
	out["visual_total_pixels"] = owner._visual_total_pixels
	out["visual_pixel_progress"] = float(owner._visual_next_pixel_idx) / float(max(1, owner._visual_total_pixels)) if owner._visual_round_active else 1.0
	out["visual_lag_ticks"] = owner._visual_lag_ticks(ctx)
	out["current_pixel_quota"] = owner._current_pixel_quota_diag
	out["wind_period_ticks"] = owner.wind_period_ticks
	out["ocean_period_ticks"] = owner.ocean_period_ticks
	out["slow_period_ticks"] = owner.ocean_period_ticks
	out["slice_count"] = owner.slice_count
	out["ticks_per_slice"] = owner._ticks_per_slice_diag()
	for daily_key in owner._last_daily_wind_report.keys():
		out["daily_wind_" + str(daily_key)] = owner._last_daily_wind_report[daily_key]
	out["done"] = done
	owner._native_ocean_physical_step(ctx, out)
	if not owner._native_ocean_state.is_empty():
		out["native_ocean_state"] = owner._native_ocean_state.duplicate(true)
	owner._last_phys_diag = out.duplicate(true)
	return out



static func last_physical_diag(owner: OceanCurrentsJob) -> Dictionary:
	return owner._last_phys_diag.duplicate(true)



static func ocean_physical_state_snapshot(owner: OceanCurrentsJob) -> Dictionary:
	owner._sync_legacy_round_state()
	var native_path_ready: bool = str(owner._last_phys_diag.get("path", "")).begins_with("gdext") \
			or str(owner._last_daily_wind_report.get("path", "")).begins_with("gdext")
	var active_owner_requested: bool = false
	var cp = owner.cfg.climate_profile if owner.cfg != null else null
	if cp != null and cp.get("native_ocean_physical_active_owner_enabled") != null:
		active_owner_requested = bool(cp.native_ocean_physical_active_owner_enabled)
	var compact_capsule_enabled: bool = cp != null \
			and cp.get("native_daily_compact_state_capsule_enabled") != null \
			and bool(cp.native_daily_compact_state_capsule_enabled)
	if active_owner_requested and compact_capsule_enabled \
			and owner.data_core_world_ext != null:
		owner._native_ocean_state = owner.data_core_world_ext.get_native_ocean_physical_hot_state()
	elif owner.data_core_world_ext != null:
		owner._native_ocean_state = owner.data_core_world_ext.get_native_ocean_physical_state_report()
	var compact_capsule: bool = bool(owner._native_ocean_state.get(
			"compact_state_capsule", false))
	var native_lifecycle_ready: bool = not owner._native_ocean_state.is_empty()
	var authority: String = "gdscript_retained"
	if native_lifecycle_ready and active_owner_requested:
		authority = "native_active"
	elif native_lifecycle_ready:
		authority = "native_ready"
	elif native_path_ready:
		authority = "native_ready_probe"
	var snapshot: Dictionary = {
		"owner": authority,
		"native_state_status": "native_lifecycle_facade" if native_lifecycle_ready else "probe_mirror_only",
		"active_owner_requested": active_owner_requested,
		"simulation_authority": native_lifecycle_ready and active_owner_requested,
		"physical_round_active": owner._phys_round_active,
		"physical_round_id": owner._physical_round_id,
		"physical_phase_locked": owner._phys_phase_locked,
		"physical_need_visual": owner._phys_need_visual,
		"physical_run_ocean": owner._phys_run_ocean_this_round,
		"phys_solve_done": owner._phys_solve_done,
		"last_physical_complete_tick": owner._last_physical_complete_tick,
		"visual_round_active": owner._visual_round_active,
		"visual_round_id": owner._visual_round_id,
		"visual_phase_locked": owner._visual_phase_locked,
		"visual_next_pixel_idx": owner._visual_next_pixel_idx,
		"visual_total_pixels": owner._visual_total_pixels,
		"visual_pending_commit": owner._visual_pending_commit,
		"phase_int_seen": owner._phase_int_seen,
		"wind_period_ticks": owner.wind_period_ticks,
		"ocean_period_ticks": owner.ocean_period_ticks,
		"slice_count": owner.slice_count,
			"last_phys_diag": {} if compact_capsule else owner._last_phys_diag.duplicate(true),
			"last_daily_wind_report": {} if compact_capsule else owner._last_daily_wind_report.duplicate(true),
			"compact_state_capsule": compact_capsule,
		"remaining_gdscript_authority": [
			"visual_raster_boundary_execution",
			"texture_commit_boundary_execution",
		],
		"native_owned_output_slots": [
			"cell_wind_x",
			"cell_wind_y",
			"cell_ocean_current_x",
			"cell_ocean_current_y",
			"cell_upwelling",
		],
	}
	if not owner._native_ocean_state.is_empty():
		snapshot["native_lifecycle_state"] = owner._native_ocean_state.duplicate(
				not compact_capsule)
		snapshot["native_owned_lifecycle_authority"] = owner._native_ocean_state.get("native_owned_lifecycle_authority", [
			"physical_round_active",
			"physical_round_id",
			"phase_locked",
			"physical_stage",
			"physical_stage_cursor",
		])
	return snapshot



static func _log_should_skip(owner: OceanCurrentsJob, ctx: SusTickContext, reason: String, detail: String = "") -> void:
	if owner._ocean_policy_diag_count >= 32:
		return
	if not PKLog.enabled:
		return
	owner._ocean_policy_diag_count += 1
	var suffix: String = ""
	if detail != "":
		suffix = " " + detail
	print("[ocean_currents][RT] skip#%d tick=%d reason=%s phys_round=%s visual_round=%s phys_done=%s pending_commit=%s cursor=%d/%d tps=%d streak=%d%s" % [
		owner._ocean_policy_diag_count, ctx.tick_index, reason, str(owner._phys_round_active), str(owner._visual_round_active),
		str(owner._phys_solve_done), str(owner._visual_pending_commit), owner._visual_next_pixel_idx, owner._visual_total_pixels,
		owner._ticks_per_slice_diag(), owner._climate_defer_streak, suffix,
	])



static func _log_pixel_slice(owner: OceanCurrentsJob, ctx: SusTickContext, stage_name: String, s: int, e: int,
		elapsed_ms: float, progress: float, used_cpp_raster: bool,
		raster_wall_ms: float, raster_native_ms: float) -> void:
	if owner._ocean_pixel_rt_diag_count >= 64:
		return
	if not PKLog.enabled:
		return
	var should_log: bool = owner._ocean_pixel_rt_diag_count < 16 \
			or stage_name == "ocean_pixel_raster_done" \
			or stage_name == "ocean_pixel_commit_deferred" \
			or (ctx.tick_index % 60) == 0
	if not should_log:
		return
	owner._ocean_pixel_rt_diag_count += 1
	print("[ocean_currents][RT] pixel#%d tick=%d stage=%s cursor=%d..%d/%d progress=%.3f elapsed=%.3f pps=%d quota_last=%d path=%s raster_wall=%.3f raster_native=%.3f pending_commit=%s" % [
		owner._ocean_pixel_rt_diag_count, ctx.tick_index, stage_name,
		s, e, owner._visual_total_pixels, progress, elapsed_ms,
		max(0, e - s), owner._last_pixel_quota,
		"gdext_raster" if used_cpp_raster else "gdscript_slice",
		raster_wall_ms, raster_native_ms, str(owner._visual_pending_commit),
	])


# Fix #11 second pass (2026-06-16) mobile：[ocean_currents][RT] / [daily_wind] 24 行
# 上限对 mobile 仍然太多（logcat ~10ms/行 → 240ms 的 startup overhead）。
# mobile 收紧到 6 行（前几个 round 看完算）。desktop 保留 24 方便开发期排查。
static func _ocean_rt_log_budget(owner: OceanCurrentsJob) -> int:
	return 6 if OS.has_feature("mobile") else 24
