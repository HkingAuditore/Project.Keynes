extends WorldRuntimeHost

# Test-only alternative dispatcher. PlayerGame never constructs this class.
# The registry describes this exact opt-in; unset/empty/0 keep normal catch-up.
var day_alignment_enabled := OS.get_environment("PK_EXPERIMENT_EXTERNAL_DAY_ALIGNMENT") == "1"
var last_aligned_day: int = 0

func _drain_runtime_natural_resource_commits() -> void:
	if not day_alignment_enabled:
		super._drain_runtime_natural_resource_commits()

func _drain_runtime_military_commits() -> void:
	if not day_alignment_enabled:
		super._drain_runtime_military_commits()

func align_committed_day(day: int) -> Dictionary:
	if not day_alignment_enabled:
		return {"ok": true, "mode": "catchup"}
	var report: Dictionary = _generator.get_runtime_thread_report()
	if day != last_aligned_day + 1 or _runtime_commit_day != day \
			or int(report.get("simulation_committed_day", -1)) != day \
			or int(report.get("worker_day_inflight", -1)) != 0:
		return {"ok": false, "code": "experiment_requires_exact_idle_day"}
	if _runtime_natural_resource_pending_target_day != day \
			or _runtime_military_pending_target_day != day:
		return {"ok": false, "code": "experiment_requires_queued_day"}
	var writeback: Dictionary = _generator.flush_runtime_economy_resource_writeback()
	if not bool(writeback.get("ok", false)) or bool(writeback.get("pending", false)):
		return {"ok": false, "code": "experiment_writeback_not_ready"}
	# Explicit day boundary, before the driver releases day D+1. Reuse both
	# original drain bodies, including military first-observation/skip/event rules.
	var before := [_runtime_natural_resource_last_commit_day, _runtime_military_last_commit_day]
	super._drain_runtime_natural_resource_commits()
	super._drain_runtime_military_commits()
	var after := [_runtime_natural_resource_last_commit_day, _runtime_military_last_commit_day]
	var complete := after == [day, day]
	if complete:
		last_aligned_day = day
	print("EXTERNAL_DAY_ALIGNMENT=" + JSON.stringify({"day": day, "before": before,
		"after": after, "ok": complete, "worker_day_inflight": report.worker_day_inflight}))
	return {"ok": complete, "mode": "day_aligned"}
