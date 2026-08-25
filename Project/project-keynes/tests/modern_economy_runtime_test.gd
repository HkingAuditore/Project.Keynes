extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

var failures := 0

func _init() -> void:
	_run()
	print("=== modern economy runtime %s ===" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition: failures += 1

func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)): return
	var ext := _new_ext(compiled)
	var native_catalog := compiled.duplicate(true)
	native_catalog.erase("ok")
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	_expect("all-technology production country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, native_catalog, 1, 2200))
	var configure_report: Dictionary = ext.configure_economy(native_catalog, profile, 1, 2200)
	_expect("native runtime configures: %s" % String(configure_report.get("reason", "ok")),
		bool(configure_report.get("ok", false)))
	_expect("bullion diagnostic trace registers",
		bool(ext.set_economy_inspector_trace_cell(0).get("ok", false)))

	var signatures: PackedStringArray = compiled.signature_keys
	var industrialist := signatures.find("industrialist|default")
	var merchant := signatures.find("merchant|default")
	var miner := signatures.find("miner|default")
	var industrial_worker := signatures.find("industrial_worker|default")
	var electrician := signatures.find("electrician|default")
	var engineer := signatures.find("engineer|default")
	var metallurgist := signatures.find("metallurgist|default")
	var technician := signatures.find("technician|default")
	var manager := signatures.find("manager|default")
	var goods: PackedStringArray = compiled.good_ids
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(0)
	stock[goods.find("coal")] = 100000
	stock[goods.find("tools")] = 100000
	stock[goods.find("explosives")] = 100000
	stock[goods.find("bauxite")] = 100000
	stock[goods.find("industrial_machinery")] = 100000
	var types: PackedStringArray = compiled.building_type_ids
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([
			industrialist, merchant, miner, industrial_worker, electrician, engineer,
			metallurgist, technician, manager]),
		"population": PackedInt64Array([10, 10, 50, 80, 20, 15, 20, 20, 20]),
		"funds": PackedInt64Array([
			100000000, 100000000, 1000000, 1000000, 1000000, 1000000, 1000000, 1000000,
			1000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0, 0, 0, 0]),
		"building_type_ids": PackedInt32Array([
			types.find("electricity_plant"), types.find("gold_mine"), types.find("silver_mine"),
			types.find("aluminum_plant")]),
		"building_owner_signature_ids": PackedInt32Array([
			industrialist, industrialist, industrialist, industrialist]),
		"building_counts": PackedInt64Array([3, 1, 1, 1]),
	})
	var boot_ok := bool(boot.get("ok", false))
	_expect("power and bullion buildings bootstrap" if boot_ok else
		"power and bullion buildings bootstrap: %s" % String(boot.get("reason", "unknown")),
		boot_ok)
	if not boot_ok:
		return
	var report := _run_day(ext, 0)
	if bool(report.get("fatal", false)):
		print("  runtime report: ", report)
	_expect("production cycle commits", bool(report.get("done", false)) and not bool(report.get("fatal", false)))
	var gold_accepted := int(report.get("gold_accepted", 0))
	var silver_accepted := int(report.get("silver_accepted", 0))
	var gold_issued := int(report.get("gold_money_issued", 0))
	var silver_issued := int(report.get("silver_money_issued", 0))
	_expect("gold issues configured value", gold_accepted > 0 and
		gold_issued == gold_accepted * 800000 / 1000)
	_expect("silver issues configured value", silver_accepted > 0 and
		silver_issued == silver_accepted * 50000 / 1000)
	_expect("only accepted bullion contributes monetary issue",
		int(report.get("bullion_money_issued", 0)) == gold_issued + silver_issued)
	var flow_produced := int(report.get("cycle_flow_produced", 0))
	var flow_consumed := int(report.get("cycle_flow_consumed", 0))
	var flow_discarded := int(report.get("cycle_flow_discarded", 0))
	_expect("utility prepass supplies same-cycle electricity",
		flow_produced > 0 and flow_consumed > 0 and flow_produced >= flow_consumed)
	_expect("unused electricity is cleared", flow_discarded == flow_produced - flow_consumed)
	_expect("all ledgers conserve exactly", int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and int(report.get("goods_error", 1)) == 0)
	var market: Dictionary = ext.get_market_cell_snapshot(0)
	_expect("accepted bullion is consumed by monetary issuance",
		_good_value(market, "stock", "gold") == 0 and
		_good_value(market, "stock", "silver") == 0 and
		int(report.get("bullion_stock_consumed", 0)) == gold_accepted + silver_accepted)
	_expect("cycle-flow inventory does not cross boundary", _good_value(market, "stock", "electricity") == 0)
	_expect("market snapshot exposes metadata",
		(market.good_storage_modes as PackedInt32Array)[goods.find("electricity")] == 1 and
		(market.good_monetary_issue_values as PackedInt64Array)[goods.find("gold")] == 800000)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var aluminum_group := (buildings.group_type_ids as PackedInt32Array).find(
		types.find("aluminum_plant"))
	var selected_offsets: PackedInt32Array = buildings.group_input_selected_offsets
	var selected_goods: PackedInt32Array = buildings.group_input_selected_good_ids
	var selected_begin := int(selected_offsets[aluminum_group]) if aluminum_group >= 0 else -1
	_expect("building snapshot reports actual per-slot input selections",
		aluminum_group >= 0 and aluminum_group + 1 < selected_offsets.size() and
		int(selected_offsets[aluminum_group + 1]) - selected_begin == 4 and
		selected_goods[selected_begin] == goods.find("bauxite") and
		selected_goods[selected_begin + 1] == goods.find("electricity") and
		selected_goods[selected_begin + 2] == goods.find("tools") and
		selected_goods[selected_begin + 3] == goods.find("industrial_machinery"))
	_expect("building snapshot exposes kind and technology tags",
		(buildings.building_kinds as PackedInt32Array).size() == types.size() and
		(buildings.building_technology_tag_offsets as PackedInt32Array).size() == types.size() + 1 and
		(buildings.building_technology_tags as PackedStringArray).size() > 0)
	_test_bullion_absorption_feedback(ext, goods, types)
	_test_bullion_entry_valuation(compiled, native_catalog)
	if OS.get_cmdline_user_args().has("--bullion-only"):
		return
	_test_technology_gating(compiled, native_catalog)
	_test_upgrade_gating(compiled, native_catalog)

func _test_bullion_absorption_feedback(ext: Object, goods: PackedStringArray,
		types: PackedStringArray) -> void:
	var day5 := _run_day(ext, 5)
	var day10 := _run_day(ext, 10)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var group_types: PackedInt32Array = buildings.group_type_ids
	var planned: PackedInt32Array = buildings.planned_utilization_q16
	var margins: PackedInt32Array = buildings.realized_profit_margin_q16
	var loss_cycles: PackedInt32Array = buildings.severe_loss_cycles
	var states: PackedByteArray = buildings.operating_state
	var driver_goods: PackedInt32Array = buildings.investment_driver_good_id
	var driver_merchant_sold: PackedInt64Array = \
		buildings.investment_driver_merchant_sold
	var driver_sell_through: PackedInt64Array = \
		buildings.investment_driver_sell_through_q16
	for pair in [
		[types.find("gold_mine"), goods.find("gold")],
		[types.find("silver_mine"), goods.find("silver")],
	]:
		var group := group_types.find(int(pair[0]))
		var good := int(pair[1])
		_expect("mint absorption preserves bullion utilization: %s" %
				String(types[int(pair[0])]),
			group >= 0 and planned[group] == 65536 and margins[group] > 0 and
			loss_cycles[group] == 0 and states[group] == 0)
		_expect("mint absorption passes bullion sell-through: %s" %
				String(types[int(pair[0])]),
			group >= 0 and driver_goods[group] == good and
			driver_merchant_sold[group] == 0 and
			driver_sell_through[group] == 65536)
	_expect("bullion feedback cycles conserve exactly",
		int(day5.get("population_error", 1)) == 0 and
		int(day5.get("money_error", 1)) == 0 and
		int(day5.get("goods_error", 1)) == 0 and
		int(day10.get("population_error", 1)) == 0 and
		int(day10.get("money_error", 1)) == 0 and
		int(day10.get("goods_error", 1)) == 0)

func _test_bullion_entry_valuation(compiled: Dictionary,
		native_catalog: Dictionary) -> void:
	var ext := _new_ext(compiled)
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	_expect("bullion-entry country bootstraps",
		CountryTestHelper.configure_all_technologies(
			ext, native_catalog, 1, 2203))
	_expect("bullion-entry runtime configures", bool(ext.configure_economy(
		native_catalog, profile, 1, 2203).get("ok", false)))
	_expect("bullion-entry diagnostic trace registers",
		bool(ext.set_economy_inspector_trace_cell(0).get("ok", false)))
	var signatures: PackedStringArray = compiled.signature_keys
	var industrialist := signatures.find("industrialist|default")
	var merchant := signatures.find("merchant|default")
	var miner := signatures.find("miner|default")
	var manager := signatures.find("manager|default")
	var goods: PackedStringArray = compiled.good_ids
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(100000000)
	stock[goods.find("gold")] = 0
	stock[goods.find("silver")] = 0
	_expect("bullion-entry population bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([
			industrialist, merchant, miner, manager]),
		"population": PackedInt64Array([10, 10, 50, 10]),
		"funds": PackedInt64Array([
			1000000000000, 1000000000000, 1000000, 1000000]),
	}, {"stock": stock}).get("ok", false)))
	_run_day(ext, 0)
	var review := _run_day(ext, 10)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var diagnostic_types: PackedInt32Array = \
		buildings.investment_candidate_type_ids
	var pressures: PackedInt64Array = \
		buildings.investment_candidate_driver_pressure_q16
	var utilizations: PackedInt64Array = \
		buildings.investment_candidate_driver_utilization_q16
	var profits: PackedInt64Array = \
		buildings.investment_candidate_projected_profit_per_day
	var reasons: PackedInt32Array = \
		buildings.investment_candidate_rejection_reasons
	var types: PackedStringArray = compiled.building_type_ids
	for type_name in ["gold_mine", "silver_mine"]:
		var row := diagnostic_types.find(types.find(type_name))
		_expect("mint face value makes new bullion entry viable: %s "
				% type_name + "(row=%d pressure=%d utilization=%d profit=%d reason=%d)" % [
					row,
					pressures[row] if row >= 0 else -1,
					utilizations[row] if row >= 0 else -1,
					profits[row] if row >= 0 else -1,
					reasons[row] if row >= 0 else -1,
				],
			row >= 0 and pressures[row] == 65536 and
			utilizations[row] == 65536 and profits[row] > 0)
	_expect("bullion-entry review conserves exactly",
		int(review.get("population_error", 1)) == 0 and
		int(review.get("money_error", 1)) == 0 and
		int(review.get("goods_error", 1)) == 0)

func _test_technology_gating(compiled: Dictionary, native_catalog: Dictionary) -> void:
	var ext := _new_ext(compiled)
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	_expect("stone-start runtime configures", bool(ext.configure_economy(
		native_catalog, profile, 1, 2201).get("ok", false)))
	var signatures: PackedStringArray = compiled.signature_keys
	_expect("stone-start runtime bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([
			signatures.find("forager|default"), signatures.find("merchant|default")]),
		"population": PackedInt64Array([10, 10]),
		"funds": PackedInt64Array([1000000, 1000000]),
	}, {}).get("ok", false)))
	var goods: PackedStringArray = compiled.good_ids
	var types: PackedStringArray = compiled.building_type_ids
	var country_summary: Dictionary = ext.get_country_cell_summary(0)
	var initial_technologies: Dictionary = ext.get_country_snapshot(country_summary.country_handle)
	var market: Dictionary = ext.get_market_cell_snapshot(0)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var population: Dictionary = ext.get_population_cell_snapshot(0)
	var demand_indices: PackedInt32Array = population.get(
		"demand_good_indices", PackedInt32Array())
	var demand_quantities: PackedInt64Array = population.get(
		"demand_per_capita_daily", PackedInt64Array())
	var good_technology_available: PackedByteArray = market.get(
		"good_technology_available", PackedByteArray())
	var demand_uses_only_discovered_goods := good_technology_available.size() == goods.size()
	var locked_demand_goods := PackedStringArray()
	for demand_cursor in range(demand_indices.size()):
		var good_index := int(demand_indices[demand_cursor])
		var quantity := int(demand_quantities[demand_cursor]) \
			if demand_cursor < demand_quantities.size() else 0
		if quantity <= 0:
			continue
		if good_index < 0 or good_index >= good_technology_available.size() \
				or good_technology_available[good_index] == 0:
			demand_uses_only_discovered_goods = false
			if good_index >= 0 and good_index < goods.size():
				locked_demand_goods.append(String(goods[good_index]))
	_expect("stone-start demand excludes undiscovered goods",
		demand_uses_only_discovered_goods and locked_demand_goods.is_empty())
	var advanced_type := types.find("subsistence_farm")
	var early_gold_type := types.find("placer_gold_working")
	var early_silver_type := types.find("surface_silver_working")
	_expect("stone start unlocks hunting and gathering",
		(initial_technologies.technology_ids as PackedStringArray).has("tech.hunting") and
		(initial_technologies.technology_ids as PackedStringArray).has("tech.gathering"))
	_expect("post-industrial technology starts locked",
		not (initial_technologies.technology_ids as PackedStringArray).has("tech.autonomous_systems"))
	_expect("stone start hides legacy modern goods but exposes gathered food",
		(market.good_technology_available as PackedByteArray)[goods.find("computers")] == 0 and
		(market.good_technology_available as PackedByteArray)[goods.find("gathered_plants")] == 1)
	_expect("stone start keeps unresearched bullion workings unavailable",
		early_gold_type >= 0 and early_silver_type >= 0 and
		(buildings.building_technology_available as PackedByteArray)[early_gold_type] == 0 and
		(buildings.building_technology_available as PackedByteArray)[early_silver_type] == 0)
	_expect("unresearched agrarian building is unavailable",
		advanced_type >= 0 and
		(buildings.building_technology_available as PackedByteArray)[advanced_type] == 0)
	var profession_catalog: PackedStringArray = compiled.get(
		"profession_ids", PackedStringArray())
	var owner_professions: PackedInt32Array = compiled.get(
		"building_owner_profession_ids", PackedInt32Array())
	var employee_offsets: PackedInt32Array = compiled.get(
		"building_employee_offsets", PackedInt32Array())
	var employee_professions: PackedInt32Array = compiled.get(
		"building_employee_profession_ids", PackedInt32Array())
	var type_available: PackedByteArray = buildings.get(
		"building_technology_available", PackedByteArray())
	var hired := {}
	for type_index in range(mini(types.size(), type_available.size())):
		if int(type_available[type_index]) == 0:
			continue
		if type_index < owner_professions.size():
			var owner_id := int(owner_professions[type_index])
			if owner_id >= 0 and owner_id < profession_catalog.size():
				hired[String(profession_catalog[owner_id])] = true
		if type_index + 1 >= employee_offsets.size():
			continue
		for role in range(int(employee_offsets[type_index]),
				int(employee_offsets[type_index + 1])):
			if role < 0 or role >= employee_professions.size():
				continue
			var employee_id := int(employee_professions[role])
			if employee_id >= 0 and employee_id < profession_catalog.size():
				hired[String(profession_catalog[employee_id])] = true
	_expect("stone start hides locked professions from family behavior",
		bool(hired.get("forager", false))
		and not bool(hired.get("ai_researcher", false))
		and not bool(hired.get("data_scientist", false)))
	_grant_technology(ext, compiled, "tech.application.subsistence_farm", 1, 1)
	_expect("economy observes the committed technology epoch",
		bool(_run_day(ext, 1).get("done", false)))
	var unlocked: Dictionary = ext.get_country_snapshot(country_summary.country_handle)
	var unlocked_buildings: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("technology grant becomes committed cell state",
		(unlocked.technology_ids as PackedStringArray).has(
			"tech.application.subsistence_farm"))
	_expect("granted technology unlocks tagged building",
		(unlocked_buildings.building_technology_available as PackedByteArray)[advanced_type] == 1)


func _test_upgrade_gating(compiled: Dictionary, native_catalog: Dictionary) -> void:
	var ext := _new_ext(compiled)
	var starting_technologies := PackedStringArray()
	var starting_seen := {}
	var technology_ids: PackedStringArray = compiled.technology_ids
	for technology_id in ["tech.gathering", "tech.weaving"]:
		_collect_technology_closure(compiled, technology_ids.find(technology_id),
			starting_seen, starting_technologies)
	_expect("upgrade test country configures", bool(ext.configure_country(
		native_catalog, {
			"country_runtime_mode": "ACTIVE",
			"starting_technology_ids": starting_technologies,
		}, 1, 2202).get("ok", false)))
	_expect("upgrade test country bootstraps", bool(ext.bootstrap_country(
		{}, PackedByteArray([0])).get("ok", false)))
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	_expect("upgrade test runtime configures", bool(ext.configure_economy(
		native_catalog, profile, 1, 2202).get("ok", false)))
	var signatures: PackedStringArray = compiled.signature_keys
	var forager := signatures.find("forager|default")
	var artisan := signatures.find("artisan|default")
	var farmer := signatures.find("subsistence_farmer|default")
	var merchant := signatures.find("merchant|default")
	var goods: PackedStringArray = compiled.good_ids
	var construction_stock := PackedInt64Array()
	construction_stock.resize(goods.size())
	construction_stock.fill(0)
	construction_stock[goods.find("logs")] = 1000000
	construction_stock[goods.find("bast_fiber")] = 1000000
	_expect("upgrade test population bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([forager, artisan, farmer, merchant]),
		"population": PackedInt64Array([4, 4, 4, 4]),
		"funds": PackedInt64Array([10000000, 10000000, 10000000, 10000000]),
	}, {"stock": construction_stock}).get("ok", false)))
	var types: PackedStringArray = compiled.building_type_ids
	var gathering := types.find("gathering_ground")
	var early_farm := types.find("subsistence_farm")
	var guild_farm := types.find("three_field_smallholding")
	var steam_farm := types.find("improved_smallholding")
	var early_weaving := types.find("household_weaving_shelter")
	var pottery_weaving := types.find("household_loom")
	var guild_weaving := types.find("cottage_weaving")
	var steam_weaving := types.find("improved_domestic_loom")
	var forager_handle := _handle_for_signature(ext.get_population_cell_snapshot(0), forager)
	_expect("stone tier build command queues", bool(ext.submit_economy_commands(
		_build_command(0, 1, forager_handle, gathering)).get("ok", false)))
	var stone_report := _run_day(ext, 0)
	var stone_buildings: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("stone tier builds before replacement",
		int(stone_report.get("rejected_commands", 0)) == 0 and
		_building_count(stone_buildings, gathering) == 1)
	var first_production_report := _run_day(ext, 5)
	stone_buildings = ext.get_building_cell_snapshot(0)
	_expect("zero-day construction produces from the following cycle",
		_building_last_output(stone_buildings, gathering) > 0)

	_grant_technologies(ext, compiled, PackedStringArray([
		"tech.application.subsistence_farm",
		"tech.application.household_loom",
	]), 10, 1)
	# Employment migration may replace the cohort slot and therefore its
	# generation-tagged handle; commands must target the current owner handle.
	forager_handle = _handle_for_signature(ext.get_population_cell_snapshot(0), forager)
	_expect("unlocked stone build command remains queueable", bool(
		ext.submit_economy_commands(_build_command(11, 3, forager_handle, gathering)).get("ok", false)))
	var pottery_report := _run_day(ext, 11)
	var pottery_buildings: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("higher technology adds choices instead of banning old construction",
		int(pottery_report.get("rejected_commands", 0)) == 0)
	_expect("new stone building and existing asset both keep producing",
		_building_count(pottery_buildings, gathering) >= 2 and
		_building_last_output(pottery_buildings, gathering) > 0)
	_expect("all unlocked pottery-era family tiers remain constructible",
		_tier_state(pottery_buildings, gathering, 2, true) and
		_tier_state(pottery_buildings, early_farm, 2, true) and
		_tier_state(pottery_buildings, early_weaving, 2, true) and
		_tier_state(pottery_buildings, pottery_weaving, 2, true))

	_grant_technologies(ext, compiled, PackedStringArray([
		"tech.application.three_field_smallholding",
		"tech.application.cottage_weaving",
	]), 15, 4)
	_run_day(ext, 15)
	var guild_buildings: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("guild tier extends construction choices without deleting old assets",
		_tier_state(guild_buildings, early_farm, 3, true) and
		_tier_state(guild_buildings, guild_farm, 3, true) and
		_tier_state(guild_buildings, pottery_weaving, 3, true) and
		_tier_state(guild_buildings, guild_weaving, 3, true) and
		_building_count(guild_buildings, gathering) >= 2)

	_grant_technologies(ext, compiled, PackedStringArray([
		"tech.application.improved_smallholding",
		"tech.application.improved_domestic_loom",
	]), 20, 6)
	_run_day(ext, 20)
	var steam_buildings: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("steam tier joins the constructible subsistence choices",
		_tier_state(steam_buildings, guild_farm, 4, true) and
		_tier_state(steam_buildings, steam_farm, 4, true) and
		_tier_state(steam_buildings, guild_weaving, 4, true) and
		_tier_state(steam_buildings, steam_weaving, 4, true))

	_grant_technology(ext, compiled, "tech.autonomous_systems", 25, 8)
	_run_day(ext, 25)
	var post_industrial: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("post-industrial technology does not create a fifth subsistence tier",
		_tier_state(post_industrial, steam_farm, 4, true) and
		_tier_state(post_industrial, steam_weaving, 4, true) and
		_max_family_tier(post_industrial, "subsistence_food") == 4 and
		_max_family_tier(post_industrial, "household_cloth") == 4)
	_expect("upgrade cycles conserve all ledgers",
		int(stone_report.get("population_error", 1)) == 0 and
		int(first_production_report.get("population_error", 1)) == 0 and
		int(pottery_report.get("population_error", 1)) == 0 and
		int(pottery_report.get("money_error", 1)) == 0 and
		int(pottery_report.get("goods_error", 1)) == 0)


func _grant_technology(ext: Object, compiled: Dictionary, technology_id: String,
		day: int, sequence: int) -> void:
	_grant_technologies(ext, compiled, PackedStringArray([technology_id]), day, sequence)


func _grant_technologies(ext: Object, compiled: Dictionary,
		technology_ids: PackedStringArray, day: int, sequence: int) -> void:
	var country: Dictionary = ext.get_country_cell_summary(0)
	var technologies: PackedStringArray = compiled.technology_ids
	var requested := technology_ids.duplicate()
	var closure := PackedStringArray()
	var seen := {}
	for technology_id in technology_ids:
		_collect_technology_closure(compiled, technologies.find(technology_id), seen, closure)
	technology_ids = closure
	var pending_day := maxi(0, day - 1)
	var count := technology_ids.size()
	var opcodes := PackedInt32Array()
	var effective_days := PackedInt64Array()
	var sequences := PackedInt64Array()
	var target_handles := PackedInt64Array()
	var cell_indices := PackedInt32Array()
	var technology_indices := PackedInt32Array()
	var negative_i32 := PackedInt32Array()
	var zero_i32 := PackedInt32Array()
	var zero_i64 := PackedInt64Array()
	var empty_strings := PackedStringArray()
	for index in range(count):
		opcodes.append(4)
		effective_days.append(pending_day)
		sequences.append(sequence + index)
		target_handles.append(country.country_handle)
		cell_indices.append(-1)
		technology_indices.append(technologies.find(technology_ids[index]))
		negative_i32.append(-1)
		zero_i32.append(0)
		zero_i64.append(0)
		empty_strings.append("")
	var queued: Dictionary = ext.submit_country_commands({
		"opcodes": opcodes,
		"effective_days": effective_days,
		"sequences": sequences,
		"target_handles": target_handles,
		"cell_indices": cell_indices,
		"aux_i32": technology_indices,
		"domain_i32": negative_i32,
		"position_i32": negative_i32,
		"weight0_bp": zero_i32,
		"weight1_bp": zero_i32,
		"weight2_bp": zero_i32,
		"weight3_bp": zero_i32,
		"value_i64": zero_i64,
		"stable_ids": empty_strings,
		"display_names": empty_strings,
	})
	var label := ",".join(requested)
	_expect("technology grant queues: %s" % label, bool(queued.get("ok", false)))
	_expect("technology grant enters pending state: %s" % label,
		bool(ext.run_country_slice({"day_index": pending_day}).get("done", false)))
	if day > pending_day:
		_expect("technology grant activates next day: %s" % label,
			bool(ext.run_country_slice({"day_index": day}).get("done", false)))


func _collect_technology_closure(compiled: Dictionary, technology_index: int,
		seen: Dictionary, out: PackedStringArray) -> void:
	if technology_index < 0 or seen.has(technology_index):
		return
	seen[technology_index] = true
	var offsets: PackedInt32Array = compiled.technology_prerequisite_offsets
	var prerequisites: PackedInt32Array = compiled.technology_prerequisites
	for edge in range(offsets[technology_index], offsets[technology_index + 1]):
		_collect_technology_closure(compiled, int(prerequisites[edge]), seen, out)
	out.append(String((compiled.technology_ids as PackedStringArray)[technology_index]))


func _build_command(day: int, sequence: int, owner_handle: int, type_id: int) -> Dictionary:
	return {
		"opcodes": PackedInt32Array([10]),
		"effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([sequence]),
		"target_handles": PackedInt64Array([owner_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([type_id]),
		"i64_0": PackedInt64Array([1]),
		"i64_1": PackedInt64Array([0]),
	}


func _handle_for_signature(snapshot: Dictionary, signature_id: int) -> int:
	var signatures: PackedInt32Array = snapshot.get("signature_ids", PackedInt32Array())
	var handles: PackedInt64Array = snapshot.get("handles", PackedInt64Array())
	var row := signatures.find(signature_id)
	return int(handles[row]) if row >= 0 and row < handles.size() else 0


func _building_count(snapshot: Dictionary, type_id: int) -> int:
	var counts: PackedInt64Array = snapshot.get("building_counts_by_type", PackedInt64Array())
	return int(counts[type_id]) if type_id >= 0 and type_id < counts.size() else 0


func _building_last_output(snapshot: Dictionary, type_id: int) -> int:
	var group_types: PackedInt32Array = snapshot.get("group_type_ids", PackedInt32Array())
	var outputs: PackedInt64Array = snapshot.get("last_output", PackedInt64Array())
	var group := group_types.find(type_id)
	return int(outputs[group]) if group >= 0 and group < outputs.size() else 0


func _tier_state(snapshot: Dictionary, type_id: int, highest_tier: int,
		constructible: bool) -> bool:
	var highest: PackedInt32Array = snapshot.get(
		"building_highest_available_tiers", PackedInt32Array())
	var available: PackedByteArray = snapshot.get(
		"building_construction_available", PackedByteArray())
	return type_id >= 0 and type_id < highest.size() and type_id < available.size() \
		and int(highest[type_id]) == highest_tier \
		and bool(available[type_id]) == constructible


func _max_family_tier(snapshot: Dictionary, family_id: String) -> int:
	var family_ids: PackedStringArray = snapshot.get(
		"building_upgrade_family_ids", PackedStringArray())
	var family_indices: PackedInt32Array = snapshot.get(
		"building_upgrade_family_indices", PackedInt32Array())
	var tiers: PackedInt32Array = snapshot.get("building_upgrade_tiers", PackedInt32Array())
	var family := family_ids.find(family_id)
	var maximum := 0
	for type_id in range(family_indices.size()):
		if family_indices[type_id] == family and type_id < tiers.size():
			maximum = maxi(maximum, int(tiers[type_id]))
	return maximum

func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var scalar := PackedFloat32Array([0.5])
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation", &"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, PackedByteArray([0]))
	var resources: PackedStringArray = catalog.building_resource_ids
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	for i in range(resources.size()):
		var reserve_sid: int = ext.register_component(StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(extra_slots[i]), 0, 1, false)
		var reserve := 1000000.0
		ext.write_f32_range(reserve_sid, 0, PackedFloat32Array([reserve]))
		ext.write_f32_range(extra_sid, 0, PackedFloat32Array([0.0]))
	return ext

func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(512):
		report = ext.run_economy_slice({"day_index": day, "tick_index": day * 1000 + slice})
		if bool(report.get("done", false)): return report
	return report

func _good_value(snapshot: Dictionary, column: String, good_id: String) -> int:
	var index := (snapshot.good_ids as PackedStringArray).find(good_id)
	return int((snapshot[column] as PackedInt64Array)[index]) if index >= 0 else 0
