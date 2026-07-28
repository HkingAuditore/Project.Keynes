extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

var failures := 0

func _init() -> void:
	_run()
	print("=== economy trade runtime %s ===" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1

func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	_exercise_accuracy_frontier(compiled, catalog)
	var ext := _new_ext(compiled, 2)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 2
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "ACTIVE"
	profile.trade_signal_pairs_per_slice = 1048576
	profile.trade_route_searches_per_slice = 64
	profile.trade_max_route_expansions = 1024
	profile.trade_capacity_per_merchant_q16 = 67108864
	profile.trade_min_margin_q16 = 0
	_expect("country configures", CountryTestHelper.configure_all_technologies(
		ext, catalog, 2, 4410))
	_expect("economy configures", bool(ext.configure_economy(
		catalog, profile, 2, 4410).get("ok", false)))
	_expect("independent trade topology captures", _capture_line_topology(ext, 2))

	var goods: PackedStringArray = compiled.good_ids
	var gathered := goods.find("gathered_plants")
	var cloth := goods.find("cloth")
	var stock := PackedInt64Array()
	var prices: PackedInt32Array = compiled.good_default_price.duplicate()
	stock.resize(goods.size() * 2)
	stock.fill(0)
	prices.resize(goods.size() * 2)
	for good in range(goods.size()):
		prices[good] = int((compiled.good_default_price as PackedInt32Array)[good])
		prices[goods.size() + good] = int((compiled.good_default_price as PackedInt32Array)[good])
	for good in [gathered, cloth]:
		stock[good] = 100000000
		prices[good] = int((compiled.good_min_price as PackedInt32Array)[good])
	_expect("two markets bootstrap", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 1]),
		"signature_ids": PackedInt32Array([
			(compiled.signature_keys as PackedStringArray).find("merchant|default"),
			(compiled.signature_keys as PackedStringArray).find("merchant|default")]),
		"population": PackedInt64Array([100, 100]),
		"funds": PackedInt64Array([1000000000, 1000000000]),
	}, {"stock": stock, "price": prices}).get("ok", false)))

	var initial_hash: int = int(ext.get_economy_state_hash())
	var report := _advance_day(ext, 0)
	report = _advance_day(ext, 1)
	_expect("opening local cycle commits exactly", bool(report.get("done", false)) and
		not bool(report.get("fatal", false)) and int(report.get("goods_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0)
	_expect("rolling markets remain within the four-day visibility bound",
		not bool(report.get("fatal", false)) and
		int(report.get("max_state_age_days", 99)) <= 4)
	var planner_report: Dictionary = ext.run_economy_slice({"day_index": 2, "tick_index": 2000})
	var continuation_report: Dictionary = ext.run_economy_slice(
		{"day_index": 2, "tick_index": 2001})
	_expect("trade planner timing is reported on its native slice",
		float(planner_report.get("trade_plan_ms", 0.0)) > 0.0)
	var planner_breakdown: Dictionary = planner_report.get("trade_plan_breakdown_ms", {})
	var planner_breakdown_total := 0.0
	for value in planner_breakdown.values():
		planner_breakdown_total += float(value)
	_expect("trade planner timing exposes an accounted substage breakdown",
		planner_breakdown.has("trade_planning.scan_body") and
		planner_breakdown.has("trade_planning.scan_finalize") and
		planner_breakdown.has("trade_planning.route_prepare") and
		planner_breakdown.has("trade_planning.route_expand") and
		planner_breakdown.has("trade_planning.route_finalize") and
		planner_breakdown.has("trade_planning.other") and
		planner_breakdown_total > 0.0 and
		absf(planner_breakdown_total - float(
			planner_report.get("trade_plan_ms", 0.0))) <= 0.05)
	_expect("trade planner timing does not leak into the next continuation slice",
		not bool(planner_report.get("done", true)) and
		is_zero_approx(float(continuation_report.get("trade_plan_ms", -1.0))) and
		String(continuation_report.get("trade_plan_substage", "x")).is_empty())
	var orders: Dictionary = ext.get_trade_orders_for_cell(0, 0, 64)
	for day in range(2, 16):
		if int(orders.get("total", 0)) > 0:
			break
		report = _advance_day(ext, day)
		orders = ext.get_trade_orders_for_cell(0, 0, 64)
	_expect("profitable domestic route dispatches", bool(orders.get("ok", false)) and
		int(orders.get("total", 0)) > 0)
	if int(orders.get("total", 0)) <= 0:
		return
	var departure_day := int((orders.departure_days as PackedInt64Array)[0])
	var arrival_day := int((orders.arrival_days as PackedInt64Array)[0])
	_expect("route ETA uses daily transport time",
		(orders.arrival_days as PackedInt64Array).size() > 0 and
		arrival_day == departure_day + 1)
	_expect("dispatch escrows goods and cash",
		int(report.get("trade_transit_goods", 0)) > 0 and
		int(report.get("trade_escrow_cash", 0)) > 0)
	_expect("country capacity reservation is bounded",
		int(report.get("trade_capacity_used", -1)) > 0 and
		int(report.get("trade_capacity_used", 0)) <=
			int(report.get("trade_capacity_available", -1)))
	_expect("route order exposes CSR goods lines",
		(orders.line_offsets as PackedInt32Array).size() ==
			(orders.order_ids as PackedInt64Array).size() + 1 and
		(orders.line_good_ids as PackedInt32Array).size() >= 2)
	var destination_after_dispatch: Dictionary = ext.get_market_cell_snapshot(1)
	var trade_purchase_cash := int(
		destination_after_dispatch.get("merchant_trade_purchase_cash", 0))
	var destination_merchant_cash := int(
		destination_after_dispatch.get("merchant_cash", 0))
	_expect("domestic trade preserves the destination merchant operating floor",
		trade_purchase_cash > 0 and
		destination_merchant_cash * 7 >= trade_purchase_cash)
	_expect("trade purchase cash is included in operating outflow",
		int(destination_after_dispatch.get("merchant_operating_outflow", -1)) >=
			int(destination_after_dispatch.get("merchant_trade_purchase_cash", 0)) and
		int(report.get("merchant_trade_purchase_cash", 0)) > 0)
	var destination_good_index := (destination_after_dispatch.good_ids as PackedStringArray).find(
		"gathered_plants")
	var dispatch_delay := int((destination_after_dispatch.trade_first_dispatch_delay_days as
		PackedInt32Array)[destination_good_index])
	var last_attempt := int((destination_after_dispatch.trade_last_attempt_day as
		PackedInt64Array)[destination_good_index])
	var last_rejection := int((destination_after_dispatch.trade_last_rejection_reason as
		PackedInt32Array)[destination_good_index])
	var deadline_exceeded := int((destination_after_dispatch.trade_deadline_exceeded as
		PackedByteArray)[destination_good_index])
	_expect("new shortage receives its first dispatch within the response target",
		dispatch_delay == -1 and
		int(report.get("trade_first_dispatch_delay_max_days", -1)) >= 0 and
		int(report.get("trade_first_dispatch_delay_max_days", 16)) <= 15 and
		int(report.get("trade_response_deadline_misses", -1)) == 0 and
		int(report.get("trade_response_deadline_misses_cumulative", -1)) == 0)
	_expect("trade signal records its last dispatch attempt and deadline state",
		last_attempt >= 0 and last_rejection == 8 and deadline_exceeded == 0)

	_expect("in-transit committed boundary conserves", bool(report.get("done", false)) and
		int(report.get("goods_error", 1)) == 0 and int(report.get("money_error", 1)) == 0)
	var source_after_dispatch: Dictionary = ext.get_market_cell_snapshot(0)
	var source_good_index := (source_after_dispatch.good_ids as PackedStringArray).find(
		"gathered_plants")
	var local_target := int((source_after_dispatch.demand_ema as PackedInt64Array)[
		source_good_index]) + int((source_after_dispatch.business_demand_ema as
		PackedInt64Array)[source_good_index])
	var inventory_ratio := int((compiled.good_inventory_target_ratios_q16 as
		PackedInt32Array)[gathered])
	local_target = local_target * int(profile.merchant_market_making_days_q16) / 65536
	local_target = local_target * inventory_ratio / 65536
	local_target = maxi(local_target, int((source_after_dispatch.production_input_reserve as
		PackedInt64Array)[source_good_index]))
	_expect("dispatch preserves the source market local-demand reserve",
		int((source_after_dispatch.stock as PackedInt64Array)[source_good_index]) >= local_target)
	var saved := _save_economy(ext)
	_expect("PKEC v21 saves in-transit escrow", bool(saved.get("ok", false)) and
		int(saved.get("schema", 0)) == 21)
	var restored := _new_ext(compiled, 2)
	CountryTestHelper.configure_all_technologies(restored, catalog, 2, 4410)
	restored.configure_economy(catalog, profile, 2, 4410)
	var restore_result := _restore_economy(restored, saved.get("chunks", []))
	_expect("mid-transit restore preserves order and hash",
		bool(restore_result.get("ok", false)) and
		int(restored.get_trade_orders_for_cell(0, 0, 64).get("total", 0)) > 0 and
		int(restored.get_economy_state_hash()) == int(ext.get_economy_state_hash()))

	for day in range(departure_day + 1, arrival_day + 1):
		report = _advance_day(ext, day)
	var destination: Dictionary = ext.get_market_cell_snapshot(1)
	_expect("arrival settles on its daily ETA", int(ext.get_trade_orders_for_cell(
		0, 0, 64).get("total", -1)) == 0 and
		_sum_column(destination, "stock") > 0)
	_expect("arrival remains exactly conserved", int(report.get("goods_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0)
	var restored_report: Dictionary = {}
	for day in range(departure_day + 1, arrival_day + 1):
		restored_report = _advance_day(restored, day)
	_expect("restored due-day order settles once",
		int(restored.get_trade_orders_for_cell(0, 0, 64).get("total", -1)) == 0 and
		int(restored_report.get("goods_error", 1)) == 0 and
		int(restored_report.get("money_error", 1)) == 0)
	_expect("trade changes authoritative hash only in ACTIVE", ext.get_economy_state_hash() != initial_hash)

	_test_probe_is_read_only(compiled, catalog)
	_test_country_boundary(compiled, catalog)
	_test_topology_contract(compiled, catalog)
	_test_cold_start_inventory_horizon(compiled, catalog)
	_test_survival_shortage_relief_routes(compiled, catalog)
	_test_unprofitable_rejected(compiled, catalog)
	_test_invalid_seller_rebind(compiled, catalog)
	_test_worker_scalar_equivalence(compiled, catalog)
	_test_route_expansion_continuation(compiled, catalog)
	_test_publish_slice_contract(compiled, catalog)
	_test_v10_migration(compiled, catalog)

func _test_probe_is_read_only(compiled: Dictionary, catalog: Dictionary) -> void:
	var ext := _new_ext(compiled, 2)
	var off := _new_ext(compiled, 2)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 2
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "PROBE"
	profile.trade_signal_pairs_per_slice = 1048576
	profile.trade_route_searches_per_slice = 64
	CountryTestHelper.configure_all_technologies(ext, catalog, 2, 4411)
	CountryTestHelper.configure_all_technologies(off, catalog, 2, 4411)
	ext.configure_economy(catalog, profile, 2, 4411)
	var off_profile := profile.duplicate(true)
	off_profile.trade_runtime_mode = "OFF"
	off.configure_economy(catalog, off_profile, 2, 4411)
	_capture_line_topology(ext, 2)
	_capture_line_topology(off, 2)
	var merchant := (compiled.signature_keys as PackedStringArray).find("merchant|default")
	var packet := {
		"cell_indices": PackedInt32Array([0, 1]),
		"signature_ids": PackedInt32Array([merchant, merchant]),
		"population": PackedInt64Array([10, 10]),
		"funds": PackedInt64Array([1000000, 1000000]),
	}
	ext.bootstrap_economy(packet, {})
	off.bootstrap_economy(packet, {})
	for day in range(6):
		_advance_day(ext, day)
		_advance_day(off, day)
	_expect("PROBE emits no authoritative orders",
		int(ext.get_trade_orders_for_cell(0, 0, 64).get("total", -1)) == 0 and
		int(ext.get_economy_report().get("trade_escrow_cash", -1)) == 0)
	_expect("PROBE and OFF committed state hashes match",
		int(ext.get_economy_state_hash()) == int(off.get_economy_state_hash()))

func _test_country_boundary(compiled: Dictionary, catalog: Dictionary) -> void:
	var ext := _new_ext(compiled, 3)
	var technologies: PackedStringArray = compiled.technology_ids
	var technology_indices := PackedInt32Array()
	for repeat in range(2):
		for technology in range(technologies.size()):
			technology_indices.append(technology)
	ext.configure_country(catalog, {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(),
	}, 3, 4412)
	ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.alpha", "country.beta"]),
		"country_names": PackedStringArray(["Alpha", "Beta"]),
		"country_cash": PackedInt64Array([0, 0]),
		"territory_offsets": PackedInt32Array([0, 2, 3]),
		"territory_cells": PackedInt32Array([0, 1, 2]),
		"technology_offsets": PackedInt32Array([0, technologies.size(), technologies.size() * 2]),
		"technology_indices": technology_indices,
		"treasury_offsets": PackedInt32Array([0, 0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}, PackedByteArray([0, 0, 0]))
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 2
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "ACTIVE"
	profile.trade_signal_pairs_per_slice = 1048576
	profile.trade_route_searches_per_slice = 64
	profile.trade_min_margin_q16 = 0
	ext.configure_economy(catalog, profile, 3, 4412)
	_capture_line_topology(ext, 3)
	var goods: PackedStringArray = compiled.good_ids
	var good := goods.find("gathered_plants")
	var stock := PackedInt64Array()
	stock.resize(goods.size() * 3)
	stock[good] = 100000000
	var price := PackedInt32Array()
	price.resize(goods.size() * 3)
	for cell in range(3):
		for g in range(goods.size()):
			price[cell * goods.size() + g] = int(
				(compiled.good_default_price as PackedInt32Array)[g])
	price[good] = int((compiled.good_min_price as PackedInt32Array)[good])
	var merchant := (compiled.signature_keys as PackedStringArray).find("merchant|default")
	ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 2]),
		"signature_ids": PackedInt32Array([merchant, merchant]),
		"population": PackedInt64Array([100, 100]),
		"funds": PackedInt64Array([100000000, 100000000]),
	}, {"stock": stock, "price": price})
	for day in range(6):
		_advance_day(ext, day)
	_expect("routes cannot cross frozen country boundary",
		int(ext.get_trade_orders_for_cell(0, 0, 64).get("total", -1)) == 0)

func _test_topology_contract(compiled: Dictionary, catalog: Dictionary) -> void:
	var ext := _new_ext(compiled, 2)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.trade_runtime_mode = "PROBE"
	CountryTestHelper.configure_all_technologies(ext, catalog, 2, 4413)
	ext.configure_economy(catalog, profile, 2, 4413)
	var neighbors := PackedInt32Array([-1, -1, -1, 1, -1, -1,
		0, -1, -1, -1, -1, -1])
	var water_terrain := PackedByteArray([9, 9])
	var passable := PackedByteArray()
	var costs := PackedInt32Array()
	passable.resize(256)
	costs.resize(256)
	passable[9] = 1
	costs[9] = 3
	_expect("explicitly enabled water terrain is trade passable",
		bool(ext.capture_economy_trade_topology(
			neighbors, water_terrain, passable, costs, 7).get("ok", false)))
	var first_generation := int(ext.get_economy_report().get(
		"trade_topology_generation", 0))
	var first_hash := int(ext.get_economy_report().get("trade_topology_hash", 0))
	var first_reset_count := int(ext.get_economy_report().get(
		"trade_plan_reset_count", -1))
	_expect("identical topology refresh ignores unrelated caller generation",
		bool(ext.capture_economy_trade_topology(
			neighbors, water_terrain, passable, costs, 8).get("ok", false)) and
		int(ext.get_economy_report().get(
			"trade_topology_generation", -1)) == first_generation)
	passable[10] = 1
	costs[10] = 3
	var equivalent_terrain := PackedByteArray([10, 10])
	var equivalent: Dictionary = ext.capture_economy_trade_topology(
		neighbors, equivalent_terrain, passable, costs, 9)
	var equivalent_report: Dictionary = ext.get_economy_report()
	_expect("terrain remap with identical trade semantics preserves the plan",
		bool(equivalent.get("ok", false)) and
		int(equivalent_report.get("trade_topology_generation", -1)) == first_generation and
		int(equivalent_report.get("trade_topology_hash", -1)) == first_hash and
		int(equivalent_report.get("trade_plan_reset_count", -1)) == first_reset_count)
	_expect("trade liveness diagnostics expose both planning cursors",
		equivalent_report.has("trade_scan_cursor") and
		equivalent_report.has("trade_route_cursor") and
		equivalent_report.has("trade_route_total") and
		equivalent_report.has("trade_last_plan_reset_reason"))
	costs[10] = 4
	var changed: Dictionary = ext.capture_economy_trade_topology(
		neighbors, equivalent_terrain, passable, costs, 10)
	var changed_report: Dictionary = ext.get_economy_report()
	_expect("real normalized trade-cost change resets the plan once",
		bool(changed.get("ok", false)) and
		int(changed_report.get("trade_topology_generation", -1)) > first_generation and
		int(changed_report.get("trade_plan_reset_count", -1)) == first_reset_count + 1 and
		String(changed_report.get("trade_last_plan_reset_reason", "")) ==
			"normalized_topology_changed")
	costs[9] = 0
	var invalid: Dictionary = ext.capture_economy_trade_topology(
		neighbors, water_terrain, passable, costs, 8)
	_expect("zero-cost passable trade terrain is rejected",
		not bool(invalid.get("ok", true)))


func _test_route_expansion_continuation(compiled: Dictionary,
		catalog: Dictionary) -> void:
	const CELLS := 300
	var ext := _new_ext(compiled, CELLS)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 2
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "ACTIVE"
	profile.trade_signal_pairs_per_slice = 1048576
	profile.trade_route_searches_per_slice = 64
	profile.trade_max_route_expansions = 1024
	profile.trade_capacity_per_merchant_q16 = 67108864
	profile.trade_min_margin_q16 = 0
	_expect("long-route country configures",
		CountryTestHelper.configure_all_technologies(ext, catalog, CELLS, 4421))
	_expect("long-route economy configures", bool(ext.configure_economy(
		catalog, profile, CELLS, 4421).get("ok", false)))
	_expect("long-route topology captures", _capture_line_topology(ext, CELLS))
	var goods: PackedStringArray = compiled.good_ids
	var gathered := goods.find("gathered_plants")
	var cloth := goods.find("cloth")
	var stock := PackedInt64Array()
	stock.resize(goods.size() * CELLS)
	stock.fill(0)
	stock[gathered] = 100000000
	stock[cloth] = 100000000
	var prices := PackedInt32Array()
	prices.resize(goods.size() * CELLS)
	for cell in range(CELLS):
		for good in range(goods.size()):
			prices[cell * goods.size() + good] = int(
				(compiled.good_default_price as PackedInt32Array)[good])
	for good in range(goods.size()):
		prices[good] = int((compiled.good_min_price as PackedInt32Array)[good])
		prices[(CELLS - 1) * goods.size() + good] = int(
			(compiled.good_max_price as PackedInt32Array)[good])
	var merchant := (compiled.signature_keys as PackedStringArray).find(
		"merchant|default")
	_expect("long-route markets bootstrap", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, CELLS - 1]),
		"signature_ids": PackedInt32Array([merchant, merchant]),
		"population": PackedInt64Array([100, 100]),
		"funds": PackedInt64Array([1000000000, 1000000000]),
	}, {"stock": stock, "price": prices}).get("ok", false)))

	_advance_day(ext, 0)
	_advance_day(ext, 1)
	# Reset any warm route cache while preserving the committed shortage. The
	# next plan must therefore exercise the resumable Dijkstra path.
	_expect("long-route topology change resets planner",
		_capture_line_topology(ext, CELLS, 2))
	var report: Dictionary = {}
	var first_slice: Dictionary = {}
	var route_seen := false
	for day in range(2, 10):
		report = _advance_day(ext, day)
		for step in range(64):
			if String(report.get("trade_plan_phase", "")) == "ROUTE":
				route_seen = true
			if bool(report.get("trade_route_search_active", false)):
				first_slice = report
				break
			report = ext.run_economy_slice({
				"day_index": day, "tick_index": 8000 + day * 10 + step})
		if not first_slice.is_empty():
			break
	_expect("long route reaches incremental route phase", route_seen)
	_expect("route search yields at the deterministic expansion budget " +
		"(active=%s cursor=%d expansion=%d budget=%d)" % [
			bool(first_slice.get("trade_route_search_active", false)),
			int(first_slice.get("trade_route_cursor", -1)),
			int(first_slice.get("trade_route_expansion_cursor", -1)),
			int(first_slice.get("trade_route_expansions_per_slice", -2))],
		not first_slice.is_empty() and
		int(first_slice.get("trade_route_expansion_cursor", -1)) ==
			int(first_slice.get("trade_route_expansions_per_slice", -2)))
	var first_breakdown: Dictionary = first_slice.get("trade_plan_breakdown_ms", {})
	var first_work: Dictionary = first_slice.get("trade_plan_breakdown_work", {})
	_expect("resumable route slice attributes time and deterministic work to expansion",
		float(first_breakdown.get("trade_planning.route_expand", 0.0)) > 0.0 and
		int(first_work.get("trade_planning.route_expansions", -1)) ==
			int(first_slice.get("trade_route_expansions_per_slice", -2)))
	if first_slice.is_empty():
		return
	var source_cursor := int(first_slice.get("trade_route_cursor", -1))
	var second_slice: Dictionary = ext.run_economy_slice({
		"day_index": int(report.get("current_day", 0)), "tick_index": 9002})
	var second_delta := int(second_slice.get("trade_route_expansions", 0)) - \
		int(first_slice.get("trade_route_expansions", 0))
	_expect("resumed route search stays within the same expansion budget",
		second_delta >= 0 and second_delta <=
			int(second_slice.get("trade_route_expansions_per_slice", -1)) and
		int(second_slice.get("trade_route_cursor", source_cursor)) > source_cursor and
			not bool(second_slice.get("trade_route_search_active", true)))


func _test_publish_slice_contract(compiled: Dictionary,
		catalog: Dictionary) -> void:
	const CELLS := 300
	var ext := _new_ext(compiled, CELLS)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 2
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "ACTIVE"
	_expect("publish-slice country configures",
		CountryTestHelper.configure_all_technologies(ext, catalog, CELLS, 4422))
	_expect("publish-slice economy configures", bool(ext.configure_economy(
		catalog, profile, CELLS, 4422).get("ok", false)))
	_expect("publish-slice topology captures", _capture_line_topology(ext, CELLS))
	var goods: PackedStringArray = compiled.good_ids
	var stock := PackedInt64Array()
	var prices := PackedInt32Array()
	stock.resize(goods.size() * CELLS)
	stock.fill(0)
	prices.resize(goods.size() * CELLS)
	for cell in range(CELLS):
		for good in range(goods.size()):
			prices[cell * goods.size() + good] = int(
				(compiled.good_default_price as PackedInt32Array)[good])
	var merchant := (compiled.signature_keys as PackedStringArray).find(
		"merchant|default")
	_expect("publish-slice markets bootstrap", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, CELLS - 1]),
		"signature_ids": PackedInt32Array([merchant, merchant]),
		"population": PackedInt64Array([100, 100]),
		"funds": PackedInt64Array([1000000000, 1000000000]),
	}, {"stock": stock, "price": prices}).get("ok", false)))

	var report: Dictionary = ext.run_economy_slice({"day_index": 0})
	var saw_commit_boundary := false
	var saw_publish_after_commit := false
	var previous_next := ""
	var publish_substages: Dictionary = {}
	var save_blocked := false
	var bounded_publish_work := true
	var publish_slice_breakdown_total := 0.0
	for continuation in range(256):
		var executed := String(report.get("executed_stage", ""))
		var next_stage := String(report.get("next_stage", ""))
		if executed == "building_commit" and next_stage == "aggregate_publish":
			saw_commit_boundary = true
		if executed == "aggregate_publish":
			saw_publish_after_commit = true
		if previous_next == "aggregate_publish" and not bool(report.get("done", false)):
			bounded_publish_work = bounded_publish_work and \
				executed == "aggregate_publish"
		if executed == "aggregate_publish":
			var substage := String(report.get("executed_substage", ""))
			publish_substages[substage] = int(publish_substages.get(substage, 0)) + 1
			var slice_breakdown_ms: Dictionary = report.get(
				"publish_breakdown_ms", {})
			var slice_breakdown_work: Dictionary = report.get(
				"publish_breakdown_work", {})
			for key in slice_breakdown_ms:
				var value: float = float(slice_breakdown_ms[key])
				if value > 0.0:
					publish_substages[String(key).trim_prefix(
						"aggregate_publish.")] = 1
			for value in slice_breakdown_ms.values():
				publish_slice_breakdown_total += float(value)
			for key in slice_breakdown_work:
				var phase_work := int(slice_breakdown_work[key])
				var phase := String(key).trim_prefix("aggregate_publish.")
				if phase.begins_with("audit_"):
					bounded_publish_work = bounded_publish_work and \
						phase_work <= 131072
				elif phase in ["watermark", "trade_init.component_clear",
						"trade_init.component_build",
						"trade_init.workspace_clear"]:
					bounded_publish_work = bounded_publish_work and \
						phase_work <= 4096
			if not save_blocked:
				var save_attempt: Dictionary = ext.begin_economy_save(65536)
				save_blocked = not bool(save_attempt.get("ok", true)) and \
					String(save_attempt.get("reason", "")) == \
					"save_requires_committed_boundary"
		previous_next = next_stage
		if bool(report.get("done", false)):
			break
		report = ext.run_economy_slice({
			"day_index": 0, "tick_index": continuation + 1})
	_expect("building commit reaches aggregate publish with optional budgeted fusion",
		saw_commit_boundary or saw_publish_after_commit)
	_expect("publish slices report executed stage and deterministic bounded work",
		bounded_publish_work and publish_substages.has("audit_market") and
		publish_substages.has("watermark") and
		publish_substages.has("trade_init.component_build") and
		publish_substages.has("trade_init.workspace_clear"))
	_expect("partial publish remains outside the save boundary", save_blocked)
	var publish_breakdown: Dictionary = report.get(
		"publish_cumulative_breakdown_ms", {})
	var publish_breakdown_total := 0.0
	for value in publish_breakdown.values():
		publish_breakdown_total += float(value)
	_expect("publish completes with exact conservation and accounted timing",
		bool(report.get("done", false)) and not bool(report.get("fatal", false)) and
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0 and
		absf(publish_breakdown_total - float(report.get("publish_ms", 0.0))) <= 0.05 and
		absf(publish_slice_breakdown_total - float(
			report.get("publish_ms", 0.0))) <= 0.05)

func _test_cold_start_inventory_horizon(compiled: Dictionary,
		catalog: Dictionary) -> void:
	var ext := _new_ext(compiled, 1)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 2
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "OFF"
	CountryTestHelper.configure_all_technologies(ext, catalog, 1, 4417)
	ext.configure_economy(catalog, profile, 1, 4417)
	var merchant := (compiled.signature_keys as PackedStringArray).find("merchant|default")
	var goods: PackedStringArray = compiled.good_ids
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(0)
	var prices: PackedInt32Array = compiled.good_default_price.duplicate()
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([merchant]),
		"population": PackedInt64Array([100]),
		"funds": PackedInt64Array([1000000000]),
	}, {"stock": stock, "price": prices})
	_expect("cold-start inventory fixture bootstraps", bool(boot.get("ok", false)))
	_advance_day(ext, 0)
	_advance_day(ext, 1)
	var market: Dictionary = ext.get_market_cell_snapshot(0)
	var demand: PackedInt64Array = market.demand_ema
	var business: PackedInt64Array = market.business_demand_ema
	var realized: PackedInt64Array = market.realized_withdrawal_ema
	var offered: PackedInt64Array = market.offered_supply_ema
	var reserves: PackedInt64Array = market.production_input_reserve
	var targets: PackedInt64Array = market.merchant_inventory_target
	var ratios: PackedInt32Array = compiled.good_inventory_target_ratios_q16
	var storage_modes: PackedInt32Array = compiled.good_storage_modes
	var candidate := -1
	for good in range(goods.size()):
		if storage_modes[good] == 0 and demand[good] + business[good] > 0 and \
				realized[good] == 0 and offered[good] == 0 and reserves[good] == 0:
			candidate = good
			break
	var exact := false
	var exceeds_epoch_recovery := false
	if candidate >= 0:
		var feasible_daily := int(demand[candidate] + business[candidate])
		var target_days_q16 := int(profile.merchant_market_making_days_q16) * \
			int(ratios[candidate]) / 65536
		var expected := feasible_daily * target_days_q16 / 65536
		exact = int(targets[candidate]) == expected
		exceeds_epoch_recovery = expected > feasible_daily * int(profile.market_cycle_days)
	_expect("zero-supply demand still receives its configured inventory horizon",
		candidate >= 0 and exact and exceeds_epoch_recovery)

func _test_survival_shortage_relief_routes(compiled: Dictionary, catalog: Dictionary) -> void:
	var ext := _new_ext(compiled, 2)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 2
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "ACTIVE"
	profile.trade_signal_pairs_per_slice = 1048576
	profile.trade_route_searches_per_slice = 64
	profile.trade_capacity_per_merchant_q16 = 67108864
	profile.trade_min_margin_q16 = 3277
	CountryTestHelper.configure_all_technologies(ext, catalog, 2, 4418)
	ext.configure_economy(catalog, profile, 2, 4418)
	_capture_line_topology(ext, 2)
	var goods: PackedStringArray = compiled.good_ids
	var good := goods.find("gathered_plants")
	var stock := PackedInt64Array()
	stock.resize(goods.size() * 2)
	stock[good] = 100000000
	var price := PackedInt32Array()
	price.resize(goods.size() * 2)
	for cell in range(2):
		for g in range(goods.size()):
			price[cell * goods.size() + g] = int(
				(compiled.good_default_price as PackedInt32Array)[g])
	price[good] = int((compiled.good_min_price as PackedInt32Array)[good])
	price[goods.size() + good] = int((compiled.good_min_price as PackedInt32Array)[good])
	var merchant := (compiled.signature_keys as PackedStringArray).find("merchant|default")
	ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 1]),
		"signature_ids": PackedInt32Array([merchant, merchant]),
		"population": PackedInt64Array([100, 100]),
		"funds": PackedInt64Array([1000000000, 1000000000]),
	}, {"stock": stock, "price": price})
	var report: Dictionary = {}
	var orders: Dictionary = {}
	for day in range(16):
		report = _advance_day(ext, day)
		orders = ext.get_trade_orders_for_cell(0, 0, 64)
		if int(orders.get("total", 0)) > 0:
			break
	_expect("survival shortage relief can route at zero spread",
		int(orders.get("total", 0)) > 0 and
		int(report.get("trade_candidates_accepted", 0)) > 0)
	_expect("survival shortage relief remains conserved",
		int(report.get("goods_error", 1)) == 0 and int(report.get("money_error", 1)) == 0)

func _test_unprofitable_rejected(compiled: Dictionary, catalog: Dictionary) -> void:
	var ext := _new_ext(compiled, 2)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 2
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "ACTIVE"
	profile.trade_signal_pairs_per_slice = 1048576
	profile.trade_route_searches_per_slice = 64
	profile.trade_min_margin_q16 = 0
	CountryTestHelper.configure_all_technologies(ext, catalog, 2, 4414)
	ext.configure_economy(catalog, profile, 2, 4414)
	_capture_line_topology(ext, 2)
	var goods: PackedStringArray = compiled.good_ids
	var good := goods.find("gathered_plants")
	var stock := PackedInt64Array()
	stock.resize(goods.size() * 2)
	stock[good] = 100000000
	var price := PackedInt32Array()
	price.resize(goods.size() * 2)
	for cell in range(2):
		for g in range(goods.size()):
			price[cell * goods.size() + g] = int(
				(compiled.good_default_price as PackedInt32Array)[g])
	price[good] = int((compiled.good_max_price as PackedInt32Array)[good])
	price[goods.size() + good] = int((compiled.good_min_price as PackedInt32Array)[good])
	var merchant := (compiled.signature_keys as PackedStringArray).find("merchant|default")
	ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 1]),
		"signature_ids": PackedInt32Array([merchant, merchant]),
		"population": PackedInt64Array([100, 100]),
		"funds": PackedInt64Array([1000000000, 1000000000]),
	}, {"stock": stock, "price": price})
	for day in range(6):
		_advance_day(ext, day)
	_expect("negative expected profit creates no trade order",
		int(ext.get_trade_orders_for_cell(0, 0, 64).get("total", -1)) == 0)
	var destination: Dictionary = ext.get_market_cell_snapshot(1)
	var attempts: PackedInt64Array = destination.trade_last_attempt_day
	var reasons: PackedInt32Array = destination.trade_last_rejection_reason
	_expect("unprofitable shortage records an explicit rejection",
		int(attempts[good]) >= 0 and int(reasons[good]) in [1, 2])

func _test_invalid_seller_rebind(compiled: Dictionary, catalog: Dictionary) -> void:
	var ext := _new_ext(compiled, 2)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 2
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "ACTIVE"
	profile.trade_signal_pairs_per_slice = 1048576
	profile.trade_route_searches_per_slice = 64
	profile.trade_capacity_per_merchant_q16 = 67108864
	profile.trade_speed_cost_per_day = 1
	profile.trade_min_margin_q16 = 0
	CountryTestHelper.configure_all_technologies(ext, catalog, 2, 4416)
	ext.configure_economy(catalog, profile, 2, 4416)
	_capture_line_topology(ext, 2, 8)
	var goods: PackedStringArray = compiled.good_ids
	var good := goods.find("gathered_plants")
	var stock := PackedInt64Array()
	stock.resize(goods.size() * 2)
	stock[good] = 100000000
	var prices := PackedInt32Array()
	prices.resize(goods.size() * 2)
	for cell in range(2):
		for g in range(goods.size()):
			prices[cell * goods.size() + g] = int(
				(compiled.good_default_price as PackedInt32Array)[g])
	prices[good] = int((compiled.good_min_price as PackedInt32Array)[good])
	var signatures := compiled.signature_keys as PackedStringArray
	var merchant := signatures.find("merchant|default")
	var worker := signatures.find("worker|default")
	ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 1]),
		"signature_ids": PackedInt32Array([merchant, worker, merchant]),
		"population": PackedInt64Array([10, 20, 100]),
		"funds": PackedInt64Array([1000000, 1000000, 1000000000]),
	}, {"stock": stock, "price": prices})
	for day in range(6):
		_advance_day(ext, day)
	var orders: Dictionary = ext.get_trade_orders_for_cell(0, 0, 64)
	if int(orders.get("total", 0)) <= 0:
		_expect("long route dispatches before seller rebind test", false)
		return
	var arrival := int((orders.arrival_days as PackedInt64Array)[0])
	var original_order_id := int((orders.order_ids as PackedInt64Array)[0])
	var source_snapshot: Dictionary = ext.get_population_cell_snapshot(0)
	var merchant_handle := 0
	for i in range((source_snapshot.handles as PackedInt64Array).size()):
		if int((source_snapshot.merchant_flags as PackedByteArray)[i]) != 0:
			merchant_handle = int((source_snapshot.handles as PackedInt64Array)[i])
			break
	_expect("long route leaves time to invalidate seller handle",
		merchant_handle != 0 and arrival >= 10)
	var move := _single_command(7, 6, merchant_handle, 1, 0, 0, 0)
	_expect("seller move queues after dispatch",
		bool(ext.submit_economy_commands(move).get("ok", false)))
	var last_report: Dictionary = {}
	for day in range(6, arrival + 1):
		last_report = _advance_day(ext, day)
	var rebound_snapshot: Dictionary = ext.get_population_cell_snapshot(0)
	var rebound_handle := 0
	for i in range((rebound_snapshot.handles as PackedInt64Array).size()):
		if int((rebound_snapshot.merchant_flags as PackedByteArray)[i]) != 0:
			rebound_handle = int((rebound_snapshot.handles as PackedInt64Array)[i])
			break
	var remaining_orders: Dictionary = ext.get_trade_orders_for_cell(0, 0, 64)
	_expect("invalid seller rebinds to current source merchant",
		rebound_handle != 0 and rebound_handle != merchant_handle and
		not (remaining_orders.order_ids as PackedInt64Array).has(original_order_id) and
		int(last_report.get("trade_unclaimed_orders", -1)) == 0)
	_expect("seller rebind settlement remains conserved",
		int(last_report.get("goods_error", 1)) == 0 and
		int(last_report.get("money_error", 1)) == 0)

func _test_worker_scalar_equivalence(compiled: Dictionary, catalog: Dictionary) -> void:
	var scalar := _new_ext(compiled, 2)
	var worker := _new_ext(compiled, 2)
	var base: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	base.market_cycle_days = 2
	base.market_runtime_mode = "ACTIVE"
	base.trade_runtime_mode = "ACTIVE"
	base.trade_signal_pairs_per_slice = 1048576
	base.trade_route_searches_per_slice = 64
	base.trade_capacity_per_merchant_q16 = 67108864
	base.trade_min_margin_q16 = 0
	base.worker_market_threshold = 1
	var scalar_profile := base.duplicate(true)
	scalar_profile.worker_enabled = false
	var worker_profile := base.duplicate(true)
	worker_profile.worker_enabled = true
	worker_profile.worker_tasks_hint = 2
	for ext in [scalar, worker]:
		CountryTestHelper.configure_all_technologies(ext, catalog, 2, 4417)
	scalar.configure_economy(catalog, scalar_profile, 2, 4417)
	worker.configure_economy(catalog, worker_profile, 2, 4417)
	_capture_line_topology(scalar, 2)
	_capture_line_topology(worker, 2)
	var goods: PackedStringArray = compiled.good_ids
	var good := goods.find("gathered_plants")
	var stock := PackedInt64Array()
	stock.resize(goods.size() * 2)
	stock[good] = 100000000
	var prices := PackedInt32Array()
	prices.resize(goods.size() * 2)
	for cell in range(2):
		for g in range(goods.size()):
			prices[cell * goods.size() + g] = int(
				(compiled.good_default_price as PackedInt32Array)[g])
	prices[good] = int((compiled.good_min_price as PackedInt32Array)[good])
	var merchant := (compiled.signature_keys as PackedStringArray).find("merchant|default")
	var population_packet := {
		"cell_indices": PackedInt32Array([0, 1]),
		"signature_ids": PackedInt32Array([merchant, merchant]),
		"population": PackedInt64Array([100, 100]),
		"funds": PackedInt64Array([1000000000, 1000000000]),
	}
	scalar.bootstrap_economy(population_packet, {"stock": stock, "price": prices})
	worker.bootstrap_economy(population_packet, {"stock": stock, "price": prices})
	var scalar_orders: Dictionary = {}
	var worker_orders: Dictionary = {}
	var emitted_day := -1
	var daily_hashes_match := true
	for day in range(16):
		_advance_day(scalar, day)
		_advance_day(worker, day)
		daily_hashes_match = daily_hashes_match and \
			int(scalar.get_economy_state_hash()) == int(worker.get_economy_state_hash())
		scalar_orders = scalar.get_trade_orders_for_cell(0, 0, 64)
		worker_orders = worker.get_trade_orders_for_cell(0, 0, 64)
		if int(scalar_orders.get("total", 0)) > 0:
			emitted_day = day
			break
	_expect("worker and scalar emit identical trade orders",
		daily_hashes_match and emitted_day >= 0 and
		scalar_orders.order_ids == worker_orders.order_ids and
		scalar_orders.arrival_days == worker_orders.arrival_days and
		scalar_orders.line_offsets == worker_orders.line_offsets and
		scalar_orders.line_good_ids == worker_orders.line_good_ids and
		scalar_orders.line_quantities == worker_orders.line_quantities)
	for day in range(emitted_day + 1, emitted_day + 3):
		_advance_day(scalar, day)
		_advance_day(worker, day)
	_expect("worker and scalar final trade hashes match",
		int(scalar.get_economy_state_hash()) == int(worker.get_economy_state_hash()))

func _test_v10_migration(compiled: Dictionary, catalog: Dictionary) -> void:
	var ext := _new_ext(compiled, 1)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "ACTIVE"
	CountryTestHelper.configure_all_technologies(ext, catalog, 1, 4415)
	ext.configure_economy(catalog, profile, 1, 4415)
	_capture_line_topology(ext, 1)
	var merchant := (compiled.signature_keys as PackedStringArray).find("merchant|default")
	ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([merchant]),
		"population": PackedInt64Array([10]),
		"funds": PackedInt64Array([1000000]),
	}, {})
	_advance_day(ext, 0)
	var saved := _save_economy(ext)
	var legacy_chunks: Array = []
	for value in saved.get("chunks", []):
		var chunk := (value as PackedByteArray).duplicate()
		if chunk.size() >= 6:
			chunk[4] = 15
			chunk[5] = 0
		legacy_chunks.append(chunk)
	var restored := _new_ext(compiled, 1)
	CountryTestHelper.configure_all_technologies(restored, catalog, 1, 4415)
	restored.configure_economy(catalog, profile, 1, 4415)
	var result := _restore_economy(restored, legacy_chunks)
	_expect("PKEC v21 explicitly rejects legacy economy saves",
		not bool(result.get("ok", true)) and
		String(result.get("reason", "")) == "legacy_technology_tree_save_unsupported")

func _new_ext(catalog: Dictionary, cells: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	var scalar := PackedFloat32Array()
	scalar.resize(cells)
	scalar.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_moisture", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	var terrain := PackedByteArray()
	terrain.resize(cells)
	terrain.fill(2)
	var zero_bytes := PackedByteArray()
	zero_bytes.resize(cells)
	zero_bytes.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, terrain if slot_name == &"cell_terrain" else zero_bytes)
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	var zeros := PackedFloat32Array()
	zeros.resize(cells)
	zeros.fill(0.0)
	for i in range(reserve_slots.size()):
		var reserve_sid: int = ext.register_component(StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(extra_slots[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, zeros)
		ext.write_f32_range(extra_sid, 0, zeros)
	return ext

func _capture_line_topology(ext: Object, cells: int, move_cost: int = 1) -> bool:
	var neighbors := PackedInt32Array()
	neighbors.resize(cells * 6)
	neighbors.fill(-1)
	for cell in range(cells - 1):
		neighbors[cell * 6] = cell + 1
		neighbors[(cell + 1) * 6 + 3] = cell
	var terrain := PackedByteArray()
	terrain.resize(cells)
	terrain.fill(2)
	var passable := PackedByteArray()
	var costs := PackedInt32Array()
	passable.resize(256)
	costs.resize(256)
	passable[2] = 1
	costs[2] = move_cost
	return bool(ext.capture_economy_trade_topology(
		neighbors, terrain, passable, costs, 1).get("ok", false))

func _advance_day(ext: Object, day: int) -> Dictionary:
	var report: Dictionary = ext.run_economy_slice({"day_index": day})
	for continuation in range(64):
		if bool(report.get("done", false)) or (
				not bool(report.get("commit_due", false)) and
				not bool(report.get("boundary_continuation_required", false))):
			break
		report = ext.run_economy_slice({"day_index": day, "tick_index": continuation + 1})
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
	return {"ok": bool(ended.get("ok", false)), "schema": int(begin.get("schema_version", 0)),
		"chunks": chunks}

func _restore_economy(ext: Object, chunks: Array) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_restore()
	if not bool(begin.get("ok", false)):
		return begin
	for chunk in chunks:
		var fed: Dictionary = ext.feed_economy_restore_chunk(chunk as PackedByteArray)
		if not bool(fed.get("ok", false)):
			return fed
	return ext.end_economy_restore()

func _single_command(opcode: int, day: int, target_handle: int, i32_0: int,
		i32_1: int, i64_0: int, i64_1: int) -> Dictionary:
	return {
		"opcodes": PackedInt32Array([opcode]),
		"effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([1]),
		"target_handles": PackedInt64Array([target_handle]),
		"i32_0": PackedInt32Array([i32_0]),
		"i32_1": PackedInt32Array([i32_1]),
		"i64_0": PackedInt64Array([i64_0]),
		"i64_1": PackedInt64Array([i64_1]),
	}

func _convert_v11_chunks_to_v10(chunks: Array, compat_hash: int) -> Array:
	var converted: Array[PackedByteArray] = []
	for source_value in chunks:
		var source := source_value as PackedByteArray
		if source.size() < 16:
			continue
		var section := int(source.decode_u16(6))
		if section == 10 or section == 11:
			continue
		var chunk := source.duplicate()
		chunk.encode_u16(4, 10)
		if section == 0:
			var payload := source.slice(16)
			# v10 fixed header ended before the 76-byte v11 trade configuration block.
			var legacy_payload := payload.slice(0, 184)
			legacy_payload.encode_s64(72, compat_hash)
			legacy_payload.append_array(payload.slice(260))
			chunk = source.slice(0, 16)
			chunk.encode_u16(4, 10)
			chunk.encode_u32(12, legacy_payload.size())
			chunk.append_array(legacy_payload)
		elif section == 12:
			chunk.encode_u16(6, 10)
		converted.append(chunk)
	return converted

func _convert_v12_chunks_to_v11(chunks: Array, catalog_hash: int,
		building_catalog_hash: int) -> Array:
	var converted: Array[PackedByteArray] = []
	for source_value in chunks:
		var source := source_value as PackedByteArray
		if source.size() < 16:
			continue
		var section := int(source.decode_u16(6))
		var chunk := source.duplicate()
		chunk.encode_u16(4, 11)
		if section == 0:
			var payload := source.slice(16)
			# v12 appends six i32 business-policy fields after the v11 trade block.
			var legacy_payload := payload.slice(0, 260)
			legacy_payload.encode_s64(72, catalog_hash)
			legacy_payload.encode_s64(80, building_catalog_hash)
			legacy_payload.append_array(payload.slice(284))
			chunk = source.slice(0, 16)
			chunk.encode_u16(4, 11)
			chunk.encode_u32(12, legacy_payload.size())
			chunk.append_array(legacy_payload)
		converted.append(chunk)
	return converted

func _convert_v14_chunks_to_v13(chunks: Array, compat_hash: int,
		building_compat_hash: int) -> Array:
	var converted: Array[PackedByteArray] = []
	for source_value in chunks:
		var source := source_value as PackedByteArray
		if source.size() < 16:
			continue
		var section := int(source.decode_u16(6))
		var chunk := source.duplicate()
		chunk.encode_u16(4, 13)
		if section == 0:
			var payload := source.slice(16)
			# v14 appends fourteen i32 dynamic-policy fields after the v13 header.
			var legacy_payload := payload.slice(0, 284)
			legacy_payload.encode_s64(72, compat_hash)
			legacy_payload.encode_s64(80, building_compat_hash)
			legacy_payload.append_array(payload.slice(340))
			chunk = source.slice(0, 16)
			chunk.encode_u16(4, 13)
			chunk.encode_u32(12, legacy_payload.size())
			chunk.append_array(legacy_payload)
		converted.append(chunk)
	return converted

func _convert_v15_chunks_to_v14(chunks: Array) -> Array:
	var converted: Array[PackedByteArray] = []
	for source_value in chunks:
		var source := source_value as PackedByteArray
		if source.size() < 16:
			continue
		var section := int(source.decode_u16(6))
		var chunk := source.duplicate()
		chunk.encode_u16(4, 14)
		if section == 3:
			var records := int(source.decode_u32(8))
			var payload := source.slice(16)
			var legacy_payload := PackedByteArray()
			for record in range(records):
				legacy_payload.append_array(payload.slice(record * 68, record * 68 + 24))
			chunk = source.slice(0, 16)
			chunk.encode_u16(4, 14)
			chunk.encode_u32(12, legacy_payload.size())
			chunk.append_array(legacy_payload)
		converted.append(chunk)
	return converted

func _set_v11_trade_mode(chunks: Array, mode: int) -> Array:
	var converted: Array[PackedByteArray] = []
	for source_value in chunks:
		var chunk := (source_value as PackedByteArray).duplicate()
		if chunk.size() >= 220 and int(chunk.decode_u16(6)) == 0:
			# Chunk header (16) + v11 fixed header (184) + counts/id (16).
			chunk.encode_s32(216, mode)
		converted.append(chunk)
	return converted

func _good_value(snapshot: Dictionary, column: String, good_id: String) -> int:
	var index := (snapshot.good_ids as PackedStringArray).find(good_id)
	return int((snapshot[column] as PackedInt64Array)[index]) if index >= 0 else 0

func _sum_column(snapshot: Dictionary, column: String) -> int:
	var total := 0
	for value in snapshot[column] as PackedInt64Array:
		total += int(value)
	return total

func _exercise_accuracy_frontier(
		compiled: Dictionary, catalog: Dictionary) -> void:
	var ext := _new_ext(compiled, 2)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.economy_accuracy_preset = "BALANCED"
	profile.economy_approximation_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "OFF"
	_expect("accuracy ACTIVE country configures",
		CountryTestHelper.configure_all_technologies(ext, catalog, 2, 4411))
	_expect("accuracy ACTIVE economy configures", bool(ext.configure_economy(
		catalog, profile, 2, 4411).get("ok", false)))
	var goods: PackedStringArray = compiled.good_ids
	var stock := PackedInt64Array()
	var prices := PackedInt32Array()
	stock.resize(goods.size() * 2)
	stock.fill(1000000)
	prices.resize(goods.size() * 2)
	for cell in range(2):
		for good in range(goods.size()):
			prices[cell * goods.size() + good] = int(
				(compiled.good_default_price as PackedInt32Array)[good])
	var merchant_signature := (
		compiled.signature_keys as PackedStringArray).find("merchant|default")
	_expect("accuracy ACTIVE markets bootstrap", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 1]),
		"signature_ids": PackedInt32Array([
			merchant_signature, merchant_signature]),
		"population": PackedInt64Array([100, 100]),
		"funds": PackedInt64Array([1000000000, 1000000000]),
	}, {"stock": stock, "price": prices}).get("ok", false)))
	var report := _advance_day(ext, 0)
	_expect("accuracy ACTIVE uses certified nested frontier",
		String(report.get("economy_accuracy_preset", "")) == "BALANCED" and
		bool(report.get("approximation_authoritative", false)) and
		int(report.get("approximation_decisions", 0)) > 0 and
		int(report.get("approximation_frontier_candidates", 0)) >=
			int(report.get("approximation_frontier_pruned", 0)))
	_expect("accuracy ACTIVE preserves exact ledgers",
		not bool(report.get("fatal", false)) and
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)
