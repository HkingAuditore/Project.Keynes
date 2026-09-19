extends Node

# Visible Stage C client runner. This is deliberately a detached root: it
# starts the formal GameFlow session, survives the scene swap, then observes
# the real player_game scene without adding any measurement-only node to it.

const PerfRecorderScript = preload("res://scripts/ui/perf_recorder.gd")
const TileDataRecorderScript = preload("res://scripts/ui/tile_data_recorder.gd")

const DEFAULT_SEED := 20260718
const DEFAULT_MAP_WIDTH := 60
const DEFAULT_MAP_HEIGHT := 40
const DEFAULT_FOREIGN_COUNT := 3
const DEFAULT_SPEED := 50.0
const DEFAULT_WARMUP_SECONDS := 5.0
const DEFAULT_RECORD_SECONDS := 30.0
const WINDOW_SIZE := Vector2i(1600, 960)

var _args: Dictionary = {}
var _mode := "OFF"
var _worker_mode := "SHADOW"
var _output_dir := ""
var _run_id := ""
var _manual := false
var _auto_tile := false
var _warmup_seconds := DEFAULT_WARMUP_SECONDS
var _record_seconds := DEFAULT_RECORD_SECONDS
var _warmup_until_tick := -1
var _record_ticks := 0
var _player: PlayerGame = null
var _host: WorldRuntimeHost = null
var _clock: WorldClock = null
var _recorder: RefCounted = null
var _economy_recorder: RefCounted = null
var _world_ready := false
var _recording := false
var _record_started_usec := 0
var _last_frame_usec := 0
var _frame_index := 0
var _last_fast_tick_count := 0
var _frame_file: FileAccess = null
var _runtime_report_start: Dictionary = {}
var _runtime_report_record_start: Dictionary = {}
var _runtime_report_end: Dictionary = {}
var _climate_start: Dictionary = {}
var _climate_end: Dictionary = {}
var _session: Dictionary = {}
var _record_fast_tick_start := 0
var _record_fast_tick_end := 0
var _record_clock_day_start := -1
var _record_clock_day_end := -1
var _last_completed_days := 0
var _last_completed_usec := 0
var _max_commit_gap_ms := 0.0


func _ready() -> void:
	_args = _arguments()
	if not OS.is_debug_build():
		_fail("Stage C client runner is Debug-only")
		return
	_mode = String(_args.get("mode", "OFF")).to_upper()
	if _mode not in ["ACTIVE", "OFF"]:
		_fail("mode must be ACTIVE or OFF")
		return
	_worker_mode = "ACTIVE" if _mode == "ACTIVE" else "SHADOW"
	_manual = _enabled(_args.get("manual", "false"))
	_auto_tile = _enabled(_args.get("auto_tile", "false"))
	_warmup_seconds = maxf(0.0, float(_args.get("warmup_seconds", DEFAULT_WARMUP_SECONDS)))
	_record_seconds = maxf(0.0, float(_args.get("record_seconds", DEFAULT_RECORD_SECONDS)))
	_warmup_until_tick = int(_args.get("warmup_until_tick", -1))
	_record_ticks = maxi(0, int(_args.get("record_ticks", 0)))
	_run_id = String(_args.get("run_id", "")).strip_edges()
	if _run_id.is_empty():
		_run_id = "client-%s-%s" % [_mode.to_lower(), _timestamp_id()]
	_output_dir = _resolve_output_dir(String(_args.get("output_dir", "")), _run_id)
	DirAccess.make_dir_recursive_absolute(_output_dir)
	_build_session_metadata()
	# These are Debug-only hooks consumed by PlayerGame before its host is
	# configured. They are intentionally not project settings or GM toggles.
	Engine.set_meta(&"stage_c_authority_mode", _mode)
	if _args.has("auto_pod_active"):
		Engine.set_meta(&"stage_c_auto_pod_active", _enabled(_args["auto_pod_active"]))
	Engine.set_meta(&"stage_c_tile_metadata", _tile_metadata())
	call_deferred("_begin_formal_session")


func _begin_formal_session() -> void:
	# Move out of the current scene before GameFlow deletes that scene.
	var tree := get_tree()
	var root := tree.root
	var was_current_scene := tree.current_scene == self
	if get_parent() != root:
		get_parent().remove_child(self)
		root.add_child(self)
	if was_current_scene:
		tree.current_scene = null
	var config := NewGameConfig.create_default()
	config.country.name = "Stage C Client"
	config.country.foreign_count = int(_args.get("foreign_count", DEFAULT_FOREIGN_COUNT))
	config.base.map_width = int(_args.get("width", DEFAULT_MAP_WIDTH))
	config.base.map_height = int(_args.get("height", DEFAULT_MAP_HEIGHT))
	config.base.initial_seed = int(_args.get("seed", DEFAULT_SEED))
	config.apply_land_layout("two")
	var result: Dictionary = GameFlow.begin_new_game(config)
	if not bool(result.get("ok", false)):
		_fail("GameFlow.begin_new_game failed: %s" % JSON.stringify(result))
		return
	await tree.process_frame
	await tree.process_frame
	await _await_player_world()


func _await_player_world() -> void:
	while _player == null or not is_instance_valid(_player):
		var current := get_tree().current_scene
		if current is PlayerGame:
			_player = current as PlayerGame
			_host = _player.get_node_or_null("RuntimeHost") as WorldRuntimeHost
			_clock = _player.get_node_or_null("WorldClock") as WorldClock
			if _host == null or _clock == null:
				_fail("player_game missing RuntimeHost or WorldClock")
				return
			if not _host.world_ready.is_connected(_on_world_ready):
				_host.world_ready.connect(_on_world_ready)
			if _host.get_current_map() != null and _host.is_runtime_ready_for_ticks():
				_on_world_ready(null, null, _host.get_generator(), null)
				return
		await get_tree().process_frame


func _on_world_ready(_map, _world_data, _generator, _view_adapter) -> void:
	if _world_ready:
		return
	_world_ready = true
	_apply_fixed_client_settings()
	_runtime_report_start = _runtime_report()
	_climate_start = _host.climate_authority_diagnostics()
	_session["runtime_report_start"] = _runtime_report_start.duplicate(true)
	_session["climate_authority_start"] = _climate_start.duplicate(true)
	var initial_resources: Array = []
	var start_cell := _host._resolve_player_start_cell()
	var map := _host.get_current_map()
	var ext = _host.get_generator().get_data_core_world_ext()
	if start_cell >= 0 and map != null and ext != null:
		for profile in ResourceProfileRegistry.ordered():
			var map_values: PackedFloat32Array = map.get(ResourceProfileRegistry.reserve_map_field(profile))
			var sid: int = ext.component_id(ResourceProfileRegistry.reserve_cpp_name(profile))
			var native_values: PackedFloat32Array = ext.snapshot_f32(sid) if sid >= 0 else PackedFloat32Array()
			initial_resources.append({"resource": String(profile.id), "cell": start_cell,
				"map_reserve": map_values[start_cell],
				"native_reserve": native_values[start_cell] if start_cell < native_values.size() else -1.0})
	_session["initial_resource_bridge"] = initial_resources
	_write_session("world_ready")
	if _manual:
		if _auto_tile and _warmup_until_tick >= 0:
			await _wait_fast_tick_target(_warmup_until_tick)
		else:
			await _wait_realtime(_warmup_seconds)
		_clock.pause(true)
		_host.on_clock_running_changed(false)
		if _auto_tile:
			await _run_automated_tile_recording()
			return
		_write_session("manual_ready")
		print("[stage-c/client] manual ready mode=%s worker=%s output=%s; start/stop TileDataRecorder in GM, then run x50 for 30 seconds." % [
			_mode, _worker_mode, _output_dir])
		return
	await _wait_realtime(_warmup_seconds)
	_start_recording()


func _run_automated_tile_recording() -> void:
	_recorder = TileDataRecorderScript.new()
	_recorder.bind_main(_host)
	_host.set_tile_data_recorder(_recorder)
	_recorder.start()
	if not _recorder.is_recording():
		_fail("TileDataRecorder failed to start")
		return
	_write_session("tile_recording")
	_clock.pause(false)
	_host.on_clock_running_changed(true)
	print("[stage-c/client] tile recording mode=%s worker=%s seconds=%.2f output=%s" % [
		_mode, _worker_mode, _record_seconds, _output_dir])
	if _record_ticks > 0:
		while _recorder.recorded_tick_count() < _record_ticks:
			await get_tree().process_frame
	else:
		await _wait_realtime(_record_seconds)
	_clock.pause(true)
	_host.on_clock_running_changed(false)
	var tile_path: String = String(_recorder.stop_and_export())
	var sidecar_path: String = String(_recorder.sidecar_path())
	var summary: Dictionary = _recorder.sampling_summary()
	_session["tile_csv"] = tile_path
	_session["tile_sidecar"] = sidecar_path
	_session["tile_ticks_seen"] = int(_recorder.tick_count())
	_session["tile_ticks_recorded"] = int(_recorder.recorded_tick_count())
	_session["tile_rows"] = int(_recorder.row_count())
	_session["tile_sampling"] = summary.duplicate(true)
	_write_session("complete")
	_host.set_tile_data_recorder(null)
	Engine.remove_meta(&"stage_c_authority_mode")
	Engine.remove_meta(&"stage_c_tile_metadata")
	print("[stage-c/client] tile complete mode=%s ticks=%d rows=%d csv=%s" % [
		_mode, int(_recorder.recorded_tick_count()), int(_recorder.row_count()), tile_path])
	get_tree().quit(0 if not tile_path.is_empty() else 2)


func _apply_fixed_client_settings() -> void:
	_session["auto_pod_active"] = _host.runtime_economy_auto_pod_active
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
	DisplayServer.window_set_size(WINDOW_SIZE)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var applied_window := DisplayServer.window_get_size()
	_session["actual_window_width"] = applied_window.x
	_session["actual_window_height"] = applied_window.y
	_session["actual_vsync_mode"] = DisplayServer.window_get_vsync_mode()
	_session["actual_max_fps"] = Engine.max_fps
	var settings = get_node_or_null("/root/GameSettings")
	if settings != null and settings.has_method("update"):
		settings.update({
			"window_mode": "windowed",
			"resolution_width": WINDOW_SIZE.x,
			"resolution_height": WINDOW_SIZE.y,
			"vsync": false,
			"render_quality": "high",
		}, false)
	var renderer := _host.get_renderer()
	if renderer != null:
		if renderer.has_method("set_visual_quality"):
			renderer.set_visual_quality(2)
		if renderer.has_method("set_perf_sampler_enabled"):
			renderer.set_perf_sampler_enabled(false)
	_host.set_day_night_enabled(true)
	_host.clear_map_overlay()
	_clock.set_speed(float(_args.get("speed", DEFAULT_SPEED)))
	_host.on_clock_running_changed(true)


func _start_recording() -> void:
	if _recording:
		return
	_recorder = PerfRecorderScript.new()
	_recorder.bind_main(_host)
	_recorder.configure_export(_output_dir, "perf.csv")
	_host.set_perf_recorder(_recorder)
	_recorder.start("CORE", 1)
	if _enabled(_args.get("auto_economy", "false")):
		_economy_recorder = preload("res://scripts/ui/economy_data_recorder.gd").new()
		_economy_recorder.bind_main(_host)
		if _host.get_selected_cell() == null:
			var start_cell := _host._resolve_player_start_cell()
			if start_cell >= 0:
				_host.set_selected_cell(_host.get_current_map().cell_at(start_cell))
		# A selected-cell record stays useful for long soaks without exhausting
		# the hard row cap on thousands of empty markets.
		if _host.get_selected_cell() != null:
			_economy_recorder.set_current_cell_only(true)
		else:
			_economy_recorder.set_sampling_config(100)
		_host.set_economy_data_recorder(_economy_recorder)
		_economy_recorder.start()
	_frame_file = FileAccess.open(_output_dir.path_join("frame_samples.csv"), FileAccess.WRITE)
	if _frame_file == null:
		_fail("could not create frame_samples.csv")
		return
	_frame_file.store_line("frame_idx,timestamp_ms,frame_wall_ms,fast_tick_count,fast_tick_occurred,last_fast_tick_ms,clock_day,writeback_last_day,writeback_lag_days,main_wait_on_sim_us,worker_fault_count,completed_days,runtime_graph_last_elapsed_us,climate_pod_plan_ms,climate_pod_replay_ms,domain_authority_plan_ms,domain_authority_replay_ms")
	_record_fast_tick_start = _host.get_fast_tick_count()
	_record_clock_day_start = _clock.day_index()
	_runtime_report_record_start = _runtime_report()
	_session["runtime_report_record_start"] = _runtime_report_record_start.duplicate(true)
	_last_fast_tick_count = _record_fast_tick_start
	_last_frame_usec = Time.get_ticks_usec()
	_record_started_usec = _last_frame_usec
	_last_completed_days = int(_runtime_report_record_start.get("completed_days", 0))
	_last_completed_usec = _record_started_usec
	_max_commit_gap_ms = 0.0
	_recording = true
	_write_session("recording")
	print("[stage-c/client] recording mode=%s worker=%s seconds=%.2f output=%s" % [
		_mode, _worker_mode, _record_seconds, _output_dir])


func _process(_delta: float) -> void:
	if not _recording:
		return
	var now := Time.get_ticks_usec()
	var frame_ms := float(now - _last_frame_usec) / 1000.0
	_last_frame_usec = now
	var fast_tick_count := _host.get_fast_tick_count()
	var report := _runtime_report()
	_max_commit_gap_ms = maxf(_max_commit_gap_ms, float(now - _last_completed_usec) / 1000.0)
	if int(report.get("completed_days", 0)) > _last_completed_days:
		_last_completed_days = int(report.get("completed_days", 0))
		_last_completed_usec = now
	var climate := _host.climate_authority_diagnostics()
	var writeback_day := int(climate.get("writeback_last_day", -1))
	var clock_day := _clock.day_index() if _clock != null else -1
	var lag := clock_day - writeback_day if writeback_day >= 0 else -1
	_frame_file.store_line(_csv_row([
		_frame_index,
		Time.get_ticks_msec(),
		frame_ms,
		fast_tick_count,
		fast_tick_count > _last_fast_tick_count,
		_host.get_last_fast_tick_ms(),
		clock_day,
		writeback_day,
		lag,
		int(report.get("main_wait_on_sim_us", 0)),
		int(report.get("worker_fault_count", 0)),
		int(report.get("completed_days", 0)),
		int(report.get("last_elapsed_us", 0)),
		float(report.get("climate_pod_plan_ms", 0.0)),
		float(report.get("climate_pod_replay_ms", 0.0)),
		float(report.get("domain_authority_plan_ms", 0.0)),
		float(report.get("domain_authority_replay_ms", 0.0)),
	]))
	_frame_index += 1
	_last_fast_tick_count = fast_tick_count
	if float(now - _record_started_usec) / 1000000.0 >= _record_seconds:
		_finish_recording()


func _finish_recording() -> void:
	if not _recording:
		return
	_recording = false
	_record_fast_tick_end = _host.get_fast_tick_count()
	_record_clock_day_end = _clock.day_index()
	var record_elapsed_ms := float(Time.get_ticks_usec() - _record_started_usec) / 1000.0
	if _frame_file != null:
		_frame_file.close()
		_frame_file = null
	var perf_path: String = String(_recorder.stop_and_export()) if _recorder != null else ""
	# Freeze the measurement endpoint before the asynchronous CSV drain.
	_runtime_report_end = _runtime_report()
	_climate_end = _host.climate_authority_diagnostics()
	if _economy_recorder != null:
		_economy_recorder.stop_and_export()
		var deadline := Time.get_ticks_msec() + 30000
		while _economy_recorder.is_recording() and Time.get_ticks_msec() < deadline:
			_economy_recorder.sampling_summary()
			await get_tree().process_frame
		_session["economy_recording"] = _economy_recorder.sampling_summary()
	_session["recording_fast_tick_start"] = _record_fast_tick_start
	_session["recording_fast_tick_end"] = _record_fast_tick_end
	_session["recording_fast_ticks"] = _record_fast_tick_end - _record_fast_tick_start
	_session["recording_clock_day_start"] = _record_clock_day_start
	_session["recording_clock_day_end"] = _record_clock_day_end
	_session["recording_effective_days"] = _record_clock_day_end - _record_clock_day_start
	_session["recording_elapsed_ms"] = record_elapsed_ms
	_session["effective_days_per_second"] = (
		float(_record_clock_day_end - _record_clock_day_start) * 1000.0 / record_elapsed_ms
		if record_elapsed_ms > 0.0 else 0.0)
	_session["frame_samples"] = _frame_index
	_session["perf_csv"] = perf_path
	_session["runtime_report_end"] = _runtime_report_end.duplicate(true)
	_session["climate_authority_end"] = _climate_end.duplicate(true)
	_session["writeback_lag_days"] = int(_clock.day_index()) - int(
		_climate_end.get("writeback_last_day", -1)) if int(
		_climate_end.get("writeback_last_day", -1)) >= 0 else -1
	var committed_delta := int(_runtime_report_end.get("completed_days", 0)) - int(
		_runtime_report_record_start.get("completed_days", 0))
	var native_rate := float(committed_delta) * 1000.0 / maxf(1.0, record_elapsed_ms)
	var faults := int(_runtime_report_end.get("worker_fault_count", 0))
	var health_errors: Array[String] = []
	for resource in _session.get("initial_resource_bridge", []):
		if float(resource.map_reserve) != float(resource.native_reserve):
			health_errors.append("opening resource bridge mismatch: %s" % resource.resource)
	if _economy_recorder != null:
		var recording: Dictionary = _session.get("economy_recording", {})
		if String(recording.get("error_code", "")) != "":
			health_errors.append("economy recording: %s" % recording.get("error_code"))
		if String(recording.get("state", "")) != "completed":
			health_errors.append("economy recording did not finish draining")
		var captured := int(recording.get("captured_epochs", 0))
		if captured <= 0 or captured != int(recording.get("written_epochs", -1)):
			health_errors.append("economy recording has zero or unwritten epochs")
	if _mode == "ACTIVE":
		if not bool(_runtime_report_end.get("authority_ready", false)):
			health_errors.append("requested ACTIVE authority was not granted")
		if _enabled(_args.get("require_owned_state", "false")) and String(
				_runtime_report_end.get("economy_formula_backing", "")) != "owned_state":
			health_errors.append("economy did not bind owned_state")
		if faults > 0:
			health_errors.append("worker_fault_count=%d" % faults)
		if committed_delta <= 0:
			health_errors.append("no native committed-day progress")
		var minimum_rate := float(_args.get("min_native_days_per_second", 0.0))
		if native_rate < minimum_rate:
			health_errors.append("native rate %.3f < %.3f" % [native_rate, minimum_rate])
		var maximum_gap := float(_args.get("max_commit_gap_ms", 0.0))
		if maximum_gap > 0.0 and _max_commit_gap_ms > maximum_gap:
			health_errors.append("commit gap %.3f > %.3f ms" % [_max_commit_gap_ms, maximum_gap])
	elif int(_runtime_report_end.get("authoritative_domain_mask", 0)) != 0:
		health_errors.append("non-ACTIVE comparison acquired worker authority")
	_session["native_committed_days"] = committed_delta
	_session["native_days_per_second"] = native_rate
	_session["max_observed_commit_gap_ms"] = _max_commit_gap_ms
	_session["health_errors"] = health_errors
	_session["health_passed"] = health_errors.is_empty()
	_write_session("complete" if health_errors.is_empty() else "failed")
	_host.set_perf_recorder(null)
	Engine.remove_meta(&"stage_c_authority_mode")
	Engine.remove_meta(&"stage_c_tile_metadata")
	print("[stage-c/client] complete mode=%s frames=%d fast_ticks=%d perf=%s" % [
		_mode, _frame_index, _record_fast_tick_end - _record_fast_tick_start, perf_path])
	if not health_errors.is_empty():
		push_error("[stage-c/client] health failed: %s" % "; ".join(health_errors))
	get_tree().quit(0 if health_errors.is_empty() else 3)


func _runtime_report() -> Dictionary:
	if _host == null or _host.get_generator() == null:
		return {}
	var generator := _host.get_generator()
	var out: Dictionary = generator.get_runtime_thread_report() \
		if generator.has_method("get_runtime_thread_report") else {}
	if generator.has_method("get_runtime_perf_snapshot"):
		var graph: Dictionary = generator.get_runtime_perf_snapshot(1)
		for key in graph:
			out[key] = graph[key]
	return out


func _build_session_metadata() -> void:
	_session = {
		"schema": "AuthorityStageCClientSession",
		"schema_version": 1,
		"run_id": _run_id,
		"stage": "C1" if not _manual else "C2",
		"build": "Debug" if OS.is_debug_build() else "NonDebug",
		"engine_version": Engine.get_version_info(),
		"seed": int(_args.get("seed", DEFAULT_SEED)),
		"map_width": int(_args.get("width", DEFAULT_MAP_WIDTH)),
		"map_height": int(_args.get("height", DEFAULT_MAP_HEIGHT)),
		"num_continents": 2,
		"continent_size": 0.50,
		"land_layout": "two",
		"foreign_count": int(_args.get("foreign_count", DEFAULT_FOREIGN_COUNT)),
		"speed": float(_args.get("speed", DEFAULT_SPEED)),
		"graphics_profile": "high",
		"window_width": WINDOW_SIZE.x,
		"window_height": WINDOW_SIZE.y,
		"vsync": false,
		"max_fps": 0,
		"day_night": true,
		"overlay": false,
		"authority_mode": _mode,
		"worker_mode": _worker_mode,
		"automated_tile_recording": _auto_tile,
		"warmup_seconds": _warmup_seconds,
		"record_seconds": _record_seconds,
		"warmup_until_tick": _warmup_until_tick,
		"record_ticks": _record_ticks,
		"recorder_schema_version": PerfRecorderScript.SCHEMA_VERSION,
		"frame_schema_version": 1,
		"output_dir": _output_dir,
	}


func _tile_metadata() -> Dictionary:
	var metadata := _session.duplicate(true)
	metadata["stage"] = "C2"
	metadata["tick_stride"] = 1
	metadata["cell_stride"] = 1
	metadata["compact_fields"] = false
	metadata["csv_path"] = _output_dir.path_join("tile_data.csv")
	metadata["sidecar_path"] = _output_dir.path_join("tile_data.sidecar.json")
	return metadata


func _write_session(state: String) -> void:
	_session["state"] = state
	_session["updated_at_utc"] = Time.get_datetime_string_from_system(true, true)
	var file := FileAccess.open(_output_dir.path_join("session.json"), FileAccess.WRITE)
	if file == null:
		push_error("[stage-c/client] session write failed")
		return
	file.store_string(JSON.stringify(_session, "  "))
	file.close()


func _wait_realtime(seconds: float) -> void:
	if seconds <= 0.0:
		return
	await get_tree().create_timer(seconds).timeout


func _wait_fast_tick_target(target: int) -> void:
	while _host != null and _host.get_fast_tick_count() < target:
		await get_tree().process_frame


func _fail(message: String) -> void:
	push_error("[stage-c/client] %s" % message)
	if not _output_dir.is_empty():
		_session["error"] = message
		_write_session("failed")
	get_tree().quit(2)


func _arguments() -> Dictionary:
	var out := {}
	for raw in OS.get_cmdline_user_args():
		var item := String(raw)
		var split := item.find("=")
		if split > 0:
			out[item.substr(0, split)] = item.substr(split + 1)
	return out


func _enabled(value) -> bool:
	return String(value).to_lower() in ["1", "true", "yes", "on"]


func _resolve_output_dir(raw: String, run_id: String) -> String:
	if not raw.strip_edges().is_empty():
		return ProjectSettings.globalize_path(raw).simplify_path()
	return ProjectSettings.globalize_path(
		"res://../../artifacts/runtime/authority-stage-c/%s" % run_id).simplify_path()


func _timestamp_id() -> String:
	var dt := Time.get_datetime_dict_from_system(true)
	return "%04d%02d%02d-%02d%02d%02d" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0))]


func _csv_row(values: Array) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for value in values:
		if typeof(value) == TYPE_FLOAT:
			var number := float(value)
			parts.append("" if is_nan(number) or is_inf(number) else ("%.6f" % number).rstrip("0").rstrip("."))
		elif typeof(value) == TYPE_BOOL:
			parts.append("true" if bool(value) else "false")
		else:
			parts.append(str(value))
	return ",".join(parts)
