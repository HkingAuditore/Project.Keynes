extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

const MILITARY_CHECKPOINT_DAYS := [20, 31, MilitaryScenario.TREATY_DAY + 1]
const SLOTS := ["manual_1", "manual_2", "manual_3"]
const RESULT_PREFIX := "BACKGROUND_MILITARY_REPLAY="


func _run() -> void:
	OS.set_environment("PK_GOLDEN_DOMAINS", "1")
	var args := OS.get_cmdline_user_args()
	var directory := OS.get_environment("PK_SAVE_DIR")
	if directory.is_empty():
		directory = ProjectSettings.globalize_path("user://test_military_replay_%d" % OS.get_process_id())
		OS.set_environment("PK_SAVE_DIR", directory)
		root.get_node("GameSave")._repository = preload("res://scripts/game/save_repository.gd").new(directory)
	if args.size() == 3 and args[0] == "--resume":
		var resumed := await _replay(args[1].to_int(), args[2].to_int(), false)
		print(RESULT_PREFIX + JSON.stringify(resumed))
		_finish()
		return
	var direct := await _replay(0, 0, false)
	var checkpoint := await _replay(0, 0, true)
	_expect("checkpoint and direct runs match through the last save",
		checkpoint == direct.slice(0, MILITARY_CHECKPOINT_DAYS[-1]))
	for index in MILITARY_CHECKPOINT_DAYS.size():
		var day: int = MILITARY_CHECKPOINT_DAYS[index]
		var output := []
		var status := OS.execute(OS.get_executable_path(), PackedStringArray([
			"--headless", "--path", ProjectSettings.globalize_path("res://"),
			"--log-file", directory.path_join("military-resume-%d.engine.log" % day),
			"--script", get_script().resource_path, "--", "--resume", str(day), str(index),
		]), output, true)
		var child_log := String(output[0]) if not output.is_empty() else ""
		var log := FileAccess.open(directory.path_join("military-resume-%d.stdout.log" % day), FileAccess.WRITE)
		log.store_string(child_log)
		var expected := JSON.stringify(direct.slice(day))
		var actual := ""
		for line in child_log.split("\n"):
			if line.begins_with(RESULT_PREFIX):
				actual = line.trim_prefix(RESULT_PREFIX)
		_expect("cold replay day %d matches every subsequent day including full PKMI" % day,
			status == 0 and not actual.is_empty() and expected == actual)
		if expected != actual:
			var resumed: Variant = JSON.parse_string(actual)
			if resumed is Array:
				for offset in mini(resumed.size(), direct.size() - day):
					var want := JSON.stringify(direct[day + offset])
					var got := JSON.stringify(resumed[offset])
					if JSON.stringify(JSON.parse_string(want)) != got:
						print("BACKGROUND_MILITARY_REPLAY_FIRST_DIFFERENCE day=%d expected=%s actual=%s" % [
							day + offset + 1, want, got])
						break
	_finish()


func _replay(restored_day: int, slot_index: int, checkpoints: bool) -> Array:
	var config := _background_config()
	var clock := WorldClock.new()
	clock.auto_start = false
	root.add_child(clock)
	clock.set_process(false)
	var host := _create_host()
	host.runtime_economy_auto_pod_active = true
	root.add_child(host)
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var request := {"kind": "load_game", "slot_id": SLOTS[slot_index]} if restored_day > 0 \
		else {"kind": "new_game", "config": config.to_dictionary()}
	root.get_node("GameFlow").set_session({"new_game_config": config.to_dictionary()})
	var configured := host.configure_session(request)
	_expect("military replay configures", bool(configured.get("ok", false)))
	var save_service := root.get_node("GameSave")
	var rows: Array = []
	if bool(configured.get("ok", false)):
		save_service.bind_runtime(host, clock, null)
		await host.generate_world()
		if host.is_runtime_ready_for_ticks():
			if restored_day > 0:
				var ext := host.get_generator().get_data_core_world_ext() as DCWorldExt
				_expect("first climate input sees the restored landforms",
					ext.snapshot_u8(ext.component_id("cell_landform")) == host.current_map().landform_arr)
			rows = await _sample_replay_days(host, clock, restored_day, slot_index, checkpoints)
		else:
			_expect("military replay generates", false)
	_expect("military replay closes", bool((await host.close_world()).get("ok", false)))
	save_service.bind_runtime(null, null, null)
	host.free()
	clock.free()
	return rows


func _sample_replay_days(host: WorldRuntimeHost, clock: WorldClock, restored_day: int,
		slot_index: int, checkpoints: bool) -> Array:
	var scenario := MilitaryScenario.new(host, _expect, restored_day)
	var rows: Array = []
	if not scenario.ready():
		return rows
	var directory := OS.get_environment("PK_SAVE_DIR")
	if restored_day > 0:
		scenario._sequence = FileAccess.get_file_as_string(directory.path_join(
			SLOTS[slot_index] + "-fixture-sequence.txt")).to_int()
	clock.set_speed(SPEED)
	var last: int = MILITARY_CHECKPOINT_DAYS[-1] if checkpoints else MilitaryScenario.DAYS
	for day in range(restored_day + 1, last + 1):
		scenario.issue_for_day(day)
		_publish_day(host, clock, day)
		var settled := await _wait_golden_read_boundary(host, scenario.economy, day)
		_expect("military replay settles day %d" % day, settled)
		if not settled:
			break
		scenario.collect_day(day)
		var row := await _summary(host, scenario.ext, day)
		row["pkmi"] = _military_archive_hash(host)
		rows.append(row)
		var index := MILITARY_CHECKPOINT_DAYS.find(day)
		if checkpoints and index >= 0:
			_check_checkpoint(host, scenario, day)
			var slot: String = SLOTS[index]
			var saved: Dictionary = await root.get_node("GameSave").request_manual_save(slot)
			var saved_ok := bool(saved.get("ok", false))
			_expect("military replay saves on day %d" % day, saved_ok)
			if saved_ok:
				var fixture := FileAccess.open(directory.path_join(slot + "-fixture-sequence.txt"), FileAccess.WRITE)
				_expect("military replay records the command sequence at day %d" % day, fixture != null)
				if fixture != null:
					fixture.store_string(str(scenario._sequence))
					fixture.close()
	return rows


func _check_checkpoint(host: WorldRuntimeHost, scenario: RefCounted, day: int) -> void:
	var military = host.get_generator().get_military_facade()
	var army: Dictionary = military.army(scenario._army)
	match day:
		20:
			_expect("checkpoint has a pending embarkation receipt",
				int(military.report().get("pending_intents", 0)) > 0 and int(army.get("personnel_pending", 0)) > 0)
		31:
			_expect("checkpoint contains a marching army", not army.get("path", []).is_empty()
				and int(army.get("lane_population", 0)) > 0 and int(army.get("cell", -1)) != scenario._capital)
		MilitaryScenario.TREATY_DAY + 1:
			_expect("checkpoint contains the same-day cession and vision result",
				int(scenario.evidence.control_days_with_vision) > 0)
