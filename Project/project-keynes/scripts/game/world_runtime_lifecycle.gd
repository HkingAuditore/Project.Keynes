extends RefCounted

## Passive lifecycle adapter. WorldRuntimeHost remains the owner of all state,
## signals and public method names; this object only preserves the old order.
const AnnualReportSessionScript = preload("res://scripts/annual/annual_report_session.gd")

func restart_worker_with_current_policy(host) -> Dictionary:
	if host._generator == null or not host._generator.has_method("request_runtime_stop"):
		return host.climate_authority_diagnostics()
	var requested: Dictionary = host._generator.request_runtime_stop()
	if not bool(requested.get("ok", false)):
		return requested
	var deadline := Time.get_ticks_msec() + 5000
	var exited := false
	while Time.get_ticks_msec() < deadline:
		var report: Dictionary = host._generator.get_runtime_thread_report()
		exited = bool(report.get("simulation_executor_exited", false))
		if exited:
			break
		host._service_country_worker_transport()
		host._consume_country_worker_read_view_if_authoritative()
		OS.delay_msec(1)
	if not exited:
		return {"ok": false, "code": "runtime_stop_incomplete"}
	var policy: Dictionary = host._resolve_climate_authority_policy()
	if bool(policy.get("enabled", false)) and host._generator.has_method("capture_country_worker_inputs"):
		host._country_worker_transport_capture = host._generator.capture_country_worker_inputs()
		if not bool(host._country_worker_transport_capture.get("ok", false)):
			return host._country_worker_transport_capture
	host._start_production_shadow_worker()
	var result: Dictionary = host.climate_authority_diagnostics()
	result["ok"] = not host.runtime_shadow_on_generate or host._web_worker_start_ok
	result["code"] = "ok" if result["ok"] else host._web_worker_start_code
	return result

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
