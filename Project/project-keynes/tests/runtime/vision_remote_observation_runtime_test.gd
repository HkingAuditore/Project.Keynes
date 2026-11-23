extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"


func _run() -> void:
	await _run_world(false, true)
	_finish()


func _sample_military_world(host: WorldRuntimeHost, clock: WorldClock) -> Dictionary:
	var generator := host.get_generator()
	var country = generator.get_country_facade()
	var economy = generator.get_economy_facade()
	var start := int(generator.gameplay_start_report().get("cell", -1))
	var handle := int(country.cell_summary(start).get("country_handle", 0))
	var grant: Dictionary = country.grant_technology(handle, &"tech.magnetic_navigation", 2, 920001, true)
	_expect("magnetic navigation is scheduled for day two",
		bool(grant.get("ok", false)) and int(grant.get("effective_day", -1)) == 2)
	clock.set_speed(SPEED)
	var observations := 0
	for day in range(1, 4):
		_publish_day(host, clock, day)
		var settled := await _wait_golden_read_boundary(host, economy, day)
		_expect("remote observation scenario settles day %d" % day, settled)
		if not settled:
			return {}
		if day == 2:
			observations = int(host._runtime_last_commit.get("vision_observations", 0))
			_expect("the magnetic sweep exceeds the 256-command batch limit", observations > 256)
	var terminal: Array = country.poll_worker_command_receipts(0, 4096).get("receipts", [])
	var committed_on_day_three := 0
	for receipt in terminal:
		if int(receipt.effective_day) == 3 and String(receipt.status) == "Committed":
			committed_on_day_three += 1
	var research: Dictionary = country.research_signal_snapshot(handle)
	var last_days: PackedInt64Array = research.get("last_days", PackedInt64Array())
	_expect("the large observation batch settles on day three", committed_on_day_three >= observations)
	_expect("day-three observations reach the research ledger", last_days.has(3))
	print("REMOTE_VISION_BATCH day=2 observations=%d next_day_terminals=%d" % [
		observations, committed_on_day_three])
	return {}
