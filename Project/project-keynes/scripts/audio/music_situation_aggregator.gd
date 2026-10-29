extends RefCounted
class_name MusicSituationAggregator

## Presentation-only situation reader for adaptive music.
##
## This object never advances simulation state and never writes economy/climate
## data.  It consumes committed event/snapshot data, keeps a bounded near-camera
## sample, and exposes normalized targets for GameAudioService.

const LOCAL_SAMPLE_CAP := 64
const LOCAL_REFRESH_SECONDS := 0.5
const FMOD_WRITE_THRESHOLD := 0.02
const FMOD_WRITE_INTERVAL_SECONDS := 0.25
const CRISIS_IMPULSE_SECONDS := 8.0
const TENSION_ATTACK_SECONDS := 1.5
const TENSION_RELEASE_SECONDS := 4.0

const ECONOMY_EVENT_CONSTRUCTION_COMPLETED := 5
const ECONOMY_EVENT_TRADE_ARRIVED := 13
const ECONOMY_EVENT_POPULATION_CHANGED := 16

const SITUATION_STRIDE := 8
const SITUATION_FOOD := 0
const SITUATION_INDUSTRY := 1
const SITUATION_CONSUMER := 2
const SITUATION_DISCONTENT := 3
const SITUATION_DROUGHT := 4
const SITUATION_FLOOD := 5
const SITUATION_UNEMPLOYMENT := 6
const SITUATION_OPENINGS := 7

var _runtime_host = null
var _generator = null
var _player_controller = null
var _economy = null
var _event_bus = null
var _situation_cache = null
var _map = null
var _camera = null

var _configured := false
var _consumer_id: StringName = &"pk_music_situation"
var _economy_consumer_id: StringName = &"pk_music_situation_economy"
var _player_country_handle := 0
var _player_country_slot := -1
var _fog_enabled := false

var _social_pressure := 0.5
var _weather_pressure := 0.0
var _local_pressure := 0.0
var _activity := 0.0
var _crisis_impulse := 0.0
var _tension_target := 0.275
var _tension_value := 0.275
var _last_tension_sent := -1.0
var _time_since_fmod_write := 999.0
var _local_query_due := 0.0
var _local_dirty := true
var _last_world_rect := Rect2()
var _last_camera_zoom := -1.0
var _last_view_center := Vector2(INF, INF)
var _last_commit_day := -1
var _last_query_ms := 0.0
var _query_count := 0
var _candidate_count := 0
var _sampled_cells := 0
var _local_busy := false
var _fallback_pressure_seeded := false

var _diagnostics := {
	"tension": 0.275,
	"activity": 0.0,
	"social_pressure": 0.5,
	"weather_pressure": 0.0,
	"local_pressure": 0.0,
	"near_weight": 0.0,
	"sampled_cells": 0,
	"candidate_cells": 0,
	"last_query_ms": 0.0,
	"query_count": 0,
	"local_busy": false,
	"source_day": -1,
}


func configure(runtime_host, generator, player_controller) -> void:
	_runtime_host = runtime_host
	_generator = generator
	_player_controller = player_controller
	_map = runtime_host.current_map() if runtime_host != null and runtime_host.has_method("current_map") else null
	_camera = player_controller._camera if player_controller != null and "_camera" in player_controller else null
	var ui_manager = player_controller._ui_manager if player_controller != null and "_ui_manager" in player_controller else null
	_situation_cache = ui_manager.get_node_or_null("UIRoot/HUDLayer/CellSituationLayer") \
		if ui_manager != null and ui_manager.has_method("get_node_or_null") else null
	_economy = generator.get_economy_facade() if generator != null and generator.has_method("get_economy_facade") else null
	_event_bus = generator.get_gameplay_event_bus() if generator != null and generator.has_method("get_gameplay_event_bus") else null
	_player_country_handle = int(player_controller.get_player_country_handle()) \
		if player_controller != null and player_controller.has_method("get_player_country_handle") else 0
	_player_country_slot = int(runtime_host.player_country_slot()) \
		if runtime_host != null and runtime_host.has_method("player_country_slot") else -1
	_fog_enabled = bool(runtime_host.is_fog_of_war_enabled()) \
		if runtime_host != null and runtime_host.has_method("is_fog_of_war_enabled") else false
	_social_pressure = 0.5
	_weather_pressure = 0.0
	_local_pressure = 0.0
	_activity = 0.0
	_crisis_impulse = 0.0
	_tension_target = 0.275
	_tension_value = 0.275
	_last_tension_sent = -1.0
	_time_since_fmod_write = 999.0
	_local_query_due = 0.0
	_last_commit_day = -1
	_last_query_ms = 0.0
	_query_count = 0
	_candidate_count = 0
	_sampled_cells = 0
	_fallback_pressure_seeded = false
	_diagnostics["tension"] = _tension_value
	_diagnostics["activity"] = 0.0
	_diagnostics["social_pressure"] = _social_pressure
	_diagnostics["weather_pressure"] = 0.0
	_diagnostics["local_pressure"] = 0.0
	_diagnostics["near_weight"] = 0.0
	_diagnostics["sampled_cells"] = 0
	_diagnostics["candidate_cells"] = 0
	_diagnostics["last_query_ms"] = 0.0
	_diagnostics["query_count"] = 0
	_diagnostics["local_busy"] = false
	_diagnostics["source_day"] = -1
	_configured = _map != null and _generator != null
	_local_dirty = true
	_seed_initial_social_pressure()


func refresh_global_from_commit() -> void:
	if not _configured:
		return
	_map = _runtime_host.current_map() if _runtime_host != null and _runtime_host.has_method("current_map") else _map
	_player_country_slot = int(_runtime_host.player_country_slot()) \
		if _runtime_host != null and _runtime_host.has_method("player_country_slot") else _player_country_slot
	_fog_enabled = bool(_runtime_host.is_fog_of_war_enabled()) \
		if _runtime_host != null and _runtime_host.has_method("is_fog_of_war_enabled") else _fog_enabled
	_consume_gameplay_events()
	_consume_economy_events()
	_refresh_weather_pressure()
	if _world_clock_day() >= 0:
		_last_commit_day = _world_clock_day()
	_diagnostics["source_day"] = _last_commit_day
	_local_dirty = true
	_recompute_tension_target()


func refresh_local_from_view(world_rect: Rect2, camera_zoom: float) -> void:
	if not _configured or _economy == null or not _economy.has_method("cell_situation_snapshot"):
		return
	var now := _clock_seconds()
	var center := world_rect.get_center()
	var zoom_changed := _last_camera_zoom < 0.0 or absf(camera_zoom - _last_camera_zoom) > 0.01
	var view_changed := _last_world_rect != world_rect or _last_view_center.distance_squared_to(center) > 16.0
	_last_camera_zoom = camera_zoom
	_last_world_rect = world_rect
	_last_view_center = center
	if now < _local_query_due and not (_local_dirty or zoom_changed or view_changed):
		return
	_local_query_due = now + LOCAL_REFRESH_SECONDS
	_local_dirty = false
	var near_weight := near_weight_for_camera_zoom(camera_zoom)
	_diagnostics["near_weight"] = near_weight
	if near_weight <= 0.001:
		_local_pressure = 0.0
		_sampled_cells = 0
		_diagnostics["local_pressure"] = 0.0
		_diagnostics["sampled_cells"] = 0
		_recompute_tension_target()
		return

	if _situation_cache != null and _situation_cache.has_method("music_situation_snapshot"):
		var cached: Dictionary = _situation_cache.music_situation_snapshot(_player_country_slot)
		if bool(cached.get("ok", false)) and not cached.get("cell_indices", PackedInt32Array()).is_empty() \
				and float(cached.get("cache_age_seconds", 999.0)) <= 1.0:
			_local_pressure = _aggregate_local_pressure(cached)
			_sampled_cells = int(cached.get("cell_indices", PackedInt32Array()).size())
			_candidate_count = _sampled_cells
			_last_query_ms = 0.0
			_diagnostics["last_query_ms"] = 0.0
			_diagnostics["cache_source"] = "cell_situation_layer"
			_diagnostics["sampled_cells"] = _sampled_cells
			_diagnostics["candidate_cells"] = _candidate_count
			_diagnostics["local_pressure"] = _local_pressure
			_recompute_tension_target()
			return

	var candidates := _build_local_candidates(world_rect)
	_candidate_count = candidates.size()
	_diagnostics["candidate_cells"] = _candidate_count
	if candidates.is_empty():
		_local_pressure = 0.0
		_sampled_cells = 0
		_diagnostics["local_pressure"] = 0.0
		_diagnostics["sampled_cells"] = 0
		_recompute_tension_target()
		return

	var started := Time.get_ticks_usec()
	_local_busy = true
	var packet: Dictionary = _economy.cell_situation_snapshot(candidates)
	_last_query_ms = float(Time.get_ticks_usec() - started) / 1000.0
	_query_count += 1
	_local_busy = false
	_diagnostics["last_query_ms"] = _last_query_ms
	_diagnostics["query_count"] = _query_count
	_diagnostics["local_busy"] = false
	if not bool(packet.get("ok", false)) or not bool(packet.get("committed", false)):
		_diagnostics["local_busy"] = bool(packet.get("busy", false))
		return
	_local_pressure = _aggregate_local_pressure(packet)
	_sampled_cells = int(packet.get("cell_indices", PackedInt32Array()).size())
	_diagnostics["local_pressure"] = _local_pressure
	_diagnostics["sampled_cells"] = _sampled_cells
	_recompute_tension_target()


func process_audio_update(delta: float) -> Dictionary:
	if not _configured:
		return diagnostics()
	var step := maxf(delta, 0.0)
	_crisis_impulse = maxf(0.0, _crisis_impulse - step / CRISIS_IMPULSE_SECONDS)
	_activity = maxf(0.0, _activity - step / CRISIS_IMPULSE_SECONDS)
	_recompute_tension_target()
	if _camera != null and _camera.has_method("current_world_view_rect"):
		var camera_zoom_ratio := 0.5
		if _player_controller != null and _player_controller.has_method("music_camera_zoom_ratio"):
			camera_zoom_ratio = float(_player_controller.music_camera_zoom_ratio())
		refresh_local_from_view(_camera.current_world_view_rect(), camera_zoom_ratio)
	_time_since_fmod_write += step
	var target := _tension_target
	var time_constant := TENSION_ATTACK_SECONDS if target > _tension_value else TENSION_RELEASE_SECONDS
	var alpha := 1.0 - exp(-maxf(delta, 0.0) / maxf(time_constant, 0.001))
	_tension_value = lerpf(_tension_value, target, clampf(alpha, 0.0, 1.0))
	_diagnostics["tension"] = _tension_value
	_diagnostics["activity"] = _activity
	if absf(_tension_value - _last_tension_sent) >= FMOD_WRITE_THRESHOLD \
			or _time_since_fmod_write >= FMOD_WRITE_INTERVAL_SECONDS:
		_diagnostics["tension_write_due"] = true
	else:
		_diagnostics["tension_write_due"] = false
	return diagnostics()


func tension_target() -> float:
	return _tension_target


func activity_target() -> float:
	return _activity


func consume_tension_write() -> float:
	_last_tension_sent = _tension_value
	_time_since_fmod_write = 0.0
	_diagnostics["tension_write_due"] = false
	return _tension_value


func diagnostics() -> Dictionary:
	var out := _diagnostics.duplicate(false)
	out["tension_target"] = _tension_target
	out["tension"] = _tension_value
	out["activity"] = _activity
	out["crisis_impulse"] = _crisis_impulse
	out["configured"] = _configured
	return out


static func social_pressure_score(level: int) -> float:
	return clampf(1.0 - float(clampi(level, 0, 4)) / 4.0, 0.0, 1.0)


static func near_weight_for_camera_zoom(camera_zoom: float) -> float:
	return smoothstep(0.60, 0.35, clampf(camera_zoom, 0.0, 1.0))


static func aggregate_risk_values(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted := Array(values)
	sorted.sort()
	var sum := 0.0
	for value in sorted:
		sum += clampf(float(value), 0.0, 1.0)
	var p90_index := clampi(ceili(float(sorted.size()) * 0.90) - 1, 0, sorted.size() - 1)
	return clampf(0.7 * float(sorted[p90_index]) + 0.3 * sum / float(sorted.size()), 0.0, 1.0)


func _consume_gameplay_events() -> void:
	if _event_bus == null or not _event_bus.has_method("poll_events"):
		return
	var batch: Dictionary = _event_bus.poll_events(_consumer_id, 128, 0, true)
	var count := int(batch.get("count", 0))
	if count <= 0:
		return
	var types: PackedInt32Array = batch.get("type", PackedInt32Array())
	var payload_i0: PackedInt32Array = batch.get("payload_i0", PackedInt32Array())
	var payload_i3: PackedInt32Array = batch.get("payload_i3", PackedInt32Array())
	for index in range(count):
		var event_type := int(types[index]) if index < types.size() else 0
		if event_type == GameplayEventBus.EVENT_ECONOMY_SOCIAL_PRESSURE:
			var level := int(payload_i0[index]) if index < payload_i0.size() else 2
			var previous := int(payload_i3[index]) if index < payload_i3.size() else level
			_social_pressure = social_pressure_score(level)
			if level < previous:
				_crisis_impulse = maxf(_crisis_impulse, 0.75)
		elif event_type == GameplayEventBus.EVENT_WEATHER_OBSERVED:
			_crisis_impulse = maxf(_crisis_impulse, 0.35)
		elif event_type in [GameplayEventBus.EVENT_ECONOMY_CONSTRUCTION_COMPLETED,
				GameplayEventBus.EVENT_ECONOMY_TRADE_ARRIVED,
				GameplayEventBus.EVENT_TECHNOLOGY_ADOPTED,
				GameplayEventBus.EVENT_TERRAIN_FLIP]:
			_activity = maxf(_activity, 0.75)


func _consume_economy_events() -> void:
	if _economy == null or not _economy.has_method("poll_events"):
		return
	var batch: Dictionary = _economy.poll_events(_economy_consumer_id, 128, 0)
	var count := int(batch.get("count", 0))
	if count <= 0:
		return
	var kinds: PackedInt32Array = batch.get("kind", PackedInt32Array())
	for index in range(count):
		var kind := int(kinds[index]) if index < kinds.size() else 0
		if kind in [ECONOMY_EVENT_CONSTRUCTION_COMPLETED,
				ECONOMY_EVENT_TRADE_ARRIVED,
				ECONOMY_EVENT_POPULATION_CHANGED]:
			_activity = maxf(_activity, 0.5)


func _refresh_weather_pressure() -> void:
	if _generator == null or not _generator.has_method("active_weather_fronts"):
		return
	var max_pressure := 0.0
	for front in _generator.active_weather_fronts():
		if front == null or not front.is_alive():
			continue
		if int(front.type) == WeatherType.WT.CLEAR:
			continue
		max_pressure = maxf(max_pressure, clampf(float(front.intensity), 0.0, 1.0))
	_weather_pressure = max_pressure
	_diagnostics["weather_pressure"] = _weather_pressure


func _recompute_tension_target() -> void:
	var global_tension := clampf(
		0.55 * _social_pressure + 0.25 * _weather_pressure + 0.20 * _crisis_impulse,
		0.0, 1.0)
	var near_weight := float(_diagnostics.get("near_weight", 0.0))
	_tension_target = lerpf(global_tension,
		clampf(0.75 * global_tension + 0.25 * _local_pressure, 0.0, 1.0),
		near_weight)
	_diagnostics["social_pressure"] = _social_pressure
	_diagnostics["weather_pressure"] = _weather_pressure
	_diagnostics["tension_target"] = _tension_target


func _aggregate_local_pressure(packet: Dictionary) -> float:
	var severity: PackedInt32Array = packet.get("severity_q16", PackedInt32Array())
	var cell_count := int(packet.get("cell_indices", PackedInt32Array()).size())
	if cell_count <= 0 or severity.size() < cell_count * SITUATION_STRIDE:
		return 0.0
	var values := PackedFloat32Array()
	values.resize(cell_count)
	for cell_index in range(cell_count):
		var base := cell_index * SITUATION_STRIDE
		var risk := 0.0
		for kind in range(SITUATION_STRIDE):
			risk = maxf(risk, float(severity[base + kind]) / 65535.0)
		values[cell_index] = clampf(risk, 0.0, 1.0)
	return aggregate_risk_values(values)


func _build_local_candidates(world_rect: Rect2) -> PackedInt32Array:
	var out := PackedInt32Array()
	if _map == null or _player_country_slot < 0:
		return out
	var hex_size := float(_runtime_host.hex_size) if _runtime_host != null else 22.0
	var start := world_rect.position - Vector2(hex_size * 2.0, hex_size * 2.0)
	var end := world_rect.end + Vector2(hex_size * 2.0, hex_size * 2.0)
	var first_row := maxi(0, floori(start.y / (hex_size * 1.5)) - 1)
	var last_row := mini(_map.height - 1, ceili(end.y / (hex_size * 1.5)) + 1)
	var column_step := sqrt(3.0) * hex_size
	var seen := {}
	for row in range(first_row, last_row + 1):
		var shift := 0.5 * float(row & 1)
		var first_col := floori(start.x / column_step - shift) - 1
		var last_col := ceili(end.x / column_step - shift) + 1
		for col in range(first_col, last_col + 1):
			var cube := HexUtils.offset_to_cube(posmod(col, _map.width), row)
			var cell = _map.get_cell_by_cube(cube)
			if cell == null or seen.has(cell.index):
				continue
			seen[cell.index] = true
			if not _can_sample_cell(int(cell.index)):
				continue
			out.append(int(cell.index))
	if out.size() <= LOCAL_SAMPLE_CAP:
		return out
	# Center-first sampling keeps the audio response tied to what the player sees.
	var center := world_rect.get_center()
	var distances := {}
	for cell_index in out:
		var cell = _map.cell_at(int(cell_index))
		var pos := HexUtils.cube_to_world(cell.q, cell.r, hex_size)
		distances[int(cell_index)] = pos.distance_squared_to(center)
	var sorted: Array = Array(out)
	sorted.sort_custom(func(a, b):
		return distances[a] < distances[b] if distances[a] != distances[b] else a < b)
	var capped := PackedInt32Array()
	for cell_index in sorted.slice(0, LOCAL_SAMPLE_CAP):
		capped.append(int(cell_index))
	return capped


func _can_sample_cell(cell_index: int) -> bool:
	if _map == null or cell_index < 0 or cell_index >= _map.cell_count():
		return false
	if cell_index >= _map.country_slot_arr.size() or int(_map.country_slot_arr[cell_index]) != _player_country_slot:
		return false
	if not _fog_enabled:
		return true
	return cell_index < _map.visible_arr.size() and _map.visible_arr[cell_index] != 0


func _seed_initial_social_pressure() -> void:
	if _fallback_pressure_seeded or _economy == null or not _economy.has_method("country_class_opinion_snapshot"):
		return
	_fallback_pressure_seeded = true
	var snapshot: Dictionary = _economy.country_class_opinion_snapshot()
	var handles: PackedInt64Array = snapshot.get("country_handles", PackedInt64Array())
	var satisfaction: PackedInt32Array = snapshot.get("satisfaction_q16", PackedInt32Array())
	for index in range(handles.size()):
		if int(handles[index]) != _player_country_handle or index >= satisfaction.size():
			continue
		var sat := clampf(float(satisfaction[index]) / 65535.0, 0.0, 1.0)
		_social_pressure = 1.0 - sat
		_diagnostics["social_pressure"] = _social_pressure
		return


func _world_clock_day() -> int:
	if _player_controller != null and "_world_clock" in _player_controller and _player_controller._world_clock != null:
		return int(_player_controller._world_clock.day_index())
	return -1


func _clock_seconds() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
