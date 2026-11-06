extends RefCounted

## Dispatch facade for split world_runtime_daily_adapter.gd.

var _part1 = preload("res://scripts/game/world_runtime_daily_adapter_part1.gd").new()
var _part2 = preload("res://scripts/game/world_runtime_daily_adapter_part2.gd").new()
var _part3 = preload("res://scripts/game/world_runtime_daily_adapter_part3.gd").new()

func run_daily_tick(host, day_idx: int, season_phase: float) -> Dictionary:
	return _part1.run_daily_tick(host, day_idx, season_phase)
func _bind_overlay_resources(host) -> void:
	_part1._bind_overlay_resources(host)
func set_map_overlay(host, request: Dictionary) -> void:
	_part1.set_map_overlay(host, request)
func clear_map_overlay(host) -> void:
	_part1.clear_map_overlay(host)
func mark_map_overlay_dirty(host, _reason: StringName = &"runtime") -> void:
	_part1.mark_map_overlay_dirty(host, _reason)
func map_overlay_diagnostics(host) -> Dictionary:
	return _part1.map_overlay_diagnostics(host)
func _web_mark(host, phase: String) -> void:
	_part1._web_mark(host, phase)
func _web_flush_slow_frame_trace(host, dt_ms: int) -> void:
	_part1._web_flush_slow_frame_trace(host, dt_ms)
func _emit_web_frame_probe(host, frame_usec: int) -> void:
	_part1._emit_web_frame_probe(host, frame_usec)
func _emit_web_beat(host, frame_usec: int) -> void:
	_part1._emit_web_beat(host, frame_usec)
func _process(host, _delta: float) -> void:
	_part1._process(host, _delta)
func _service_worker_lead_and_prefetch(host) -> void:
	_part1._service_worker_lead_and_prefetch(host)
func _prefetch_diag_tick_prep(host) -> void:
	_part1._prefetch_diag_tick_prep(host)
func _prefetch_diag_enabled(host) -> bool:
	return _part1._prefetch_diag_enabled(host)
func _emit_prefetch_boot_once(host) -> void:
	_part1._emit_prefetch_boot_once(host)
func _prefetch_diag_boot_payload(host) -> Dictionary:
	return _part1._prefetch_diag_boot_payload(host)
func _prefetch_diag_note(host, code: StringName) -> void:
	_part1._prefetch_diag_note(host, code)
func _prefetch_diag_collect_extras(host) -> void:
	_part1._prefetch_diag_collect_extras(host)
func _prefetch_diag_seen_text(host) -> String:
	return _part1._prefetch_diag_seen_text(host)
func _emit_prefetch_diag(host, code: StringName) -> void:
	_part1._emit_prefetch_diag(host, code)
func _environment_publish_next_day(host) -> int:
	return _part1._environment_publish_next_day(host)
func _set_environment_publish_next_day(host, day: int) -> void:
	_part1._set_environment_publish_next_day(host, day)
func _suspend_environment_prefetch_for_save(host, reason: String) -> void:
	_part1._suspend_environment_prefetch_for_save(host, reason)
func _resume_environment_prefetch_after_save(host) -> void:
	_part1._resume_environment_prefetch_after_save(host)
func _poll_environment_prefetch_resume(host) -> void:
	_part1._poll_environment_prefetch_resume(host)
func _service_runtime_liveness(host, frame_usec: int, _capacity_pending: bool) -> void:
	_part1._service_runtime_liveness(host, frame_usec, _capacity_pending)
func _service_runtime_progress(host, frame_usec: int) -> void:
	_part1._service_runtime_progress(host, frame_usec)
func _arm_climate_capacity_pending(host, day_idx: int) -> void:
	_part1._arm_climate_capacity_pending(host, day_idx)
func _clear_climate_capacity_pending(host) -> void:
	_part1._clear_climate_capacity_pending(host)

func _note_climate_capacity_pending_stall(host) -> void:
	_part2._note_climate_capacity_pending_stall(host)
func _runtime_control_state(host) -> Dictionary:
	return _part2._runtime_control_state(host)
func _observe_runtime_worker_fault(host, report: Dictionary = {}) -> void:
	_part2._observe_runtime_worker_fault(host, report)
func get_runtime_fault_diagnostics(host) -> Dictionary:
	return _part2.get_runtime_fault_diagnostics(host)
func is_runtime_fault_paused(host) -> bool:
	return _part2.is_runtime_fault_paused(host)
func _service_country_worker_transport(host) -> void:
	_part2._service_country_worker_transport(host)
func _consume_modifier_worker_snapshot_if_authoritative(host) -> void:
	_part2._consume_modifier_worker_snapshot_if_authoritative(host)
func _consume_effect_worker_snapshot_if_authoritative(host) -> void:
	_part2._consume_effect_worker_snapshot_if_authoritative(host)
func _service_effect_worker_intents_if_authoritative(host) -> void:
	_part2._service_effect_worker_intents_if_authoritative(host)
func _step_ideology_instance_refresh_if_authoritative(host, day_idx: int) -> void:
	_part2._step_ideology_instance_refresh_if_authoritative(host, day_idx)
func _consume_ideology_worker_snapshot_if_authoritative(host) -> void:
	_part2._consume_ideology_worker_snapshot_if_authoritative(host)
func _service_ideology_worker_intents_if_authoritative(host) -> void:
	_part2._service_ideology_worker_intents_if_authoritative(host)
func _consume_trigger_worker_snapshot_if_authoritative(host) -> void:
	_part2._consume_trigger_worker_snapshot_if_authoritative(host)
func _service_trigger_worker_intents_if_authoritative(host) -> void:
	_part2._service_trigger_worker_intents_if_authoritative(host)
func _service_trigger_country_delivery(host, ext: Object, _report: Dictionary) -> void:
	_part2._service_trigger_country_delivery(host, ext, _report)
func _ack_trigger_delivery_ids(host, ext: Object) -> Dictionary:
	return _part2._ack_trigger_delivery_ids(host, ext)
func _consume_country_worker_read_view_if_authoritative(host) -> void:
	_part2._consume_country_worker_read_view_if_authoritative(host)
func _service_country_visual_refresh_budgeted(host, frame_started_usec: int) -> void:
	_part2._service_country_visual_refresh_budgeted(host, frame_started_usec)

func _consume_runtime_commit_if_ready(host, report_override: Dictionary = {}) -> void:
	_part3._consume_runtime_commit_if_ready(host, report_override)
func _queue_runtime_natural_resource_commit(host, day: int) -> void:
	_part3._queue_runtime_natural_resource_commit(host, day)
func _drain_runtime_natural_resource_commits(host) -> void:
	_part3._drain_runtime_natural_resource_commits(host)
func _queue_runtime_military_commit(host, day: int) -> void:
	_part3._queue_runtime_military_commit(host, day)
func _drain_runtime_military_commits(host) -> void:
	_part3._drain_runtime_military_commits(host)
func _refresh_military_terrain_after_season(host) -> void:
	_part3._refresh_military_terrain_after_season(host)
func _refresh_military_terrain_on_season_edge(host, day_idx: int) -> void:
	_part3._refresh_military_terrain_on_season_edge(host, day_idx)
func military_report(host) -> Dictionary:
	return _part3.military_report(host)
func _apply_climate_writeback_if_authoritative(host, report: Dictionary) -> void:
	_part3._apply_climate_writeback_if_authoritative(host, report)
func wait_for_climate_consumed(host, after_environment_generation: int) -> Dictionary:
	return _part3.wait_for_climate_consumed(host, after_environment_generation)
