extends SceneTree

var _failures := PackedStringArray()
var _generation_active := false
var _frame_heartbeats := 0
var _last_heartbeat_usec := 0
var _max_heartbeat_gap_ms := 0.0


func _initialize() -> void:
	process_frame.connect(_on_process_frame)
	call_deferred("_run")


func _run() -> void:
	var profile: ClimateProfile = load("res://data/world/earth_like.tres").duplicate(true)
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_environment_runtime_enabled = false
	var cfg := MapConfig.make(8, 6)
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
	for i in range(1, fractions.size()):
		if fractions[i] + 0.0001 < fractions[i - 1]:
			_failures.append("generation progress regressed at stage %s" % stages[i])
			break

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
			_max_heartbeat_gap_ms = maxf(
				_max_heartbeat_gap_ms, float(now_usec - _last_heartbeat_usec) / 1000.0)
		_last_heartbeat_usec = now_usec
		_frame_heartbeats += 1


func _expect(_label: String, condition: bool) -> void:
	if not condition:
		_failures.append(_label)
