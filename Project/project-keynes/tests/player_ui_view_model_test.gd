extends SceneTree


class CountingEconomyFacade extends RefCounted:
	var summary_calls := 0
	var population_calls := 0
	var market_calls := 0
	var building_calls := 0
	var settlement_generation := 7
	var population := 100

	func population_cell_summary(_cell_idx: int) -> Dictionary:
		summary_calls += 1
		return {"ok": true, "population": population, "cohort_count": 1,
			"settlement_generation": settlement_generation}

	func population_cell_snapshot(_cell_idx: int) -> Dictionary:
		population_calls += 1
		return {"ok": false}

	func market_cell_snapshot(_cell_idx: int) -> Dictionary:
		market_calls += 1
		return {"ok": false}

	func building_cell_snapshot(_cell_idx: int) -> Dictionary:
		building_calls += 1
		return {"ok": false}


class CountingGenerator extends RefCounted:
	var facade := CountingEconomyFacade.new()

	func get_economy_facade():
		return facade


func _initialize() -> void:
	var failures := PackedStringArray()
	var map := MapData.new(1, 1)
	map.res_timber_reserve_arr = PackedFloat32Array([12500.0])
	map.res_iron_ore_reserve_arr = PackedFloat32Array([10000.0])
	map.res_pasture_reserve_arr = PackedFloat32Array([80.0])

	var cell := HexCell.new(0, 0)
	cell.index = 0
	cell.terrain = TerrainType.TERRAIN.PLAIN
	cell.landform = LandformType.LF.PLAIN
	cell.vegetation = VegetationType.VEG.TEMPERATE_GRASSLAND
	cell.base_vegetation = VegetationType.VEG.TEMPERATE_GRASSLAND
	cell.cover = CoverType.CV.NONE
	cell.elevation = 0.55
	cell.moisture = 0.58
	cell.base_moisture = 0.50
	cell.temperature = 0.52
	cell.vegetation_vitality = 0.72

	var view_model := CellInspectorViewModel.new()
	view_model.set_context(map, null, null, null, 0.42, 22.0)
	var before_reserve := float(map.res_timber_reserve_arr[0])
	var model := view_model.build(cell)
	var counting_generator := CountingGenerator.new()
	var lazy_view_model := CellInspectorViewModel.new()
	lazy_view_model.set_context(map, counting_generator, null, null, 0.42, 22.0)
	lazy_view_model.build(cell)
	if counting_generator.facade.summary_calls != 1 \
			or counting_generator.facade.population_calls != 0 \
			or counting_generator.facade.market_calls != 0 \
			or counting_generator.facade.building_calls != 0:
		failures.append("initial dossier build queried hidden economy detail")
	lazy_view_model.build_tab_category(cell, "market")
	if counting_generator.facade.market_calls != 1 \
			or counting_generator.facade.population_calls != 0 \
			or counting_generator.facade.building_calls != 0:
		failures.append("lazy market tab queried unrelated economy detail")
	var population_revision := lazy_view_model.live_patch_revision(cell, "population")
	var population_patch := lazy_view_model.build_live_patch(
		cell, "population", false, population_revision.get("population_summary", {}))
	if int(population_revision.get("category_generation", -1)) != 7 \
			or population_patch.has("category") \
			or counting_generator.facade.population_calls != 0 \
			or counting_generator.facade.market_calls != 1:
		failures.append("population generation gate queried or built unchanged detail")
	var common_hash_before := int(population_revision.get("common_hash", 0))
	counting_generator.facade.population = 101
	var changed_revision := lazy_view_model.live_patch_revision(cell, "population")
	if int(changed_revision.get("common_hash", 0)) == common_hash_before \
			or int(changed_revision.get("category_generation", -1)) != 7:
		failures.append("population common hash did not track rendered summary independently")
	lazy_view_model.build_live_patch(cell, "population", true)
	if counting_generator.facade.population_calls != 1 \
			or counting_generator.facade.market_calls != 2:
		failures.append("dirty population generation did not build both detail snapshots")

	if model.is_empty():
		failures.append("view model returned an empty model")
	if String(model.get("header", {}).get("subtitle", "")).contains("cube"):
		failures.append("player header still exposes debug cube text")
	if String(model.get("header", {}).get("subtitle", "")).contains("档案 #"):
		failures.append("player header still exposes a redundant dossier number")
	var tabs: Array = model.get("tabs", [])
	if tabs.size() != 5:
		failures.append("expected five dossier tabs")
	var expected_tabs := ["geography", "population", "market", "buildings", "natural_resources"]
	var expected_labels := ["地理信息", "人口信息", "市场信息", "建筑", "自然资源"]
	for i in range(expected_tabs.size()):
		if i >= tabs.size() or String(tabs[i].get("id", "")) != expected_tabs[i] \
				or String(tabs[i].get("label", "")) != expected_labels[i]:
			failures.append("dossier tab order or label mismatch at %d" % i)
	if UITokens.format_compact_number_cn(12500.0, 2) != "1.25万":
		failures.append("Chinese compact number formatting regressed")

	for raw in model.get("summary_cards", []):
		var card: Dictionary = raw
		if String(card.get("id", "")).is_empty():
			failures.append("summary card missing stable id")
		if _is_legacy_icon(String(card.get("icon", ""))):
			failures.append("summary card still uses a legacy Unicode icon")
	if not _find_by_id(model.get("summary_cards", []), "summary_geo").is_empty():
		failures.append("summary still repeats terrain already shown in the title")
	if not _find_by_id(model.get("summary_cards", []), "summary_risk").is_empty():
		failures.append("summary still exposes the presentation-only risk heuristic")
	if (model.get("summary_cards", []) as Array).size() != 3:
		failures.append("summary should contain climate, population, and country")
	for summary_id in ["summary_climate", "summary_population", "summary_country"]:
		if _find_by_id(model.get("summary_cards", []), summary_id).is_empty():
			failures.append("summary missing %s" % summary_id)
	for hidden_summary_id in ["summary_market", "summary_resource"]:
		if not _find_by_id(model.get("summary_cards", []), hidden_summary_id).is_empty():
			failures.append("summary still displays %s" % hidden_summary_id)

	var categories: Dictionary = model.get("categories", {})
	if categories.size() != 1 or not categories.has("geography"):
		failures.append("initial dossier model eagerly built hidden tab data")
	for lazy_tab in ["population", "market", "buildings", "natural_resources"]:
		categories[lazy_tab] = view_model.build_tab_category(cell, lazy_tab)
	var geography: Dictionary = categories.get("geography", {})
	var physical: Dictionary = _find_section(geography.get("sections", []), "physical_geography")
	var climate: Dictionary = _find_section(geography.get("sections", []), "climate_hydrology")
	var ecology: Dictionary = _find_section(geography.get("sections", []), "vegetation_ecology")
	if physical.is_empty() or climate.is_empty() or ecology.is_empty():
		failures.append("geography tab is missing grouped sections")
	if _find_by_id(physical.get("metrics", []), "geography_terrain").is_empty() \
			or _find_by_id(physical.get("metrics", []), "geography_landform").is_empty():
		failures.append("geography tab is missing terrain or landform")
	if (climate.get("gauges", []) as Array).size() != 2:
		# Climate and hydrology are intentionally merged; require at least temp/moisture.
		if _find_by_id(climate.get("gauges", []), "climate_temp_gauge").is_empty() \
				or _find_by_id(climate.get("gauges", []), "climate_moisture_gauge").is_empty():
			failures.append("geography climate section is missing temperature or moisture")
	var initial_temp_chart := _find_by_id(climate.get("charts", []), "climate_temperature")
	var initial_temp_values: Array = initial_temp_chart.get("values", [])
	if initial_temp_values.size() != 1 or not is_equal_approx(float(initial_temp_values[0]), 0.52):
		failures.append("temperature chart did not start from the actual observed value")
	if float(initial_temp_chart.get("min_value", -1.0)) != 0.0 \
			or float(initial_temp_chart.get("max_value", -1.0)) != 1.0:
		failures.append("temperature chart did not keep a stable normalized axis")
	if int(initial_temp_chart.get("window_size", 0)) != CellInspectorViewModel.TEMPERATURE_HISTORY_CAPACITY:
		failures.append("temperature chart is missing its fixed right-growing window")
	for tab_id in categories.keys():
		var category: Dictionary = categories[tab_id]
		for raw in category.get("metrics", []):
			var metric: Dictionary = raw
			if String(metric.get("id", "")).is_empty():
				failures.append("%s metric missing stable id" % tab_id)
			if _is_legacy_icon(String(metric.get("icon", ""))):
				failures.append("%s metric uses a legacy Unicode icon" % tab_id)
		for raw in category.get("gauges", []):
			if String((raw as Dictionary).get("id", "")).is_empty():
				failures.append("%s gauge missing stable id" % tab_id)
		for raw in category.get("charts", []):
			if String((raw as Dictionary).get("id", "")).is_empty():
				failures.append("%s chart missing stable id" % tab_id)

	var resource_rows: Array = (categories.get("natural_resources", {}) as Dictionary).get("resource_rows", [])
	var expected_land_rows := ResourceProfileRegistry.ordered().filter(
		func(p): return ResourceProfileRegistry.habitat_available(p, 1)).size()
	if resource_rows.size() != expected_land_rows:
		failures.append("resource dossier must retain all habitat-valid rows for stable live updates")
	for raw in resource_rows:
		var row: Dictionary = raw
		if String(row.get("id", "")).is_empty():
			failures.append("resource row missing stable id")
		if _is_legacy_icon(String(row.get("icon", ""))):
			failures.append("resource row uses a legacy Unicode icon")
	var timber_row := _find_by_id(resource_rows, "timber")
	var iron_row := _find_by_id(resource_rows, "iron_ore")
	var pasture_row := _find_by_id(resource_rows, "pasture")
	if String(timber_row.get("density", "")) != "丰饶":
		failures.append("timber density did not use its resource-specific reference scale")
	if String(iron_row.get("density", "")) != "贫乏":
		failures.append("iron density still behaves like a raw absolute threshold")
	if pasture_row.is_empty() or String(pasture_row.get("icon", "")) != "livestock":
		failures.append("pasture capacity did not replace species livestock resource rows")
	var gated_resources: Array = view_model._resource_state(0, false, {
		"enforce_discovery": true,
		"technology_ids": PackedStringArray(),
		"enforce_extraction": true,
		"extractable_resource_ids": {&"timber": true, &"rare_earth": true},
	})
	if _find_by_id(gated_resources, "timber").is_empty() \
			or not _find_by_id(gated_resources, "rare_earth").is_empty() \
			or not _find_by_id(gated_resources, "iron_ore").is_empty():
		failures.append("resource dossier did not enforce discovery and extraction technology")

	var population_category: Dictionary = view_model._population_category({
		"ok": true,
		"population": 100,
		"funds": 40000000,
		"cohort_count": 1,
		"handles": PackedInt64Array([1]),
		"profession_ids": PackedInt32Array([0]),
		"ethnicity_ids": PackedInt32Array([0]),
		"profession_stable_ids": PackedStringArray(["worker"]),
		"ethnicity_stable_ids": PackedStringArray(["default"]),
		"profession_display_names": PackedStringArray(["工人"]),
		"ethnicity_display_names": PackedStringArray(["本地人口"]),
		"populations": PackedInt64Array([100]),
		"funds_by_cohort": PackedInt64Array([40000000]),
		"satisfaction_by_cohort_q16": PackedInt32Array([52428]),
		"merchant_flags": PackedByteArray([0]),
		"settlement_detail_available": true,
		"settlement_period_days": 5,
		"settlement_cashflow_source_stable_ids": PackedStringArray(["wages", "owner_operations", "merchant_household_sales", "merchant_business_sales", "transfer", "household_consumption", "producer_support_issuance"]),
		"settlement_cashflow_offsets": PackedInt32Array([0, 3]),
		"settlement_cashflow_source_indices": PackedInt32Array([0, 5, 6]),
		"settlement_cashflow_income": PackedInt64Array([1000000, 0, 500000]),
		"settlement_cashflow_expense": PackedInt64Array([0, 500000, 0]),
		"settlement_income_by_cohort": PackedInt64Array([1500000]),
		"settlement_expense_by_cohort": PackedInt64Array([500000]),
		"demand_good_offsets": PackedInt32Array([0, 2]),
		"demand_good_indices": PackedInt32Array([0, 1]),
		"demand_per_capita_daily": PackedInt64Array([800, 40]),
		"demand_good_stable_ids": PackedStringArray(["grain", "cloth", "fur", "clothing"]),
		"demand_need_stable_ids": PackedStringArray(["staple_food", "produce", "clothing"]),
		"demand_need_offsets": PackedInt32Array([0, 3]),
		"demand_need_indices": PackedInt32Array([0, 1, 2]),
		"demand_need_variant_offsets": PackedInt32Array([0, 1, 2, 5]),
		"demand_variant_component_offsets": PackedInt32Array([0, 1, 2, 3, 4, 5]),
		"demand_component_good_indices": PackedInt32Array([0, 0, 1, 2, 3]),
		"demand_component_per_capita_daily": PackedInt64Array([500, 300, 40, 0, 0]),
		"demand_preview_environment_ready": true,
	}, {
		"ok": true,
		"good_ids": PackedStringArray(["grain", "cloth", "fur", "clothing"]),
		"price": PackedInt32Array([12500, 25000, 24000, 32000]),
		"good_technology_available": PackedByteArray([1, 1, 1, 0]),
	})
	var cohort_rows: Array = population_category.get("cohort_rows", [])
	if cohort_rows.size() != 1 or not String(cohort_rows[0].get("wealth", "")).contains("40"):
		failures.append("population dossier did not calculate per-capita wealth")
	elif (cohort_rows[0].get("demand_rows", []) as Array).filter(
		func(row: Dictionary) -> bool: return bool(row.get("visible", false))
	).size() != 3:
		failures.append("population dossier did not expose positive and unlocked alternative demands")
	elif String(cohort_rows[0].get("income", "")) != "+1.5" \
			or String(cohort_rows[0].get("expense", "")) != "−0.5":
		failures.append("population dossier did not expose last-settlement per-capita cashflow")
	elif (cohort_rows[0].get("income_rows", []) as Array).size() != 2 \
			or (cohort_rows[0].get("expense_rows", []) as Array).size() != 1:
		failures.append("population dossier did not expose non-zero cashflow sources")
	elif String(_find_by_id(cohort_rows[0].get("income_rows", []),
			"income_producer_support_issuance").get("name", "")) != "托底收购":
		failures.append("population dossier did not label producer support issuance")
	elif String((cohort_rows[0].get("demand_summary", {}) as Dictionary).get("value", "")) \
			!= "2 项用途 · 3 种商品":
		failures.append("population dossier did not collapse demands into a readable summary")
	else:
		var demand_rows: Array = cohort_rows[0].get("demand_rows", [])
		var demand_groups: Array = cohort_rows[0].get("demand_groups", [])
		var grain_demand := _find_by_id(demand_rows, "demand_grain")
		var cloth_demand := _find_by_id(demand_rows, "demand_cloth")
		var fur_demand := _find_by_id(demand_rows, "demand_fur")
		var locked_clothing := _find_by_id(demand_rows, "demand_clothing")
		var demand_summary: Dictionary = cohort_rows[0].get("demand_summary", {})
		if String(grain_demand.get("quantity", "")) != "0.800" \
				or String(grain_demand.get("price", "")) != "1.25" \
				or String(grain_demand.get("daily_cost", "")) != "1":
			failures.append("population demand detail did not combine quantity with the local grain price")
		elif String(cloth_demand.get("daily_cost", "")) != "0.1" \
				or String(demand_summary.get("total_daily_cost", "")) != "1.1":
			failures.append("population demand detail did not calculate per-capita daily spending")
		elif demand_groups.size() != 2 \
				or String((demand_groups[0] as Dictionary).get("name", "")) != "食品" \
				or String((demand_groups[1] as Dictionary).get("name", "")) != "衣着" \
				or ((demand_groups[1] as Dictionary).get("rows", []) as Array).size() != 2:
			failures.append("population demand detail did not group goods by player-facing usage")
		elif demand_rows.any(func(row: Dictionary) -> bool:
			return String(row.get("category_text", "")).contains("替代品")):
			failures.append("population demand rows still expose redundant substitute wording")
		elif String(fur_demand.get("quantity", "")) != "0.000" \
				or not bool(fur_demand.get("visible", false)) \
				or not bool(fur_demand.get("is_unallocated_alternative", false)):
			failures.append("unlocked zero-allocation substitute disappeared from demand detail")
		elif bool(locked_clothing.get("visible", true)):
			failures.append("technology-locked substitute leaked into demand detail")

	var unavailable_population: Dictionary = view_model._population_category({
		"ok": true,
		"busy": true,
		"population": 1000,
		"funds": 400000000,
		"cohort_count": 4,
	})
	if _find_by_id(unavailable_population.get("insights", []),
			"population_details_unavailable").is_empty():
		failures.append("incomplete population snapshot did not report a query failure")

	var unavailable_market: Dictionary = view_model._market_category({
		"ok": true,
		"busy": true,
		"market_id": 0,
	})
	if _find_by_id(unavailable_market.get("insights", []),
			"market_details_unavailable").is_empty():
		failures.append("incomplete market snapshot did not report a query failure")
	var gated_market: Dictionary = view_model._market_category({
		"ok": true,
		"market_id": 0,
		"good_ids": PackedStringArray(["gathered_plants", "autonomous_systems"]),
		"good_technology_available": PackedByteArray([1, 0]),
		"stock": PackedInt64Array([1000, 0]),
		"price": PackedInt32Array([10000, 10000]),
		"demand_ema": PackedInt64Array([0, 0]),
		"business_demand_ema": PackedInt64Array([0, 0]),
		"offered_supply_ema": PackedInt64Array([0, 0]),
		"cost_anchor_price": PackedInt32Array([0, 0]),
		"shortage_q16": PackedInt32Array([0, 0]),
	})
	var gated_market_rows: Array = gated_market.get("market_rows", [])
	if gated_market_rows.size() != 1 \
			or String(gated_market_rows[0].get("id", "")) != "market_gathered_plants":
		failures.append("market dossier exposed technology-locked goods")

	var daily_cache := {}
	var first_delta: float = view_model._sample_daily_delta(daily_cache, "0:wheat_grain", 10.0, 4)
	var same_day_delta: float = view_model._sample_daily_delta(daily_cache, "0:wheat_grain", 20.0, 4)
	var next_day_delta: float = view_model._sample_daily_delta(daily_cache, "0:wheat_grain", 30.0, 5)
	var stable_delta: float = view_model._sample_daily_delta(daily_cache, "0:wheat_grain", 45.0, 5)
	if not is_nan(first_delta) or not is_nan(same_day_delta):
		failures.append("daily stock delta should remain unknown until the calendar day advances")
	if not is_equal_approx(next_day_delta, 20.0) or not is_equal_approx(stable_delta, 20.0):
		failures.append("daily stock delta was overwritten by same-day UI refreshes")
	if view_model._daily_delta_text(20.0) != "+20" or view_model._daily_delta_text(-3.0) != "-3":
		failures.append("market delta still contains a redundant daily-change prefix")

	var building_category: Dictionary = view_model._building_category({
		"ok": true,
		"building_type_ids": PackedStringArray(["textile_workshop"]),
		"building_type_display_names": PackedStringArray(["纺织工坊"]),
		"group_type_ids": PackedInt32Array([0]),
		"owner_signature_ids": PackedInt32Array([0]),
		"group_counts": PackedInt64Array([2]),
		"filled_owner": PackedInt64Array([2]),
		"employee_fill_offsets": PackedInt32Array([0, 1]),
		"employee_profession_ids": PackedInt32Array([1]),
		"employee_required": PackedInt64Array([40]),
		"employee_filled": PackedInt64Array([30]),
		"capacity_q16": PackedInt64Array([49152]),
		"last_input": PackedInt64Array([3000]),
		"last_output": PackedInt64Array([12000]),
		"last_sold": PackedInt64Array([10000]),
		"last_discarded": PackedInt64Array([2000]),
		"last_resource": PackedInt64Array([0]),
		"last_revenue": PackedInt64Array([900000]),
		"last_input_cost": PackedInt64Array([200000]),
		"last_wages_paid": PackedInt64Array([300000]),
		"building_counts_by_type": PackedInt64Array([2]),
		"building_owner_slots": PackedInt64Array([1]),
		"signature_profession_ids": PackedInt32Array([0]),
		"profession_stable_ids": PackedStringArray(["landlord", "worker"]),
		"profession_display_names": PackedStringArray(["地主", "工人"]),
		"building_input_offsets": PackedInt32Array([0, 1]),
		"building_input_good_ids": PackedInt32Array([0]),
		"building_input_quantities": PackedInt64Array([2000]),
		"building_output_offsets": PackedInt32Array([0, 1]),
		"building_output_good_ids": PackedInt32Array([1]),
		"building_output_quantities": PackedInt64Array([8000]),
		"building_resource_offsets": PackedInt32Array([0, 0]),
		"building_production_resource_ids": PackedInt32Array(),
		"building_production_resource_quantities": PackedInt64Array(),
		"building_resource_ids": PackedStringArray(),
		"good_ids": PackedStringArray(["grain", "cloth"]),
	})
	var building_rows: Array = building_category.get("building_rows", [])
	if building_rows.size() != 1 or String(building_rows[0].get("owner", "")) != "业主 · 地主":
		failures.append("building dossier did not resolve owner class")
	elif String(building_rows[0].get("profit", "")) != "+40":
		failures.append("building dossier profit did not subtract input and wage costs")
	elif String(_find_by_id(building_rows[0].get("job_rows", []), "job_0").get("value", "")) != "30 / 40":
		failures.append("building dossier did not expose employee attendance")
	else:
		var production_rows: Array = building_rows[0].get("production_rows", [])
		if not _find_by_id(production_rows, "sales").is_empty():
			failures.append("building dossier still exposes a sales row")
		var output_row := _find_by_id(production_rows, "output_0")
		if String(output_row.get("value", "")) != "6.000 单位/栋/日":
			failures.append("building output is not normalized to actual units per building per day")
		var finance: Dictionary = building_rows[0].get("finance", {})
		if String(finance.get("revenue", "")) != "90" or String(finance.get("cost", "")) != "50" or String(finance.get("profit", "")) != "+40":
			failures.append("building dossier finance card did not expose revenue, total cost and profit")
		for detail in production_rows:
			var text := "%s %s" % [detail.get("name", ""), detail.get("value", "")]
			if text.contains("实付") or text.contains("应付") or text.contains("有效储量"):
				failures.append("building dossier still exposes diagnostic bookkeeping labels")

	var suspended_building_category: Dictionary = view_model._building_category({
		"ok": true,
		"period_days": 5,
		"building_type_ids": PackedStringArray(["surface_silver_working"]),
		"building_type_display_names": PackedStringArray(["露天银矿"]),
		"building_technology_available": PackedByteArray([1]),
		"group_type_ids": PackedInt32Array([0]),
		"owner_signature_ids": PackedInt32Array([0]),
		"group_counts": PackedInt64Array([1247]),
		"owner_capacity": PackedInt64Array([1247]),
		"owner_required": PackedInt64Array([0]),
		"filled_owner": PackedInt64Array([0]),
		"owner_openings": PackedInt64Array([0]),
		"employee_fill_offsets": PackedInt32Array([0, 1]),
		"employee_profession_ids": PackedInt32Array([1]),
		"employee_required": PackedInt64Array([0]),
		"employee_filled": PackedInt64Array([0]),
		"operating_state": PackedByteArray([1]),
		"pending_operating_state": PackedByteArray([255]),
		"severe_loss_cycles": PackedInt32Array([3]),
		"recovery_cycles": PackedInt32Array([0]),
		"realized_profit_margin_q16": PackedInt32Array([-32768]),
		"planned_utilization_q16": PackedInt32Array([0]),
		"capacity_q16": PackedInt64Array([0]),
		"last_input": PackedInt64Array([0]),
		"last_output": PackedInt64Array([0]),
		"last_resource": PackedInt64Array([0]),
		"last_resource_generated": PackedInt64Array([0]),
		"last_revenue": PackedInt64Array([0]),
		"last_input_cost": PackedInt64Array([0]),
		"last_wages_paid": PackedInt64Array([0]),
		"last_wages_due": PackedInt64Array([0]),
		"last_operating_cost": PackedInt64Array([0]),
		"wage_suspended": PackedByteArray([0]),
		"building_counts_by_type": PackedInt64Array([1247]),
		"building_owner_slots": PackedInt64Array([1]),
		"signature_profession_ids": PackedInt32Array([0]),
		"profession_stable_ids": PackedStringArray(["merchant", "miner"]),
		"profession_display_names": PackedStringArray(["商人", "矿工"]),
		"building_input_offsets": PackedInt32Array([0, 0]),
		"building_input_good_ids": PackedInt32Array(),
		"building_input_quantities": PackedInt64Array(),
		"building_output_offsets": PackedInt32Array([0, 1]),
		"building_output_good_ids": PackedInt32Array([0]),
		"building_output_quantities": PackedInt64Array([2000]),
		"building_resource_offsets": PackedInt32Array([0, 0]),
		"building_production_resource_ids": PackedInt32Array(),
		"building_production_resource_quantities": PackedInt64Array(),
		"building_resource_ids": PackedStringArray(),
		"good_ids": PackedStringArray(["silver"]),
	})
	var suspended_rows: Array = suspended_building_category.get("building_rows", [])
	if suspended_rows.size() != 1:
		failures.append("loss-suspended building disappeared from the dossier")
	else:
		var suspended_row: Dictionary = suspended_rows[0]
		var suspended_state: Dictionary = suspended_row.get("state_summary", {})
		if String(suspended_row.get("status", "")) != "亏损停产" \
				or String(suspended_row.get("profit_label", "")) != "状态" \
				or String(suspended_row.get("profit", "")) != "停产":
			failures.append("loss-suspended building header still looks like an active zero-profit business")
		elif String(_find_by_id(suspended_row.get("job_rows", []),
				"owner_job").get("value", "")) != "0 / 0（物理容量 1247）":
			failures.append("suspended owner row did not distinguish period demand from physical capacity")
		elif not String(_find_by_id(suspended_row.get("job_rows", []),
				"job_0").get("value", "")).contains("岗位已释放"):
			failures.append("suspended employee row did not explain why its period demand is zero")
		elif not String(suspended_state.get("detail", "")).contains("建筑仍保留") \
				or not String(suspended_state.get("meta", "")).contains("上一经营期利润率 -50.0%") \
				or not String(suspended_state.get("meta", "")).contains("连续亏损 3 期"):
			failures.append("suspended state summary did not expose the cause and prior operating result")
		elif not String((suspended_row.get("finance", {}) as Dictionary).get(
				"warning", "")).contains("本期停产"):
			failures.append("suspended finance card still presents zero cashflow without context")

	map.res_timber_reserve_arr[0] = 12600.0
	view_model.build_live_patch(cell, "natural_resources")

	cell.temperature = 0.64
	view_model.observe_temperature(cell, 1)
	var climate_patch := view_model.build_live_patch(cell, "geography")
	var climate_patch_section := _find_section(
		(climate_patch.get("category", {}) as Dictionary).get("sections", []),
		"climate_hydrology"
	)
	var updated_temp_chart := _find_by_id(
		climate_patch_section.get("charts", []),
		"climate_temperature"
	)
	var updated_temp_values: Array = updated_temp_chart.get("values", [])
	if updated_temp_values.size() != 2 \
			or not is_equal_approx(float(updated_temp_values[0]), 0.52) \
			or not is_equal_approx(float(updated_temp_values[1]), 0.64):
		failures.append("temperature chart rewrote its history instead of appending the new day")

	view_model.set_context(map, null, null, null, 0.42, 22.0)
	view_model.build_live_patch(cell, "natural_resources")
	if not is_equal_approx(float(map.res_timber_reserve_arr[0]), 12600.0):
		failures.append("UI view model mutated simulation reserve data")
	if not is_equal_approx(before_reserve, 12500.0):
		failures.append("test reserve baseline was unexpectedly changed")

	if failures.is_empty():
		print("[player-ui-view-model] PASS")
		quit(0)
	else:
		for failure in failures:
			push_error("[player-ui-view-model] FAIL: %s" % failure)
		quit(1)


func _find_by_id(items: Array, target_id: String) -> Dictionary:
	for raw in items:
		var item: Dictionary = raw
		if String(item.get("id", "")) == target_id:
			return item
	return {}


func _find_section(items: Array, target_id: String) -> Dictionary:
	return _find_by_id(items, target_id)


func _is_legacy_icon(icon: String) -> bool:
	return icon in ["⚙", "▶", "Ⅱ", "☼", "♣", "◆", "▰", "☁", "✦", "⌖", "≈", "↗", "↟", "✤", "♞", "◈", "◇"]
