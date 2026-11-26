extends RefCounted

## Runs ocean visual updates and publishes the committed textures.


static func _run_visual_slice(owner: OceanCurrentsJob, ctx: SusTickContext, t_start_us: int) -> Dictionary:
	owner._sync_legacy_round_state()
	if owner._visual_pending_commit:
		var t_commit2_us: int = Time.get_ticks_usec()
		owner.baker.commit_ocean_buffers(owner.world, true)
		var commit_only_ms: float = (Time.get_ticks_usec() - t_commit2_us) / 1000.0
		if owner.on_commit.is_valid():
			owner.on_commit.call()
		var elapsed_commit_only: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
		var committed_round_id: int = owner._visual_round_id
		owner._visual_pending_commit = false
		owner._visual_round_active = false
		owner._visual_next_pixel_idx = 0
		owner._visual_total_pixels = 0
		owner._visual_enqueued_tick = owner._NO_DAILY_WIND_TICK
		owner._sync_legacy_round_state()
		owner._log_pixel_slice(ctx, "ocean_pixel_commit_deferred", 0, 0,
			elapsed_commit_only, 1.0, true, -1.0, -1.0)
		var commit_report: Dictionary = {
			"done": true,
			"work_done": 0,
			"elapsed_ms": elapsed_commit_only,
			"progress_ratio": 1.0,
			"stage_name": "ocean_pixel_commit_deferred",
			"substage": "commit_only",
			"path": "gpu_upload",
			"commit_wall_ms": commit_only_ms,
			"visual_round_id": committed_round_id,
		}
		return owner._record_phys_diag(ctx, commit_report, true)

	if not owner._visual_round_active:
		return {}

	var use_cpp_raster_plan: bool = owner.baker._use_physical_circulation(owner.cfg) \
			and owner.cfg != null \
			and owner.cfg.climate_profile != null \
			and owner.baker.has_method("run_ocean_field_rasterize_full")
	var pps: int = owner._pixel_quota_for_next_slice(not use_cpp_raster_plan)
	owner._current_pixel_quota_diag = pps
	var s: int = owner._visual_next_pixel_idx
	var e: int = mini(owner._visual_total_pixels, s + pps)
	if s == 0:
		print("[ocean_currents] season_crossed -> rebaking pixel atlas at phase=%.3f (phase_int=%d, total_pixels=%d)" % [
			owner._visual_phase_locked, owner._phase_int_seen, owner._visual_total_pixels
		])

	var used_cpp_raster: bool = false
	var raster_native_ms: float = -1.0
	var raster_wall_ms: float = -1.0
	var raster_fallback_reason: String = "gdscript_slice"
	var raster_pixels: int = 0
	var raster_requested_start: int = -1
	var raster_requested_end: int = -1
	var raster_returned_start: int = -1
	var raster_returned_end: int = -1
	var raster_progress_guard_fired: bool = false
	var raster_atlas_updated: bool = false
	var cpp_sub_s: int = -1
	var cpp_sub_e: int = -1
	if use_cpp_raster_plan:
		var cp_oc: ClimateProfile = owner.cfg.climate_profile if owner.cfg != null else null
		if cp_oc != null and owner.baker.has_method("run_ocean_field_rasterize_full"):
			var sub_count: int = 1
			if "ocean_pixel_subslice_count" in cp_oc:
				sub_count = max(1, int(cp_oc.ocean_pixel_subslice_count))
			var sub_pps: int = mini(int(ceil(float(owner._visual_total_pixels) / float(sub_count))), pps)
			var sub_s: int = owner._visual_next_pixel_idx
			var sub_e: int = mini(owner._visual_total_pixels, sub_s + sub_pps)
			raster_requested_start = sub_s
			raster_requested_end = sub_e
			var t_raster_us: int = Time.get_ticks_usec()
			var raster_res: Dictionary = owner.baker.run_ocean_field_rasterize_full(owner.map, owner.world, owner.cfg, sub_s, sub_e)
			raster_wall_ms = (Time.get_ticks_usec() - t_raster_us) / 1000.0
			raster_native_ms = float(raster_res.get("elapsed_ms", -1.0))
			raster_pixels = int(raster_res.get("pixels", 0))
			raster_atlas_updated = bool(raster_res.get("atlas_updated", false))
			if bool(raster_res.get("fallback", true)):
				raster_fallback_reason = str(raster_res.get("reason", "cpp_fallback"))
			if not bool(raster_res.get("fallback", true)):
				cpp_sub_s = int(raster_res.get("start_idx", sub_s))
				cpp_sub_e = int(raster_res.get("end_idx", sub_e))
				raster_returned_start = cpp_sub_s
				raster_returned_end = cpp_sub_e
				var returned_span: int = max(0, cpp_sub_e - cpp_sub_s)
				var returned_range_ok: bool = (cpp_sub_s == sub_s \
						and cpp_sub_e > sub_s \
						and cpp_sub_e <= owner._visual_total_pixels \
						and cpp_sub_e <= sub_e)
				var returned_pixels_ok: bool = (raster_pixels == returned_span)
				if returned_range_ok and returned_pixels_ok:
					used_cpp_raster = true
					owner._visual_next_pixel_idx = cpp_sub_e
					s = cpp_sub_s
					e = cpp_sub_e
					raster_fallback_reason = ""
				else:
					raster_progress_guard_fired = true
					raster_fallback_reason = "cpp_non_progress start=%d end=%d pixels=%d requested=%d..%d" % [
						cpp_sub_s, cpp_sub_e, raster_pixels, sub_s, sub_e,
					]
	if not used_cpp_raster and owner._worker_visual_source_id != 0:
		# 不能把同一提交态的 raster 失败悄悄换成读取实时 HexCell 的另一代数据。
		return owner._record_phys_diag(ctx, {
			"done": false, "work_done": 0,
			"elapsed_ms": (Time.get_ticks_usec() - t_start_us) / 1000.0,
			"progress_ratio": float(owner._visual_next_pixel_idx) / float(maxi(1, owner._visual_total_pixels)),
			"stage_name": "worker_visual_retry", "path": "raster_retry",
			"raster_fallback_reason": raster_fallback_reason,
		}, false)
	if not used_cpp_raster:
		owner.baker.bake_ocean_currents_slice(owner.map, owner.world, owner.hex_size, owner.cfg, owner._visual_phase_locked, s, e)
		owner.baker.bake_ocean_upwelling_slice(owner.map, owner.world, owner.hex_size, owner.cfg, owner._visual_phase_locked, s, e)
		owner._visual_next_pixel_idx = e

	var done: bool = (owner._visual_next_pixel_idx >= owner._visual_total_pixels)
	var commit_wall_ms: float = -1.0
	if done:
		owner._visual_pending_commit = true
		done = false

	var elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
	if elapsed_ms > 25.0:
		var marker: String = "pixel_commit_pending" if owner._visual_pending_commit else "pixel"
		var rest_ms: float = elapsed_ms
		if raster_wall_ms >= 0.0:
			rest_ms -= raster_wall_ms
		if commit_wall_ms >= 0.0:
			rest_ms -= commit_wall_ms
		print("  [ocean_currents] slow visual slice=%.1fms (%s, pixels=%d-%d / %d) raster_wall=%.1f raster_native=%.1f commit_wall=%.1f rest=%.1f" % [
			elapsed_ms, marker, s, e, owner._visual_total_pixels,
			raster_wall_ms, raster_native_ms, commit_wall_ms, rest_ms
		])
	var progress: float = 0.0
	if owner._visual_total_pixels > 0:
		if done or owner._visual_pending_commit:
			progress = 1.0
		else:
			progress = float(owner._visual_next_pixel_idx) / float(owner._visual_total_pixels)
	var work_done_pixels: int = e - s
	if work_done_pixels > 0:
		owner._last_pixel_slice_ms = elapsed_ms
		owner._last_pixel_slice_pixels = work_done_pixels
		owner._last_pixel_quota = work_done_pixels
	var slice_stage_name: String = "ocean_pixel_slice"
	if owner._visual_pending_commit:
		slice_stage_name = "ocean_pixel_raster_done"
	elif done:
		slice_stage_name = "ocean_pixel_commit"
	owner._sync_legacy_round_state()
	owner._log_pixel_slice(ctx, slice_stage_name, s, e, elapsed_ms, progress,
		used_cpp_raster, raster_wall_ms, raster_native_ms)
	var pixel_report: Dictionary = {
		"done": done,
		"work_done": work_done_pixels,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": progress,
		"pixel_quota": pps,
		"stage_name": slice_stage_name,
		"substage": "pixels_%d_%d" % [s, e],
		"path": "gdext_raster" if used_cpp_raster else "gdscript_slice",
		"processed_pixels": work_done_pixels,
		"cursor_start": s,
		"cursor_end": e,
		"raster_requested_start": raster_requested_start,
		"raster_requested_end": raster_requested_end,
		"raster_returned_start": raster_returned_start,
		"raster_returned_end": raster_returned_end,
		"raster_pixels": raster_pixels,
		"raster_wall_ms": raster_wall_ms,
		"raster_native_ms": raster_native_ms,
		"raster_used_cpp": used_cpp_raster,
		"raster_atlas_updated": raster_atlas_updated,
		"raster_fallback_reason": raster_fallback_reason,
		"raster_progress_guard_fired": raster_progress_guard_fired,
	}
	return owner._record_phys_diag(ctx, pixel_report, done)



static func _discard_worker_visual_round(owner: OceanCurrentsJob) -> void:
	owner._phase_int_seen = owner._NO_VISUAL_PHASE
	owner._drop_visual_round()
	owner.baker.discard_ocean_buffers()



static func _worker_visual_report(owner: OceanCurrentsJob, ctx: SusTickContext, started: int, commit: Dictionary,
		visual_error: String = "") -> Dictionary:
	var elapsed_ms := (Time.get_ticks_usec() - started) / 1000.0
	return owner._record_phys_diag(ctx, owner.WorkerVisual.report(commit, elapsed_ms, visual_error), true)



static func _run_worker_visual(owner: OceanCurrentsJob, ctx: SusTickContext, started: int, is_mobile: bool) -> Dictionary:
	var source: Object = owner.data_core_world_ext
	var commit: Dictionary = source.get_climate_physics_commit_info() if source != null else {}
	if not bool(commit.get("authoritative", false)):
		if owner._worker_visual_source_id != 0:
			owner._worker_visual_source_id = 0
			owner._last_daily_wind_tick = owner._NO_DAILY_WIND_TICK
			owner._daily_wind_due_seq = 0
			owner._discard_worker_visual_round()
		return {}
	var map_id := owner.map.get_instance_id()
	var size := owner.world.derived_size
	var target := [map_id, owner.world.get_instance_id(), owner.baker.get_instance_id(), size]
	var source_id := source.get_instance_id()
	if owner._worker_visual_source_id != source_id or owner._worker_visual_target != target:
		owner._discard_worker_visual_round()
		owner._worker_visual_source_id = source_id
		owner._worker_visual_target = target
	owner._phys_round_active = false
	owner._phys_solve_done = true

	if not owner.WorkerVisual.matches_map(commit, map_id, owner.map.soa_size(), size):
		if owner._visual_round_active:
			owner._discard_worker_visual_round()
		else:
			owner._phase_int_seen = owner._NO_VISUAL_PHASE
		return owner._worker_visual_report(ctx, started, commit, "physics_visual_map_mismatch")

	# Keep the fields selected at the start through all slices and the upload.
	if owner._visual_round_active:
		return owner._run_visual_slice(ctx, started)

	var phase := owner._current_phase(ctx)
	var phase_int := int(floor(phase))
	# Invalidated draws are due on mobile, too.
	var due := owner._phase_int_seen == owner._NO_VISUAL_PHASE or (not is_mobile and phase_int != owner._phase_int_seen)
	if not due or not DCFeatureFlags.ocean_current_visual_active():
		return owner._worker_visual_report(ctx, started, commit)
	if not owner.WorkerVisual.commit_ready(commit):
		return owner._worker_visual_report(ctx, started, commit, "physics_visual_commit_invalid")

	var view: Dictionary = source.get_climate_physics_read_view()
	if not owner.WorkerVisual.same_commit(view, commit) or not owner.baker.begin_runtime_physics_visual(owner.map, owner.world, view, phase):
		return owner._worker_visual_report(ctx, started, commit, "physics_visual_view_invalid")
	var wind := owner.baker.run_wind_field_rasterize_full(owner.map, owner.world, owner.cfg)
	if bool(wind.get("fallback", true)):
		owner._discard_worker_visual_round()
		return owner._worker_visual_report(ctx, started, commit, str(wind.get("reason", "wind_raster_failed")))
	owner._phase_int_seen = phase_int
	owner._enqueue_visual_round(ctx, phase)
	return owner._run_visual_slice(ctx, started)
