extends RefCounted

## Read back textures only in the behaviour run. The paired timings never read the GPU.
var _scene: PlayerGame
var _host: WorldRuntimeHost
var _settings: Node
var _view: Viewport
var _camera: MapCamera
var _pause_button: Button
var _mode_index := 0
var _input_checked := false
var _zoom_before := Vector2.ZERO
var _fog_request := false
var _reveal_drawn := false
var _held_day := -1
var _caught_up := false
var _last_day := -1
var _last_weather := PackedByteArray()
var _failure := ""


func setup(scene: PlayerGame, settings: Node) -> void:
	_scene = scene
	_host = scene.get_node("RuntimeHost")
	_settings = settings
	_view = scene.get_viewport()
	_camera = scene.get_node("MapCamera")
	_pause_button = scene.get_node("UI/UIRoot/HUDLayer/PlayerTopBar")._pause_button
	if not _host.is_fog_of_war_enabled():
		_failure = "fog_not_enabled_for_reveal_test"


func step(day: int) -> void:
	var days := [41, 46, 51]
	var limits := [30, -1, 60]
	if _mode_index < days.size() and day >= days[_mode_index]:
		_settings.update({"frame_rate_limit": limits[_mode_index]}, false)
		if Engine.max_fps != (30 if _mode_index == 0 else 60):
			_failure = "live_frame_limit_change_failed"
		_mode_index += 1
	if day >= 42 and _held_day >= 0 and not _input_checked:
		_exercise_input()
	if day >= 47 and not _fog_request:
		_fog_request = true
		if not _host.set_fog_of_war_enabled(false).get("ok", false):
			_failure = "fog_change_not_admitted"


func _exercise_input() -> void:
	_input_checked = true
	var area: Rect2 = _scene.get_node("UI").map_safe_area()
	var center := area.get_center()
	var old_position := _camera.position
	_zoom_before = _camera.zoom
	_push_button(MOUSE_BUTTON_RIGHT, center, true)
	var drag := InputEventMouseMotion.new()
	drag.position = center + Vector2(40, 0)
	drag.relative = Vector2(40, 0)
	drag.button_mask = MOUSE_BUTTON_MASK_RIGHT
	_view.push_input(drag, true)
	_push_button(MOUSE_BUTTON_RIGHT, drag.position, false)
	_push_button(MOUSE_BUTTON_WHEEL_UP, center, true)
	if _camera.position == old_position or _camera._target_zoom == _zoom_before:
		_failure = "map_drag_or_zoom_not_handled"
	var button_center := _pause_button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = button_center
	_view.push_input(motion, true)
	_push_button(MOUSE_BUTTON_LEFT, button_center, true)
	_push_button(MOUSE_BUTTON_LEFT, button_center, false)
	var clock: WorldClock = _scene.get_node("WorldClock")
	if not clock.paused:
		_failure = "pause_button_not_handled"
	_push_button(MOUSE_BUTTON_LEFT, button_center, true)
	_push_button(MOUSE_BUTTON_LEFT, button_center, false)
	if clock.paused:
		_failure = "resume_button_not_handled"


func _push_button(button: MouseButton, at: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.position = at
	event.pressed = pressed
	_view.push_input(event, true)


func check_draw(day: int) -> void:
	var arrived := _host._runtime_commit_day
	if not _failure.is_empty() or arrived < 38 or arrived > 75:
		return
	var world := _host.world_data()
	var weather := world.weather_lut_tex.get_image().get_data()
	if day == _last_day and 40 <= arrived and arrived < 55 and arrived > day:
		_held_day = arrived
		if weather != _last_weather:
			_failure = "weather_changed_during_held_draw"
	if _fog_request and not _reveal_drawn and not _host.is_fog_of_war_enabled():
		var renderer = _host.get_renderer()
		if day != arrived or renderer._fog_enabled or _host._settlement_label_layer._fog_enabled:
			_failure = "vision_layers_late_on_first_revealed_draw"
			return
		_reveal_drawn = true
	if day != _last_day and day == arrived:
		if not _matches_map(world.enum_lut_tex.get_image().get_data(), weather):
			_failure = "cell_texture_missing_committed_changes"
			return
		if not _last_weather.is_empty() and weather != _last_weather \
				and world.weather_lut_prev_tex.get_image().get_data() != _last_weather:
			_failure = "weather_previous_endpoint_mismatch"
			return
		_caught_up = _caught_up or (_held_day >= 0 and day > _held_day)
	_last_day = day
	_last_weather = weather


func _matches_map(classes: PackedByteArray, weather: PackedByteArray) -> bool:
	var map := _host.current_map()
	for cell in map.cell_count():
		var i := cell * 4
		if classes[i] != map.terrain_arr[cell] or classes[i + 1] != map.vegetation_arr[cell] \
				or classes[i + 2] != map.cover_arr[cell] or classes[i + 3] != map.fog_k_arr[cell]:
			return false
		if weather[i] != map.weather_type_arr[cell] \
				or weather[i + 1] != roundi(clampf(map.weather_intensity_arr[cell], 0, 1) * 255.0) \
				or weather[i + 2] != roundi(clampf(map.weather_cloud_arr[cell], 0, 1) * 255.0) \
				or weather[i + 3] != roundi(clampf(map.weather_vapor_arr[cell], 0, 1) * 255.0):
			return false
	return true


func result() -> String:
	if not _failure.is_empty():
		return _failure
	if not _caught_up:
		return "map_never_held_and_caught_up"
	if _mode_index != 3 or not _input_checked or _camera.zoom == _zoom_before:
		return "display_exercise_incomplete"
	if not _reveal_drawn:
		return "missing_reveal_draw"
	return "target"
