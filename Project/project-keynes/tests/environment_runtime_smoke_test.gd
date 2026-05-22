extends SceneTree

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== environment_runtime smoke test ===")
	_expect("EnvironmentRuntime class exists", ClassDB.class_exists("EnvironmentRuntime"))
	if not ClassDB.class_exists("EnvironmentRuntime"):
		_finish()
		return

	var rt: RefCounted = ClassDB.instantiate("EnvironmentRuntime") as RefCounted
	_expect("EnvironmentRuntime instantiated", rt != null)
	if rt == null:
		_finish()
		return

	var n: int = 8
	rt.call("initialize_with_sizes", n, Vector2i(8, 1))
	_expect("runtime initialized", bool(rt.call("is_initialized")))
	_expect("cell count", int(rt.call("get_cell_count")) == n)

	var neighbors: PackedInt32Array = PackedInt32Array()
	neighbors.resize(n * 6)
	for i in range(n):
		for d in range(6):
			neighbors[i * 6 + d] = clampi(i + (d - 2), 0, n - 1)
	var water: PackedByteArray = PackedByteArray([1, 1, 1, 0, 0, 0, 1, 0])
	var terrain: PackedByteArray = water.duplicate()
	rt.call("build_topology_from_arrays", neighbors, water, terrain, PackedInt32Array())
	var topo: Dictionary = rt.call("topology_summary")
	_expect("topology valid", bool(topo.get("topology_valid", false)))
	_expect("water indices built", int(topo.get("water_indices", 0)) == 4)
	_expect("coastal indices built", int(topo.get("coastal_indices", 0)) > 0)

	var f: PackedFloat32Array = PackedFloat32Array()
	f.resize(n)
	for i in range(n):
		f[i] = float(i) * 0.1
	rt.call("bind_core_buffers", f, f, f, f, f, f, f, f)
	rt.call("bind_weather_buffers", f, f, f)

	var ocean_res: Dictionary = rt.call("step_ocean_budgeted", 0.75, 4, 4, 4)
	_expect("ocean step returns native path", str(ocean_res.get("path", "")) == "ocean_native_pipeline")
	_expect("ocean step processed work", int(ocean_res.get("work_done", 0)) >= 0)
	for _i in range(64):
		ocean_res = rt.call("step_ocean_budgeted", 0.75, 32, 32, 32)
		if bool(ocean_res.get("done", false)):
			break
	_expect("ocean round completes", bool(ocean_res.get("done", false)))
	var dirty_tiles: PackedInt32Array = rt.call("consume_ocean_dirty_tiles")
	_expect("dirty tiles consumable", dirty_tiles.size() > 0)

	var weather_res: Dictionary = rt.call("step_weather_budgeted", 0.55, 4, 0, 4)
	_expect("weather step returns native path", str(weather_res.get("path", "")) == "weather_native_solver")
	for _i in range(64):
		weather_res = rt.call("step_weather_budgeted", 0.55, 32, 0, 32)
		if bool(weather_res.get("done", false)):
			break
	_expect("weather round completes", bool(weather_res.get("done", false)))
	_expect("weather publishes snapshot", int(weather_res.get("weather_snapshot_version", 0)) > 0)

	var climate_res: Dictionary = rt.call("step_climate_budgeted", 0.75, 4, 0, 4)
	_expect("climate step returns native path", str(climate_res.get("path", "")) == "climate_native_daily")
	for _i in range(64):
		climate_res = rt.call("step_climate_budgeted", 0.75, 32, 0, 32)
		if bool(climate_res.get("done", false)):
			break
	_expect("climate round completes", bool(climate_res.get("done", false)))
	_expect("climate publishes snapshot", int(climate_res.get("climate_snapshot_version", 0)) > 0)

	var status: Dictionary = rt.call("status")
	_expect("thread model is single-thread budgeted", str(status.get("runtime_thread_model", "")) == "single_thread_budgeted")
	_expect("worker threads disabled", not bool(status.get("worker_threads_enabled", true)))
	_expect("Godot object access stays on main thread", str(status.get("godot_object_access", "")) == "main_thread_only")

	var state: Dictionary = rt.call("export_runtime_state")
	_expect("export runtime state", int(state.get("cell_count", 0)) == n)
	_expect("export thread model", str(state.get("runtime_thread_model", "")) == "single_thread_budgeted")
	rt.call("restore_runtime_state", state)
	var state2: Dictionary = rt.call("export_runtime_state")
	_expect("restore runtime state", int(state2.get("snapshot_version", -1)) == int(state.get("snapshot_version", -2)))

	_finish()


func _finish() -> void:
	print("  → checks=%d  failures=%d" % [_checks, _failures])
	if _failures == 0:
		print("=== environment_runtime smoke test PASS ===")
	else:
		printerr("=== environment_runtime smoke test FAIL: %d failures ===" % _failures)


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
