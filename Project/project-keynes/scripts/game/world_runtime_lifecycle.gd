extends RefCounted

## Passive lifecycle adapter. WorldRuntimeHost remains the owner of all state,
## signals and public method names; this object only preserves the old order.
const AnnualReportSessionScript = preload("res://scripts/annual/annual_report_session.gd")

func close_world(host) -> Dictionary:
	host._runtime_ready_for_ticks = false
	host.set_process(false)
	if is_instance_valid(host._world_clock):
		host._world_clock.pause(true)
		host.on_clock_running_changed(false)
	return await host._runtime_session.close()

func cancel_world_preparation(host) -> void:
	host._clock_binding.detach()
	host._runtime_ready_for_ticks = false
	host.set_process(false)
	host._session_frames.cancel()
	if host._generator != null:
		host._generator.cancel_loading_work()
		host._generator.request_runtime_stop()

func cancel_session_simulation(host) -> void:
	host._clock_binding.detach()
	if host._generator != null:
		host._generator.request_runtime_stop()

func release_session_simulation(host) -> Dictionary:
	return await host._stop_previous_runtime_worker()

func cancel_session_presentation(host) -> void:
	host._session_frames.cancel()

func release_session_presentation(host) -> Dictionary:
	host.clear_map_overlay()
	if is_instance_valid(host._settlement_label_layer):
		host._settlement_label_layer.free()
		host._settlement_label_layer = null
	if is_instance_valid(host.military_map_layers):
		host.military_map_layers.free()
		host.military_map_layers = null
	host._overlay.release_resources()
	host._presentation.release_resources()
	# Renderer resources remain scene-owned; only detach the simulation API.
	if is_instance_valid(host._renderer):
		host._renderer.set_world_ext(null)
		host._renderer.set_map_baker(null)
	return {"ok": true}

func release_world_data(host) -> Dictionary:
	var stopped: Dictionary = await host._stop_previous_runtime_worker()
	if not bool(stopped.get("ok", false)):
		return stopped
	host._annual_reports = AnnualReportSessionScript.new()
	if host._generator != null:
		host._generator.sus_reset_all()
	host._overlay.release_resources()
	host._presentation.release_resources()
	host._view_adapter = null
	host._selected_cell = null
	host._current_map = null
	host._world_data = null
	host._generator = null
	return {"ok": true}
