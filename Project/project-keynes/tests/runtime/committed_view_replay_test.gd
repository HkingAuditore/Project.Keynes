extends "res://tests/runtime/golden_external_advancers_test.gd"

# Independent nonempty command log. Existing v1-v5 fixtures stay untouched.
const COMMAND_LOG := "res://tests/runtime/committed_view_commands.json"

func _run() -> void:
	OS.set_environment("PK_GOLDEN_DOMAINS", "1")
	var ext_check := DCWorldExt.new()
	_expect("Climate owned view: retry, rejected versions, restore continuation", ext_check.runtime_climate_authority_self_test())
	ext_check = null
	var commands: Array = JSON.parse_string(FileAccess.get_file_as_string(COMMAND_LOG))
	var save_day := maxi(1, int(OS.get_environment("PK_COMMITTED_REPLAY_SAVE_DAY")))
	if OS.get_environment("PK_COMMITTED_REPLAY_SAVE_DAY").is_empty(): save_day = 2
	var observe_days := maxi(4, int(OS.get_environment("PK_COMMITTED_REPLAY_DAYS")))
	for day in range(5, observe_days + 1):
		commands.append({"day": day, "operation": "military_target", "value": day + 1})
	var scenario := OS.get_environment("PK_COMMITTED_REPLAY_SCENARIO")
	var config := NewGameConfig.create_default()
	config.country.name = "Committed View Replay"
	config.country.foreign_count = 2 if scenario in ["multicountry", "military"] else 0
	config.base.map_width = 40
	config.base.map_height = 28
	config.base.initial_seed = 20260727
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	var clock := WorldClock.new()
	# Test-only short calendar: real season/year methods, no real-time speed changes.
	if scenario == "calendar": clock.days_per_year_count = 8
	var annual := OS.get_environment("PK_COMMITTED_REPLAY_AUTOSAVE") == "1"
	if not OS.get_environment("PK_COMMITTED_REPLAY_YEAR_DAYS").is_empty():
		clock.days_per_year_count = int(OS.get_environment("PK_COMMITTED_REPLAY_YEAR_DAYS"))
	clock.auto_start = false
	root.add_child(clock)
	clock.set_process(false)
	clock._rng.seed = 150015
	var host := ReplayHost.new()
	host.runtime_economy_auto_pod_active = true
	root.add_child(host)
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var save_service := root.get_node("GameSave")
	var autosave_results: Array = []
	if annual:
		save_service._autosave_enabled = true
		save_service.save_completed.connect(func(slot: String, result: Dictionary) -> void:
			if slot != "autosave": return
			autosave_results.append(result.duplicate(true))
			print("ANNUAL_AUTOSAVE=" + JSON.stringify(result))
			if autosave_results.size() == 1 and bool(result.get("ok", false)):
				var directory := OS.get_environment("PK_SAVE_DIR")
				DirAccess.copy_absolute(directory.path_join("autosave.pksv"), directory.path_join("annual-checkpoint.pksv"))
		)
	# Manual calendar fixtures disable deferred autosaves unless the dedicated
	# annual-autosave probe explicitly asks for the production coordinator path.
	# Do not write GameSettings from a headless test.
	if scenario == "calendar" and OS.get_environment("PK_COMMITTED_REPLAY_AUTOSAVE") != "1":
		save_service._autosave_enabled = false
	var flow := root.get_node("GameFlow")
	flow.set_session({"new_game_config": config.to_dictionary()})
	var mode := OS.get_environment("PK_COMMITTED_REPLAY_MODE")
	var request := {"kind": "new_game", "config": config.to_dictionary()}
	if mode == "resume":
		var resume_slot := OS.get_environment("PK_COMMITTED_REPLAY_SLOT")
		if resume_slot.is_empty(): resume_slot = "manual_3"
		request = {"kind": "load_game", "slot_id": resume_slot}
	var configured: Dictionary = host.configure_session(request)
	print("REPLAY_CONFIG=" + JSON.stringify(configured))
	_expect("replay configures", bool(configured.get("ok", false)))
	if not bool(configured.get("ok", false)):
		host.free()
		clock.free()
		_finish()
		return
	save_service.bind_runtime(host, clock, null)
	await host.generate_world()
	var generator := host.get_generator()
	if generator == null:
		_expect("replay world restored", false)
		host.close_world()
		host.free()
		clock.free()
		_finish()
		return
	var economy = generator.get_economy_facade()
	_expect("replay cadence is fixed", preload("res://tests/runtime/replay_cadence.gd").install(economy.world_ext()))
	var cell := int(generator.gameplay_start_report().get("cell", -1))
	var ext: Object = economy.world_ext()
	if not OS.get_environment("PK_SIM_DAY_TRACE").is_empty():
		print("REPLAY_INGRESS_START=" + str(ext.get_gameplay_event_bus_report().get("next_event_id")))
	var military = generator.get_military_facade()
	var handle := int(ext.get_country_cell_summary(cell).get("country_handle", 0))
	var military_enemy := 0
	var military_target_cell := -1
	var rows: Array = []
	if mode == "resume" and OS.get_environment("PK_COMMITTED_REPLAY_ROUNDTRIP") == "1":
		var reencoded: Dictionary = await save_service.request_manual_save("manual_2")
		print("REPLAY_REENCODE=" + JSON.stringify(reencoded))
		_expect("restored checkpoint reencodes", bool(reencoded.get("ok", false)))
		_export_archive("manual_2")
	if annual and mode == "resume" and not OS.get_environment("PK_REPLAY_BASE_CONTROL").is_empty():
		var bytes := FileAccess.get_file_as_bytes(OS.get_environment("PK_SAVE_DIR").path_join("base-control.bin"))
		var saved: Dictionary = bytes_to_var(bytes)
		var current: PackedFloat32Array = host.current_map().base_moisture_arr
		print("BASE_CONTROL=" + JSON.stringify({"map_equals_saved": current == saved.map, "world_equals_saved": current == saved.world}))
		if OS.get_environment("PK_REPLAY_BASE_CONTROL") == "prime":
			host.current_map().base_moisture_arr = saved.map
			ext.refresh_slots_from_map_keys(PackedStringArray(["cell_base_moisture"]))
	clock.pause(false)
	for command in commands:
		var day := int(command.day)
		if mode == "resume" and day <= save_day: continue
		if scenario == "military" and day == 1:
			var state_building := -1
			for item in military.catalog_view().get("state_buildings", []):
				if int(item.role) == 0:
					state_building = int(item.index)
					break
			_expect("military state building admitted", state_building >= 0 and bool(military.build_state_building(handle, cell, state_building).get("ok", false)))
			_expect("military levy admitted", bool(military.set_levy_enabled(handle, true).get("ok", false)))
		if scenario == "military" and day == 20:
			_expect("military army admitted", bool(military.create_army(handle, cell, {0: 5}).get("ok", false)))
		if scenario == "military" and day == 21:
			for candidate in range(config.base.map_width * config.base.map_height):
				var candidate_handle := int(ext.get_country_cell_summary(candidate).get("country_handle", 0))
				if candidate_handle != 0 and candidate_handle != handle:
					military_enemy = candidate_handle
					military_target_cell = candidate
					break
			var armies: Array = military.armies(handle)
			_expect("military war target found", military_enemy != 0 and military_target_cell >= 0 and not armies.is_empty())
			if military_enemy != 0 and not armies.is_empty():
				_expect("military war admitted", bool(military.declare_war(handle, military_enemy).get("ok", false)))
				_expect("military move admitted", bool(military.move_army(int(armies[0].handle), military_target_cell).get("ok", false)))
		_expect("known command", String(command.operation) == "military_target")
		var receipt: Dictionary = military.set_target(handle, 0, int(command.value))
		_expect("logged command admitted", bool(receipt.get("ok", false)))
		var gm_receipt := {}
		if scenario == "mixed":
			gm_receipt = host.execute_gm_command("country.rename", {
				"country_handle": handle, "name": "Replay day %d" % day, "day": day + 2})
			_expect("GM command admitted", bool(gm_receipt.get("ok", false)))
		if scenario == "calendar" or annual:
			# Keep the headless daily driver; exercise actual calendar callbacks separately.
			var next_season := clock.season_index_for_day(day + 1)
			if next_season != clock._last_season:
				clock._last_season = next_season
				clock.season_changed.emit(next_season)
			var next_year := clock.year_index_for_day(day + 1)
			if next_year != clock._last_year:
				clock._last_year = next_year
				clock._apply_year_rollover(next_year)
		if not OS.get_environment("PK_SIM_DAY_TRACE").is_empty() and day >= 364:
			var m = host.current_map()
			print("REPLAY_WEATHER_BEFORE=" + JSON.stringify({"day": day,
				"native": generator._native_daily_last_result.get("rc", -1),
				"weather_job": generator._weather_refresh_job != null,
				"native_job": generator._native_daily_sim_job != null,
				"weather": [m.weather_type_arr[cell], m.weather_intensity_arr[cell], m.temp_arr[cell], m.cover_arr[cell], m.wind_speed_arr[cell]]}))
		var report := await _run_day(host, economy, clock, day)
		_expect("replay commits day", bool(report.get("done", false)))
		if not bool(report.get("done", false)): break
		_expect("replay same-day boundary", await _wait_golden_read_boundary(host, economy, day))
		var caught_up := false
		for _slice in range(MAX_SLICES_PER_DAY):
			host._process(0.0)
			if host._runtime_military_last_commit_day == day and host._runtime_natural_resource_last_commit_day == day:
				caught_up = true
				break
			await process_frame
		_expect("external boundary", caught_up)
		var army: Dictionary = military.country_snapshot(handle)
		_expect("command changes authoritative target", int(army.get("target_value", -1)) == int(command.value))
		if scenario == "military" and day >= 40:
			_expect("military soldiers remain nonzero", int(army.get("soldiers_total", 0)) > 0)
			_expect("military war remains visible", int(army.get("wars_active", 0)) > 0)
		var domains := await _read_domains(ext, day)
		if not OS.get_environment("PK_SIM_DAY_TRACE").is_empty():
			var diagnostics: Dictionary = ext.get_runtime_thread_report()
			print("REPLAY_BOUNDARY=" + JSON.stringify({"day": day,
				"ideology": diagnostics.get("ideology_pod_fallback_reason"),
				"trigger": diagnostics.get("trigger_pod_fallback_reason"),
				"economy_backing": diagnostics.get("economy_formula_backing"),
				"economy_switch": diagnostics.get("economy_authority_switch_blocker"),
				"economy_switch_reason": diagnostics.get("economy_authority_switch_reason"),
				"economy_ready": diagnostics.get("economy_pod_active_ready"),
				"event_ingress": ext.get_gameplay_event_bus_report().get("next_event_id")}))
		rows.append({"day": day, "domains": domains, "whole_economy_hash": str(ext.get_economy_state_hash()),
			"military": _canonical(army), "resources": _resource_state(ext).hash})
		if scenario == "military":
			rows[-1]["field_armies"] = _canonical(military.armies(handle))
			rows[-1]["military_control"] = _canonical(military.control_snapshot())
		if scenario == "mixed": rows[-1]["gm_receipt"] = gm_receipt
		if scenario == "calendar":
			rows[-1]["calendar"] = [clock._last_season, clock._last_year,
				clock.climate_anomaly, str(clock._rng.state)]
		if annual:
			if day == save_day and mode != "resume":
				for _frame in range(MAX_SLICES_PER_DAY):
					host._process(0.0)
					if not autosave_results.is_empty() and not save_service._busy: break
					await process_frame
				_expect("annual coordinator saved", autosave_results.size() == 1 and bool(autosave_results[0].get("ok", false)))
			if day == save_day and mode != "resume" and not OS.get_environment("PK_REPLAY_BASE_CONTROL").is_empty():
				var output := FileAccess.open(OS.get_environment("PK_SAVE_DIR").path_join("base-control.bin"), FileAccess.WRITE)
				output.store_buffer(var_to_bytes({"map": host.current_map().base_moisture_arr,
					"world": generator.get_data_core_world().serialize().cells.cell_base_moisture}))
			var annual_report: Dictionary = host.annual_report_snapshot(1)
			rows[-1]["annual"] = _canonical(annual_report)
			rows[-1]["annual_status"] = _canonical(host.annual_report_status())
			if day >= save_day:
				_expect("annual report complete and settled", bool(annual_report.get("complete", false)) and bool(annual_report.get("reward_settled", false)))
		if not annual and mode == "checkpoint" and day == save_day:
			var saved: Dictionary = await save_service.request_manual_save("manual_3")
			print("REPLAY_SAVE=" + JSON.stringify(saved))
			_expect("checkpoint writes PKSV", bool(saved.get("ok", false)))
			if not bool(saved.get("ok", false)): break
			_export_archive("manual_3")
	print("COMMITTED_REPLAY_RESULT=" + JSON.stringify({"commands": commands, "rows": rows}))
	_expect("replay closes", bool((await host.close_world()).get("ok", false)))
	save_service.bind_runtime(null, null, null)
	host.free()
	clock.free()
	_finish()


func _export_archive(slot: String) -> void:
	if OS.get_environment("PK_COMMITTED_REPLAY_EXPORT") != "1": return
	var directory := OS.get_environment("PK_SAVE_DIR")
	var decoded: Dictionary = preload("res://scripts/game/save_container_reader.gd").read_container(directory.path_join(slot + ".pksv"), true, true)
	_expect("archive export validates", bool(decoded.get("ok", false)))
	if not bool(decoded.get("ok", false)): return
	var target := directory.path_join(slot + "-sections")
	DirAccess.make_dir_recursive_absolute(target)
	for key in decoded.section_bytes:
		var file := FileAccess.open(target.path_join(String(key) + ".bin"), FileAccess.WRITE)
		file.store_buffer(decoded.section_bytes[key])


class ReplayHost extends WorldRuntimeHost:
	func _prepare_world_restore() -> Dictionary:
		if OS.get_environment("PK_REPLAY_CATALOG_CONTROL").is_empty():
			return super._prepare_world_restore()
		var before := _catalog_probe()
		if OS.get_environment("PK_REPLAY_CATALOG_CONTROL") == "prime":
			_generator._runtime_climate_catalog_hash_for_map(_current_map)
		var result := super._prepare_world_restore()
		print("CATALOG_CONTROL=" + JSON.stringify({"before": before, "after": _catalog_probe()}))
		return result

	func _catalog_probe() -> Dictionary:
		var old_hash := _generator._runtime_climate_catalog_hash
		var old_id := _generator._runtime_climate_catalog_map_id
		_generator._runtime_climate_catalog_hash = 0
		var computed := _generator._runtime_climate_catalog_hash_for_map(_current_map)
		_generator._runtime_climate_catalog_hash = old_hash
		_generator._runtime_climate_catalog_map_id = old_id
		var columns := {}
		for key in ["elevation_arr", "cell_lat_norm_arr", "terrain_arr", "landform_arr", "is_water_arr", "hydro_parent_arr"]:
			var bytes: PackedByteArray = var_to_bytes(_current_map.get(key))
			var h := HashingContext.new()
			h.start(HashingContext.HASH_SHA256)
			h.update(bytes)
			columns[key] = h.finish().hex_encode()
		return {"cached": str(old_hash), "computed": str(computed), "columns": columns}
