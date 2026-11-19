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
	if OS.get_environment("PK_COMMITTED_REPLAY_PRODUCTION_CADENCE") == "1":
		var cadence: Dictionary = economy.world_ext().get_economy_report()
		_expect("replay uses production cadence without timing injection",
			not bool(cadence.get("cadence_timing_injected", true)))
	else:
		_expect("replay cadence is fixed", preload("res://tests/runtime/replay_cadence.gd").install(economy.world_ext()))
	var cell := int(generator.gameplay_start_report().get("cell", -1))
	var ext: Object = economy.world_ext()
	if mode == "resume":
		var restored_map := host.get_current_map()
		_expect("restored province inputs are installed before the first day's diffusion",
			ext.snapshot_i32(ext.component_id("cell_province_id")) == restored_map.province_id_arr)
	if not OS.get_environment("PK_SIM_DAY_TRACE").is_empty():
		print("REPLAY_INGRESS_START=" + str(ext.get_gameplay_event_bus_report().get("next_event_id")))
	var military = generator.get_military_facade()
	var handle := int(ext.get_country_cell_summary(cell).get("country_handle", 0))
	var military_construction := {}
	var military_material_quantity := 0
	if scenario == "military":
		economy.construction_command_settled.connect(func(result: Dictionary) -> void:
			if int(result.get("sequence", -1)) == 900001:
				military_construction.merge(result, true)
		)
	var militia_unit: int = military.unit_ids().find("militia")
	var vision_target := -1
	if scenario == "military":
		var map := host.get_current_map()
		for candidate in range(map.cell_count()):
			if absi(candidate / config.base.map_width - cell / config.base.map_width) >= 10 \
					and map.is_water_arr[candidate] == 0:
				vision_target = candidate
				break
		_expect("military replay has distant land for a vision change", vision_target >= 0)
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
	if annual and mode == "resume":
		_check_annual_report_pause(host, clock, generator, save_day)
	var previous_target := int(commands[save_day - 1].value) if mode == "resume" else 0
	for command in commands:
		var day := int(command.day)
		if mode == "resume" and day <= save_day: continue
		if annual or scenario == "calendar":
			_confirm_ready_report(host, clock, day)
		if scenario == "military" and day == 1:
			# Every barracks needs a military technology; the scenario grants
			# the earliest one (warrior lodge) instead of researching it. Like
			# the rename above, the GM command is dated ahead of the running day
			# so it lands on the same day in every mode.
			_expect("military technology granted", bool(host.execute_gm_command("country.grant_technology", {
				"country_handle": handle, "technology_id": "tech.military.war_bands", "day": day + 1}).get("ok", false)))
			var levy: Dictionary = military.set_levy_enabled(handle, true)
			_expect("military levy admitted for day two",
				bool(levy.get("ok", false)) and int(levy.get("effective_day", -1)) == 2)
		if scenario == "military" and day == 4:
			# State buildings are economy construction: the treasury pays and
			# queues the lot, then the military side books the schedule (the
			# PlayerController order). Day 4 is the first day the economy's
			# frozen availability sees the day-2 grant.
			var economy_ids: PackedStringArray = economy.building_type_ids()
			var state_building := -1
			var building_id := &""
			for item in military.catalog_view().get("state_buildings", []):
				var economy_type := int(military.state_building_economy_id(int(item.index)))
				if economy_type >= 0 and economy_type < economy_ids.size() and economy_ids[economy_type] == "warrior_lodge":
					state_building = int(item.index)
					building_id = StringName(economy_ids[economy_type])
					break
			# The old fixture queued a paid build without supplying materials.
			# The actual day-5 receipt rejected it, so no barracks or soldiers
			# existed at day 20. Supply the authoritative recipe on the same
			# day before construction settles; keep the real ten-day build.
			var profile: Resource = load("res://data/economy/buildings/warrior_lodge.tres")
			var material_ids: PackedStringArray = profile.construction_good_ids
			var material_qty: PackedInt64Array = profile.construction_quantities
			_expect("military fixture has a real construction recipe",
				not material_ids.is_empty() and material_ids.size() == material_qty.size())
			var market: Dictionary = economy.market_cell_snapshot(cell)
			var market_id := int(market.get("market_id", -1))
			var good_ids: PackedStringArray = economy.good_ids()
			_expect("military construction market exists", market_id >= 0)
			for material in range(material_ids.size()):
				var good := good_ids.find(material_ids[material])
				var request_id := 800000 + material
				military_material_quantity += material_qty[material]
				# The active runtime rejects the legacy facade ADD_STOCK lane.
				# Use its owned command lane, as the maintenance fixtures do.
				_expect("military construction material admitted", market_id >= 0 and good >= 0
					and bool(ext.submit_economy_pod_commands({
						"request_ids": PackedInt64Array([request_id]),
						"opcodes": PackedInt32Array([EconomyFacade.Opcode.ADD_STOCK]),
						"payload0s": PackedInt64Array([material_qty[material]]),
						"target_cells": PackedInt32Array([market_id]),
						"target_countries": PackedInt64Array([good]),
					}).get("ok", false)))
			_expect("military state building request admitted", state_building >= 0 and bool(economy.treasury_sponsored_build(
				handle, cell, building_id, day + 1, 900001).get("ok", false)))
			var barracks: Dictionary = military.build_state_building(handle, cell, state_building)
			_expect("military state building admitted for day five", state_building >= 0
				and bool(barracks.get("ok", false)) and int(barracks.get("effective_day", -1)) == 5)
		if scenario == "military" and day == 20:
			# Settlement has its own committed-read publication boundary. The
			# receipt must prove actual day-5 settlement before army creation;
			# a queued request or an ephemeral POD receipt is not that proof.
			economy.dispatch_construction_command_receipts()
			_expect("military construction actually settled on day five",
				bool(military_construction.get("ok", false))
				and int(military_construction.get("sequence", -1)) == 900001
				and int(military_construction.get("settled_day", -1)) == 5)
			_expect("military construction consumed the real recipe",
				int(military_construction.get("treasury_goods_used", 0))
				+ int(military_construction.get("market_goods_used", 0)) == military_material_quantity)
			# A single warrior lodge has four posts. Dense unit zero is bronze
			# spearmen, not the militia recruited here; resolve its stable id.
			var local: Dictionary = military.cell_snapshot(cell, handle)
			var militia_heads := 0
			for lot in local.get("garrison_lots", []):
				if int(lot.get("unit", -1)) == militia_unit:
					militia_heads += int(lot.get("count", 0))
			_expect("military completed barracks has posts", int(local.get("post_count", 0)) >= 4)
			_expect("military recruited four local militia", militia_unit >= 0 and militia_heads >= 4)
			var enlist: Dictionary = military.create_army(handle, cell, {militia_unit: 4})
			_expect("military army admitted for day 21", militia_unit >= 0
				and bool(enlist.get("ok", false)) and int(enlist.get("effective_day", -1)) == 21)
		if scenario == "military" and day == 22:
			var military_enemy := 0
			for candidate in range(config.base.map_width * config.base.map_height):
				var candidate_handle := int(ext.get_country_cell_summary(candidate).get("country_handle", 0))
				if candidate_handle != 0 and candidate_handle != handle:
					military_enemy = candidate_handle
					break
			var armies: Array = military.armies(handle)
			_expect("military war target found", military_enemy != 0 and not armies.is_empty())
			if military_enemy != 0 and not armies.is_empty():
				var war: Dictionary = military.declare_war(handle, military_enemy)
				_expect("military war admitted for day 23",
					bool(war.get("ok", false)) and int(war.get("effective_day", -1)) == 23)
				var army_handle := int(armies[0].handle)
				var target := -1
				for direction in range(6):
					var candidate := host.get_current_map().neighbor_index(cell, direction)
					var route: Dictionary = military.preview_path(army_handle, candidate)
					if bool(route.get("ok", false)):
						target = candidate
						break
				_expect("military move has a passable route", target >= 0)
				if target >= 0:
					var move: Dictionary = military.move_army(army_handle, target)
					_expect("military move admitted for day 23",
						bool(move.get("ok", false)) and int(move.get("effective_day", -1)) == 23)
		if scenario == "military" and day == 22 and vision_target >= 0:
			_expect("distant land starts hidden", host.get_current_map().physical_visible_arr[vision_target] == 0)
			var claim: Dictionary = generator.get_country_facade().transfer_territory(
				vision_target, handle, day + 1, 910001, true)
			_expect("dated territory transfer accepted", bool(claim.get("ok", false))
				and int(claim.get("effective_day", -1)) == day + 1)
		_expect("known command", String(command.operation) == "military_target")
		var receipt: Dictionary = military.set_target(handle, 0, int(command.value))
		_expect("logged command admitted for day %d" % (day + 1),
			bool(receipt.get("ok", false)) and int(receipt.get("effective_day", -1)) == day + 1)
		var gm_receipt := {}
		if scenario == "mixed":
			gm_receipt = host.execute_gm_command("country.rename", {
				"country_handle": handle, "name": "Replay day %d" % day, "day": day + 2})
			_expect("GM command admitted", bool(gm_receipt.get("ok", false)))
			_expect("GM receipt preserves the explicitly requested future day",
				int(gm_receipt.get("effective_day", -1)) == day + 2)
			_expect("ACTIVE admission uses the same receipt before and after the first grant",
				String((gm_receipt.get("data", {}) as Dictionary).get("code", "")) == "accepted")
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
			if host._runtime_tail_completed_day == day:
				caught_up = true
				break
			await process_frame
		_expect("external boundary", caught_up)
		if scenario == "military" and day in [20, 21]:
			var formations: Array = military.armies(handle)
			var field_heads := 0
			for formation in formations:
				for lot in military.army(int(formation.handle)).get("composition", []):
					if int(lot.get("unit", -1)) == militia_unit:
						field_heads += int(lot.get("count", 0))
			_expect("military field heads change from zero on day 20 to four on day 21",
				field_heads == (4 if day == 21 else 0))
		var army: Dictionary = military.country_snapshot(handle)
		_expect("the target settles on its admitted day", int(army.get("target_value", -1)) == previous_target)
		previous_target = int(command.value)
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
		var replay_map := host.get_current_map()
		_expect("committed physical vision covers the player origin",
			replay_map.physical_visible_arr.size() == replay_map.cell_count()
			and replay_map.physical_visible_arr[cell] != 0)
		var vision_hash := _digest([replay_map.physical_visible_arr.hex_encode(),
			replay_map.explored_arr.hex_encode(), replay_map.fog_k_arr.hex_encode()])
		rows.append({"day": day, "domains": domains, "whole_economy_hash": _whole_economy_hash,
			"military": _canonical(army), "resources": _resource_state(ext).hash,
			"vision": vision_hash, "species": _digest(replay_map.bio_occupancy_bits_arr.to_byte_array().hex_encode())})
		if scenario == "military":
			var formations: Array = military.armies(handle)
			rows[-1]["field_armies"] = _canonical(formations)
			rows[-1]["military_control"] = _canonical(military.control_snapshot())
			if day == 23:
				_expect("military march order settles on day 23",
					not formations.is_empty() and int(formations[0].mission) == 1)
			if day in [24, 25, 26]:
				_expect("military first enters the next cell on day 26",
					not formations.is_empty() and (int(formations[0].cell) != cell) == (day == 26)
					and int(formations[0].moved_day) == (26 if day == 26 else 21))
			if day == 23 and vision_target >= 0:
				_expect("territory transfer becomes visible on its settlement day",
					replay_map.physical_visible_arr[vision_target] != 0
					and replay_map.explored_arr[vision_target] != 0)
				_expect("changed vision was computed on the background executor",
					bool(host._runtime_last_commit.get("vision_solved", false)))
		if scenario == "mixed":
			rows[-1]["gm_receipt"] = gm_receipt
			# Observe the actual name after the day's commit, not only admission.
			var actual_name := String(ext.get_country_cell_summary(cell).get("country_name", ""))
			var expected_name: String = "Replay day %d" % (day - 2) if day >= 3 else config.country.name
			_expect("dated rename takes effect on its requested day", actual_name == expected_name)
			rows[-1]["country_name"] = actual_name
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
			if day == save_day and mode != "resume":
				_check_annual_report_pause(host, clock, generator, day)
		if not annual and mode == "checkpoint" and day == save_day:
			print("REPLAY_CHECKPOINT_ECOLOGY=" + JSON.stringify({
				"day": day, "resource_recovery_cells": host._runtime_last_commit.get("resource_recovery_cells", 0),
				"species_diffused_cells": host._runtime_last_commit.get("species_diffused_cells", 0),
			}))
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


func _confirm_ready_report(host: WorldRuntimeHost, clock: WorldClock, next_day: int) -> void:
	var state := host.annual_report_status()
	var report_id := int(state.get("ready_report_id", 0))
	if report_id <= 0 or next_day <= report_id * clock.days_per_year():
		return
	host.mark_annual_report_presented(report_id)
	_expect("player confirms annual report before day %d" % next_day,
		bool(host.annual_report_snapshot(report_id).get("presented", false)))


func _check_annual_report_pause(host: WorldRuntimeHost, _clock: WorldClock, generator, day: int) -> void:
	var report_id := int(host.annual_report_status().get("ready_report_id", 0))
	var admitted := int(generator.get_data_core_world_ext().request_runtime_calendar_day(day + 2))
	_expect("next day was offered with an unread annual report",
		report_id > 0 and admitted == day + 1)
	var frames := Engine.get_process_frames()
	OS.delay_msec(100)
	var status: Dictionary = generator.get_runtime_control_state()
	var after := int(status.get("simulation_committed_day", -1))
	print("ANNUAL_REPORT_BLOCK day=%d next_admitted=%d after=%d process_frames=%d state=%s" % [
		day, admitted, after, Engine.get_process_frames() - frames,
		String(status.get("simulation_host_state", ""))])
	_expect("executor waits for annual confirmation even with the next day offered",
		after == day and Engine.get_process_frames() == frames
		and String(status.get("simulation_host_state", "")) == "PAUSED")


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
