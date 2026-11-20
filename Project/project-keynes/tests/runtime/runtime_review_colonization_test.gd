extends "res://tests/runtime/vision_fog_command_runtime_test.gd"


func _sample_military_world(host: WorldRuntimeHost, clock: WorldClock) -> Dictionary:
	var generator := host.get_generator()
	var country = generator.get_country_facade()
	var economy = generator.get_economy_facade()
	var ext = generator.get_data_core_world_ext()
	var start := int(generator.gameplay_start_report().get("cell", -1))
	var player := int(country.cell_summary(start).get("country_handle", 0))
	clock.set_speed(SPEED)
	var quote := {}
	var target := -1
	var results := {}
	host.simulation_command_results.connect(func(rows: Array) -> void:
		for row: Dictionary in rows:
			results[int(row.get("sequence", -1))] = row)
	for day in range(1, 5):
		_publish_day(host, clock, day)
		if not await _wait_golden_read_boundary(host, economy, day):
			_expect("executor settles expedition test day %d" % day, false)
			return {}
		match day:
			1:
				_expect("fog policy is admitted", host.set_fog_of_war_enabled(false).get("effective_day") == 2)
			2:
				var result := await _hidden_quote(host, economy, host.current_map(), start, player)
				quote = result.get("quote", {})
				target = int(result.get("target", -1))
				_expect("start uses a real quote with enough population", target >= 0
					and not quote.is_empty() and int(quote.maximum_populations[0]) >= 10)
				if target < 0 or quote.is_empty() or int(quote.maximum_populations[0]) < 10:
					return {}
				var first: Dictionary = economy.start_family_colonization(player, int(quote.family_handles[0]),
					int(quote.source_cells[0]), target, 10, int(quote.quote_tokens[0]), 3, 961001)
				_expect("first expedition admitted for day three", first.get("effective_day") == 3)
			3:
				var receipt := _receipt(ext, player, 961001)
				print("REVIEW_EXPEDITION_FIRST ", receipt)
				var expedition := int(receipt.get("expedition_handle", 0))
				_expect("fixture holds the target while preparing", expedition > 0 and receipt.get("code") == "PREPARING")
				if expedition <= 0 or receipt.get("code") != "PREPARING":
					return {}
				var cancelled: Dictionary = economy.cancel_family_colonization(player, expedition, 4, 961002)
				var started: Dictionary = economy.start_family_colonization(player, int(quote.family_handles[0]),
					int(quote.source_cells[0]), target, 1, int(quote.quote_tokens[0]), 4, 961003)
				_expect("cancel and start both admitted for day four", cancelled.get("effective_day") == 4
					and started.get("effective_day") == 4)
			4:
				var second := _receipt(ext, player, 961003)
				print("REVIEW_EXPEDITION_ORDER result=", results.get(961003, {}), " settlement=", second)
				var cancelled := _receipt(ext, player, 961002)
				_expect("the earlier cancellation releases the target for the same-day expedition",
					cancelled.get("code") == "CANCELLED" and cancelled.get("settled_day") == 4
					and second.get("settled_day") == 4 and second.get("code") == "PREPARING"
					and second.get("target_cell") == target and int(second.get("expedition_handle", 0)) > 0
					and second.get("expedition_handle") != cancelled.get("expedition_handle")
					and int(second.get("receipt_id", 0)) > int(cancelled.get("receipt_id", 0)))
	return {}


func _receipt(ext: Object, player: int, sequence: int) -> Dictionary:
	var batch: Dictionary = ext.get_family_colonization_receipts(player, 0, 32)
	for row: Dictionary in batch.get("receipts", []):
		if row.sequence == sequence:
			return row
	return {}
