extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

class CapacityHost extends WorldRuntimeHost:
	const SWEEP_CELLS := 24
	const PLAIN_VIEW_COST := 10

	var synthetic_observations := 0
	func _bind_renderer_and_camera(safe_area: Rect2) -> void:
		var map := current_map()
		var start := _resolve_player_start_cell()
		var player_slot := int(map.country_slot_arr[start])
		# Keep the stress sweep independent of the generated relief at the spawn.
		# Flat plains supply four rings. Use 24 remote cells to retain the
		# original workload within the receipt pages this test reads.
		var heights := PackedByteArray()
		heights.resize(map.cell_count())
		heights.fill(0)
		var blocks := PackedByteArray()
		blocks.resize(map.cell_count())
		blocks.fill(PLAIN_VIEW_COST)
		_world_data.cell_view_height = heights
		_world_data.cell_view_block = blocks
		var visible: PackedByteArray = VisionSolver.compute_visible_for_sources(
			map, _world_data, PackedInt32Array([start])).get("visible", PackedByteArray())
		var count: int = ResearchSignalCatalog.compile_native_catalog().research_signal_ids.size()
		var offsets := PackedInt32Array([0])
		var signals := PackedInt32Array()
		var remote_cells := 0
		for cell in map.cell_count():
			if (remote_cells < SWEEP_CELLS and cell < visible.size() and visible[cell] != 0
					and int(map.country_slot_arr[cell]) != player_slot):
				remote_cells += 1
				for signal_id in count:
					signals.append(signal_id)
			offsets.append(signals.size())
		map.cell_research_signal_offsets = offsets
		map.cell_research_signal_ids = signals
		await super._bind_renderer_and_camera(safe_area)
		for cell in map.cell_count():
			if map.physical_visible_arr[cell] != 0:
				synthetic_observations += offsets[cell + 1] - offsets[cell]
		print("CAPACITY_FIXTURE initial_remote_observations=%d valid_signal_ids=%d" % [synthetic_observations, count])

func _create_host() -> WorldRuntimeHost:
	return CapacityHost.new()

func _run() -> void:
	OS.set_environment("PK_GOLDEN_DOMAINS", "1")
	await _run_world(false, true)
	_finish()

func _sample_military_world(host: WorldRuntimeHost, clock: WorldClock) -> Dictionary:
	var fixture := host as CapacityHost
	_expect("synthetic observation count exceeds 4,096", fixture.synthetic_observations > 4096)
	var generator := host.get_generator()
	var country = generator.get_country_facade()
	var start := int(generator.gameplay_start_report().get("cell", -1))
	var handle := int(country.cell_summary(start).get("country_handle", 0))
	var grant: Dictionary = country.grant_technology(handle, &"tech.magnetic_navigation", 2, 920001, true)
	_expect("magnetic navigation admitted for day two", bool(grant.get("ok", false)) and int(grant.get("effective_day", -1)) == 2)
	clock.set_speed(SPEED)
	_expect("day one settled", await _advance_fixture(host, clock, 1))
	var day_two := await _advance_fixture(host, clock, 2)
	var report: Dictionary = generator.get_runtime_thread_report()
	print("CAPACITY_RESULT " + JSON.stringify({
		"second_day_settled": day_two, "committed_day": report.get("simulation_committed_day"),
		"state": report.get("simulation_host_state"), "fault": report.get("fault_code"),
		"queue_refusals": report.get("command_queue_capacity_exceeded"),
	}))
	_expect("a legal sweep exceeding 4,096 observations commits without queue refusal",
		day_two and report.get("fault_code", "") == ""
		and int(report.get("simulation_committed_day", -1)) == 2
		and report.get("command_queue_capacity_exceeded", -1) == 0)
	if day_two:
		var emitted := int(host._runtime_last_commit.get("vision_observations", 0))
		_expect("the whole observation batch is usable the next day",
			await _advance_fixture(host, clock, 3))
		var cursor := 0
		var settled := 0
		var ids := {}
		for _page in range(16):
			var page: Dictionary = country.poll_worker_command_receipts(cursor, 512)
			var rows: Array = page.get("receipts", [])
			if rows.is_empty():
				break
			cursor = int(page.last_publication_sequence)
			for row: Dictionary in rows:
				if row.effective_day == 3 and row.status == "Committed":
					settled += 1
					ids[row.request_id] = true
		print("CAPACITY_TERMINALS day=3 emitted=", emitted, " settled=", settled, " unique=", ids.size())
		_expect("every observation has one terminal even across receipt pages",
			emitted > 4096 and settled >= emitted and ids.size() == settled)
	return {}

func _advance_fixture(host: WorldRuntimeHost, clock: WorldClock, day: int) -> bool:
	_publish_day(host, clock, day)
	return await _wait_golden_read_boundary(host, host.get_generator().get_economy_facade(), day)
