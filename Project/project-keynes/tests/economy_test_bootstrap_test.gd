extends SceneTree

const EconomyFacadeScript = preload("res://scripts/economy/economy_facade.gd")
const EconomyTestBootstrapScript = preload("res://scripts/economy/economy_test_bootstrap.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const WorldSetupScript = preload("res://scripts/ui/world_setup.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

var _failures := PackedStringArray()


func _initialize() -> void:
	var option_found := false
	var scale_option_found := false
	for field in WorldSetupScript.BASE_FIELDS:
		if String(field.get("name", "")) == "generate_test_economy_data":
			option_found = true
			_expect("test economy option defaults off", not bool(field.get("default", true)))
		if String(field.get("name", "")) == "test_economy_population_scale":
			scale_option_found = true
			_expect("test economy population scale defaults to resource-tiered mix",
				int(field.get("default", -1)) == 0)
	_expect("world setup exposes test economy option", option_found)
	_expect("world setup exposes test economy population scale", scale_option_found)
	if not ClassDB.class_exists("DCWorldExt"):
		print("[economy-test-bootstrap] SKIP: DCWorldExt unavailable")
		quit(0)
		return
	var map := _make_map()
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(map.cell_count())
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("building catalog compiles", bool(compiled.get("ok", false)))
	var environment := PackedFloat32Array([0.5, 0.5, 0.5, 0.5])
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, environment)
	var enum_values := map.terrain_arr
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation", &"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, enum_values if slot_name == &"cell_terrain" else PackedByteArray([0, 0, 0, 0]))
	var csv_resource_slot_ids := PackedInt32Array()
	var csv_resource_ids := PackedStringArray()
	for i in range((compiled.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(
			StringName(compiled.building_resource_reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(
			StringName(compiled.building_resource_extra_slots[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, _resource_values(
			map, StringName(compiled.building_resource_ids[i])))
		ext.write_f32_range(extra_sid, 0, PackedFloat32Array([0.0, 0.0, 0.0, 0.0]))
		csv_resource_slot_ids.append(reserve_sid)
		csv_resource_ids.append(String(compiled.building_resource_ids[i]))
	var facade = EconomyFacadeScript.new()
	var profile = load("res://data/economy/default_economy.tres").duplicate(true)
	profile.market_cycle_days = 5
	var native_catalog := compiled.duplicate(true)
	native_catalog.erase("ok")
	_expect("all-technology test country bootstraps", CountryTestHelper.configure_all_technologies(
		ext, native_catalog, map.cell_count(), 42, map.is_water_arr))
	var configure_result: Dictionary = facade.configure(ext, map.cell_count(), 42, profile)
	var configure_ok := bool(configure_result.get("ok", false))
	_expect("facade configures" if configure_ok else "facade configures: %s" %
		String(configure_result.get("reason", "unknown")), configure_ok)
	if not configure_ok:
		_finish()
		return
	var first: Dictionary = EconomyTestBootstrapScript.build(map, facade, 42)
	var same: Dictionary = EconomyTestBootstrapScript.build(map, facade, 42)
	var resource_tiered: Dictionary = EconomyTestBootstrapScript.build(map, facade, 42, 0)
	var stress_hundreds: Dictionary = EconomyTestBootstrapScript.build(map, facade, 42, 10)
	var stress_thousands: Dictionary = EconomyTestBootstrapScript.build(map, facade, 42, 100)
	var stress_ten_thousands: Dictionary = EconomyTestBootstrapScript.build(
		map, facade, 42, 1000)
	var missing_source_map := _make_map()
	_clear_resource(missing_source_map, &"stone")
	var missing_source: Dictionary = EconomyTestBootstrapScript.build(
		missing_source_map, facade, 42)
	_expect("construction-source-free trade region fails explicitly",
		not bool(missing_source.get("ok", true)) and
		String(missing_source.get("reason", "")) ==
			"bootstrap_construction_source_missing")
	var traded_source_map := _make_map()
	_set_resource_cell(traded_source_map, &"timber", 0, 0.0)
	_set_resource_cell(traded_source_map, &"fertile_soil", 1, 1000000.0)
	_set_resource_cell(traded_source_map, &"flint", 1, 1000000.0)
	var traded_source: Dictionary = EconomyTestBootstrapScript.build(
		traded_source_map, facade, 42)
	_expect("settlement without local forest closes through a populated regional source",
		bool(traded_source.get("ok", false)) and
		int(traded_source.get("construction_source_component_count", 0)) == 1)
	var distributed_source_map := _make_distributed_source_map()
	var distributed_source: Dictionary = EconomyTestBootstrapScript.build(
		distributed_source_map, facade, 42)
	_expect("distributed regional survival and construction chains survive local pruning " +
		"ok=%s fallback=%s sources=%d cells=%d reason=%s" % [
			str(bool(distributed_source.get("ok", false))),
			str(bool(distributed_source.get("regional_capacity_fallback", false))),
			int(distributed_source.get("construction_source_component_count", 0)),
			int(distributed_source.get("regional_capacity_fallback_cells", 0)),
			String(distributed_source.get("reason", "")),
		],
		bool(distributed_source.get("ok", false)) and
		bool(distributed_source.get("regional_capacity_fallback", false)) and
		int(distributed_source.get("construction_source_component_count", 0)) == 1 and
		int(distributed_source.get("regional_capacity_fallback_cells", 0)) >= 3)
	var short_horizon_map := _make_map()
	_clear_resource(short_horizon_map, &"timber")
	_clear_resource(short_horizon_map, &"stone")
	_set_resource_cell(short_horizon_map, &"timber", 0, 500.0)
	_set_resource_cell(short_horizon_map, &"stone", 0, 500.0)
	var short_horizon: Dictionary = EconomyTestBootstrapScript.build(
		short_horizon_map, facade, 42)
	var short_fallbacks: Dictionary = short_horizon.get(
		"construction_source_root_fallback_counts", {})
	_expect("one-year construction roots start a map below the normal ten-year runway",
		bool(short_horizon.get("ok", false)) and
		int(short_fallbacks.get("timber_collector", 0)) > 0 and
		int(short_fallbacks.get("stone_collector", 0)) > 0)
	var isolated_incomplete_map := _make_partitioned_source_map()
	var isolated_incomplete: Dictionary = EconomyTestBootstrapScript.build(
		isolated_incomplete_map, facade, 42)
	var isolated_building_cells: PackedInt32Array = isolated_incomplete.get(
		"building_packet", {}).get("building_cells", PackedInt32Array())
	_expect("incomplete isolated candidate stays empty without aborting a closed mainland " +
		"ok=%s candidates=%d skipped=%d cell3=%s" % [
			str(bool(isolated_incomplete.get("ok", false))),
			int(isolated_incomplete.get(
				"construction_source_candidate_component_count", 0)),
			(isolated_incomplete.get(
				"construction_source_skipped_components", []) as Array).size(),
			str(isolated_building_cells.find(3) >= 0),
		],
		bool(isolated_incomplete.get("ok", false)) and
		int(isolated_incomplete.get(
			"construction_source_candidate_component_count", 0)) == 2 and
		(isolated_incomplete.get(
			"construction_source_skipped_components", []) as Array).size() == 1 and
		isolated_building_cells.find(3) < 0)
	var first_ok := bool(first.get("ok", false))
	var same_ok := bool(same.get("ok", false))
	_expect("fixture builds" if first_ok else "fixture builds: %s" %
		String(first.get("reason", "unknown")), first_ok)
	_expect("repeated fixture builds" if same_ok else "repeated fixture builds: %s" %
		String(same.get("reason", "unknown")), same_ok)
	if not first_ok or not same_ok:
		_finish()
		return
	_expect("10x stress fixture expands populated cells into hundreds",
		_stress_population_matches_baseline(first, stress_hundreds, 10, 100))
	_expect("10x fixture rebalances buildings by demand, inputs, and safe resource yield",
		_demand_balanced_supply_valid(first, stress_hundreds, 10))
	_expect("100x stress fixture expands populated cells into thousands",
		_stress_population_matches_baseline(first, stress_thousands, 100, 1000))
	_expect("1000x stress fixture expands populated cells into ten-thousands",
		_stress_population_matches_baseline(
			first, stress_ten_thousands, 1000, 10000))
	_expect("resource-tiered fixture ranks cells and caps population by generated jobs",
		_resource_tiered_population_valid(first, resource_tiered) and
		_fixture_respects_renewable_safe_yield(
			resource_tiered, facade, map) and
		bool(resource_tiered.get("employment_acceptance_ok", false)) and
		int(resource_tiered.get("initial_job_coverage_q16", 0)) >=
			int(resource_tiered.get("target_employment_q16", 65537)))
	print("[economy-test-bootstrap/tiered] population=%d jobs=%d coverage=%.1f%% trimmed=%d unemployed=%d" % [
		int(resource_tiered.get("total_population", 0)),
		int(resource_tiered.get("total_job_capacity", 0)),
		float(resource_tiered.get("initial_job_coverage_q16", 0)) *
			100.0 / 65536.0,
		int(resource_tiered.get("job_limited_population_trimmed", 0)),
		int(resource_tiered.get("initial_unemployed_population", -1)),
	])
	_expect("only land cells with a quantitatively closed input chain are populated",
		int(first.get("populated_cells", 0)) >= 1 and
		int(first.get("populated_cells", 0)) +
			int(first.get("basic_capacity_deficient_cells", 0)) == 2)
	var catalog_buildings: PackedStringArray = facade.building_type_ids()
	var communal_hearth_jobs: Dictionary = facade.building_job_spec(&"communal_hearth")
	_expect("communal hearth uses an artisan owner and an early apprentice position",
		bool(communal_hearth_jobs.get("ok", false)) and
		String(communal_hearth_jobs.get("owner_profession", "")) == "artisan" and
		communal_hearth_jobs.get("employee_professions", PackedStringArray()).has("apprentice") and
		(communal_hearth_jobs.get("employee_slots", PackedInt64Array()) as PackedInt64Array).size() == 1 and
		int((communal_hearth_jobs.get("employee_slots", PackedInt64Array()) as PackedInt64Array)[0]) == 1)
	_expect("fixture is restricted to a sparse mid-stone subset",
		int(first.get("building_group_count", 0)) > 0 and
		int(first.get("eligible_building_type_count", 0)) < catalog_buildings.size() / 4 and
		_fixture_uses_only_mid_stone_buildings(first, facade))
	_expect("bootstrap creates exactly one merchant post per populated cell",
		_fixture_has_one_merchant_post_per_populated_cell(first, facade))
	_expect("professions follow actual local building jobs",
		int(first.get("generated_profession_count", 0)) > 1 and
		int(first.get("generated_profession_count", 0)) <= facade.profession_ids().size())
	_expect("population follows actual jobs with only the employment-target remainder unemployed",
		_population_matches_fixture(first, facade))
	_expect("bootstrap reports formula-based initial finance source",
		String(first.get("population_source", "")) ==
			"resource_tiered_complete_chain_test_bootstrap_v21" and
		String(first.get("collector_placement_model", "")) ==
			"resource_backed_complete_chain_v18" and
		int(first.get("initial_resource_horizon_days", 0)) == 3650 and
		int(first.get("cell_population_cap", 0)) == 300 and
		String(first.get("initial_employment", "")) == "unemployed")
	_expect("carrying-capacity balancing honors demand-calibrated collector caps",
		int(first.get("basic_capacity_initial_buildings", 0)) >=
			int(first.get("basic_capacity_final_buildings", 0)) and
		int(first.get("basic_capacity_initial_buildings", 0)) -
			int(first.get("basic_capacity_final_buildings", 0)) ==
			int(first.get("basic_capacity_trimmed_buildings", 0)) and
		_max_building_group_count(first) > 1 and
		_max_building_group_count(first) <= 24 and
		_fixture_respects_test_collector_caps(first, facade))
	_expect("every initial collector is backed by its own cell resources",
		_fixture_collectors_use_local_resources(first, facade, map))
	_expect("each passable cell population follows its zero-to-300 carrying capacity",
		_population_matches_carrying_capacity(first) and
		int(first.get("carrying_capacity_total", -1)) == int(first.get("total_population", 0)))
	_expect("all cohorts receive survival funds and owner/merchant additions reconcile",
		_fixture_bootstrap_finance_reconciles(first, facade))
	_expect("every populated fixture cell covers conservative food and clothing demand",
		_basic_capacity_is_covered(first))
	_expect("same seed is deterministic",
		first.population_packet.population == same.population_packet.population and
		first.population_packet.funds == same.population_packet.funds)
	_expect("fixture supplies household, building-input, and construction bridge stock",
		not first.market_packet.is_empty() and
		int(first.get("initial_household_stock_days", 0)) == 1 and
		int(first.get("initial_building_input_stock_days", 0)) == 1 and
		int(first.get("initial_household_stock_units", 0)) > 0 and
		int(first.get("initial_building_input_stock_units", 0)) > 0 and
		int(first.get("initial_bridge_stock_units", -1)) ==
			int(first.get("populated_cells", 0)) * 1750 and
		int(first.get("initial_stock_units", 0)) ==
			int(first.get("initial_household_stock_units", 0)) +
			int(first.get("initial_building_input_stock_units", 0)) +
			int(first.get("initial_bridge_stock_units", 0)) and
		bool(first.get("construction_closure_ok", false)))
	var boot: Dictionary = facade.bootstrap(
		first.population_packet, first.market_packet, first.building_packet)
	_expect("native bootstrap accepts fixture", bool(boot.get("ok", false)))
	_expect("pre-seeded merchants require no native repair",
		int(boot.get("merchant_repairs", -1)) == 0)
	_expect("native bootstrap receives all building groups",
		int(boot.get("building_group_count", 0)) == int(first.building_group_count))
	var csv_test := _start_csv_recorder(ext, map, csv_resource_slot_ids, csv_resource_ids)
	_expect("native CSV v22 recorder starts", bool(csv_test.get("ok", false)) and
		int(csv_test.get("schema_version", 0)) == 22)
	var buildings: Dictionary = facade.building_cell_snapshot(0)
	var second_buildings: Dictionary = facade.building_cell_snapshot(1)
	_expect("closed-chain land receives a settlement and the broken chain stays empty",
		(buildings.get("group_type_ids", PackedInt32Array()) as PackedInt32Array).size() > 0 and
		(second_buildings.get("group_type_ids", PackedInt32Array()) as PackedInt32Array).is_empty())
	_expect("fertile soil and flint create their mid-stone chains",
		_has_building(buildings, "gathering_ground") and
		_has_building(buildings, "flint_quarry") and
		_has_building(buildings, "knapping_workshop"))
	_expect("complete stone-age material chain includes logging quarrying and lumber",
		_has_building(buildings, "timber_collector") and
		_has_building(buildings, "stone_collector") and
		_has_building(buildings, "lumber_plant"))
	_expect("wild game creates hunting only where its local tool chain is closed",
		_has_building(buildings, "stone_age_hunting_camp") and
		not _has_building(second_buildings, "stone_age_hunting_camp") and
		not _has_building(buildings, "wild_game_collector") and
		not _has_building(second_buildings, "wild_game_collector"))
	_expect("resource-backed stone-age bullion extraction is present",
		_has_building(buildings, "placer_gold_working") or
		_has_building(buildings, "surface_silver_working"))
	_expect("stone-age household weaving remains in the complete industry set",
		_has_building(buildings, "household_weaving_shelter"))
	_expect("stone food processing is demand-sized instead of fixed at two",
		_building_count(buildings, "communal_hearth") <= 2)
	_expect("stone tool fixture trims to one workshop after root-chain coverage",
		_building_count(buildings, "knapping_workshop") == 1)
	var initial_land: Dictionary = facade.population_cell_snapshot(0)
	var initial_second_land: Dictionary = facade.population_cell_snapshot(1)
	_expect("survival satisfaction alias matches the compatibility fields",
		int(initial_land.get("survival_satisfaction_q16", -1)) ==
			int(initial_land.get("satisfaction_q16", -2)) and
		initial_land.get("survival_satisfaction_by_cohort_q16", PackedInt32Array()) ==
			initial_land.get("satisfaction_by_cohort_q16", PackedInt32Array()))
	_expect("bootstrapped closed-chain population starts unemployed",
		_all_population_unemployed(initial_land) and
		int(initial_second_land.get("population", 0)) == 0)
	_expect("populated native market receives its complete startup stock",
		_market_stock_total(facade.market_cell_snapshot(0)) ==
			int(first.get("initial_stock_units", 0)) and
		_market_stock_total(facade.market_cell_snapshot(1)) == 0)
	var startup_market: Dictionary = facade.market_cell_snapshot(0)
	_expect("startup inventory covers food, clothing, construction, and real tool inputs",
		_good_stock(startup_market, "gathered_plants") > 0 and
		(_good_stock(startup_market, "fur") > 0 or
			_good_stock(startup_market, "cloth") > 0) and
		_good_stock(startup_market, "logs") > 0 and
		_good_stock(startup_market, "flint") > 0 and
		_good_stock(startup_market, "chipped_stone_tools") > 0)
	var cycle: Dictionary = _run_day(ext, 0)
	_expect("bootstrap economy cycle commits", bool(cycle.get("done", false)) and
		not bool(cycle.get("fatal", false)))
	var land: Dictionary = facade.population_cell_snapshot(0)
	var second_land: Dictionary = facade.population_cell_snapshot(1)
	var ocean: Dictionary = facade.population_cell_snapshot(2)
	var mountain: Dictionary = facade.population_cell_snapshot(3)
	_expect("only the viable land cell exposes resource-specific professions",
		int(land.get("cohort_count", 0)) > 1 and int(second_land.get("cohort_count", 0)) == 0)
	_expect("land has merchant", _sum_u8(land.get("merchant_flags", PackedByteArray())) >= 1)
	_expect("water and impassable cells stay empty", int(ocean.get("population", -1)) == 0 and int(mountain.get("population", -1)) == 0)
	_expect("demand preview CSR aligns with cohorts",
		(land.get("demand_good_offsets", PackedInt32Array()) as PackedInt32Array).size() ==
		int(land.get("cohort_count", 0)) + 1)
	_expect("employment and unemployment account for every generated person",
		_sum_i64(land.get("owner_employed_by_cohort", PackedInt64Array())) +
		_sum_i64(land.get("employee_employed_by_cohort", PackedInt64Array())) +
		_sum_i64(land.get("unemployed_by_cohort", PackedInt64Array())) ==
		_sum_i64(land.get("populations", PackedInt64Array())))
	_expect("employment logic hires after bootstrap",
		_sum_i64(land.get("owner_employed_by_cohort", PackedInt64Array())) > 0)
	_expect("first cycle leaves usable local goods after startup consumption",
		_market_stock_total(facade.market_cell_snapshot(0)) +
		_market_stock_total(facade.market_cell_snapshot(1)) > 0)
	_expect("phase-zero bullion output uses the audited monetary issue path",
		int(cycle.get("bullion_money_issued", 0)) > 0 and
		int(cycle.get("bullion_money_issued", 0)) ==
			int(cycle.get("gold_money_issued", 0)) +
			int(cycle.get("silver_money_issued", 0)))
	_expect("retired virtual mint is absent",
		not _has_building(buildings, "shell_money_station") and
		not _has_building(buildings, "stone_tool_exchange"))
	_expect("bootstrap cycle conserves population money and goods",
		int(cycle.get("population_error", 1)) == 0 and
		int(cycle.get("money_error", 1)) == 0 and int(cycle.get("goods_error", 1)) == 0)
	var substitute_stock: Dictionary = facade.add_stock(
		0, &"chipped_stone_tools", 100000, 1, 9001)
	_expect("stone tool substitute stock command is accepted",
		bool(substitute_stock.get("ok", false)))
	var second_cycle: Dictionary = _run_day(ext, 1)
	_expect("second cycle consumes category-compatible stone tools",
		bool(second_cycle.get("done", false)) and not bool(second_cycle.get("fatal", false)) and
		int(second_cycle.get("production_inputs_consumed", 0)) > 0)
	_expect("complete stone-age chain retains household weaving",
		_has_building(facade.building_cell_snapshot(0),
			"household_weaving_shelter"))
	var third_cycle: Dictionary = _run_day(ext, 2)
	_expect("third recorder cycle commits", bool(third_cycle.get("done", false)) and
		not bool(third_cycle.get("fatal", false)))
	_verify_csv_recorder(ext, csv_test, csv_resource_slot_ids, csv_resource_ids)
	var invalid_cell_start := _start_csv_recorder(
		ext, map, csv_resource_slot_ids, csv_resource_ids,
		5_000_000, false, 0, -1, PackedInt32Array([map.cell_count()]))
	_expect("CSV rejects an out-of-range explicit cell",
		not bool(invalid_cell_start.get("ok", true)) and
		str(invalid_cell_start.get("error_message", "")) == "cell_index_out_of_range")
	_cleanup_csv_paths(invalid_cell_start.get("test_paths", {}))
	var selected_cell_start := _start_csv_recorder(
		ext, map, csv_resource_slot_ids, csv_resource_ids,
		5_000_000, false, 0, -1, PackedInt32Array([0, 0]))
	_expect("single-cell CSV starts and normalizes duplicate indices",
		bool(selected_cell_start.get("ok", false)) and
		str(selected_cell_start.get("cell_scope", "")) == "selected" and
		int(selected_cell_start.get("sampled_cell_count", 0)) == 1 and
		int(selected_cell_start.get("selected_cell_index", -1)) == 0)
	_run_day(ext, 3)
	_verify_single_cell_csv(ext, selected_cell_start, 0)
	var overload_start := _start_csv_recorder(
		ext, map, csv_resource_slot_ids, csv_resource_ids, 5_000_000, true, 250)
	_expect("slow-writer recorder starts", bool(overload_start.get("ok", false)))
	_run_day(ext, 4)
	_run_day(ext, 5)
	_run_day(ext, 6)
	var overload_status := _wait_csv_terminal(ext)
	_expect("double buffer overload applies lossless writer backpressure",
		str(overload_status.get("state", "")) == "completed" and
		str(overload_status.get("error_code", "")) == "" and
		int(overload_status.get("captured_epochs", 0)) == 3 and
		int(overload_status.get("written_epochs", 0)) == 3 and
		int(overload_status.get("backpressure_wait_count", 0)) >= 1 and
		float(overload_status.get("backpressure_wait_ms_total", 0.0)) > 0.0 and
		int(overload_status.get("first_unrecorded_epoch", -1)) == -1)
	_cleanup_csv_paths(overload_start.get("test_paths", {}))
	var limit_start := _start_csv_recorder(
		ext, map, csv_resource_slot_ids, csv_resource_ids, 1, false, 0)
	_expect("row-limit recorder starts", bool(limit_start.get("ok", false)))
	_run_day(ext, 7)
	var limit_status := _wait_csv_terminal(ext)
	_expect("row limit rejects the whole epoch without partial rows",
		str(limit_status.get("error_code", "")) == "row_limit" and
		int(limit_status.get("captured_epochs", -1)) == 0 and
		int(limit_status.get("written_rows", -1)) == 0)
	_cleanup_csv_paths(limit_start.get("test_paths", {}))
	var failure_start := _start_csv_recorder(
		ext, map, csv_resource_slot_ids, csv_resource_ids, 5_000_000, false, 0, 32)
	_expect("write-failure recorder starts", bool(failure_start.get("ok", false)))
	_run_day(ext, 8)
	var failure_status := _wait_csv_terminal(ext)
	_expect("injected write failure reports one accepted but no committed file epoch",
		str(failure_status.get("error_code", "")) == "write_failed" and
		int(failure_status.get("captured_epochs", 0)) == 1 and
		int(failure_status.get("written_epochs", -1)) == 0)
	for path in (failure_start.get("test_paths", {}) as Dictionary).values():
		var text := FileAccess.get_file_as_string(str(path)).trim_prefix("﻿")
		_expect("write failure rolls every CSV back to its header",
			text.split("\n", false).size() == 1)
	_cleanup_csv_paths(failure_start.get("test_paths", {}))
	var soak_start: Dictionary = facade.population_cell_snapshot(0)
	var soak_start_population := _sum_i64(soak_start.get("populations", PackedInt64Array()))
	var soak_start_unemployed := _sum_i64(
		soak_start.get("unemployed_by_cohort", PackedInt64Array()))
	var soak_audits_ok := true
	var soak_supported := 0
	var soak_stocked := 0
	for day in range(9, 129):
		var soak_cycle := _run_day(ext, day)
		soak_audits_ok = soak_audits_ok and bool(soak_cycle.get("done", false)) and \
			not bool(soak_cycle.get("fatal", false)) and \
			int(soak_cycle.get("population_error", 1)) == 0 and \
			int(soak_cycle.get("money_error", 1)) == 0 and \
			int(soak_cycle.get("goods_error", 1)) == 0
		soak_supported += int(soak_cycle.get("production_output_supported", 0))
		soak_stocked += int(soak_cycle.get("production_output_stock", 0))
	var soak_final: Dictionary = facade.population_cell_snapshot(0)
	var soak_final_population := _sum_i64(soak_final.get("populations", PackedInt64Array()))
	var soak_final_unemployed := _sum_i64(
		soak_final.get("unemployed_by_cohort", PackedInt64Array()))
	var soak_support_q16 := int(soak_supported * 65536 / maxi(1, soak_stocked))
	print("[economy-test-bootstrap/soak] population=%d->%d unemployed=%d->%d support=%.1f%%" % [
		soak_start_population, soak_final_population,
		soak_start_unemployed, soak_final_unemployed,
		float(soak_support_q16) * 100.0 / 65536.0,
	])
	_expect("120-cycle calibrated bootstrap conserves every ledger", soak_audits_ok)
	_expect("120-cycle demand-driven bootstrap remains a populated settlement",
		soak_final_population > 0 and
		soak_final_population * 4 >= soak_start_population)
	_expect("120-cycle demand-balanced bootstrap ends below 35 percent unemployment",
		soak_final_unemployed * 100 <= maxi(1, soak_final_population) * 35)
	_expect("120-cycle calibrated bootstrap keeps producer support below 90 percent",
		soak_support_q16 <= int(0.90 * 65536))
	_finish()


func _make_map() -> MapData:
	var map := MapData.new(4, 1)
	for col in range(4):
		var cube := HexUtils.offset_to_cube(col, 0)
		var cell := HexCell.new(cube.x, cube.y)
		cell.terrain = [TerrainType.TERRAIN.PLAIN, TerrainType.TERRAIN.PLAIN,
			TerrainType.TERRAIN.OCEAN, TerrainType.TERRAIN.MOUNTAIN][col]
		map.set_cell(cell)
	map._build_indices()
	map.terrain_arr = PackedByteArray([
		TerrainType.TERRAIN.PLAIN,
		TerrainType.TERRAIN.PLAIN,
		TerrainType.TERRAIN.OCEAN,
		TerrainType.TERRAIN.MOUNTAIN,
	])
	ResourceProfileRegistry.ensure_loaded()
	for profile in ResourceProfileRegistry.ordered():
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field == "":
			continue
		var values := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
		if String(profile.id) in ["fertile_soil", "flint", "gold_ore", "stone"]:
			values[0] = 1000000.0
		elif String(profile.id) == "wild_game":
			values[0] = 1000000.0
			values[1] = 1000000.0
		elif String(profile.id) == "timber":
			values[0] = 1000000.0
			values[1] = 1000000.0
		elif String(profile.id) in ["rare_earth", "silver_ore"]:
			values[1] = 1000000.0
		map.set(field, values)
	return map


func _make_partitioned_source_map() -> MapData:
	# 地图横向环绕，因此孤立陆格两侧都必须用海格隔开。
	var map := MapData.new(6, 1)
	var terrains := PackedByteArray([
		TerrainType.TERRAIN.PLAIN,
		TerrainType.TERRAIN.PLAIN,
		TerrainType.TERRAIN.OCEAN,
		TerrainType.TERRAIN.PLAIN,
		TerrainType.TERRAIN.OCEAN,
		TerrainType.TERRAIN.OCEAN,
	])
	for col in range(6):
		var cube := HexUtils.offset_to_cube(col, 0)
		var cell := HexCell.new(cube.x, cube.y)
		cell.terrain = terrains[col]
		map.set_cell(cell)
	map._build_indices()
	map.terrain_arr = terrains
	ResourceProfileRegistry.ensure_loaded()
	for profile in ResourceProfileRegistry.ordered():
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field == "":
			continue
		var values := PackedFloat32Array()
		values.resize(6)
		values.fill(0.0)
		if String(profile.id) in ["fertile_soil", "flint", "stone"]:
			values[0] = 1000000.0
		elif String(profile.id) == "timber":
			values[0] = 1000000.0
			values[1] = 1000000.0
			values[3] = 1000000.0
		elif String(profile.id) == "wild_game":
			values[0] = 1000000.0
			values[1] = 1000000.0
			values[3] = 1000000.0
		map.set(field, values)
	return map


func _make_distributed_source_map() -> MapData:
	# No cell can close food, clothing, tools and construction inputs alone, but
	# the four connected land cells form one quantitatively viable trade region.
	var map := MapData.new(4, 1)
	var terrains := PackedByteArray([
		TerrainType.TERRAIN.PLAIN,
		TerrainType.TERRAIN.PLAIN,
		TerrainType.TERRAIN.PLAIN,
		TerrainType.TERRAIN.PLAIN,
	])
	for col in range(4):
		var cube := HexUtils.offset_to_cube(col, 0)
		var cell := HexCell.new(cube.x, cube.y)
		cell.terrain = terrains[col]
		map.set_cell(cell)
	map._build_indices()
	map.terrain_arr = terrains
	ResourceProfileRegistry.ensure_loaded()
	for profile in ResourceProfileRegistry.ordered():
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field == "":
			continue
		var values := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
		match String(profile.id):
			"fertile_soil":
				values[0] = 1000000.0
			"flint":
				values[1] = 1000000.0
			"timber", "wild_game":
				values[2] = 1000000.0
			"stone":
				values[3] = 1000000.0
		map.set(field, values)
	return map


func _resource_values(map: MapData, resource_id: StringName) -> PackedFloat32Array:
	for profile in ResourceProfileRegistry.ordered():
		if StringName(profile.id) != resource_id:
			continue
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		return map.get(field) if field != "" else PackedFloat32Array()
	return PackedFloat32Array()


func _clear_resource(map: MapData, resource_id: StringName) -> void:
	for profile in ResourceProfileRegistry.ordered():
		if StringName(profile.id) != resource_id:
			continue
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field != "":
			var values := PackedFloat32Array()
			values.resize(map.cell_count())
			values.fill(0.0)
			map.set(field, values)
		return


func _set_resource_cell(map: MapData, resource_id: StringName,
		cell_idx: int, value: float) -> void:
	for profile in ResourceProfileRegistry.ordered():
		if StringName(profile.id) != resource_id:
			continue
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field != "":
			var values: PackedFloat32Array = map.get(field)
			values[cell_idx] = value
			map.set(field, values)
		return


func _start_csv_recorder(ext: Object, map: MapData, resource_slots: PackedInt32Array,
		resource_ids: PackedStringArray, max_rows: int = 5_000_000,
		summary_only: bool = false, test_write_delay_ms: int = 0,
		test_fail_after_bytes: int = -1,
		cell_indices: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	var q := PackedInt32Array()
	var r := PackedInt32Array()
	var s := PackedInt32Array()
	q.resize(map.cell_count())
	r.resize(map.cell_count())
	s.resize(map.cell_count())
	for idx in range(map.cell_count()):
		var cell = map.cell_at(idx)
		q[idx] = cell.q
		r[idx] = cell.r
		s[idx] = cell.s
	var dir := ProjectSettings.globalize_path("user://economy_csv_v6_test")
	DirAccess.make_dir_recursive_absolute(dir)
	var paths := {}
	for dim in ["summary", "cohorts", "buildings", "resources", "market"]:
		paths[dim] = dir.path_join("integration_v6_%s.csv" % dim)
		if FileAccess.file_exists(paths[dim]):
			DirAccess.remove_absolute(paths[dim])
	var result: Dictionary = ext.start_economy_csv_recording({
		"record_summary": true,
		"record_cohorts": not summary_only,
		"record_buildings": not summary_only,
		"record_resources": not summary_only,
		"record_market": not summary_only,
		"cell_stride": 1,
		"cell_indices": cell_indices,
		"max_rows": max_rows,
		"test_write_delay_ms": test_write_delay_ms,
		"test_fail_after_bytes": test_fail_after_bytes,
		"q_arr": q,
		"r_arr": r,
		"s_arr": s,
		"resource_slot_ids": resource_slots,
		"resource_ids": resource_ids,
		"paths": paths,
	})
	result["test_paths"] = paths
	return result


func _verify_single_cell_csv(ext: Object, start_result: Dictionary,
		expected_cell: int) -> void:
	var status := _wait_csv_terminal(ext)
	_expect("single-cell CSV drains one accepted commit",
		str(status.get("state", "")) == "completed" and
		int(status.get("captured_epochs", 0)) == 1 and
		int(status.get("written_epochs", 0)) == 1)
	var paths: Dictionary = start_result.get("test_paths", {})
	var summary_lines := FileAccess.get_file_as_string(str(paths.summary)) \
		.trim_prefix("﻿").split("\n", false)
	_expect("summary remains one global row per selected-cell epoch", summary_lines.size() == 2)
	for dim in ["cohorts", "buildings", "resources", "market"]:
		var lines := FileAccess.get_file_as_string(str(paths[dim])) \
			.trim_prefix("﻿").split("\n", false)
		_expect("single-cell %s contains data" % dim, lines.size() > 1)
		for line_idx in range(1, lines.size()):
			var columns := lines[line_idx].split(",", true)
			_expect("single-cell %s row %d is filtered" % [dim, line_idx],
				columns.size() > 3 and int(columns[3]) == expected_cell)
	_cleanup_csv_paths(paths)


func _verify_csv_recorder(ext: Object, start_result: Dictionary,
		resource_slots: PackedInt32Array, resource_ids: PackedStringArray) -> void:
	ext.request_stop_economy_csv_recording()
	var status: Dictionary = ext.get_economy_csv_recording_status()
	var deadline := Time.get_ticks_msec() + 5000
	while str(status.get("state", "")) == "draining" and Time.get_ticks_msec() < deadline:
		OS.delay_msec(1)
		status = ext.get_economy_csv_recording_status()
	_expect("CSV worker drains asynchronously", str(status.get("state", "")) == "completed")
	_expect("CSV captures and writes exactly three commits",
		int(status.get("captured_epochs", 0)) == 3 and
		int(status.get("written_epochs", 0)) == 3)
	_expect("CSV reports no writer error", str(status.get("error_code", "")) == "")
	var paths: Dictionary = start_result.get("test_paths", {})
	var expected_columns := {"summary": 167, "cohorts": 26, "buildings": 78,
		"resources": 21, "market": 49}
	for dim in expected_columns:
		var path: String = str(paths.get(dim, ""))
		var bytes := FileAccess.get_file_as_bytes(path)
		_expect("%s CSV has UTF-8 BOM" % dim,
			bytes.size() >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF)
		var text := bytes.get_string_from_utf8().trim_prefix("﻿")
		var lines := text.split("\n", false)
		_expect("%s CSV contains data" % dim, lines.size() > 1)
		_expect("%s CSV header column count" % dim,
			lines[0].split(",", true).size() == int(expected_columns[dim]))
		for line_idx in range(1, lines.size()):
			_expect("%s CSV row %d column count" % [dim, line_idx],
				lines[line_idx].split(",", true).size() == int(expected_columns[dim]))
	var summary_text := FileAccess.get_file_as_string(str(paths.summary)).trim_prefix("﻿")
	var summary_header := summary_text.split("\n", false)[0].split(",", true)
	_expect("summary CSV v22 exposes portfolio, recovery, trade, procurement, and climate diagnostics",
		[
			"construction_goods_consumed", "building_investment_candidates",
			"building_owner_mobility", "building_owner_job_reallocations",
			"building_owner_job_profession_changes",
			"building_owner_job_probability_skips", "building_investments_started",
			"building_investment_blocked_funds",
			"building_investment_blocked_materials",
			"building_investment_probability_skips",
			"trade_response_deadline_misses_cumulative",
			"merchant_credit_outstanding", "recovery_approved",
			"trade_candidates_arbitrated_out",
			"merchant_cash", "merchant_inventory_liquidation_value",
			"merchant_economic_assets", "merchant_procurement_margin_value",
			"merchant_trade_purchase_cash", "merchant_trade_sale_cash",
			"merchant_operating_outflow", "merchant_liquidity_coverage_q16",
			"merchant_effective_buy_factor_q16",
			"building_investment_buildings_started",
			"building_investment_portfolios_started",
			"building_investment_types_started",
			"building_investment_owner_population_moved",
			"building_investment_max_type_owner_share_q16",
			"recovery_partially_liquidated_buildings",
			"recovery_fully_liquidated_groups",
			"merchant_survival_procurement_required",
			"merchant_survival_procurement_allocated",
			"merchant_input_procurement_required",
			"merchant_input_procurement_allocated",
			"climate_profiled_building_groups",
			"climate_limited_building_groups",
			"average_climate_capacity_q16",
		].all(func(column: String) -> bool: return summary_header.has(column)))
	var building_text := FileAccess.get_file_as_string(str(paths.buildings)).trim_prefix("﻿")
	var building_lines := building_text.split("\n", false)
	var building_header := building_lines[0].split(",", true)
	_expect("building CSV v22 exposes climate production diagnostics",
		["last_temperature_fit_q16", "last_water_fit_q16",
			"last_climate_capacity_q16", "last_climate_lost_output"].all(
			func(column: String) -> bool: return building_header.has(column)))
	var owner_capacity_col := building_header.find("owner_capacity")
	var owner_required_col := building_header.find("owner_required")
	var planned_owner_equivalent_col := building_header.find("planned_owner_equivalent")
	var filled_owner_col := building_header.find("filled_owner")
	var owner_openings_col := building_header.find("owner_openings")
	var projected_owner_income_col := building_header.find(
		"projected_owner_income_per_day")
	var owner_columns_valid := owner_capacity_col >= 0 and owner_required_col >= 0 \
		and planned_owner_equivalent_col >= 0 \
		and filled_owner_col >= 0 and owner_openings_col >= 0 \
		and projected_owner_income_col >= 0
	var owner_rows_valid := owner_columns_valid
	for line in building_lines.slice(1):
		var columns := line.split(",", true)
		if columns.size() != int(expected_columns.buildings) or int(columns[7]) != 0:
			continue
		var capacity := int(columns[owner_capacity_col])
		var required := int(columns[owner_required_col])
		var planned_equivalent := int(columns[planned_owner_equivalent_col])
		var filled := int(columns[filled_owner_col])
		var openings := int(columns[owner_openings_col])
		if required != capacity or planned_equivalent > required \
				or openings != maxi(0, required - filled):
			owner_rows_valid = false
			break
	_expect("building CSV v22 separates jobs and exposes aggregate debt",
		owner_columns_valid and owner_rows_valid and
		building_header.has("merchant_debt_principal") and
		building_header.has("last_in_kind_livelihood_value"))
	if not resource_slots.is_empty() and not resource_ids.is_empty():
		var reserves: PackedFloat32Array = ext.snapshot_f32(resource_slots[0])
		var resource_text := FileAccess.get_file_as_string(str(paths.resources)).trim_prefix("﻿")
		var resource_header := resource_text.split("\n", false)[0].split(",", true)
		var reserve_col := resource_header.find("reserve")
		var pending_col := resource_header.find("artificial_change_pending")
		var found := false
		for line in resource_text.split("\n", false).slice(1):
			var cols := line.split(",", true)
			if cols.size() == int(expected_columns.resources) and int(cols[0]) == 3 and int(cols[3]) == 0 \
					and cols[7] == resource_ids[0]:
				found = reserve_col >= 0 and is_equal_approx(float(cols[reserve_col]), reserves[0])
				break
		_expect("resource CSV uses post-delta committed slot value", found)
		var wild_pending_is_local := false
		for line in resource_text.split("\n", false).slice(1):
			var cols := line.split(",", true)
			if cols.size() == int(expected_columns.resources) and int(cols[3]) == 0 and cols[7] == "wild_game" \
					and pending_col >= 0 and float(cols[pending_col]) < 0.0:
				wild_pending_is_local = true
				break
		_expect("resource CSV maps native artificial deltas by stable resource id",
			wild_pending_is_local)
	var market_snapshot: Dictionary = ext.get_market_cell_snapshot(0)
	var market_goods: PackedStringArray = market_snapshot.get("good_ids", PackedStringArray())
	var market_pressure: PackedInt32Array = market_snapshot.get(
		"price_pressure_total_q16", PackedInt32Array())
	if not market_goods.is_empty() and not market_pressure.is_empty():
		var market_text := FileAccess.get_file_as_string(str(paths.market)).trim_prefix("﻿")
		var market_header := market_text.split("\n", false)[0].split(",", true)
		var pressure_col := market_header.find("price_pressure_total_q16")
		var pressure_matches := false
		for line in market_text.split("\n", false).slice(1):
			var cols := line.split(",", true)
			if cols.size() == int(expected_columns.market) and int(cols[0]) == 3 and int(cols[3]) == 0 \
					and cols[7] == market_goods[0]:
				pressure_matches = pressure_col >= 0 and int(cols[pressure_col]) == market_pressure[0]
				break
		_expect("worker price-pressure encoding matches committed native snapshot",
			pressure_matches)
	_cleanup_csv_paths(paths)


func _wait_csv_terminal(ext: Object) -> Dictionary:
	ext.request_stop_economy_csv_recording()
	var status: Dictionary = ext.get_economy_csv_recording_status()
	var deadline := Time.get_ticks_msec() + 5000
	while str(status.get("state", "")) in ["opening", "recording", "draining"] \
			and Time.get_ticks_msec() < deadline:
		OS.delay_msec(1)
		status = ext.get_economy_csv_recording_status()
	return status


func _cleanup_csv_paths(paths: Dictionary) -> void:
	for path in paths.values():
		DirAccess.remove_absolute(str(path))


func _sum_u8(values: PackedByteArray) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _max_building_group_count(fixture: Dictionary) -> int:
	var packet: Dictionary = fixture.get("building_packet", {})
	var counts: PackedInt64Array = packet.get("building_counts", PackedInt64Array())
	var maximum := 0
	for count in counts:
		maximum = maxi(maximum, int(count))
	return maximum


func _fixture_has_one_merchant_post_per_populated_cell(
		fixture: Dictionary, facade) -> bool:
	var packet: Dictionary = fixture.get("building_packet", {})
	var cells: PackedInt32Array = packet.get("building_cells", PackedInt32Array())
	var type_ids: PackedInt32Array = packet.get("building_type_ids", PackedInt32Array())
	var counts: PackedInt64Array = packet.get("building_counts", PackedInt64Array())
	var stable_ids: PackedStringArray = facade.building_type_ids()
	if cells.size() != type_ids.size() or cells.size() != counts.size():
		return false
	var merchant_cells := {}
	for i in range(type_ids.size()):
		var type_id := int(type_ids[i])
		if type_id < 0 or type_id >= stable_ids.size():
			return false
		if stable_ids[type_id] != "merchant_post":
			continue
		if int(counts[i]) != 1 or merchant_cells.has(int(cells[i])):
			return false
		merchant_cells[int(cells[i])] = true
	return merchant_cells.size() == int(fixture.get("populated_cells", 0))


func _population_matches_carrying_capacity(fixture: Dictionary) -> bool:
	var capacity_cells: PackedInt32Array = fixture.get(
		"carrying_capacity_cell_indices", PackedInt32Array())
	var capacities: PackedInt64Array = fixture.get(
		"carrying_capacity_population", PackedInt64Array())
	var packet: Dictionary = fixture.get("population_packet", {})
	var population_cells: PackedInt32Array = packet.get("cell_indices", PackedInt32Array())
	var populations: PackedInt64Array = packet.get("population", PackedInt64Array())
	if capacity_cells.is_empty() or capacity_cells.size() != capacities.size() or \
			population_cells.size() != populations.size():
		return false
	var population_by_cell := {}
	for cohort in range(population_cells.size()):
		var cell := int(population_cells[cohort])
		population_by_cell[cell] = int(population_by_cell.get(cell, 0)) + int(populations[cohort])
	var distinct_capacities := {}
	for i in range(capacity_cells.size()):
		var capacity := int(capacities[i])
		if capacity < 0 or capacity > 300 or \
				int(population_by_cell.get(int(capacity_cells[i]), 0)) != capacity:
			return false
		distinct_capacities[capacity] = true
	return distinct_capacities.size() > 1


func _stress_population_matches_baseline(
		baseline: Dictionary, stress: Dictionary, scale: int,
		expected_minimum: int) -> bool:
	if not bool(stress.get("ok", false)) or int(stress.get("population_scale", 0)) != scale \
			or String(stress.get("population_scale_mode", "")) != "uniform_stress":
		return false
	var base_cells: PackedInt32Array = baseline.get(
		"carrying_capacity_cell_indices", PackedInt32Array())
	var base_populations: PackedInt64Array = baseline.get(
		"carrying_capacity_population", PackedInt64Array())
	var stress_cells: PackedInt32Array = stress.get(
		"carrying_capacity_cell_indices", PackedInt32Array())
	var stress_populations: PackedInt64Array = stress.get(
		"carrying_capacity_population", PackedInt64Array())
	if base_cells != stress_cells or base_populations.size() != stress_populations.size():
		return false
	var maximum := 0
	for i in range(base_populations.size()):
		if int(stress_populations[i]) != int(base_populations[i]) * scale:
			return false
		maximum = maxi(maximum, int(stress_populations[i]))
	return maximum >= expected_minimum and \
		int(stress.get("cell_population_cap", 0)) == 300 * scale


func _demand_balanced_supply_valid(
		baseline: Dictionary, scaled: Dictionary, scale: int) -> bool:
	if String(scaled.get("building_scale_model", "")) != \
			"household_demand_input_fixed_point_safe_yield_v2" or \
			int(scaled.get("resource_building_runway_days", 0)) != 3650 or \
			int(scaled.get("renewable_safe_harvest_q16", 0)) != 32768:
		return false
	var baseline_buildings: PackedInt64Array = baseline.get(
		"building_packet", {}).get("building_counts", PackedInt64Array())
	var scaled_buildings: PackedInt64Array = scaled.get(
		"building_packet", {}).get("building_counts", PackedInt64Array())
	if baseline_buildings.size() != scaled_buildings.size():
		return false
	var demand_trimmed := false
	for i in range(baseline_buildings.size()):
		if scaled_buildings[i] <= 0 or scaled_buildings[i] > baseline_buildings[i] * scale:
			return false
		demand_trimmed = demand_trimmed or \
			scaled_buildings[i] < baseline_buildings[i] * scale
	var baseline_household := int(baseline.get("initial_household_stock_units", 0))
	var scaled_household := int(scaled.get("initial_household_stock_units", 0))
	var scaled_population := int(scaled.get("total_population", 0))
	return demand_trimmed and scaled_population > 0 and \
		int(scaled.get("initial_building_input_stock_units", 0)) > 0 and \
		int(scaled.get("initial_bridge_stock_units", -1)) == \
			int(baseline.get("initial_bridge_stock_units", 0)) and \
		scaled_household > baseline_household


func _resource_tiered_population_valid(
		baseline: Dictionary, tiered: Dictionary) -> bool:
	if not bool(tiered.get("ok", false)) or \
			String(tiered.get("population_scale_mode", "")) != "resource_tiered":
		return false
	var base: PackedInt64Array = baseline.get(
		"carrying_capacity_population", PackedInt64Array())
	var scaled: PackedInt64Array = tiered.get(
		"carrying_capacity_population", PackedInt64Array())
	var scales: PackedInt32Array = tiered.get(
		"population_scales_by_cell", PackedInt32Array())
	var scores: PackedInt64Array = tiered.get(
		"resource_population_scores", PackedInt64Array())
	if base.size() != scaled.size() or base.size() != scales.size() \
			or base.size() != scores.size():
		return false
	var seen := {}
	for i in range(base.size()):
		if scaled[i] > base[i] * scales[i]:
			return false
		if base[i] > 0:
			seen[int(scales[i])] = true
	for scale in seen:
		if int(scale) not in [1, 10, 100, 500]:
			return false
	for i in range(base.size()):
		if base[i] <= 0:
			continue
		for j in range(base.size()):
			if base[j] > 0 and scores[i] < scores[j] and scales[i] > scales[j]:
				return false
	var jobs: PackedInt64Array = tiered.get(
		"job_capacity_by_cell", PackedInt64Array())
	if jobs.size() != scaled.size() or \
			int(tiered.get("target_employment_q16", 0)) != 65536 or \
			int(tiered.get("initial_unemployed_population", -1)) != 0:
		return false
	for i in range(scaled.size()):
		if scaled[i] > jobs[i]:
			return false
	return not seen.is_empty()


func _fixture_respects_test_collector_caps(fixture: Dictionary, facade) -> bool:
	var packet: Dictionary = fixture.get("building_packet", {})
	var type_ids: PackedInt32Array = packet.get("building_type_ids", PackedInt32Array())
	var counts: PackedInt64Array = packet.get("building_counts", PackedInt64Array())
	var stable_ids: PackedStringArray = facade.building_type_ids()
	var caps := {
		"flint_quarry": 1,
		"household_weaving_shelter": 2,
		"placer_gold_working": 1,
		"stone_age_hunting_camp": 12,
		"stone_collector": 1,
		"surface_silver_working": 1,
		"timber_collector": 3,
	}
	if type_ids.size() != counts.size():
		return false
	for i in range(type_ids.size()):
		var type_id := int(type_ids[i])
		if type_id < 0 or type_id >= stable_ids.size():
			return false
		var stable_id := String(stable_ids[type_id])
		if caps.has(stable_id) and int(counts[i]) > int(caps[stable_id]):
			return false
	return true


func _fixture_collectors_use_local_resources(
		fixture: Dictionary, facade, map: MapData) -> bool:
	var packet: Dictionary = fixture.get("building_packet", {})
	var cells: PackedInt32Array = packet.get("building_cells", PackedInt32Array())
	var type_ids: PackedInt32Array = packet.get("building_type_ids", PackedInt32Array())
	var stable_ids: PackedStringArray = facade.building_type_ids()
	if cells.size() != type_ids.size():
		return false
	var resource_fields := {}
	for profile in ResourceProfileRegistry.ordered():
		resource_fields[StringName(profile.id)] = \
			ResourceProfileRegistry.reserve_map_field(profile)
	for i in range(type_ids.size()):
		var type_id := int(type_ids[i])
		if type_id < 0 or type_id >= stable_ids.size():
			return false
		var spec: Dictionary = facade.building_placement_spec(
			StringName(stable_ids[type_id]))
		if int(spec.get("kind", -1)) != 0:
			continue
		for resource_id in spec.get("resource_ids", PackedStringArray()):
			var field := String(resource_fields.get(StringName(resource_id), ""))
			if field == "":
				return false
			var reserves: PackedFloat32Array = map.get(field)
			var cell := int(cells[i])
			if cell < 0 or cell >= reserves.size() or reserves[cell] <= 0.0:
				return false
	return true


func _fixture_respects_renewable_safe_yield(
		fixture: Dictionary, facade, map: MapData) -> bool:
	var packet: Dictionary = fixture.get("building_packet", {})
	var cells: PackedInt32Array = packet.get(
		"building_cells", PackedInt32Array())
	var type_ids: PackedInt32Array = packet.get(
		"building_type_ids", PackedInt32Array())
	var counts: PackedInt64Array = packet.get(
		"building_counts", PackedInt64Array())
	var stable_ids: PackedStringArray = facade.building_type_ids()
	if cells.size() != type_ids.size() or cells.size() != counts.size():
		return false
	var profiles := {}
	for profile in ResourceProfileRegistry.ordered():
		profiles[StringName(profile.id)] = profile
	for i in range(cells.size()):
		var type_id := int(type_ids[i])
		if type_id < 0 or type_id >= stable_ids.size():
			return false
		var spec: Dictionary = facade.building_placement_spec(
			StringName(stable_ids[type_id]))
		var resource_ids: PackedStringArray = spec.get(
			"resource_ids", PackedStringArray())
		var quantities: PackedInt64Array = spec.get(
			"resource_quantities", PackedInt64Array())
		var modes: PackedInt32Array = spec.get(
			"resource_modes", PackedInt32Array())
		for edge in range(mini(
				resource_ids.size(), mini(quantities.size(), modes.size()))):
			if int(modes[edge]) != 0 or int(quantities[edge]) <= 0:
				continue
			var profile = profiles.get(StringName(resource_ids[edge]))
			if profile == null or float(profile.ecology_capacity) <= 0.0 or \
					float(profile.ecology_growth_rate) <= 0.0:
				continue
			var field := ResourceProfileRegistry.reserve_map_field(profile)
			var reserves: PackedFloat32Array = map.get(field)
			var cell := int(cells[i])
			if cell < 0 or cell >= reserves.size():
				return false
			var capacity := float(profile.ecology_capacity) * \
				ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
			var reserve_floor := maxf(0.0, reserves[cell]) * 22938.0 / 65536.0
			var daily_yield := minf(
				maxf(0.0, reserves[cell] - reserve_floor), capacity / 8.0) * \
				float(profile.ecology_growth_rate) * 0.5
			var peak_per_building := float(quantities[edge]) / 1000.0
			var cap := int(floor(daily_yield / peak_per_building))
			if int(counts[i]) > maxi(1, cap):
				return false
	return true


func _has_building(snapshot: Dictionary, building_id: String) -> bool:
	return _building_count(snapshot, building_id) > 0


func _building_count(snapshot: Dictionary, building_id: String) -> int:
	var ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var counts: PackedInt64Array = snapshot.get("building_counts_by_type", PackedInt64Array())
	var idx := ids.find(building_id)
	return int(counts[idx]) if idx >= 0 and idx < counts.size() else 0


func _building_output_reconciles(snapshot: Dictionary, building_id: String) -> bool:
	var ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var groups: PackedInt32Array = snapshot.get("group_type_ids", PackedInt32Array())
	var output: PackedInt64Array = snapshot.get("last_output", PackedInt64Array())
	var sold: PackedInt64Array = snapshot.get("last_sold", PackedInt64Array())
	var retained: PackedInt64Array = snapshot.get("last_retained", PackedInt64Array())
	var discarded: PackedInt64Array = snapshot.get("last_discarded", PackedInt64Array())
	var type_id := ids.find(building_id)
	for i in range(groups.size()):
		if int(groups[i]) != type_id or i >= output.size() or i >= sold.size() \
				or i >= retained.size() or i >= discarded.size():
			continue
		if int(output[i]) > 0:
			return int(output[i]) == int(sold[i]) + int(retained[i]) + int(discarded[i])
	return false


func _fixture_uses_only_mid_stone_buildings(packet: Dictionary, facade) -> bool:
	var type_ids: PackedInt32Array = packet.building_packet.building_type_ids
	var stable_ids: PackedStringArray = facade.building_type_ids()
	for type_id in type_ids:
		if type_id < 0 or type_id >= stable_ids.size():
			return false
		var spec: Dictionary = facade.building_placement_spec(StringName(stable_ids[type_id]))
		for tag in spec.get("technology_tags", PackedStringArray()):
			var technology := String(tag)
			if technology.begins_with("tech.") and technology not in [
					"tech.hunting", "tech.gathering", "tech.stone_knapping", "tech.fire_control"]:
				return false
	return true


func _all_population_unemployed(snapshot: Dictionary) -> bool:
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	return not populations.is_empty() and \
		_sum_i64(snapshot.get("owner_employed_by_cohort", PackedInt64Array())) == 0 and \
		_sum_i64(snapshot.get("employee_employed_by_cohort", PackedInt64Array())) == 0 and \
		_sum_i64(snapshot.get("unemployed_by_cohort", PackedInt64Array())) == _sum_i64(populations)


func _all_market_stock_zero(snapshot: Dictionary) -> bool:
	return _market_stock_total(snapshot) == 0


func _market_stock_total(snapshot: Dictionary) -> int:
	return _sum_i64(snapshot.get("stock", PackedInt64Array()))


func _good_stock(snapshot: Dictionary, good_id: String) -> int:
	var ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var stock: PackedInt64Array = snapshot.get("stock", PackedInt64Array())
	var index := ids.find(good_id)
	return int(stock[index]) if index >= 0 and index < stock.size() else 0


func _population_matches_fixture(packet: Dictionary, facade) -> bool:
	var job_capacity := {}
	var building_packet: Dictionary = packet.building_packet
	var building_cells: PackedInt32Array = building_packet.building_cells
	var building_types: PackedInt32Array = building_packet.building_type_ids
	var building_counts: PackedInt64Array = building_packet.building_counts
	var planned_utilization_q16 := int(packet.get("planned_utilization_q16", 65536))
	if planned_utilization_q16 < 0 or planned_utilization_q16 > 65536:
		return false
	var building_ids: PackedStringArray = EconomyCatalogScript.compile_native_catalog().building_type_ids
	for i in range(building_counts.size()):
		var spec: Dictionary = facade.building_job_spec(
			StringName(building_ids[building_types[i]]))
		if not bool(spec.get("ok", false)):
			return false
		var owner_signature: int = facade.signature_id(StringName(spec.owner_profession), &"default")
		var owner_key := "%d:%d" % [building_cells[i], owner_signature]
		job_capacity[owner_key] = int(job_capacity.get(owner_key, 0)) + \
			int(building_counts[i]) * int(spec.owner_slots)
		var professions: PackedStringArray = spec.employee_professions
		var slots: PackedInt64Array = spec.employee_slots
		for role in range(professions.size()):
			var signature: int = facade.signature_id(StringName(professions[role]), &"default")
			var key := "%d:%d" % [building_cells[i], signature]
			var full_positions := int(building_counts[i]) * int(slots[role])
			var retained_positions := full_positions * planned_utilization_q16 / 65536
			if retained_positions == 0 and full_positions > 0 and planned_utilization_q16 > 0:
				retained_positions = 1
			job_capacity[key] = int(job_capacity.get(key, 0)) + \
				retained_positions
	var merchant_signature: int = facade.signature_id(&"merchant", &"default")
	var unemployed_signature: int = facade.signature_id(&"unemployed", &"default")
	var population_packet: Dictionary = packet.population_packet
	var cells: PackedInt32Array = population_packet.cell_indices
	var signatures: PackedInt32Array = population_packet.signature_ids
	var populations: PackedInt64Array = population_packet.population
	var actual := {}
	var totals_by_cell := {}
	for i in range(populations.size()):
		var key := "%d:%d" % [cells[i], signatures[i]]
		if actual.has(key):
			return false
		actual[key] = int(populations[i])
		totals_by_cell[cells[i]] = int(totals_by_cell.get(cells[i], 0)) + \
			int(populations[i])
		if signatures[i] != merchant_signature and \
				signatures[i] != unemployed_signature and \
				int(populations[i]) > int(job_capacity.get(key, 0)):
			return false
	var target_cells: PackedInt32Array = packet.get(
		"carrying_capacity_cell_indices", PackedInt32Array())
	var target_populations: PackedInt64Array = packet.get(
		"carrying_capacity_population", PackedInt64Array())
	if target_cells.size() != target_populations.size():
		return false
	for i in range(target_cells.size()):
		var cell := int(target_cells[i])
		var target := int(target_populations[i])
		if target <= 0:
			continue
		var merchant_key := "%d:%d" % [cell, merchant_signature]
		var expected_merchants := mini(
			target, int(job_capacity.get(merchant_key, 0)))
		if int(totals_by_cell.get(cell, -1)) != target or \
				int(actual.get(merchant_key, 0)) != expected_merchants:
			return false
	return true


func _fixture_bootstrap_finance_reconciles(packet: Dictionary, facade) -> bool:
	var population_packet: Dictionary = packet.population_packet
	var cells: PackedInt32Array = population_packet.cell_indices
	var signatures: PackedInt32Array = population_packet.signature_ids
	var funds: PackedInt64Array = population_packet.funds
	var survival: PackedInt64Array = packet.get("survival_funds_by_cohort", PackedInt64Array())
	var owners: PackedInt64Array = packet.get(
		"owner_operating_funds_by_cohort", PackedInt64Array())
	var merchants: PackedInt64Array = packet.get(
		"merchant_inventory_funds_by_cohort", PackedInt64Array())
	if survival.size() != funds.size() or owners.size() != funds.size() \
			or merchants.size() != funds.size() or int(packet.get("survival_fund_days", 0)) != 30:
		return false
	var merchant_signature: int = facade.signature_id(&"merchant", &"default")
	var funded_cells := {}
	var survival_total := 0
	var owner_total := 0
	var merchant_total := 0
	for i in range(funds.size()):
		if survival[i] < 0 or owners[i] < 0 or merchants[i] < 0 \
				or funds[i] != survival[i] + owners[i] + merchants[i]:
			return false
		survival_total += survival[i]
		owner_total += owners[i]
		merchant_total += merchants[i]
		if signatures[i] == merchant_signature and merchants[i] > 0:
			funded_cells[cells[i]] = true
	return survival_total == int(packet.get("initial_survival_funds", -1)) and \
		owner_total == int(packet.get("initial_owner_operating_funds", -1)) and \
		merchant_total == int(packet.get("initial_merchant_inventory_funds", -1)) and \
		funded_cells.size() == int(packet.get("populated_cells", -1))


func _basic_capacity_is_covered(fixture: Dictionary) -> bool:
	var populations: PackedInt64Array = fixture.get(
		"basic_capacity_population", PackedInt64Array())
	var food: PackedInt64Array = fixture.get("basic_food_capacity", PackedInt64Array())
	var clothing: PackedInt64Array = fixture.get(
		"basic_clothing_capacity", PackedInt64Array())
	if populations.is_empty() or populations.size() != food.size() or \
			populations.size() != clothing.size():
		return false
	var food_per_capita := int(fixture.get("food_requirement_per_capita", 0))
	var clothing_per_capita := int(fixture.get("clothing_requirement_per_capita", 0))
	if food_per_capita <= 0 or clothing_per_capita <= 0:
		return false
	for i in range(populations.size()):
		if int(populations[i]) <= 0 or \
				int(food[i]) < int(populations[i]) * food_per_capita or \
				int(clothing[i]) < int(populations[i]) * clothing_per_capita:
			return false
	return true


func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	var simulation_day := day * 5
	for slice in range(256):
		report = ext.run_economy_slice({
			"day_index": simulation_day,
			"tick_index": simulation_day * 1000 + slice,
		})
		if bool(report.get("done", false)):
			return report
	return report


func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures.append(label)


func _finish() -> void:
	if _failures.is_empty():
		print("[economy-test-bootstrap] PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("[economy-test-bootstrap] FAIL: %s" % failure)
	quit(1)
