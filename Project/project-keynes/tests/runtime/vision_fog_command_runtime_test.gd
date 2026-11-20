extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"


class SkippingDisplayHost extends WorldRuntimeHost:
	var skip_display := false

	func apply_runtime_vision_display() -> Dictionary:
		if skip_display:
			return {"ok": false, "reason": "test_display_failure"}
		return super.apply_runtime_vision_display()


func _create_host() -> WorldRuntimeHost:
	return SkippingDisplayHost.new()


func _run() -> void:
	await _run_world(false, true)
	_finish()


func _sample_military_world(host: WorldRuntimeHost, clock: WorldClock) -> Dictionary:
	var generator := host.get_generator()
	var country = generator.get_country_facade()
	var economy = generator.get_economy_facade()
	var ext = generator.get_data_core_world_ext()
	var map := host.current_map()
	var start := int(generator.gameplay_start_report().get("cell", -1))
	var player := int(country.cell_summary(start).get("country_handle", 0))
	var hidden := _find_hidden_unowned_land(map)
	_expect("fog fixture has hidden land and an active player", hidden >= 0 and player != 0)
	if hidden < 0 or player == 0:
		return {}
	clock.set_speed(SPEED)
	var test_host := host as SkippingDisplayHost
	var original_frame: Dictionary
	var target := -1
	var quote := {}
	for day in range(1, 9):
		_publish_day(host, clock, day)
		var settled := await _wait_golden_read_boundary(host, economy, day)
		_expect("day %d settles with vision display failure allowed" % day, settled)
		if not settled:
			return {}
		var frame: Dictionary = ext.get_runtime_vision_frame(-1)
		_expect("fog change takes effect exactly on day two and day six",
			bool(frame.fog_enabled) == (day < 2 or day >= 6))
		if not test_host.skip_display:
			_expect("GM fog readback agrees with the installed frame",
				host.get_gm_toggle_state("visual.fog_of_war").get("enabled") == frame.fog_enabled)
		match day:
			1:
				original_frame = frame
				var off := host.set_gm_toggle("visual.fog_of_war", false)
				_expect("fog off sealed for day two", bool(off.ok) and int(off.effective_day) == 2)
				var forged := map.visible_arr.duplicate()
				forged.fill(1)
				map.visible_arr = forged
				var request: Callable = economy.family_colonization_quotes.bind(player, hidden, 0, -1, 0, 1)
				var first: Dictionary = request.call()
				_expect("the first quote request returns while the executor owns the read",
					first.get("pending") == true and first.get("busy") == true)
				var blocked := await _published_quote(host, request)
				_expect("making a display cell visible does not authorize colonization",
					not bool(blocked.get("ok", false)) and blocked.get("code") == "colonization_target_invalid"
					and blocked.get("read_view_day") == day)
				test_host.skip_display = true
			2:
				var claim: Dictionary = country.transfer_territory(hidden, player, 4, 950001, true)
				_expect("a separate visibility update is sealed for day four",
					bool(claim.ok) and int(claim.effective_day) == 4)
			3:
				_expect("disabling fog leaves physical visibility and exploration untouched",
					frame.physical_visible == original_frame.physical_visible
					and frame.explored_arr == original_frame.explored_arr)
			4:
				_expect("display skipped two revisions while the territory became visible",
					int(frame.revision) >= int(original_frame.revision) + 2
					and int(map.vision_revision) == int(original_frame.revision)
					and int(frame.physical_visible[hidden]) != 0)
				test_host.skip_display = false
				var refreshed := host.apply_runtime_vision_display()
				_expect("one read installs the complete latest frame",
					bool(refreshed.get("applied", false)) and map.physical_visible_arr == frame.physical_visible
					and map.explored_arr == frame.explored_arr and map.visible_arr.count(1) == map.cell_count()
					and map.fog_k_arr.count(255) == map.cell_count()
					and host.get_gm_toggle_state("visual.fog_of_war").get("enabled") == false)
				var forged := map.visible_arr.duplicate()
				forged.fill(0)
				map.visible_arr = forged
				var result := await _hidden_quote(host, economy, map, start, player)
				target = int(result.get("target", -1))
				quote = result.get("quote", {})
				_expect("fog off opens routes even with a hidden display", target >= 0)
				if target >= 0:
					var token := int(quote.quote_tokens[0])
					var detail := await _published_quote(host,
						ext.get_family_colonization_quote_detail.bind(token, 1))
					_expect("the executor publishes the valid route at the same boundary",
						bool(detail.get("ok", false)) and detail.get("read_view_day") == day)
					var sent: Dictionary = economy.start_family_colonization(player,
						int(quote.family_handles[0]), int(quote.source_cells[0]), target, 1, token, 5, 950002)
					_expect("starting that expedition is queued for day five",
						bool(sent.ok) and bool(sent.queued) and int(sent.effective_day) == 5)
			5:
				var receipt_batch: Dictionary = ext.get_family_colonization_receipts(player, 0, 16)
				var exact_day := false
				for receipt in receipt_batch.get("receipts", []):
					exact_day = exact_day or (int(receipt.sequence) == 950002
						and int(receipt.effective_day) == 5 and int(receipt.settled_day) == 5
						and int(receipt.expedition_handle) != 0)
				_expect("the expedition settles on day five", exact_day)
				var on := host.set_fog_of_war_enabled(true)
				_expect("fog on sealed for day six", bool(on.ok) and int(on.effective_day) == 6)
			6:
				if target >= 0:
					var pending: Dictionary = economy.start_family_colonization(player,
						int(quote.family_handles[0]), int(quote.source_cells[0]), target, 1,
						int(quote.quote_tokens[0]), 8, 950003)
					_expect("the request is admitted before route revalidation", pending.get("admitted") == true
						and pending.get("effective_day") == 8)
				_expect("fog display is restored from the authoritative physical frame",
					map.visible_arr == frame.physical_visible and map.fog_k_arr == frame.fog_k_arr)
			8:
				var receipt_batch: Dictionary = ext.get_family_colonization_receipts(player, 0, 32)
				var refused := false
				for row: Dictionary in receipt_batch.get("receipts", []):
					if row.sequence == 950003:
						refused = row.effective_day == 8 and row.settled_day == 8 \
							and row.code == "colonization_route_not_visible"
				_expect("re-enabled fog rejects the old quote on its effective day", refused)
	print("FOG_VISIBILITY_COMMANDS off_day=2 on_day=6 hidden_route=", target)
	return {}


func _published_quote(host: WorldRuntimeHost, request: Callable) -> Dictionary:
	var started := Time.get_ticks_usec()
	var quote: Dictionary = request.call()
	while bool(quote.get("pending", false)) and Time.get_ticks_usec() - started < HOLD_WATCHDOG_USEC:
		await process_frame
		host._consume_runtime_commit_if_ready()
		quote = request.call()
	_expect("the quote is published without advancing the clock: %s" % quote.get("code", ""),
		not bool(quote.get("pending", false)))
	return quote


func _hidden_quote(host: WorldRuntimeHost, economy, map: MapData, start: int, player: int) -> Dictionary:
	var origin := HexUtils.offset_to_cube(start % map.width, start / map.width)
	for cell in map.cell_count():
		if map.physical_visible_arr[cell] != 0 or map.is_water_arr[cell] != 0 or map.country_slot_arr[cell] >= 0:
			continue
		var distance := HexUtils.cube_distance(origin, HexUtils.offset_to_cube(cell % map.width, cell / map.width))
		if distance > 10:
			continue
		var quote := await _published_quote(host,
			economy.family_colonization_quotes.bind(player, cell, 0, -1, 0, 1))
		if bool(quote.get("ok", false)) and not quote.get("quote_tokens", PackedInt64Array()).is_empty():
			return {"target": cell, "quote": quote}
	return {}
