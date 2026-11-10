extends "res://tests/game/starter_settlement_soak_test.gd"

class InlineHost extends WorldRuntimeHost:
	func _native_daily_inline_requested() -> bool:
		return true

func _run() -> void:
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
	var host := InlineHost.new()
	host.runtime_economy_auto_pod_active = true
	root.add_child(host)
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	root.get_node("GameFlow").set_session({"new_game_config": config.to_dictionary()})
	_expect("inline formal session configures", host.configure_session({"kind": "new_game", "config": config.to_dictionary()}).get("ok", false))
	var saves := root.get_node("GameSave")
	var previous_repository = saves._repository
	var test_directory := "user://test_inline_coordinator_%d" % OS.get_process_id()
	saves._repository = preload("res://scripts/game/save_repository.gd").new(test_directory)
	saves.bind_runtime(host, clock, null)
	saves._autosave_enabled = false
	await host.generate_world()
	host.set_process(false)
	var ext: Object = host.generator().get_data_core_world_ext()
	_expect("inline executor is selected", ext.get_runtime_thread_report().get("native_daily_inline", false))
	_expect("inline cadence is fixed", preload("res://tests/runtime/replay_cadence.gd").install(ext))
	clock.pause(false)
	for day in range(1, 5):
		await _inline_day(host, clock, day)
	var handle := 0
	for cell in host.current_map().cell_count():
		handle = int(ext.get_country_cell_summary(cell).get("country_handle", 0))
		if handle != 0:
			break
	_expect("formal rename is accepted", ext.submit_country_commands(_rename_batch(handle)).get("ok", false))
	await _inline_day(host, clock, 5)
	var running_save: Dictionary = await saves.request_manual_save("manual_1")
	_expect("formal save succeeds from a running inline session", running_save.get("ok", false))
	_expect("save restores the running clock", not clock.paused)
	clock.pause(true)
	var paused_save: Dictionary = await saves.request_manual_save("manual_2")
	_expect("formal save succeeds from a paused inline session", paused_save.get("ok", false))
	_expect("save preserves the paused clock", clock.paused)
	var report: Dictionary = ext.get_runtime_thread_report()
	_expect("formal capture can observe the native pending-day flag", report.has("inline_day_pending"))
	var pending := report.duplicate(true)
	pending["inline_day_pending"] = true
	_expect("a partial inline day still blocks formal capture", saves._worker_idle_blocker(pending) == "inline_day_pending")
	await _inline_day(host, clock, 6)
	var expected_hash := str(ext.get_economy_state_hash())
	_expect("source session closes", (await host.close_world()).get("ok", false))
	saves.bind_runtime(null, null, null)
	host.free()
	var restored := InlineHost.new()
	restored.runtime_economy_auto_pod_active = true
	root.add_child(restored)
	restored.configure(null, null, clock)
	restored.set_climate_authority_override("force_on")
	_expect("inline saved session prepares", restored.configure_session({"kind": "load_game", "slot_id": "manual_2"}).get("ok", false))
	saves.bind_runtime(restored, clock, null)
	await restored.generate_world()
	restored.set_process(false)
	var restored_ext: Object = restored.generator().get_data_core_world_ext()
	_expect("inline load installs the saved day", restored_ext.get_runtime_thread_report().get("simulation_committed_day", -1) == 5)
	_expect("restored cadence is fixed", preload("res://tests/runtime/replay_cadence.gd").install(restored_ext))
	var country_hash: int = restored_ext.get_country_worker_read_view(0).get("state_hash", 0)
	var receipts: Array = restored_ext.poll_country_command_receipts(0, 100).get("receipts", [])
	_expect("the saved rename has a durable result", not receipts.is_empty())
	for repeat in 2:
		_expect("formal same-policy restart succeeds", restored.set_climate_authority_override("force_on").get("ok", false))
		_expect("formal restart retains the committed name", restored_ext.get_country_snapshot(handle).get("country_name", "") == "Restart Country")
		_expect("formal restart retains Country business state", restored_ext.get_country_worker_read_view(0).get("state_hash", 0) == country_hash)
		_expect("formal restart retains unclaimed results", restored_ext.poll_country_command_receipts(0, 100).get("receipts", []) == receipts)
	await _inline_day(restored, clock, 6)
	_expect("inline save continuation preserves the whole economy", str(restored_ext.get_economy_state_hash()) == expected_hash)
	var before_reset: Dictionary = restored_ext.get_economy_report()
	_expect("reset fixture has populated economy stores", int(before_reset.get("cohort_count", 0)) > 0)
	restored_ext.request_runtime_stop()
	var reset_deadline := Time.get_ticks_msec() + 3000
	while not restored_ext.get_runtime_thread_report().get("simulation_executor_exited", false) and Time.get_ticks_msec() < reset_deadline:
		await process_frame
	var catalog: Dictionary = preload("res://scripts/economy/economy_catalog.gd").compile_native_catalog()
	catalog.erase("ok")
	_expect("populated world can be reconfigured after stop", restored_ext.configure_country(catalog,
		{"country_runtime_mode": "ACTIVE", "starting_technology_ids": PackedStringArray()}, 2, 405).get("ok", false))
	_expect("new Country bootstraps after owner replacement", restored_ext.bootstrap_country({}, PackedByteArray([0, 0])).get("ok", false))
	var detached: Dictionary = restored_ext.get_economy_report()
	_expect("economy columns remain valid after replacing their owner", detached.get("cohort_count", -1) == before_reset.get("cohort_count", -2) and detached.get("market_count", -1) == before_reset.get("market_count", -2))
	_expect("detached economy still hashes its populated stores", int(restored_ext.get_economy_state_hash()) != 0)
	_expect("restored session closes", (await restored.close_world()).get("ok", false))
	saves.bind_runtime(null, null, null)
	restored.free()
	clock.free()
	saves._repository = previous_repository
	for file in DirAccess.get_files_at(test_directory):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(test_directory.path_join(file)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(test_directory))
	print("inline coordinator save: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _inline_day(host: WorldRuntimeHost, clock: WorldClock, day: int) -> void:
	clock.current_day = float(day + 1)
	host._on_clock_day_changed(day + 1)
	host._process(0.0)
	await process_frame
	var ext: Object = host.generator().get_data_core_world_ext()
	_expect("inline day %d commits" % day, host._runtime_native_daily_inline_last.get("ok", false) and ext.get_runtime_thread_report().get("simulation_committed_day", -1) == day)
	_expect("inline grant suppresses the old Country writer", not ext.country_should_run(day + 1))

func _rename_batch(handle: int) -> Dictionary:
	return {"opcodes": PackedInt32Array([2]), "effective_days": PackedInt64Array([5]),
		"sequences": PackedInt64Array([100]), "target_handles": PackedInt64Array([handle]),
		"cell_indices": PackedInt32Array([-1]), "aux_i32": PackedInt32Array([-1]),
		"domain_i32": PackedInt32Array([-1]), "position_i32": PackedInt32Array([-1]),
		"weight0_bp": PackedInt32Array([0]), "weight1_bp": PackedInt32Array([0]),
		"weight2_bp": PackedInt32Array([0]), "weight3_bp": PackedInt32Array([0]),
		"value_i64": PackedInt64Array([0]), "tax_kinds": PackedInt32Array([-1]),
		"tax_item_indices": PackedInt32Array([-1]), "tax_rate_basis_points": PackedInt32Array([0]),
		"tax_assessment_modes": PackedInt32Array([0]), "stable_ids": PackedStringArray([""]),
		"display_names": PackedStringArray(["Restart Country"])}
