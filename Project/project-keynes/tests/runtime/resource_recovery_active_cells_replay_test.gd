extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

const CHECKPOINT_DAY := 7
const LAST_DAY := 10
const MOVE_POPULATION := 7
const REPLAY_RESULT := "RESOURCE_ACTIVE_CELLS_REPLAY="


func _run() -> void:
	OS.set_environment("PK_GOLDEN_DOMAINS", "1")
	if "--resume" in OS.get_cmdline_user_args():
		var resumed := await _replay(true, false)
		print(REPLAY_RESULT + JSON.stringify(resumed))
		_finish()
		return
	var directory := OS.get_environment("PK_SAVE_DIR")
	if directory.is_empty():
		directory = ProjectSettings.globalize_path("user://test_resource_recovery_%d" % OS.get_process_id())
		OS.set_environment("PK_SAVE_DIR", directory)
		root.get_node("GameSave")._repository = preload("res://scripts/game/save_repository.gd").new(directory)
	var direct := await _replay(false, false)
	var checkpoint := await _replay(false, true)
	_expect("direct and checkpoint runs agree through the save day", checkpoint == direct.slice(0, CHECKPOINT_DAY))
	var output := []
	var status := OS.execute(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--log-file", directory.path_join("resource-active-resume.engine.log"),
		"--script", get_script().resource_path, "--", "--resume",
	]), output, true)
	var resumed: Array = []
	var child_log := String(output[0]) if not output.is_empty() else ""
	for line in child_log.split("\n"):
		if line.begins_with(REPLAY_RESULT):
			var decoded: Variant = JSON.parse_string(line.trim_prefix(REPLAY_RESULT))
			if decoded is Array:
				resumed = decoded
	_expect("cold process replays all days", status == 0 and resumed.size() == LAST_DAY - CHECKPOINT_DAY)
	if status != 0 or resumed.is_empty():
		print(child_log)
	for index in range(mini(resumed.size(), maxi(0, direct.size() - CHECKPOINT_DAY))):
		var expected := JSON.stringify(JSON.parse_string(JSON.stringify(direct[CHECKPOINT_DAY + index])))
		var actual := JSON.stringify(resumed[index])
		_expect("cold resource selection and daily summary match day %d" % (CHECKPOINT_DAY + index + 1),
			expected == actual)
		if expected != actual:
			print("RESOURCE_ACTIVE_CELLS_DIFFERENCE expected=" + expected + " actual=" + actual)
			break
	_finish()


func _replay(resume: bool, checkpoint: bool) -> Array:
	var config := NewGameConfig.create_default()
	config.country.name = "Resource Active Cells Replay"
	config.country.foreign_count = COUNTRY_COUNT - 1
	config.base.map_width = MAP_WIDTH
	config.base.map_height = MAP_HEIGHT
	config.base.initial_seed = SEED
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	var clock := WorldClock.new()
	clock.auto_start = false
	root.add_child(clock)
	clock.set_process(false)
	var host := WorldRuntimeHost.new()
	host.runtime_economy_auto_pod_active = true
	root.add_child(host)
	host.configure(null, null, clock)

	var save_service := root.get_node("GameSave")
	root.get_node("GameFlow").set_session({"new_game_config": config.to_dictionary()})
	var request := {"kind": "load_game", "slot_id": "manual_3"} if resume \
		else {"kind": "new_game", "config": config.to_dictionary()}
	var configured := host.configure_session(request)
	_expect("resource replay configures", bool(configured.get("ok", false)))
	var rows: Array = []
	if bool(configured.get("ok", false)):
		save_service.bind_runtime(host, clock, null)
		await host.generate_world()
		if host.is_runtime_ready_for_ticks():
			rows = await _sample_replay(host, clock, resume, checkpoint)
		else:
			_expect("resource replay generates", false)
	_expect("resource replay closes", bool((await host.close_world()).get("ok", false)))
	save_service.bind_runtime(null, null, null)
	host.free()
	clock.free()
	return rows


func _sample_replay(host: WorldRuntimeHost, clock: WorldClock, resume: bool, checkpoint: bool) -> Array:
	var generator := host.get_generator()
	var economy = generator.get_economy_facade()
	var ext: Object = economy.world_ext()
	var map := host.current_map()
	var capital := int(generator.gameplay_start_report().get("cell", -1))
	var country := int(ext.get_country_cell_summary(capital).get("country_handle", 0))
	var cells := PackedInt32Array()
	for cell in range(map.cell_count()):
		if map.is_water_arr[cell] == 0 \
				and cell % 60 != (CHECKPOINT_DAY + 1) and cell != capital:
			cells.append(cell)
			if cells.size() == 2:
				break
	_expect("fixture has two land cells off the next day's wilderness stride", cells.size() == 2)
	if cells.size() != 2:
		return []
	var source := cells[0]
	var destination := cells[1]
	clock.set_speed(SPEED)
	var rows: Array = []
	var first_day := CHECKPOINT_DAY + 1 if resume else 1
	var last_day := CHECKPOINT_DAY if checkpoint else LAST_DAY
	var pasture_slot := int(ext.component_id("cell_res_pasture_reserve"))
	var previous: PackedFloat32Array = ext.snapshot_f32(pasture_slot)
	for day in range(first_day, last_day + 1):
		if day == 1:
			for cell in cells:
				var claim: Dictionary = generator.get_country_facade().transfer_territory(
					cell, country, day, 900700 + cell, true)
				_expect("replay cell gets a country before receiving a cohort", bool(claim.get("ok", false)))
		if day == 2:
			var unemployed: int = economy.profession_ids().find("unemployed")
			_move(ext, capital, source, 3, day, unemployed)
		if day == CHECKPOINT_DAY - 1:
			_expect("only the source is populated before the flip",
				_population(ext, source) > 0 and _population(ext, destination) == 0)
			_move(ext, source, destination, 0, day)
		_publish_day(host, clock, day)
		var settled := await _wait_golden_read_boundary(host, economy, day)
		_expect("resource replay settles day %d" % day, settled)
		if not settled:
			print("RESOURCE_ACTIVE_CELLS_UNSETTLED=" + JSON.stringify(ext.get_runtime_thread_report()))
			break
		var row := await _summary(host, ext, day)
		# Compare the entire PKMI bridge and core, including every AI slot and
		# its decision date. The country projection omits those fields.
		row["military_pkmi_sha256"] = _military_archive_hash(host)
		var pasture: PackedFloat32Array = ext.snapshot_f32(pasture_slot)
		if day >= CHECKPOINT_DAY - 2 and day <= CHECKPOINT_DAY + 1:
			var active: PackedInt32Array = ext.get_economy_live_cells()
			row["sample"] = {"cells": [source, destination],
				"live": [active.has(source), active.has(destination)],
				"population": [_population(ext, source), _population(ext, destination)],
				"pasture_after": [pasture[source], pasture[destination]],
				"recovered": host._runtime_last_commit.get("resource_recovery_cells", -1)}
			print("RESOURCE_ACTIVE_CELLS day=%d %s pasture_before=%s" % [
				day, JSON.stringify(row.sample), [previous[source], previous[destination]]])
			if day >= CHECKPOINT_DAY:
				_expect("the structural move clears the source and populates the destination",
					_population(ext, source) == 0 and _population(ext, destination) > 0)
		previous = pasture
		rows.append(row)
		if checkpoint and day == CHECKPOINT_DAY:
			var saved: Dictionary = await root.get_node("GameSave").request_manual_save("manual_3")
			_expect("resource replay writes a real checkpoint", bool(saved.get("ok", false)))
	return rows


func _move(ext: Object, source: int, destination: int, quantity: int, day: int, profession: int = -1) -> void:
	var report: Dictionary = ext.get_population_cell_snapshot(source, false)
	var handles: PackedInt64Array = report.get("handles", PackedInt64Array())
	var professions: PackedInt32Array = report.get("profession_ids", PackedInt32Array())
	var queued := 0
	for index in range(handles.size()):
		if profession >= 0 and professions[index] != profession:
			continue
		var result: Dictionary = ext.submit_economy_pod_commands({
			"request_ids": PackedInt64Array([900600 + 100 * day + index]),
			"opcodes": PackedInt32Array([MOVE_POPULATION]),
			"target_cells": PackedInt32Array([destination]),
			"target_cohorts": PackedInt64Array([handles[index]]),
			"payload0s": PackedInt64Array([quantity]),
		})
		_expect("population move admitted on day %d" % day, bool(result.get("ok", false)))
		if not bool(result.get("ok", false)):
			print("RESOURCE_ACTIVE_CELLS_MOVE=" + JSON.stringify(result))
		queued += 1
		if profession >= 0:
			break
	_expect("source cohort exists for move on day %d" % day, queued > 0)


func _population(ext: Object, cell: int) -> int:
	var report: Dictionary = ext.get_population_cell_snapshot(cell, false)
	var population := 0
	for count in report.get("populations", PackedInt64Array()):
		population += int(count)
	return population
