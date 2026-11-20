extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

const Technology := preload("res://scripts/economy/technology_catalog.gd")
const Workspace := preload("res://scenes/ui/technology_workspace.tscn")


func _run() -> void:
	await _run_world(false, true)
	_finish()


func _sample_military_world(host: WorldRuntimeHost, clock: WorldClock) -> Dictionary:
	var generator := host.get_generator()
	var country: CountryFacade = generator.get_country_facade()
	var economy = generator.get_economy_facade()
	var player := PlayerController.new()
	root.add_child(player)
	player.configure(null, null, host, clock, null)
	player.refresh_country_binding()
	var handle := player.get_player_country_handle()
	var ids: PackedStringArray = country.get("_catalog").technology_ids
	var domains: PackedInt32Array = country.get("_catalog").technology_domain_indices
	var view := country.research_snapshot(handle)
	var states: PackedInt32Array = view.technology_states
	var eligible := states.find(2)
	_expect("real player has a researchable technology", eligible >= 0 and handle > 0)
	if eligible < 0 or handle == 0:
		player.free()
		return {}
	var unavailable := (eligible + 1) % ids.size()
	var later := country.enqueue_research(handle, StringName(ids[eligible]),
		domains[eligible], -1, 3, 91001)
	var earlier := country.enqueue_research(handle, StringName(ids[unavailable]),
		-1, -1, 2, 91002)
	print("REVIEW_RESEARCH_ADMISSION later=", later, " earlier=", earlier)
	_expect("both real requests receive their distinct dates",
		later.get("effective_day") == 3 and earlier.get("effective_day") == 2)
	if not later.has("request_ids") or not earlier.has("request_ids"):
		player.free()
		return {}
	var later_id := int(later.request_ids[0])
	var earlier_id := int(earlier.request_ids[0])
	_expect("earlier settlement has higher request number", earlier_id > later_id)
	var panel := Workspace.instantiate()
	root.add_child(panel)
	panel.set_player_controller(player)
	var compiled: Dictionary = Technology.compile_native_catalog()
	panel.set_model({"country_handle": handle, "research": view,
		"technology_definitions": Technology.public_definitions(compiled),
		"technology_eras": Technology.public_era_metadata(),
		"technology_domains": Technology.public_domain_metadata(),
		"technology_lanes": Technology.public_lane_metadata(),
		"technology_visual_edges": Technology.public_visual_edges()})
	panel.set("_optimistic_queue", {
		eligible: {"request_id": later_id, "domain": domains[eligible], "technology_id": ids[eligible]},
		unavailable: {"request_id": earlier_id, "domain": 0, "technology_id": ids[unavailable]},
	})
	# Poll explicitly at each committed boundary so the UI sees both page splits.
	panel.process_mode = Node.PROCESS_MODE_DISABLED
	clock.set_speed(SPEED)
	for day in range(1, 4):
		_publish_day(host, clock, day)
		if not await _wait_golden_read_boundary(host, economy, day):
			_expect("research executor reaches day %d" % day, false)
			break
		if day < 2:
			continue
		var cursor := int(panel.get("_receipt_cursor"))
		var batch := country.poll_worker_command_receipts(cursor, 64)
		panel._poll_optimistic_receipts()
		var pending: Dictionary = panel.get("_optimistic_queue")
		print("REVIEW_RESEARCH_PAGE day=", day, " cursor=", cursor, " page=", batch, " pending=", pending.keys())
		var match_id := earlier_id if day == 2 else later_id
		var match_status := "RejectedAtExecution" if day == 2 else "Committed"
		var matched := false
		for row: Dictionary in batch.get("receipts", []):
			if row.request_id == match_id and row.status == match_status and row.effective_day == day:
				matched = day != 2 or row.reason == "country_research_queue_argument_invalid"
		_expect("page has the matching research terminal on day %d" % day, matched)
		if day == 2:
			_expect("unrelated pending request survives the rejection",
				pending.has(eligible) and not pending.has(unavailable))
		else:
			_expect("the low request number is cleared only after its own commit", pending.is_empty())
	panel.free()
	player.free()
	return {}
