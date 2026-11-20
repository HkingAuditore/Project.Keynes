extends RefCounted

## Dispatch facade for split world_runtime_daily_adapter.gd.

var _part1 = preload("res://scripts/game/world_runtime_daily_adapter_part1.gd").new()
var _part2 = preload("res://scripts/game/world_runtime_daily_adapter_part2.gd").new()
var _part3 = preload("res://scripts/game/world_runtime_daily_adapter_part3.gd").new()

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
func _service_runtime_liveness(host, frame_usec: int) -> void:
	_part1._service_runtime_liveness(host, frame_usec)
func _service_runtime_progress(host, frame_usec: int) -> void:
	_part1._service_runtime_progress(host, frame_usec)
func _runtime_control_state(host) -> Dictionary:
	return _part2._runtime_control_state(host)
func _observe_runtime_worker_fault(host, report: Dictionary = {}) -> void:
	_part2._observe_runtime_worker_fault(host, report)
func get_runtime_fault_diagnostics(host) -> Dictionary:
	return _part2.get_runtime_fault_diagnostics(host)
func is_runtime_fault_paused(host) -> bool:
	return _part2.is_runtime_fault_paused(host)
func _consume_modifier_worker_snapshot_if_authoritative(host) -> void:
	_part2._consume_modifier_worker_snapshot_if_authoritative(host)
func _consume_country_worker_read_view_if_authoritative(host) -> void:
	_part2._consume_country_worker_read_view_if_authoritative(host)
func _service_country_visual_refresh_budgeted(host, frame_started_usec: int) -> void:
	_part2._service_country_visual_refresh_budgeted(host, frame_started_usec)

func _consume_runtime_commit_if_ready(host, report_override: Dictionary = {}) -> void:
	_part3._consume_runtime_commit_if_ready(host, report_override)
func military_report(host) -> Dictionary:
	return _part3.military_report(host)
func _apply_climate_writeback_if_authoritative(host, report: Dictionary) -> void:
	_part3._apply_climate_writeback_if_authoritative(host, report)
## G4 moved host responsibilities
func _run_native_daily_inline_day(host, day_idx: int) -> void:
	_part1._run_native_daily_inline_day(host, day_idx)

func _native_daily_inline_requested(host) -> bool:
	return _part1._native_daily_inline_requested(host)

func _is_web_build(host) -> bool:
	return _part1._is_web_build(host)

func _web_worker_requested(host) -> bool:
	return _part1._web_worker_requested(host)

func _clear_web_daily_fallback_failure(host) -> void:
	_part1._clear_web_daily_fallback_failure(host)

func _reject_web_daily_fallback(host, code: String, reason: String) -> bool:
	return _part1._reject_web_daily_fallback(host, code, reason)

func _publish_fast_tick_perf_sample(host,
		t_sus_ms: float,
		t_render_ms: float,
		t_ui_ms: float,
		fast_ms: float,
		was_skipped_day: bool
) -> Dictionary:
	return _part1._publish_fast_tick_perf_sample(host, t_sus_ms, t_render_ms, t_ui_ms, fast_ms, was_skipped_day)

func finish_daily_tick(host, ui_ms: float, ui_breakdown: Dictionary = {}) -> void:
	_part1.finish_daily_tick(host, ui_ms, ui_breakdown)

func get_sim_breakdowns(host) -> Dictionary:
	return _part1.get_sim_breakdowns(host)

func get_environment_perf_summary(host) -> Dictionary:
	return _part1.get_environment_perf_summary(host)

func get_recorder_perf_summary(host) -> Dictionary:
	return _part1.get_recorder_perf_summary(host)

func _recorder_ready(host, recorder: RefCounted) -> bool:
	return _part1._recorder_ready(host, recorder)

func on_speed_changed(host, new_speed: float) -> void:
	_part1.on_speed_changed(host, new_speed)

func on_clock_running_changed(host, running: bool) -> void:
	_part1.on_clock_running_changed(host, running)

func _sync_runtime_worker_clock(host) -> void:
	_part1._sync_runtime_worker_clock(host)

func on_visual_day_phase_changed(host, visual_day_phase: float) -> void:
	_part1.on_visual_day_phase_changed(host, visual_day_phase)
