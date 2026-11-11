extends "res://tests/game/starter_settlement_soak_test.gd"

class ControlledHost extends WorldRuntimeHost:
	var inline_mode := false
	var hold_inputs := false
	func _native_daily_inline_requested() -> bool:
		return inline_mode
	func _process(delta: float) -> void:
		if not hold_inputs: super._process(delta)
	func step() -> void:
		super._process(0.0)
	func _prepare_world_simulation() -> Dictionary:
		# The formal bootstrap prepares all domains. Hold the fresh world's
		# initial environment frame so both executors share a known empty queue.
		hold_inputs = true
		_country_worker_transport_capture = _generator.capture_country_worker_inputs()
		var annual: Dictionary = _annual_reports.configure(_generator, _world_clock,
			_resolve_player_country_handle())
		if not annual.get("ok", false): return annual
		_start_production_shadow_worker()
		_clock_binding.attach(_world_clock, _generator.set_runtime_clock_threaded,
			_runtime_session.set_running)
		return {"ok": true}

func _run() -> void:
	for inline_mode in [false, true]:
		await _check_startup(inline_mode)
	print("startup save boundary: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _check_startup(inline_mode: bool) -> void:
	var config := NewGameConfig.create_default()
	config.country.foreign_count = 0
	config.base.map_width = 40
	config.base.map_height = 28
	config.base.initial_seed = 20260727
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	var clock := WorldClock.new()
	clock.auto_start = false
	root.add_child(clock)
	clock.set_process(false)
	clock.pause(true)
	var host := ControlledHost.new()
	host.inline_mode = inline_mode
	host.runtime_economy_auto_pod_active = true
	root.add_child(host)
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	_expect("startup fixture configures", host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()}).get("ok", false))
	await host.generate_world()
	host.set_process(false)
	var ext: Object = host.generator().get_data_core_world_ext()
	var economy = host.generator().get_economy_facade()
	_expect("startup fixture uses daily settlements", preload("res://tests/runtime/replay_cadence.gd").install(ext))
	_expect("fixture is truly before its first settlement", int(economy.report().get("last_committed_day", 0)) == -1)
	var saves := root.get_node("GameSave")
	var previous_repository = saves._repository
	var folder := "user://startup_save_%d_%s" % [OS.get_process_id(), str(inline_mode)]
	root.get_node("GameFlow").set_session({"new_game_config": config.to_dictionary()})
	saves._repository = preload("res://scripts/game/save_repository.gd").new(folder)
	saves.bind_runtime(host, clock, null)
	saves._autosave_enabled = false
	for repeat in 2:
		var request: int = saves._next_runtime_save_request_id
		saves._next_runtime_save_request_id += 1
		var result: Dictionary = await saves.request_manual_save("manual_1")
		_expect("coordinator rejects a pre-settlement save", not result.get("ok", true)
			and result.get("code", "") == "save_requires_first_settlement")
		_expect("native request is admitted", ext.request_runtime_save(request).get("ok", false))
		var native := {}
		for frame in 600:
			native = ext.poll_runtime_save(request)
			if not native.get("ok", true) or native.get("ready", false): break
			await create_timer(0.005).timeout
		if native.get("reason", "") != "save_requires_first_settlement": print("startup native rejection: ", native)
		_expect("native rejection has the same first-settlement reason", not native.get("ok", true)
			and native.get("code", "") == "runtime_save_failed"
			and native.get("reason", "") == "save_requires_first_settlement")
		_expect("a rejected capture preserves the healthy executor", ext.get_runtime_thread_report().get("simulation_host_state", "") != "FAULTED")
		_expect("rejected save preserves pause state", clock.paused)
	clock.pause(false)
	for day in range(1, 9):
		clock.current_day = float(day + 1)
		host._on_clock_day_changed(day + 1)
		host.step()
		for frame in 1200:
			host.step()
			var runtime: Dictionary = ext.get_runtime_thread_report()
			if runtime.get("simulation_committed_day", -1) >= day or runtime.get("simulation_host_state", "") == "FAULTED": break
			await create_timer(0.001).timeout
		_expect("the same executor still commits after a rejected save",
			ext.get_runtime_thread_report().get("simulation_committed_day", -1) >= day
			and not economy.report().get("fatal", false))
	clock.pause(true)
	var saved: Dictionary = await saves.request_manual_save("manual_1")
	if not saved.get("ok", false): print("later startup save: ", saved)
	_expect("a later committed boundary can be saved", saved.get("ok", false))
	_expect("session closes after both rejected and successful saves", (await host.close_world()).get("ok", false))
	saves.bind_runtime(null, null, null)
	saves._repository = previous_repository
	host.free()
	clock.free()
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder)): return
	for file in DirAccess.get_files_at(folder):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(folder.path_join(file)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(folder))
