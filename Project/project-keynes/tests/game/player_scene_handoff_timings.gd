extends RefCounted

## Time the production calls from the probe, without changing their inputs or order.
const RendererWeatherState = preload("res://scripts/rendering/renderer_weather_state.gd")


class TimedConsumer extends "res://scripts/game/world_runtime_daily_adapter_part3.gd":
	var consume_us := 0
	var climate_install_us := 0

	func _consume_runtime_commit_if_ready(host, report_override: Dictionary = {}) -> void:
		var started := Time.get_ticks_usec()
		super(host, report_override)
		consume_us += Time.get_ticks_usec() - started

	func _apply_climate_writeback_if_authoritative(host, report: Dictionary,
			commit: Dictionary = {}) -> void:
		var started := Time.get_ticks_usec()
		super(host, report, commit)
		climate_install_us += Time.get_ticks_usec() - started


class TimedBridge extends "res://scripts/game/map_runtime_bridge.gd":
	var receive_us := 0
	var received_batches := 0

	func poll_runtime_commit(after_generation: int = 0, take_days: bool = false) -> Dictionary:
		var started := Time.get_ticks_usec()
		var result := super(after_generation, take_days)
		var elapsed := Time.get_ticks_usec() - started
		if take_days and not result.get("days", []).is_empty():
			receive_us += elapsed
			received_batches += 1
		return result


class TimedVision extends "res://scripts/game/world_runtime_visual_adapter.gd":
	var install_us := 0

	func apply_runtime_vision_display(host) -> Dictionary:
		var started := Time.get_ticks_usec()
		var result := super(host)
		install_us += Time.get_ticks_usec() - started
		return result


class TimedClimateVisuals extends "res://scripts/simulation/climate/mapgen_native_daily_runtime.gd":
	var refresh_us := 0
	var encode_us := 0
	var immediate_texture_us := 0

	func _init(generator) -> void:
		super(generator)

	func publish_worker_climate_visuals(defer_upload: bool, commit: Dictionary = {}) -> Dictionary:
		var started := Time.get_ticks_usec()
		var result := super(defer_upload, commit)
		refresh_us += Time.get_ticks_usec() - started
		if result.get("lut_encode_path") == "gdext":
			encode_us += roundi(float(result.get("elapsed_ms", 0.0)) * 1000.0)
		immediate_texture_us += roundi(float(result.get("texture_upload_ms", 0.0)) * 1000.0)
		return result


class TimedUpload extends RendererWeatherState.CellLutUpload:
	var upload_us := 0

	func _process(delta: float) -> void:
		var world: WorldData = get_parent()._world
		var pending := world != null and not world.staged_cell_lut_upload.is_empty()
		var started := Time.get_ticks_usec() if pending else 0
		super(delta)
		if started > 0:
			upload_us += Time.get_ticks_usec() - started


var _consumer := TimedConsumer.new()
var _bridge := TimedBridge.new()
var _vision := TimedVision.new()
var _visuals: TimedClimateVisuals
var _upload: Node


func attach(host: WorldRuntimeHost) -> void:
	var generator := host.get_generator()
	_bridge._generator = generator
	_bridge._main_steps = generator._get_map_runtime_bridge()._main_steps
	generator._map_runtime_bridge = _bridge
	_visuals = TimedClimateVisuals.new(generator)
	generator._mapgen_native_daily_runtime = _visuals
	host._daily_adapter._part3 = _consumer
	host._visual_adapter = _vision
	var renderer := host.get_renderer()
	if renderer != null:
		_upload = renderer.get_node_or_null(^"CellLutUpload")
		if _upload != null:
			_upload.set_script(TimedUpload)


func take() -> Dictionary:
	var sample := {"consume_us": _consumer.consume_us,
		"receive_us": _bridge.receive_us, "received_batches": _bridge.received_batches,
		"climate_install_us": _consumer.climate_install_us, "vision_install_us": _vision.install_us,
		"cell_refresh_us": _visuals.refresh_us, "cell_encode_us": _visuals.encode_us,
		"immediate_texture_us": _visuals.immediate_texture_us,
		"staged_publish_us": int(_upload.get("upload_us")) if _upload != null else 0}
	_consumer.consume_us = 0
	_consumer.climate_install_us = 0
	_bridge.receive_us = 0
	_bridge.received_batches = 0
	_vision.install_us = 0
	_visuals.refresh_us = 0
	_visuals.encode_us = 0
	_visuals.immediate_texture_us = 0
	if _upload != null:
		_upload.set("upload_us", 0)
	return sample
