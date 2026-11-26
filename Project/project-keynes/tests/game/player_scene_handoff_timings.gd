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
	var map_copies: Array[Dictionary] = []

	func poll_runtime_commit(after_generation: int = 0, take_days: bool = false) -> Dictionary:
		var started := Time.get_ticks_usec()
		var result := super(after_generation, take_days)
		var elapsed := Time.get_ticks_usec() - started
		if take_days and not result.get("days", []).is_empty():
			receive_us += elapsed
			received_batches += 1
			# Older builds copy the two lanes as part of day receipt delivery.
			var lut: Dictionary = result.get("cell_lut_frame", {})
			if not lut.is_empty():
				map_copies.append({"day": result.committed_day, "ns": lut.get("copy_ns", -1),
					"bytes": lut.transition_age.size() + lut.previous_vitality.size()})
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
	var map_copies: Array[Dictionary] = []

	func _init(generator) -> void:
		super(generator)

	func publish_worker_climate_visuals(defer_upload: bool, commit: Dictionary = {}) -> Dictionary:
		var started := Time.get_ticks_usec()
		var result := super(defer_upload, commit)
		refresh_us += Time.get_ticks_usec() - started
		if result.has("map_lut_copy"):
			map_copies.append(result.map_lut_copy)
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


class PanelFeedback extends RefCounted:
	const CLICK_DAYS := [27, 30, 33, 36, 39, 41, 43, 45, 47, 49, 51, 53, 56, 59, 62]
	var _button: Button
	var _panel: Control
	var _index := 0
	var _started := 0
	var _clicked_day := -1
	var _shown := false
	var _samples: Array[Dictionary] = []

	func attach(scene: PlayerGame) -> void:
		var ui: GameUIManager = scene.get_node("UI")
		_button = ui._top_bar._dispatch_button
		_panel = ui._colonization_panel

	func step(day: int, viewport: Viewport) -> void:
		if _shown:
			_panel.close_panel()
			_shown = false
			return
		if _started != 0 or _index == CLICK_DAYS.size() or day < CLICK_DAYS[_index]:
			return
		if not _button.is_visible_in_tree():
			return
		_clicked_day = day
		_started = Time.get_ticks_usec()
		for pressed in [true, false]:
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = pressed
			click.position = _button.get_global_rect().get_center()
			viewport.push_input(click, true)

	func observe_draw(usec: int) -> void:
		if _started == 0 or not _panel.is_visible_in_tree() or _panel.modulate.a <= 0.0:
			return
		if _panel.get("_current_tab") != "expeditions":
			return
		_samples.append({"day": _clicked_day, "usec": usec - _started})
		_started = 0
		_index += 1
		_shown = true

	func take() -> Array[Dictionary]:
		var samples := _samples
		_samples = []
		return samples

	func complete() -> bool:
		return _index == CLICK_DAYS.size()


var _consumer := TimedConsumer.new()
var _bridge := TimedBridge.new()
var _vision := TimedVision.new()
var _visuals: TimedClimateVisuals
var _upload: Node


func attach(host: WorldRuntimeHost) -> void:
	var generator := host.get_generator()
	_bridge._generator = generator
	_bridge._main_steps = generator._get_map_runtime_bridge()._main_steps
	if "measure_map_lut_copies" in _bridge:
		_bridge.set("measure_map_lut_copies", true)
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
		"map_copies": _bridge.map_copies + _visuals.map_copies,
		"climate_install_us": _consumer.climate_install_us, "vision_install_us": _vision.install_us,
		"cell_refresh_us": _visuals.refresh_us, "cell_encode_us": _visuals.encode_us,
		"immediate_texture_us": _visuals.immediate_texture_us,
		"staged_publish_us": int(_upload.get("upload_us")) if _upload != null else 0}
	_consumer.consume_us = 0
	_consumer.climate_install_us = 0
	_bridge.receive_us = 0
	_bridge.received_batches = 0
	_bridge.map_copies.clear()
	_vision.install_us = 0
	_visuals.refresh_us = 0
	_visuals.encode_us = 0
	_visuals.immediate_texture_us = 0
	_visuals.map_copies.clear()
	if _upload != null:
		_upload.set("upload_us", 0)
	return sample
