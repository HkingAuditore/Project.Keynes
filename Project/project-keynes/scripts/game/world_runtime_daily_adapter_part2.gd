extends RefCounted

## Extracted world_runtime_daily_adapter.gd group 2; state stays with host.

func _runtime_control_state(host) -> Dictionary:
	if host._generator == null:
		return {}
	if host._generator.has_method("get_runtime_control_state"):
		return host._generator.get_runtime_control_state()
	return host._generator.get_runtime_thread_report() \
		if host._generator.has_method("get_runtime_thread_report") else {}


## When the native worker enters FAULTED, pause the authoritative clock and keep
## the last committed generation/hash diagnostics for soak evidence. Do not
## clear live MapData; the parked snapshot remains the recovery baseline.


func _observe_runtime_worker_fault(host, report: Dictionary = {}) -> void:
	if host._runtime_worker_fault_paused:
		return
	if report.is_empty():
		report = host._runtime_control_state()
	var state = String(report.get(
		"simulation_host_state", report.get("state", "")))
	if state != "FAULTED":
		return
	# Full diagnostics are needed once, when a fault is actually observed.
	if not report.has("fault_code") and host._generator != null \
			and host._generator.has_method("get_runtime_thread_report"):
		report = host._generator.get_runtime_thread_report()
	host._runtime_worker_fault_paused = true
	if host._world_clock != null:
		if host._world_clock.has_method("latch_authority_fault_hold"):
			host._world_clock.latch_authority_fault_hold()
		else:
			host._world_clock.pause(true)
	host._runtime_last_fault_diagnostics = {
		"fault_code": String(report.get("fault_code", "")),
		"committed_day": int(report.get("simulation_committed_day", report.get("committed_day", -1))),
		"generation": int(report.get("generation", 0)),
		"state_hash": int(report.get("state_hash", 0)),
		"worker_fault_count": int(report.get("worker_fault_count", 0)),
		"economy_authority_last_committed_generation": int(report.get(
			"economy_authority_last_committed_generation", 0)),
		"economy_authority_last_committed_hash": int(report.get(
			"economy_authority_last_committed_hash", 0)),
		"economy_authority_fault_paused": bool(report.get(
			"economy_authority_fault_paused", false)),
		"last_commit": host._runtime_last_commit.duplicate(false),
	}
	push_warning("[runtime-worker] FAULTED code=%s committed_day=%s generation=%s faults=%s - world_clock.pause(true)" % [
		str(host._runtime_last_fault_diagnostics.get("fault_code", "")),
		str(host._runtime_last_fault_diagnostics.get("committed_day", -1)),
		str(host._runtime_last_fault_diagnostics.get("generation", 0)),
		str(host._runtime_last_fault_diagnostics.get("worker_fault_count", 0))])
	host.RuntimeForensics.capture_and_dump(
		String(host._runtime_last_fault_diagnostics.get("fault_code", "runtime_worker_fault")),
		host._generator, host._world_clock, "runtime_worker_fault", {
			"source": "world_runtime_host",
			"worker_fault": host._runtime_last_fault_diagnostics.duplicate(true),
		})



func get_runtime_fault_diagnostics(host) -> Dictionary:
	return host._runtime_last_fault_diagnostics.duplicate(false)



func is_runtime_fault_paused(host) -> bool:
	return host._runtime_worker_fault_paused


## E8 ACTIVE Modifier write-back. Non-blocking: drops intermediate generations.
## Targets legacy ModifierRuntime (not MapData arrays). main_wait_on_sim_us stays 0.


func _consume_modifier_worker_snapshot_if_authoritative(host) -> void:
	host._modifier_worker_snapshot_generation = preload("res://scripts/game/world_runtime_modifier_writeback.gd").consume(
		host._runtime_ready_for_ticks, host._generator, host._runtime_control_state,
		host._modifier_worker_snapshot_generation)


func _consume_country_worker_read_view_if_authoritative(host) -> void:
	if not host._runtime_ready_for_ticks or host._generator == null \
			or not host._generator.has_method("get_country_worker_read_view"):
		return
	var report = host._runtime_control_state()
	var granted_mask = int(report.get("authoritative_domain_mask", 0))
	if (granted_mask & 0x004) == 0:
		return
	var view: Dictionary = host._generator.get_country_worker_read_view(
		host._country_worker_read_generation)
	if not bool(view.get("ok", false)) or not bool(view.get("available", false)):
		return
	var generation = int(view.get("generation", 0))
	if generation <= host._country_worker_read_generation:
		return
	var cell_count = host._current_map.cell_count() if host._current_map != null else 0
	if cell_count <= 0:
		host._country_worker_read_rejected_count += 1
		return
	var changed_cells: PackedInt32Array = view.get(
		"changed_cells", PackedInt32Array())
	var changed_owners: PackedInt32Array = view.get(
		"changed_owners", PackedInt32Array())
	var full_required = bool(view.get("full_snapshot_required", false))
	var territory_changed_count = 0
	if full_required:
		var full_owners: PackedInt32Array = view.get(
			"full_cell_owners", PackedInt32Array())
		if full_owners.size() != cell_count:
			host._country_worker_read_rejected_count += 1
			push_warning("[country-authority] full read view rejected: cell shape mismatch")
			return
		# Repair MapData with the full owner plane, but never advertise
		# cell_count as "changed": that forced O(n) vision/border on every
		# missed-generation catch-up even when only a few cells differed.
		var previous_owners: PackedInt32Array = host._current_map.country_slot_arr
		if previous_owners.size() == cell_count:
			for cell in range(cell_count):
				if int(previous_owners[cell]) != int(full_owners[cell]):
					territory_changed_count += 1
		else:
			territory_changed_count = cell_count
		host._current_map.country_slot_arr = full_owners
		host._country_worker_read_full_snapshot_count += 1
	else:
		if changed_cells.size() != changed_owners.size():
			host._country_worker_read_rejected_count += 1
			push_warning("[country-authority] sparse read view rejected: patch shape mismatch")
			return
		if host._current_map.country_slot_arr.size() != cell_count:
			host._country_worker_read_rejected_count += 1
			push_warning("[country-authority] sparse read view rejected: MapData shape mismatch")
			return
		for i in changed_cells.size():
			var cell = int(changed_cells[i])
			if cell < 0 or cell >= cell_count:
				host._country_worker_read_rejected_count += 1
				push_warning("[country-authority] sparse read view rejected: cell out of range")
				return
			host._current_map.country_slot_arr[cell] = int(changed_owners[i])
		territory_changed_count = changed_cells.size()
		host._country_worker_read_patch_count += 1

	host._country_worker_read_generation = generation
	host._country_worker_read_last_day = int(view.get("committed_day", -1))
	host._country_read_last_full_snapshot = full_required
	host._country_read_last_applied_cells = territory_changed_count
	host._country_read_last_territory_changed_cells = territory_changed_count
	view.erase("full_cell_owners")
	view.erase("changed_cells")
	view.erase("changed_owners")
	# Shallow copy is enough: remaining fields are scalars / packed arrays.
	host._country_worker_read_last_result = view.duplicate(false)
	host._country_worker_read_last_result["applied_cells"] = territory_changed_count
	host._country_worker_read_last_result["territory_changed_cells"] = territory_changed_count
	host._country_worker_read_last_result["full_snapshot_applied"] = full_required
	var worker_report = host._country_worker_read_last_result.duplicate(false)
	# Border consumers key off changed_cells. Use the real territory
	# delta, never the repaired plane width.
	worker_report["changed_cells"] = territory_changed_count
	worker_report["changed_cell_count"] = territory_changed_count
	worker_report["full_snapshot_applied"] = full_required
	worker_report["country_generation"] = generation
	# CountryFacade is the existing notification path.  It emits the same
	# country_committed signal consumed by borders, the controller and UI.
	var facade = host._generator.get_country_facade() \
		if host._generator.has_method("get_country_facade") else null
	if facade != null and facade.has_method("dispatch_worker_committed_view"):
		facade.dispatch_worker_committed_view(worker_report)


## Budgeted country vision/border refresh. Pending work survives frames that
## already spent their sim budget so day capture and peer pumps stay responsive.


func _service_country_visual_refresh_budgeted(host, frame_started_usec: int, vision_changed: bool) -> void:
	if not host._country_visual_refresh_pending:
		return
	var frame_elapsed_ms = host._sched_elapsed_ms(frame_started_usec)
	var budget_ms = host.COUNTRY_VISUAL_REFRESH_BUDGET_MS
	if host._world_clock != null:
		budget_ms = minf(budget_ms, float(host._world_clock.sim_frame_budget_ms))
	var force = vision_changed or host._country_visual_refresh_deferred_frames >= \
		host.COUNTRY_VISUAL_REFRESH_MAX_DEFER_FRAMES
	if not force and frame_elapsed_ms >= budget_ms:
		host._country_visual_refresh_deferred_frames += 1
		host._country_visual_refresh_defer_count += 1
		return
	host._country_visual_refresh_pending = false
	host._country_visual_refresh_deferred_frames = 0
	var started_usec = Time.get_ticks_usec()
	host.refresh_country_visuals(host._country_visual_refresh_reason)
	host._country_visual_last_refresh_ms = host._sched_elapsed_ms(started_usec)
	host._country_visual_refresh_run_count += 1
