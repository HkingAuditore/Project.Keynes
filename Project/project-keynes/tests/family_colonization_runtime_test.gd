extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")

var _failures := 0


func _init() -> void:
	_run()
	print("=== family colonization runtime: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var fixture := _make_fixture(catalog, 260810)
	var ext: Object = fixture.ext
	var country_handle := int(fixture.country_handle)
	if ext == null or country_handle == 0:
		return
	var families: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	_expect("founder family is available as a source branch",
		bool(families.get("ok", false)) and int(families.get("total", 0)) == 1)
	if int(families.get("total", 0)) != 1:
		return
	var family_handle := int((families.family_handles as PackedInt64Array)[0])
	var source_before := int(ext.get_population_cell_snapshot(0).population)
	var family_before: Dictionary = ext.get_family_snapshot(family_handle)
	fixture.map.visible_arr[1] = 0
	fixture.map.vision_revision += 1
	var hidden_route: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 2, family_handle, 0, 0, 64)
	_expect("a route with any fogged intermediate cell produces no quote",
		bool(hidden_route.get("ok", false)) and int(hidden_route.get("total", -1)) == 0)
	fixture.map.visible_arr[1] = 1
	fixture.map.vision_revision += 1

	var quotes: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 2, family_handle, 0, 0, 64)
	_expect("one reverse Dijkstra returns the owned family branch",
		bool(quotes.get("ok", false)) and int(quotes.get("total", 0)) == 1
		and String(quotes.get("kind", "")) == "colonize"
		and int((quotes.route_costs as PackedInt32Array)[0]) == 4
		and int(quotes.get("expansions", 9000)) <= 8192
		and quotes.has("busy") and not bool(quotes.get("busy", true)))
	if int(quotes.get("total", 0)) != 1:
		print("quotes=", quotes)
		return
	var token := int((quotes.quote_tokens as PackedInt64Array)[0])
	var detail: Dictionary = ext.get_family_colonization_quote_detail(token)
	_expect("quote detail freezes route and cumulative enter costs",
		(detail.route_cells as PackedInt32Array) == PackedInt32Array([0, 1, 2])
		and (detail.cumulative_costs as PackedInt32Array) == PackedInt32Array([0, 2, 4]))

	# A revision-only vision change is accepted when the deterministic route hash
	# remains unchanged. The command extracts real population immediately.
	fixture.map.vision_revision += 1
	var started: Dictionary = ext.start_family_colonization(country_handle,
		family_handle, 0, 2, 1, token, 0, 1)
	_expect("revision-only requote validation accepts an unchanged route",
		bool(started.get("ok", false)) and int(started.get("arrival_day", -1)) == 4)
	if not bool(started.get("ok", false)):
		print("start=", started)
		return
	var expedition_handle := int(started.expedition_handle)
	var in_transit: Dictionary = ext.get_family_expedition_snapshot(
		country_handle, expedition_handle)
	_expect("departure moves population into sparse transit custody",
		int(ext.get_population_cell_snapshot(0).population) == source_before - 1
		and int(in_transit.population) == 1
		and int(ext.get_family_snapshot(family_handle).population) ==
			int(family_before.population))
	_expect("idle expedition start does not pause the money ledger",
		not bool(ext.get_economy_report().get("fatal", false))
		and int(ext.get_economy_report().get("money_error", -1)) == 0)
	var saved := _save_economy(ext)
	var restored_fixture := _make_fixture(catalog.duplicate(true), 260810)
	var restored: Object = restored_fixture.ext
	var restored_result := _restore_economy(restored, saved.get("chunks", []))
	var restored_page: Dictionary = restored.get_family_expeditions(
		int(restored_fixture.country_handle), 0, 64)
	if not bool(restored_result.get("ok", false)) or int(
			restored_page.get("total", 0)) != 1:
		print("restore=", restored_result, " page=", restored_page,
			" saved_schema=", saved.get("schema", 0))
	_expect("PKEC v41 restores in-flight route, payload, cargo and due heap exactly",
		int(saved.get("schema", 0)) == 39
		and bool(restored_result.get("ok", false))
		and int(restored_page.get("total", 0)) == 1
		and int(restored.get_economy_state_hash()) == int(ext.get_economy_state_hash()))
	var duplicate: Dictionary = ext.start_family_colonization(country_handle,
		family_handle, 0, 2, 1, token, 0, 2)
	_expect("country and target active index rejects duplicates in O(1)",
		String(duplicate.get("code", "")) == "colonization_duplicate_target")

	var cancelled: Dictionary = ext.cancel_family_colonization(
		country_handle, expedition_handle, 1, 3)
	var returning: Dictionary = ext.get_family_expedition_snapshot(
		country_handle, expedition_handle)
	_expect("cancellation derives return duration from progressed route cost",
		bool(cancelled.get("ok", false)) and int(returning.state) == 3
		and int(returning.due_day) == 2)
	_run_day(ext, 2)
	ext.capture_economy_trade_topology(fixture.neighbors, fixture.terrain,
		fixture.passable, fixture.costs, 1)
	_expect("return restores the original source even without ownership checks",
		int(ext.get_family_expeditions(country_handle, 0, 64).total) == 0
		and int(ext.get_population_cell_snapshot(0).population) == source_before)
	_expect("return epoch keeps money conservation at zero",
		not bool(ext.get_economy_report().get("fatal", false))
		and int(ext.get_economy_report().get("money_error", -1)) == 0)
	var receipts: Dictionary = ext.get_family_colonization_receipts(
		country_handle, 0, 64)
	var codes := PackedStringArray()
	for receipt in receipts.get("receipts", []):
		codes.append(String(receipt.get("code", "")))
	_expect("event receipts publish start, cancellation and return",
		codes.has("STARTED") and codes.has("CANCELLED_RETURNING")
		and codes.has("RETURNED"))
	var report: Dictionary = ext.get_economy_report()
	_expect("diagnostics expose sparse-heap and stage timing counters",
		report.has("family_expedition_active_count")
		and report.has("colonization_route_query_ms")
		and int(report.family_expedition_active_count) == 0)

	var second_quotes: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 2, family_handle, 0, 0, 64)
	_expect("returned source can be quoted again after the transit release",
		bool(second_quotes.get("ok", false)) and
		int(second_quotes.get("total", 0)) == 1)
	if int(second_quotes.get("total", 0)) != 1:
		return
	var second_token := int((second_quotes.quote_tokens as PackedInt64Array)[0])
	var second_start: Dictionary = ext.start_family_colonization(country_handle,
		family_handle, 0, 2, 1, second_token, 2, 4)
	_expect("second expedition starts for the cross-domain arrival path",
		bool(second_start.get("ok", false)))
	# One cooperative slice enqueues SETTLING and typically leaves the frozen
	# cycle open. SETTLE must then queue into pending and survive EPOCH_BEGIN
	# preflight instead of being dropped as a fake cohort handle.
	var arrival_slice: Dictionary = ext.run_economy_slice({
		"day_index": 6,
		"tick_index": 6001,
		"slice_budget_ms": 0.1,
	})
	var live_quotes: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 0, family_handle, 0, 0, 64)
	_expect("quotes stay readable while a frozen cycle may be open",
		bool(live_quotes.get("ok", false)) and live_quotes.has("busy")
		and int(live_quotes.get("total", -1)) == 0)
	if bool(arrival_slice.get("epoch_active", false)):
		_expect("an open epoch marks colonization quotes as nonbinding",
			bool(live_quotes.get("busy", false))
			and bool(live_quotes.get("nonbinding", false)))
		var busy_invalid: Dictionary = ext.start_family_colonization(
			country_handle, family_handle, 0, 2, 1, 1, 6, 99)
		_expect("invalid tokens are rejected even while an epoch is open",
			not bool(busy_invalid.get("ok", true))
			and String(busy_invalid.get("code", "")) != "economy_busy_retry")
		var side_quotes: Dictionary = ext.get_family_colonization_quotes(
			country_handle, 1, family_handle, 0, 0, 64)
		if bool(side_quotes.get("ok", false)) and int(side_quotes.get("total", 0)) > 0:
			var side_token := int((side_quotes.quote_tokens as PackedInt64Array)[0])
			var source_during_busy := int(ext.get_population_cell_snapshot(0).population)
			var queued: Dictionary = ext.start_family_colonization(
				country_handle, family_handle, 0, 1, 1, side_token, 6, 100)
			_expect("start queues during a frozen cycle instead of blocking the button",
				bool(queued.get("ok", false))
				and String(queued.get("code", "")) == "colonization_queued"
				and int(ext.get_population_cell_snapshot(0).population) ==
					source_during_busy)
			var duplicate_queue: Dictionary = ext.start_family_colonization(
				country_handle, family_handle, 0, 1, 1, side_token, 6, 101)
			_expect("queued starts still occupy the target in O(1)",
				String(duplicate_queue.get("code", "")) ==
					"colonization_duplicate_target")
	var second_handle := int(second_start.expedition_handle)
	var settling: Dictionary = ext.get_family_expedition_snapshot(
		country_handle, second_handle)
	_expect("arrival enqueue moves the expedition into SETTLING",
		int(settling.get("state", -1)) == 2)
	var premature_economy_dispatch: Dictionary = ext.dispatch_effect_native_economy()
	var country_dispatch: Dictionary = ext.dispatch_effect_native_country()
	var country_commit: Dictionary = ext.run_country_slice({"day_index": 6})
	var country_ack: Dictionary = ext.ack_effect_native_country()
	var economy_dispatch: Dictionary = ext.dispatch_effect_native_economy()
	var queued_during_epoch := bool(arrival_slice.get("epoch_active", false)) \
		and _has_expedition(ext, country_handle, second_handle)
	if queued_during_epoch:
		_expect("an open epoch queues SETTLE instead of applying it immediately",
			int(economy_dispatch.get("submitted_transactions", 0)) == 1)
	var landed := false
	var economy_ack: Dictionary = {}
	for day in range(6, 20):
		_run_day(ext, day)
		economy_ack = ext.ack_effect_native_economy()
		if not _has_expedition(ext, country_handle, second_handle):
			landed = true
			break
	_expect("arrival claims neutral territory and settles custody through two ACKs",
		int(premature_economy_dispatch.get("submitted_transactions", -1)) == 0
		and int(country_dispatch.get("submitted_transactions", 0)) == 1
		and bool(country_commit.get("ok", false))
		and int(country_ack.get("acknowledged", 0)) == 1
		and int(economy_dispatch.get("submitted_transactions", 0)) == 1
		and landed
		and int(economy_ack.get("acknowledged", 0)) >= 0
		and int(ext.get_country_cell_summary(2).country_handle) == country_handle
		and not _has_expedition(ext, country_handle, second_handle)
		and int(ext.get_population_cell_snapshot(2).population) == 1)
	_run_owned_cell_relocation(ext, country_handle, family_handle)
	_run_foreign_target_rejection(catalog.duplicate(true))
	_run_colonization_kit_cases(catalog.duplicate(true))


func _run_colonization_kit_cases(catalog: Dictionary) -> void:
	_run_greenfield_kit_and_return(catalog.duplicate(true))
	_run_greenfield_kit_settle(catalog.duplicate(true))
	_run_interior_kit_settle_during_frozen_cycle(catalog.duplicate(true))
	_run_zero_stock_partial_kit(catalog.duplicate(true))


func _economy_command_day(ext: Object) -> int:
	return maxi(0, int(ext.get_economy_report().get("current_day", 0)))


func _run_greenfield_kit_and_return(catalog: Dictionary) -> void:
	var fixture := _make_fixture(catalog, 260820)
	var ext: Object = fixture.ext
	var country_handle := int(fixture.country_handle)
	if ext == null or country_handle == 0:
		return
	var families: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	if int(families.get("total", 0)) != 1:
		_expect("kit return fixture has a founder family", false)
		return
	var family_handle := int((families.family_handles as PackedInt64Array)[0])
	var quotes: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 2, family_handle, 0, 0, 64)
	_expect("greenfield kit quote is available from the founder household",
		bool(quotes.get("ok", false)) and int(quotes.get("total", 0)) == 1)
	if int(quotes.get("total", 0)) != 1:
		print("kit_quotes=", quotes)
		return
	var token := int((quotes.quote_tokens as PackedInt64Array)[0])
	var detail: Dictionary = ext.get_family_colonization_quote_detail(token, 3)
	var gathering := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var merchant := (catalog.building_type_ids as PackedStringArray).find(
		"early_merchant_post")
	var kit_ids: PackedInt32Array = detail.get("kit_building_ids", PackedInt32Array())
	_expect("N=3 greenfield quote plans gathering plus a merchant post",
		bool(detail.get("ok", false)) and bool(detail.get("kit_place_buildings", false))
		and not bool(detail.get("kit_partial", true))
		and kit_ids.has(gathering) and kit_ids.has(merchant))
	var stock_before := _market_stock_total(ext, 0)
	var start_day := _economy_command_day(ext)
	var started: Dictionary = ext.start_family_colonization(country_handle,
		family_handle, 0, 2, 3, token, start_day, 401)
	var stock_after_start := _market_stock_total(ext, 0)
	_expect("greenfield kit extracts conserved cargo from the source market",
		bool(started.get("ok", false))
		and stock_after_start < stock_before
		and int(ext.get_economy_report().get("goods_error", -1)) == 0
		and int(ext.get_economy_report().get("population_error", -1)) == 0)
	if not bool(started.get("ok", false)):
		print("kit_start=", started, " detail=", detail)
		return
	var saved := _save_economy(ext)
	var restored_fixture := _make_fixture(catalog.duplicate(true), 260820)
	var restored: Object = restored_fixture.ext
	var restored_result := _restore_economy(restored, saved.get("chunks", []))
	_expect("PKEC v41 restores in-flight kit cargo and frozen buildings",
		int(saved.get("schema", 0)) == 39
		and bool(restored_result.get("ok", false))
		and int(restored.get_economy_state_hash()) == int(ext.get_economy_state_hash()))
	var cancelled: Dictionary = ext.cancel_family_colonization(
		country_handle, int(started.expedition_handle), start_day + 1, 402)
	var due := int(ext.get_family_expedition_snapshot(country_handle,
		int(started.expedition_handle)).get("due_day", start_day + 2))
	_run_day(ext, due)
	ext.capture_economy_trade_topology(fixture.neighbors, fixture.terrain,
		fixture.passable, fixture.costs, 1)
	_expect("returned kit cargo is restored to the source market",
		bool(cancelled.get("ok", false))
		and int(ext.get_family_expeditions(country_handle, 0, 64).total) == 0
		and _market_stock_total(ext, 0) >= stock_after_start
		and int(ext.get_economy_report().get("goods_error", -1)) == 0)


func _run_greenfield_kit_settle(catalog: Dictionary) -> void:
	var fixture := _make_fixture(catalog, 260821)
	var ext: Object = fixture.ext
	var country_handle := int(fixture.country_handle)
	if ext == null or country_handle == 0:
		return
	var families: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	if int(families.get("total", 0)) != 1:
		_expect("kit settle fixture has a founder family", false)
		return
	var family_handle := int((families.family_handles as PackedInt64Array)[0])
	var quotes: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 2, family_handle, 0, 0, 64)
	if int(quotes.get("total", 0)) != 1:
		_expect("kit settle quote exists", false)
		print("kit_settle_quotes=", quotes)
		return
	var token := int((quotes.quote_tokens as PackedInt64Array)[0])
	var gathering := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var merchant := (catalog.building_type_ids as PackedStringArray).find(
		"early_merchant_post")
	var start_day := _economy_command_day(ext)
	var started: Dictionary = ext.start_family_colonization(country_handle,
		family_handle, 0, 2, 3, token, start_day, 501)
	_expect("kit settle expedition starts with three people",
		bool(started.get("ok", false)))
	if not bool(started.get("ok", false)):
		print("kit_settle_start=", started)
		return
	var arrival := int(started.get("arrival_day", start_day + 4))
	var landed := _settle_unowned_expedition(ext, country_handle,
		int(started.expedition_handle), arrival)
	var buildings: Dictionary = ext.get_building_cell_snapshot(2)
	var type_ids: PackedInt32Array = buildings.get("group_type_ids", PackedInt32Array())
	var counts: PackedInt64Array = buildings.get("group_counts", PackedInt64Array())
	var filled: PackedInt64Array = buildings.get("filled_owner", PackedInt64Array())
	var gathering_count := 0
	var merchant_count := 0
	var gathering_filled := 0
	var merchant_filled := 0
	for index in range(type_ids.size()):
		if int(type_ids[index]) == gathering:
			gathering_count += int(counts[index]) if index < counts.size() else 0
			gathering_filled += int(filled[index]) if index < filled.size() else 0
		elif int(type_ids[index]) == merchant:
			merchant_count += int(counts[index]) if index < counts.size() else 0
			merchant_filled += int(filled[index]) if index < filled.size() else 0
	_expect("greenfield arrival consumes cargo and places family buildings",
		landed
		and gathering_count >= 1 and merchant_count >= 1
		and gathering_filled > 0 and merchant_filled > 0
		and int(ext.get_population_cell_snapshot(2).population) == 3
		and int(ext.get_economy_report().get("goods_error", -1)) == 0
		and int(ext.get_economy_report().get("population_error", -1)) == 0)
	var dest_before := _building_group_total(ext, 2)
	ext.capture_economy_trade_topology(fixture.neighbors, fixture.terrain,
		fixture.passable, fixture.costs, 2)
	var relocate_quotes: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 2, family_handle, 0, 0, 64)
	if int(relocate_quotes.get("total", 0)) != 1:
		_expect("developed-cell relocate quote exists after kit landing", false)
		print("kit_relocate_quotes=", relocate_quotes)
		return
	var relocate_token := int((relocate_quotes.quote_tokens as PackedInt64Array)[0])
	var relocate_detail: Dictionary = ext.get_family_colonization_quote_detail(
		relocate_token, 3)
	_expect("developed cells only carry a survival bridge, not new buildings",
		bool(relocate_detail.get("ok", false))
		and not bool(relocate_detail.get("kit_place_buildings", true)))
	var relocate_day := _economy_command_day(ext)
	var relocated: Dictionary = ext.start_family_colonization(country_handle,
		family_handle, 0, 2, 3, relocate_token, relocate_day, 502)
	if not bool(relocated.get("ok", false)):
		_expect("developed-cell relocate starts", false)
		print("kit_relocate_start=", relocated)
		return
	var relocate_arrival := int(relocated.get("arrival_day", relocate_day + 4))
	var relocate_landed := _settle_owned_expedition(ext, country_handle,
		int(relocated.expedition_handle), relocate_arrival)
	_expect("relocation into a developed cell does not place another kit",
		relocate_landed and _building_group_total(ext, 2) == dest_before
		and int(ext.get_economy_report().get("goods_error", -1)) == 0)


func _run_interior_kit_settle_during_frozen_cycle(catalog: Dictionary) -> void:
	# Cell 2 keeps buildings while the second landing inserts cell 1, which
	# sorts into the middle of (cell, good) market signals. Mid-epoch topology
	# rebuild used to shift cell 2's reserves and fatal the live calendar.
	var fixture := _make_fixture(catalog, 260823)
	var ext: Object = fixture.ext
	var country_handle := int(fixture.country_handle)
	if ext == null or country_handle == 0:
		return
	var families: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	if int(families.get("total", 0)) != 1:
		_expect("interior-kit fixture has a founder family", false)
		return
	var family_handle := int((families.family_handles as PackedInt64Array)[0])
	var first_quotes: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 2, family_handle, 0, 0, 64)
	if int(first_quotes.get("total", 0)) != 1:
		_expect("coastal kit quote exists before the interior landing", false)
		print("interior_first_quotes=", first_quotes)
		return
	var first_token := int((first_quotes.quote_tokens as PackedInt64Array)[0])
	var first_start_day := _economy_command_day(ext)
	var first_started: Dictionary = ext.start_family_colonization(
		country_handle, family_handle, 0, 2, 3, first_token, first_start_day,
		701)
	_expect("coastal kit expedition starts before the interior landing",
		bool(first_started.get("ok", false)))
	if not bool(first_started.get("ok", false)):
		print("interior_first_start=", first_started)
		return
	var first_arrival := int(first_started.get("arrival_day", first_start_day + 4))
	var first_landed := _settle_unowned_expedition(ext, country_handle,
		int(first_started.expedition_handle), first_arrival)
	_expect("coastal cell keeps kit buildings as the higher-index producer",
		first_landed and _building_group_total(ext, 2) >= 1
		and not bool(ext.get_economy_report().get("fatal", false)))
	if bool(ext.get_economy_report().get("fatal", false)):
		print("interior_after_coastal=", ext.get_economy_report())
		return
	ext.capture_economy_trade_topology(fixture.neighbors, fixture.terrain,
		fixture.passable, fixture.costs, 2)
	var gathering := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var merchant := (catalog.building_type_ids as PackedStringArray).find(
		"early_merchant_post")
	var interior_quotes: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 1, family_handle, 0, 0, 64)
	if int(interior_quotes.get("total", 0)) != 1:
		_expect("interior greenfield quote exists after the coastal landing",
			false)
		print("interior_quotes=", interior_quotes)
		return
	var interior_token := int((interior_quotes.quote_tokens as PackedInt64Array)[0])
	var travel_days := int(ext.get_family_colonization_quote_detail(
		interior_token, 3).get("travel_days", 2))
	var start_day := _economy_command_day(ext)
	while (start_day + travel_days) % 5 != 2 and start_day < 64:
		start_day += 1
		var waited: Dictionary = _run_day(ext, start_day)
		if bool(waited.get("fatal", false)):
			_expect("waiting for cell-2 production phase stays conserved", false)
			print("interior_wait=", waited)
			return
		# Slice capture rebuilds topology from map slots. Restore the fixture
		# LUT so cell 1 stays a reachable greenfield target.
		ext.capture_economy_trade_topology(fixture.neighbors, fixture.terrain,
			fixture.passable, fixture.costs, 2)
		interior_quotes = ext.get_family_colonization_quotes(
			country_handle, 1, family_handle, 0, 0, 64)
		if int(interior_quotes.get("total", 0)) != 1:
			_expect("interior quote survives the phase wait", false)
			print("interior_wait_quotes=", interior_quotes, " day=", start_day)
			return
		interior_token = int((interior_quotes.quote_tokens as PackedInt64Array)[0])
	var interior_started: Dictionary = ext.start_family_colonization(
		country_handle, family_handle, 0, 1, 3, interior_token, start_day, 702)
	_expect("interior kit expedition starts toward the mid-index cell",
		bool(interior_started.get("ok", false)))
	if not bool(interior_started.get("ok", false)):
		print("interior_start=", interior_started, " day=", start_day)
		return
	var interior_arrival := int(interior_started.get("arrival_day",
		start_day + travel_days))
	var interior_landed := _settle_unowned_expedition(ext, country_handle,
		int(interior_started.expedition_handle), interior_arrival)
	var buildings: Dictionary = ext.get_building_cell_snapshot(1)
	var type_ids: PackedInt32Array = buildings.get("group_type_ids",
		PackedInt32Array())
	var report: Dictionary = ext.get_economy_report()
	if bool(report.get("fatal", false)):
		print("interior_fatal=", report)
	_expect("mid-index kit landing during a frozen cycle stays conserved",
		interior_landed
		and type_ids.has(gathering) and type_ids.has(merchant)
		and int(ext.get_population_cell_snapshot(1).population) == 3
		and not bool(report.get("fatal", false))
		and int(report.get("goods_error", -1)) == 0
		and int(report.get("population_error", -1)) == 0
		and int(report.get("money_error", -1)) == 0)


func _run_zero_stock_partial_kit(catalog: Dictionary) -> void:
	var fixture := _make_fixture(catalog, 260822, 0)
	var ext: Object = fixture.ext
	var country_handle := int(fixture.country_handle)
	if ext == null or country_handle == 0:
		return
	var families: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	if int(families.get("total", 0)) != 1:
		_expect("zero-stock kit fixture has a founder family", false)
		return
	var family_handle := int((families.family_handles as PackedInt64Array)[0])
	var quotes: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 2, family_handle, 0, 0, 64)
	if int(quotes.get("total", 0)) != 1:
		_expect("zero-stock quote exists", false)
		print("zero_stock_quotes=", quotes)
		return
	var token := int((quotes.quote_tokens as PackedInt64Array)[0])
	var detail: Dictionary = ext.get_family_colonization_quote_detail(token, 3)
	var gathering := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var kit_ids: PackedInt32Array = detail.get("kit_building_ids", PackedInt32Array())
	_expect("zero source stock drops paid buildings and marks the kit partial",
		bool(detail.get("ok", false)) and bool(detail.get("kit_partial", false))
		and not kit_ids.has(gathering))
	var start_day := _economy_command_day(ext)
	var started: Dictionary = ext.start_family_colonization(country_handle,
		family_handle, 0, 2, 3, token, start_day, 601)
	_expect("partial kits may still depart when only the survival bridge is short",
		bool(started.get("ok", false)))
	if not bool(started.get("ok", false)):
		print("zero_stock_start=", started)
		return
	var saved := _save_economy(ext)
	var restored_fixture := _make_fixture(catalog.duplicate(true), 260822, 0)
	var restored: Object = restored_fixture.ext
	var restored_result := _restore_economy(restored, saved.get("chunks", []))
	_expect("v37 empty-cargo expeditions restore like a v36 in-flight party",
		int(saved.get("schema", 0)) == 39
		and bool(restored_result.get("ok", false))
		and int(restored.get_economy_state_hash()) == int(ext.get_economy_state_hash()))


func _settle_unowned_expedition(ext: Object, country_handle: int,
		expedition_handle: int, arrival_day: int) -> bool:
	ext.run_economy_slice({
		"day_index": arrival_day,
		"tick_index": arrival_day * 1000 + 1,
		"slice_budget_ms": 0.1,
	})
	ext.dispatch_effect_native_economy()
	ext.dispatch_effect_native_country()
	ext.run_country_slice({"day_index": arrival_day})
	ext.ack_effect_native_country()
	ext.dispatch_effect_native_economy()
	if not _has_expedition(ext, country_handle, expedition_handle):
		return true
	for day in range(arrival_day, arrival_day + 15):
		_run_day(ext, day)
		ext.ack_effect_native_economy()
		if not _has_expedition(ext, country_handle, expedition_handle):
			return true
	return false


func _settle_owned_expedition(ext: Object, country_handle: int,
		expedition_handle: int, arrival_day: int) -> bool:
	ext.run_economy_slice({
		"day_index": arrival_day,
		"tick_index": arrival_day * 1000 + 1,
		"slice_budget_ms": 0.1,
	})
	ext.dispatch_effect_native_country()
	if _has_expedition(ext, country_handle, expedition_handle):
		ext.dispatch_effect_native_economy()
	if not _has_expedition(ext, country_handle, expedition_handle):
		return true
	for day in range(arrival_day, arrival_day + 15):
		_run_day(ext, day)
		ext.ack_effect_native_economy()
		if not _has_expedition(ext, country_handle, expedition_handle):
			return true
	return false


func _market_stock_total(ext: Object, cell_idx: int) -> int:
	var snapshot: Dictionary = ext.get_market_cell_snapshot(cell_idx)
	var stock: PackedInt64Array = snapshot.get("stock", PackedInt64Array())
	var total := 0
	for quantity in stock:
		total += int(quantity)
	return total


func _building_group_total(ext: Object, cell_idx: int) -> int:
	var snapshot: Dictionary = ext.get_building_cell_snapshot(cell_idx)
	var counts: PackedInt64Array = snapshot.get("group_counts", PackedInt64Array())
	var total := 0
	for count in counts:
		total += int(count)
	return total


func _run_owned_cell_relocation(ext: Object, country_handle: int,
		family_handle: int) -> void:
	country_handle = int(ext.get_country_cell_summary(0).get("country_handle", 0))
	_expect("economy remains conserved after the unowned claim landing",
		not bool(ext.get_economy_report().get("fatal", false))
		and int(ext.get_economy_report().get("population_error", -1)) == 0
		and int(ext.get_economy_report().get("money_error", -1)) == 0)
	var grow_day := int(ext.get_economy_report().get("current_day", 7)) + 1
	_grow_founder_family(ext, family_handle, 0, 2, grow_day)
	var neighbors := PackedInt32Array()
	neighbors.resize(18)
	neighbors.fill(-1)
	neighbors[0] = 1
	neighbors[9] = 0
	neighbors[6] = 2
	neighbors[15] = 1
	var passable := PackedByteArray()
	var costs := PackedInt32Array()
	passable.resize(256)
	costs.resize(256)
	passable[2] = 1
	costs[2] = 2
	ext.capture_economy_trade_topology(neighbors, PackedByteArray([2, 2, 2]),
		passable, costs, 2)
	var self_quotes: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 0, family_handle, 0, 0, 64)
	_expect("source cell is not a colonization target for its own branch",
		bool(self_quotes.get("ok", false)) and int(self_quotes.get("total", -1)) == 0)
	var relocate_quotes: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 2, family_handle, 0, 0, 64)
	_expect("owned populated cell returns a relocate quote",
		bool(relocate_quotes.get("ok", false))
		and String(relocate_quotes.get("kind", "")) == "relocate"
		and int(relocate_quotes.get("total", 0)) == 1)
	if int(relocate_quotes.get("total", 0)) != 1:
		print("relocate_quotes=", relocate_quotes)
		return
	var token := int((relocate_quotes.quote_tokens as PackedInt64Array)[0])
	var detail: Dictionary = ext.get_family_colonization_quote_detail(token)
	_expect("relocate quote detail names the owned destination",
		String(detail.get("kind", "")) == "relocate"
		and int(detail.get("target_cell", -1)) == 2)
	var source_before := int(ext.get_population_cell_snapshot(0).population)
	var dest_before := int(ext.get_population_cell_snapshot(2).population)
	var family_before := int(ext.get_family_snapshot(family_handle).population)
	var start_day := int(ext.get_economy_report().get("current_day", 6))
	var started: Dictionary = ext.start_family_colonization(country_handle,
		family_handle, 0, 2, 1, token, start_day, 20)
	_expect("owned-cell relocation extracts conserved transit population",
		bool(started.get("ok", false))
		and int(ext.get_population_cell_snapshot(0).population) == source_before - 1
		and int(ext.get_family_snapshot(family_handle).population) == family_before)
	if not bool(started.get("ok", false)):
		print("relocate_start=", started)
		return
	var arrival := int(started.get("arrival_day", start_day + 4))
	var arrival_report: Dictionary = _run_day(ext, arrival)
	ext.ack_effect_native_economy()
	var country_dispatch: Dictionary = ext.dispatch_effect_native_country()
	_expect("owned-cell relocation does not submit a country claim",
		int(country_dispatch.get("submitted_transactions", -1)) == 0)
	var landed := int(ext.get_family_expeditions(country_handle, 0, 64).get(
		"total", -1)) == 0
	_expect("SETTLE-only idle arrival lands without a second GDScript dispatch",
		landed
		and int(ext.get_population_cell_snapshot(2).population) == dest_before + 1
		and not bool(arrival_report.get("fatal", false)))
	if not landed:
		for day in range(arrival, arrival + 15):
			_run_day(ext, day)
			ext.ack_effect_native_economy()
			if int(ext.get_family_expeditions(country_handle, 0, 64).total) == 0:
				landed = true
				break
	var receipts: Dictionary = ext.get_family_colonization_receipts(
		country_handle, 0, 64)
	var codes := PackedStringArray()
	for receipt in receipts.get("receipts", []):
		codes.append(String(receipt.get("code", "")))
	_expect("relocation settles into the owned populated cell without claiming",
		landed
		and int(ext.get_country_cell_summary(2).country_handle) == country_handle
		and int(ext.get_population_cell_snapshot(2).population) == dest_before + 1
		and int(ext.get_population_cell_snapshot(0).population) == source_before - 1
		and int(ext.get_family_snapshot(family_handle).population) == family_before
		and codes.has("RELOCATED"))


func _run_foreign_target_rejection(catalog: Dictionary) -> void:
	var fixture := _make_two_country_fixture(catalog, 260811)
	if fixture.ext == null:
		return
	var quotes: Dictionary = fixture.ext.get_family_colonization_quotes(
		int(fixture.country_handle), 2, 0, -1, 0, 64)
	_expect("foreign owned cells stay invalid colonization targets",
		not bool(quotes.get("ok", false))
		and String(quotes.get("code", "")) == "colonization_target_invalid")


func _make_two_country_fixture(catalog: Dictionary, seed: int) -> Dictionary:
	var map := MapData.new(3, 1)
	for q in range(3):
		var cell := HexCell.new(q, 0)
		cell.terrain = TerrainType.TERRAIN.PLAIN
		cell.landform = LandformType.LF.PLAIN
		map.set_cell(cell)
	map._build_indices()
	map.init_soa_from_bake()
	map.visible_arr.fill(1)
	map.explored_arr.fill(1)
	map.vision_revision = 1
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if not bool(ext.bind_map_data(map)):
		_expect("foreign-target map binds", false)
		return {"ext": null, "country_handle": 0}
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	ext.configure_modifiers(modifier_catalog, 3)
	var effect_catalog := EffectCatalogScript.new()
	ext.configure_effects(effect_catalog.compile_native_catalog())
	var country_profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": catalog.technology_ids,
	}
	if not bool(ext.configure_country(catalog, country_profile, 3, seed).get("ok", false)):
		_expect("foreign-target country configures", false)
		return {"ext": null, "country_handle": 0}
	var technology_indices := PackedInt32Array()
	technology_indices.resize((catalog.technology_ids as PackedStringArray).size())
	for index in range(technology_indices.size()):
		technology_indices[index] = index
	var both_techs := PackedInt32Array()
	both_techs.append_array(technology_indices)
	both_techs.append_array(technology_indices)
	var tech_n := technology_indices.size()
	if not bool(ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.colonization_home",
			"country.colonization_foreign"]),
		"country_names": PackedStringArray(["开拓本国", "开拓外国"]),
		"country_cash": PackedInt64Array([0, 0]),
		"territory_offsets": PackedInt32Array([0, 1, 2]),
		"territory_cells": PackedInt32Array([0, 2]),
		"technology_offsets": PackedInt32Array([0, tech_n, tech_n * 2]),
		"technology_indices": both_techs,
		"treasury_offsets": PackedInt32Array([0, 0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, PackedByteArray([0, 0, 0])).get("ok", false)):
		_expect("two-country bootstrap succeeds", false)
		return {"ext": null, "country_handle": 0}
	var country_handle := int(ext.get_country_cell_summary(0).country_handle)
	_expect("foreign cell is owned by a different country",
		int(ext.get_country_cell_summary(2).country_handle) != 0
		and int(ext.get_country_cell_summary(2).country_handle) != country_handle)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "ACTIVE"
	profile.family_min_settlement_tier = 0
	profile.family_min_population_per_active = 1
	profile.notable_person_runtime_mode = "ACTIVE"
	profile.starvation_death_rate_q32 = 0
	var birth_rates: PackedInt64Array = catalog.signature_birth_rate_q32
	birth_rates.fill(0)
	catalog.signature_birth_rate_q32 = birth_rates
	if not bool(ext.configure_economy(catalog, profile, 3, seed).get("ok", false)):
		_expect("foreign-target economy configures", false)
		return {"ext": null, "country_handle": 0}
	var neighbors := PackedInt32Array()
	neighbors.resize(18)
	neighbors.fill(-1)
	neighbors[0] = 1
	neighbors[9] = 0
	neighbors[6] = 2
	neighbors[15] = 1
	var terrain := PackedByteArray([2, 2, 2])
	var passable := PackedByteArray()
	var costs := PackedInt32Array()
	passable.resize(256)
	costs.resize(256)
	passable[2] = 1
	costs[2] = 2
	ext.capture_economy_trade_topology(neighbors, terrain, passable, costs, 1)
	var signatures: PackedStringArray = catalog.signature_keys
	var forager := signatures.find("forager|default")
	var merchant := signatures.find("merchant|default")
	var building := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var stock := PackedInt64Array()
	stock.resize(3 * (catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000)
	ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([forager, merchant]),
		"population": PackedInt64Array([10, 2]),
		"funds": PackedInt64Array([1000000, 1000000]),
		"forced_named_cells": PackedInt32Array([0]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([building]),
		"building_owner_signature_ids": PackedInt32Array([forager]),
		"building_counts": PackedInt64Array([1]),
		"founder_family_cells": PackedInt32Array([0]),
		"founder_family_building_type_ids": PackedInt32Array([building]),
		"founder_family_owner_signature_ids": PackedInt32Array([forager]),
	})
	return {"ext": ext, "map": map, "country_handle": country_handle}


func _make_fixture(catalog: Dictionary, seed: int, stock_fill: int = 1000000) -> Dictionary:
	var map := MapData.new(3, 1)
	for q in range(3):
		var cell := HexCell.new(q, 0)
		cell.terrain = TerrainType.TERRAIN.PLAIN
		cell.landform = LandformType.LF.PLAIN
		map.set_cell(cell)
	map._build_indices()
	map.init_soa_from_bake()
	map.visible_arr.fill(1)
	map.explored_arr.fill(1)
	map.vision_revision = 1
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("map binds to native world", bool(ext.bind_map_data(map)))
	var modifier_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifier_catalog.erase("ok")
	_expect("modifier runtime configures", bool(ext.configure_modifiers(
		modifier_catalog, 3).get("ok", false)))
	var effect_catalog := EffectCatalogScript.new()
	_expect("effect runtime configures for built-in colonization transactions",
		bool(ext.configure_effects(effect_catalog.compile_native_catalog()).get(
			"ok", false)))
	var country_profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": catalog.technology_ids,
	}
	_expect("country runtime configures", bool(ext.configure_country(
		catalog, country_profile, 3, seed).get("ok", false)))
	var technology_indices := PackedInt32Array()
	technology_indices.resize((catalog.technology_ids as PackedStringArray).size())
	for index in range(technology_indices.size()):
		technology_indices[index] = index
	_expect("one-cell country bootstraps", bool(ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.colonization_test"]),
		"country_names": PackedStringArray(["开拓测试国"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, technology_indices.size()]),
		"technology_indices": technology_indices,
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, PackedByteArray([0, 0, 0])).get("ok", false)))
	var country_handle := int(ext.get_country_cell_summary(0).country_handle)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "ACTIVE"
	profile.family_min_settlement_tier = 0
	profile.family_min_population_per_active = 1
	profile.notable_person_runtime_mode = "ACTIVE"
	profile.starvation_death_rate_q32 = 0
	var birth_rates: PackedInt64Array = catalog.signature_birth_rate_q32
	birth_rates.fill(0)
	catalog.signature_birth_rate_q32 = birth_rates
	_expect("economy runtime configures", bool(ext.configure_economy(
		catalog, profile, 3, seed).get("ok", false)))
	var neighbors := PackedInt32Array()
	neighbors.resize(18)
	neighbors.fill(-1)
	neighbors[0] = 1
	neighbors[9] = 0
	neighbors[6] = 2
	neighbors[15] = 1
	var terrain := PackedByteArray([2, 2, 2])
	var passable := PackedByteArray()
	var costs := PackedInt32Array()
	passable.resize(256)
	costs.resize(256)
	passable[2] = 1
	costs[2] = 2
	_expect("packed six-neighbor topology configures", bool(
		ext.capture_economy_trade_topology(neighbors, terrain, passable,
			costs, 1).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var forager := signatures.find("forager|default")
	var merchant := signatures.find("merchant|default")
	var building := (catalog.building_type_ids as PackedStringArray).find(
		"gathering_ground")
	var stock := PackedInt64Array()
	stock.resize(3 * (catalog.good_ids as PackedStringArray).size())
	stock.fill(stock_fill)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([forager, merchant]),
		"population": PackedInt64Array([10, 2]),
		"funds": PackedInt64Array([1000000, 1000000]),
		"forced_named_cells": PackedInt32Array([0]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([building]),
		"building_owner_signature_ids": PackedInt32Array([forager]),
		"building_counts": PackedInt64Array([1]),
		"founder_family_cells": PackedInt32Array([0]),
		"founder_family_building_type_ids": PackedInt32Array([building]),
		"founder_family_owner_signature_ids": PackedInt32Array([forager]),
	})
	_expect("economy and founder family bootstrap", bool(boot.get("ok", false)))
	return {"ext": ext, "map": map, "country_handle": country_handle,
		"neighbors": neighbors, "terrain": terrain,
		"passable": passable, "costs": costs}


func _grow_founder_family(ext: Object, family_handle: int, cell_idx: int,
		extra_people: int, day: int) -> void:
	var branches: Dictionary = ext.get_family_branches(family_handle, 0, 64)
	var handles: PackedInt64Array = branches.get("branch_handles", PackedInt64Array())
	var cells: PackedInt32Array = branches.get("cell_indices", PackedInt32Array())
	var branch_handle := 0
	for i in range(mini(handles.size(), cells.size())):
		if int(cells[i]) == cell_idx and int(handles[i]) != 0:
			branch_handle = int(handles[i])
			break
	if branch_handle == 0:
		_run_day(ext, maxi(0, int(ext.get_economy_report().get("current_day", 0))))
		branches = ext.get_family_branches(family_handle, 0, 64)
		handles = branches.get("branch_handles", PackedInt64Array())
		cells = branches.get("cell_indices", PackedInt32Array())
		for i in range(mini(handles.size(), cells.size())):
			if int(cells[i]) == cell_idx and int(handles[i]) != 0:
				branch_handle = int(handles[i])
				break
	_expect("source branch influence exists for family growth",
		branch_handle != 0)
	if branch_handle == 0:
		return
	var family_before := int(ext.get_family_snapshot(family_handle).population)
	var submitted: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([15]),
		"effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([50]),
		"target_handles": PackedInt64Array([branch_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([-1]),
		"i64_0": PackedInt64Array([extra_people]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("family population reward queues extra source-branch members",
		bool(submitted.get("ok", false)))
	var grown := _run_day(ext, day)
	_expect("extra family members land without breaking conservation",
		bool(grown.get("done", false)) and not bool(grown.get("fatal", false))
		and int(ext.get_family_snapshot(family_handle).population) ==
			family_before + extra_people)


func _has_expedition(ext: Object, country_handle: int, expedition_handle: int) -> bool:
	if expedition_handle == 0:
		return false
	var page: Dictionary = ext.get_family_expeditions(country_handle, 0, 64)
	var handles: PackedInt64Array = page.get("expedition_handles", PackedInt64Array())
	return handles.has(expedition_handle)


func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(512):
		report = ext.run_economy_slice({
			"day_index": day,
			"tick_index": day * 1000 + slice,
		})
		if bool(report.get("done", false)):
			return report
	return report


func _save_economy(ext: Object) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_save(65536)
	if not bool(begin.get("ok", false)):
		return begin
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	var ended: Dictionary = ext.end_economy_save()
	return {"ok": bool(ended.get("ok", false)),
		"schema": int(begin.get("schema_version", 0)), "chunks": chunks}


func _restore_economy(ext: Object, chunks: Array) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_restore()
	if not bool(begin.get("ok", false)):
		return begin
	for chunk in chunks:
		var fed: Dictionary = ext.feed_economy_restore_chunk(chunk)
		if not bool(fed.get("ok", false)):
			return fed
	return ext.end_economy_restore()
