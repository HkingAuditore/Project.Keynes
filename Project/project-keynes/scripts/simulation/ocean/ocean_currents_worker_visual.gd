extends RefCounted


static func run_if_authoritative(job: OceanCurrentsJob, ctx: SusTickContext, started: int,
		is_mobile: bool) -> Dictionary:
	var source: Object = job.data_core_world_ext
	var commit: Dictionary = source.get_climate_physics_commit_info() if source != null else {}
	if not bool(commit.get("authoritative", false)):
		if job._worker_visual_source_id != 0:
			job._worker_visual_source_id = 0
			job._last_daily_wind_tick = job._NO_DAILY_WIND_TICK
			job._daily_wind_due_seq = 0
			_discard_round(job)
		return {}

	var map_id := job.map.get_instance_id()
	var size := job.world.derived_size
	var target := [map_id, job.world.get_instance_id(), job.baker.get_instance_id(), size]
	var source_id := source.get_instance_id()
	if job._worker_visual_source_id != source_id or job._worker_visual_target != target:
		if not job._worker_visual_target.is_empty() and job._worker_visual_target != target:
			job.baker._ocean_pixel_cache_size = Vector2i.ZERO
		_discard_round(job)
		job._worker_visual_source_id = source_id
		job._worker_visual_target = target
	job._phys_round_active = false
	job._phys_solve_done = true

	var cells := job.map.soa_size()
	if int(commit.get("map_instance_id", 0)) != map_id or cells <= 0 \
			or int(commit.get("cell_count", 0)) != cells or size.x <= 0 or size.y <= 0:
		if job._visual_round_active:
			_discard_round(job)
		return _report(job, ctx, started, commit, "physics_visual_map_mismatch")
	# A newer day can be installed while the pixels are in flight. The baker
	# keeps the view chosen at the start through the final upload.
	if job._visual_round_active:
		return job._run_visual_slice(ctx, started)

	var phase := job._current_phase(ctx)
	var phase_int := int(floor(phase))
	var due := job._phase_int_seen == -9999 or phase_int != job._phase_int_seen
	if not due or not DCFeatureFlags.ocean_current_visual_active() \
			or (is_mobile and job._visual_round_id > 0):
		return _report(job, ctx, started, commit)
	if not bool(commit.get("ready", false)) or not bool(commit.get("ok", false)) \
			or int(commit.get("committed_day", -1)) < 0 \
			or int(commit.get("input_generation", 0)) <= 0 or int(commit.get("generation", 0)) <= 0:
		return _report(job, ctx, started, commit, "physics_visual_commit_invalid")

	var view: Dictionary = source.get_climate_physics_read_view()
	if not _same_commit(view, commit) \
			or not job.baker.begin_runtime_physics_visual(job.map, job.world, view, phase):
		return _report(job, ctx, started, commit, "physics_visual_view_invalid")
	var wind: Dictionary = job.baker.run_wind_field_rasterize_full(job.map, job.world, job.cfg)
	if bool(wind.get("fallback", true)):
		_discard_round(job)
		return _report(job, ctx, started, commit, str(wind.get("reason", "wind_raster_failed")))
	job._phase_int_seen = phase_int
	job._enqueue_visual_round(ctx, phase)
	return job._run_visual_slice(ctx, started)


static func _same_commit(view: Dictionary, commit: Dictionary) -> bool:
	if not bool(view.get("ready", false)) or not bool(view.get("ok", false)) \
			or not bool(view.get("authoritative", false)):
		return false
	for key in ["map_instance_id", "cell_count", "committed_day", "input_generation", "generation"]:
		if view.get(key) != commit[key]:
			return false
	return true


static func _discard_round(job: OceanCurrentsJob) -> void:
	job._drop_visual_round()
	job._phase_int_seen = -9999
	job.baker.discard_ocean_buffers()
	job.baker._runtime_physics_visual_view = {}


static func _report(job: OceanCurrentsJob, ctx: SusTickContext, started: int, commit: Dictionary,
		visual_error: String = "") -> Dictionary:
	return job._record_phys_diag(ctx, {
		"done": true, "work_done": 0, "progress_ratio": 1.0,
		"elapsed_ms": (Time.get_ticks_usec() - started) / 1000.0,
		"stage_name": "worker_physics_committed", "path": "worker_snapshot",
		"committed_day": commit.get("committed_day", -1),
		"input_generation": commit.get("input_generation", 0),
		"physics_authoritative": true,
		"raster_fallback_reason": visual_error,
	}, true)
