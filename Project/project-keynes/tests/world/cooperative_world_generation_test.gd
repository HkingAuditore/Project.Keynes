extends SceneTree

var _failures := PackedStringArray()
var _generation_active := false
var _frame_heartbeats := 0
var _last_heartbeat_usec := 0
var _max_heartbeat_gap_ms := 0.0
var _stage := "preparing"
var _previous_stage := "preparing"
var _gaps: Array[float] = []


func _initialize() -> void:
	process_frame.connect(_on_process_frame)
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2i(1280,720))
		await create_timer(.2).timeout
	var profile: ClimateProfile = load("res://data/world/earth_like.tres").duplicate(true)
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_environment_runtime_enabled = false
	var dimensions := OS.get_environment("PK_LOADING_SIZE").split("x")
	var cfg := MapConfig.make(int(dimensions[0]) if dimensions.size()==2 else 8, int(dimensions[1]) if dimensions.size()==2 else 6)
	cfg.seed = 20260723
	cfg.num_continents = 1
	cfg.sea_level = 0.45
	cfg.continent_size = 0.82
	cfg.climate_profile = profile

	var fractions := PackedFloat32Array()
	var stages := PackedStringArray()
	var generator := MapGenerator.new()
	generator.climate_profile = profile
	generator.bake_progress.connect(func(stage: String, fraction: float) -> void:
		_stage = stage
		stages.append(stage)
		fractions.append(fraction)
	)
	_generation_active = true
	var generated: Dictionary = await generator.generate(cfg, 10.0)
	_generation_active = false

	_expect("world generated", generated.get("map", null) is MapData)
	_expect("generation yielded multiple real frames", _frame_heartbeats >= 8)
	_expect("progress published multiple stages", stages.size() >= 8)
	_expect("progress finished at 100%",
		not fractions.is_empty() and is_equal_approx(fractions[-1], 1.0))
	_expect("loading never blocks the main thread for 100ms", _max_heartbeat_gap_ms <= 100.0)
	for i in range(1, fractions.size()):
		if fractions[i] + 0.0001 < fractions[i - 1]:
			_failures.append("generation progress regressed at stage %s" % stages[i])
			break

	_gaps.sort()
	var p95 := _gaps[int(float(_gaps.size()-1)*.95)] if not _gaps.is_empty() else 0.0
	print("[loading-frame-report] cells=%d frames=%d p95_ms=%.1f max_ms=%.1f" % [cfg.width*cfg.height,_gaps.size(),p95,_max_heartbeat_gap_ms])
	_expect("loading p95 stays within 33ms",p95<=33.0)
	if _failures.is_empty():
		print("[cooperative-world-generation] PASS frames=%d stages=%d max_gap_ms=%.1f" % [
			_frame_heartbeats, stages.size(), _max_heartbeat_gap_ms])
		quit(0)
	else:
		for failure in _failures:
			push_error("[cooperative-world-generation] FAIL: %s" % failure)
		quit(1)


func _on_process_frame() -> void:
	if _generation_active:
		var now_usec := Time.get_ticks_usec()
		if _last_heartbeat_usec > 0:
			var gap := float(now_usec-_last_heartbeat_usec)/1000.0
			_gaps.append(gap)
			if gap > 100.0:
				print("[loading-gap] %.1fms %s -> %s" % [gap,_previous_stage,_stage+" / "+str(Engine.get_meta("loading_step",""))])
			_max_heartbeat_gap_ms = maxf(
				_max_heartbeat_gap_ms, float(now_usec - _last_heartbeat_usec) / 1000.0)
		_last_heartbeat_usec = now_usec
		_previous_stage = _stage
		_frame_heartbeats += 1


func _expect(_label: String, condition: bool) -> void:
	if not condition:
		_failures.append(_label)
