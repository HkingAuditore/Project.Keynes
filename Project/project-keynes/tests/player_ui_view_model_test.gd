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
			"settlement_generation": settlement_generation,
			"prosperity_name": "乡村",
			"settlement_name_active": true,
			"settlement_name": "长安"}

	func population_cell_snapshot(_cell_idx: int, _include_details: bool = true) -> Dictionary:
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


class ProfessionUnlockFacade extends RefCounted:
	func building_cell_snapshot(_cell_idx: int) -> Dictionary:
		return {
			"ok": true,
			"building_type_ids": PackedStringArray(["gathering_ground"]),
			"building_technology_available": PackedByteArray([1]),
			"building_construction_available": PackedByteArray([1]),
			"building_counts_by_type": PackedInt64Array([1]),
			"building_owner_profession_ids": PackedInt32Array([0]),
			"building_employee_offsets": PackedInt32Array([0, 0]),
			"building_employee_profession_ids": PackedInt32Array(),
			"profession_stable_ids": PackedStringArray([
				"forager", "ai_researcher"]),
		}

	func market_cell_snapshot(_cell_idx: int) -> Dictionary:
		return {
			"ok": true,
			"good_ids": PackedStringArray(),
			"good_technology_available": PackedByteArray(),
		}

	func population_cell_snapshot(_cell_idx: int,
			_include_details: bool = true) -> Dictionary:
		return {
			"ok": true,
			"profession_stable_ids": PackedStringArray([
				"forager", "ai_researcher"]),
			"profession_technology_available": PackedByteArray([1, 1]),
			"profession_ids": PackedInt32Array([0]),
		}


class ProfessionUnlockGenerator extends RefCounted:
	func get_economy_facade():
		return ProfessionUnlockFacade.new()


class PlayerDiscoveryCountryFacade extends RefCounted:
	var owned_cells := {}
	var countries := {}

	func cell_summary(cell_idx: int) -> Dictionary:
		if owned_cells.has(cell_idx):
			return {
				"ok": true,
				"owned": true,
				"country_handle": int(owned_cells[cell_idx]),
				"country_name": "新国家",
			}
		return {
			"ok": true,
			"owned": false,
			"country_handle": 0,
			"country_name": "无主之地",
		}

	func snapshot(handle: int) -> Dictionary:
		return countries.get(handle, {"ok": false})


class PlayerDiscoveryGenerator extends RefCounted:
	var country := PlayerDiscoveryCountryFacade.new()
	var start_cell := 0

	func get_country_facade():
		return country

	func gameplay_start_report() -> Dictionary:
		return {"ok": true, "cell": start_cell}


class ConstructionRecipeEconomy extends RefCounted:
	func building_placement_spec(building_id: StringName) -> Dictionary:
		if String(building_id) != "timber_collector":
			return {"ok": false}
		return {
			"ok": true,
			"input_good_ids": PackedStringArray(["tools"]),
			"input_quantities": PackedInt64Array([200]),
			"input_candidate_offsets": PackedInt32Array([0, 4]),
			"input_candidate_good_ids": PackedStringArray([
				"bronze_tools", "chipped_stone_tools", "precision_tools", "tools"]),
			"input_candidate_efficiency_q16": PackedInt32Array([
				52429, 32768, 98304, 65536]),
			"output_good_ids": PackedStringArray(["logs"]),
			"output_quantities": PackedInt64Array([7090]),
		}

	func building_job_spec(_building_id: StringName) -> Dictionary:
		return {
			"ok": true,
			"owner_profession": "forager",
			"owner_slots": 2,
			"employee_professions": PackedStringArray(),
			"employee_slots": PackedInt64Array(),
		}

	func profession_display_name(profession_id: StringName) -> String:
		return "采集者" if String(profession_id) == "forager" else String(profession_id)


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
	_seed_research_signals(map, 0, PackedStringArray([
		"bio.maize", "bio.wheat", "bio.rice", "resource.timber", "landform.grassland"]),
		PackedInt32Array([1, 1, 0, 1, 1]))

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
	lazy_view_model.build_live_patch(cell, "population", true, {}, false)
	if counting_generator.facade.population_calls != 2 \
			or counting_generator.facade.market_calls != 2:
		failures.append("population list live patch queried market demand detail")
	var named_model := lazy_view_model.build(cell)
	if String(named_model.get("header", {}).get("title", "")) != "长安 · 乡村":
		failures.append("named settlement header did not replace terrain title")

	if model.is_empty():
		failures.append("view model returned an empty model")
	if String(model.get("header", {}).get("subtitle", "")).contains("cube"):
		failures.append("player header still exposes debug cube text")
	if String(model.get("header", {}).get("subtitle", "")).contains("档案 #"):
		failures.append("player header still exposes a redundant dossier number")
	var header_title := String(model.get("header", {}).get("title", ""))
	if header_title.contains("气候区"):
		failures.append("player header still exposes a redundant climate-zone label")
	if not header_title.contains(TerrainType.terrain_name_cn(int(cell.terrain))):
		failures.append("player header does not show the biome name")
	var tabs: Array = model.get("tabs", [])
	if tabs.size() != 5:
		failures.append("expected five dossier tabs")
	var expected_tabs := ["geography", "population", "families", "market", "buildings"]
	var expected_labels := ["地理", "人口", "家族", "市场", "建筑"]
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
	if (model.get("summary_cards", []) as Array).size() != 4:
		failures.append("summary should contain climate, population, prosperity, and country")
	for summary_id in ["summary_climate", "summary_population",
			"summary_prosperity", "summary_country"]:
		if _find_by_id(model.get("summary_cards", []), summary_id).is_empty():
			failures.append("summary missing %s" % summary_id)
	for hidden_summary_id in ["summary_market", "summary_resource"]:
		if not _find_by_id(model.get("summary_cards", []), hidden_summary_id).is_empty():
			failures.append("summary still displays %s" % hidden_summary_id)

	var categories: Dictionary = model.get("categories", {})
	if categories.size() != 1 or not categories.has("geography"):
		failures.append("initial dossier model eagerly built hidden tab data")
	for lazy_tab in ["population", "families", "market", "buildings"]:
		categories[lazy_tab] = view_model.build_tab_category(cell, lazy_tab)
	for banned in ["原生", "MarketStore", "测试人口", "硬前置", "揭示证据", "安全边界", "中性环境"]:
		if _player_text_contains(categories, banned) or _player_text_contains(model, banned):
			failures.append("player copy still contains '%s'" % banned)
	var geography: Dictionary = categories.get("geography", {})
	var physical: Dictionary = _find_section(geography.get("sections", []), "physical_geography")
	var climate: Dictionary = _find_section(geography.get("sections", []), "climate_hydrology")
	var ecology: Dictionary = _find_section(geography.get("sections", []), "vegetation_ecology")
	var biogeography: Dictionary = _find_section(geography.get("sections", []), "biogeography")
	if physical.is_empty() or climate.is_empty() or ecology.is_empty():
		failures.append("geography tab is missing grouped sections")
	if bool(physical.get("collapsed", false)):
		failures.append("landform section should stay expanded by default")
	if not bool(climate.get("collapsed", false)) \
			or not bool(ecology.get("collapsed", false)):
		failures.append("climate and ecology gauges should start collapsed")
	if biogeography.is_empty() or String(biogeography.get("title", "")) != "本地物种":
		failures.append("geography tab is missing local species facts")
	var maize_badge := _find_by_id(biogeography.get("badges", []), "bio.maize")
	var wheat_badge := _find_by_id(biogeography.get("badges", []), "bio.wheat")
	if String(maize_badge.get("text", "")) != "玉米" \
			or String(wheat_badge.get("text", "")) != "小麦":
		failures.append("local species badges did not use catalog display names")
	if not _find_by_id(biogeography.get("badges", []), "bio.rice").is_empty() \
			or not _find_by_id(biogeography.get("badges", []), "resource.timber").is_empty() \
			or not _find_by_id(biogeography.get("badges", []), "landform.grassland").is_empty():
		failures.append("local species section leaked zero-value, resource, or landform signals")
	var climate_zone_metric := _find_by_id(climate.get("metrics", []), "geography_terrain")
	var vegetation_metric := _find_by_id(ecology.get("metrics", []), "ecology_vegetation")
	if _find_by_id(physical.get("metrics", []), "geography_landform").is_empty():
		failures.append("geography tab is missing landform")
	if String(climate_zone_metric.get("title", "")) != "气候区":
		failures.append("terrain/biome axis is not explicitly presented as climate zone")
	if String(vegetation_metric.get("title", "")) != "当前植被":
		failures.append("vegetation axis is not explicitly presented as current vegetation")
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

	var resource_rows: Array = _find_section(
		geography.get("sections", []), "natural_resources").get("resource_rows", [])
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
	if String(timber_row.get("density", "")) != _expected_density("timber", 12500.0):
		failures.append("timber density did not use its resource-specific reference scale")
	if String(iron_row.get("density", "")) != _expected_density("iron_ore", 10000.0):
		failures.append("iron density still behaves like a raw absolute threshold")
	if pasture_row.is_empty() or String(pasture_row.get("icon", "")) \
			!= String(_resource_icon("pasture")):
		failures.append("pasture capacity did not replace species livestock resource rows")
	var gated_resources: Array = view_model._resource_state(0, false, {
		"enforce_discovery": true,
		"technology_ids": PackedStringArray([
			"tech.deadwood_collection", "tech.iron_ore_identification"]),
		"enforce_extraction": true,
		"extractable_resource_ids": {&"timber": true, &"rare_earth": true},
	})
	var gated_timber := _find_by_id(gated_resources, "timber")
	var gated_iron := _find_by_id(gated_resources, "iron_ore")
	if gated_timber.is_empty() or not bool(gated_timber.get("extractable", false)) \
			or not _find_by_id(gated_resources, "rare_earth").is_empty() \
			or gated_iron.is_empty() or bool(gated_iron.get("extractable", true)):
		failures.append("resource dossier did not enforce discovery and extraction technology")
	var opening_resources: Array = view_model._resource_state(0, false, {
		"enforce_discovery": true,
		"technology_ids": PackedStringArray(["tech.gathering", "tech.hunting"]),
	})
	if _find_by_id(opening_resources, "fertile_soil").is_empty() \
			or _find_by_id(opening_resources, "wild_game").is_empty() \
			or not _find_by_id(opening_resources, "iron_ore").is_empty() \
			or not _find_by_id(opening_resources, "copper_ore").is_empty() \
			or not _find_by_id(opening_resources, "timber").is_empty():
		failures.append("opening techs must name soil/game without naming unidentified minerals")
	var undiscovered := view_model._resources_category([], {"enforce_discovery": true})
	var undiscovered_insight := _find_by_id(
		undiscovered.get("insights", []), "resource_undiscovered")
	if undiscovered_insight.is_empty() \
			or String(undiscovered_insight.get("text", "")).find("尚未识别") < 0:
		failures.append("gated empty resource lists must not claim types are unconfigured")

	var explored_map := MapData.new(1, 1)
	_seed_research_signals(explored_map, 0, PackedStringArray(["bio.maize"]), PackedInt32Array([1]))
	explored_map.visible_arr = PackedByteArray([0])
	explored_map.explored_arr = PackedByteArray([1])
	var explored_view_model := CellInspectorViewModel.new()
	explored_view_model.set_context(explored_map, null, null, null, 0.42, 22.0)
	var explored_model := explored_view_model.build(cell)
	var explored_geo: Dictionary = explored_model.get("categories", {}).get("geography", {})
	var explored_bio := _find_section(explored_geo.get("sections", []), "biogeography")
	if explored_bio.is_empty() or _find_by_id(explored_bio.get("badges", []), "bio.maize").is_empty():
		failures.append("remembered geography must keep local species facts")
	var unnamed_bio: Array = explored_view_model._cell_bio_badges(0, {
		"enforce_discovery": true,
		"technology_ids": PackedStringArray(["tech.gathering"]),
	})
	if not _find_by_id(unnamed_bio, "bio.maize").is_empty():
		failures.append("undiscovered species must not be named after gathering-only techs")
	var named_bio: Array = explored_view_model._cell_bio_badges(0, {
		"enforce_discovery": true,
		"technology_ids": PackedStringArray(["tech.maize_identification"]),
	})
	if _find_by_id(named_bio, "bio.maize").is_empty():
		failures.append("identified species must keep their display names")
	if not _find_section(explored_geo.get("sections", []), "natural_resources").is_empty():
		failures.append("explored-but-unseen cells must not expose live natural-resource intel")

	var unexplored_map := MapData.new(1, 1)
	_seed_research_signals(unexplored_map, 0, PackedStringArray(["bio.maize"]), PackedInt32Array([1]))
	unexplored_map.visible_arr = PackedByteArray([0])
	unexplored_map.explored_arr = PackedByteArray([0])
	var unexplored_view_model := CellInspectorViewModel.new()
	unexplored_view_model.set_context(unexplored_map, null, null, null, 0.42, 22.0)
	var unexplored_model := unexplored_view_model.build(cell)
	if not (unexplored_model.get("categories", {}) as Dictionary).is_empty() \
			or String(unexplored_model.get("header", {}).get("title", "")) != "未探索区域":
		failures.append("unexplored cells must not leak local species facts")

	var empty_bio_map := MapData.new(1, 1)
	var empty_bio_view_model := CellInspectorViewModel.new()
	empty_bio_view_model.set_context(empty_bio_map, null, null, null, 0.42, 22.0)
	var empty_bio_geo: Dictionary = empty_bio_view_model.build(cell).get(
		"categories", {}).get("geography", {})
	if not _find_section(empty_bio_geo.get("sections", []), "biogeography").is_empty():
		failures.append("empty occupancy bits must not invent a local species section")

	var discovery_map := MapData.new(2, 1)
	discovery_map.res_timber_reserve_arr = PackedFloat32Array([12500.0, 8000.0])
	discovery_map.res_rare_earth_reserve_arr = PackedFloat32Array([5000.0, 4000.0])
	discovery_map.resource_habitat_mask_arr = PackedByteArray([1, 1])
	var discovery_generator := PlayerDiscoveryGenerator.new()
	discovery_generator.country.owned_cells[0] = 42
	discovery_generator.country.countries[42] = {
		"ok": true,
		"technology_ids": PackedStringArray(["tech.deadwood_collection", "tech.gathering"]),
	}
	var discovery_view_model := CellInspectorViewModel.new()
	discovery_view_model.set_context(discovery_map, discovery_generator, null, null, 0.42, 22.0)
	var unowned_visibility: Dictionary = discovery_view_model._resource_visibility_context(1)
	var unowned_techs: PackedStringArray = unowned_visibility.get(
		"technology_ids", PackedStringArray())
	if not bool(unowned_visibility.get("enforce_discovery", false)) \
			or not unowned_techs.has("tech.deadwood_collection"):
		failures.append("unowned cells must use the player country's completed technologies")
	var unowned_resources: Array = discovery_view_model._resource_state(
		1, false, unowned_visibility)
	if _find_by_id(unowned_resources, "timber").is_empty() \
			or not _find_by_id(unowned_resources, "rare_earth").is_empty():
		failures.append("unowned cells must show player-identified deposits instead of hiding the dossier")
	var unowned_category: Dictionary = discovery_view_model._resources_category(
		unowned_resources, unowned_visibility)
	if not _find_by_id(unowned_category.get("insights", []), "resource_unconfigured").is_empty() \
			or _find_by_id(unowned_category.get("resource_rows", []), "timber").is_empty():
		failures.append("unowned identified deposits must render as resource rows")

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
		"demand_good_offsets": PackedInt32Array([0, 3]),
		"demand_good_indices": PackedInt32Array([0, 1, 3]),
		"demand_per_capita_daily": PackedInt64Array([800, 40, 25]),
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
	if (gated_market.get("metrics", []) as Array).size() != 3 \
			or _find_by_id(gated_market.get("metrics", []), "merchant_cash").is_empty() \
			or _find_by_id(gated_market.get("metrics", []), "market_shortage_count").is_empty() \
			or _find_by_id(gated_market.get("metrics", []), "merchant_trade_net").is_empty():
		failures.append("market dossier should keep three player-facing summary cards")
	var merchant_accounts: Dictionary = _find_section(
		gated_market.get("sections", []), "merchant_accounts")
	if merchant_accounts.is_empty() or not bool(merchant_accounts.get("collapsed", false)):
		failures.append("merchant accounts should remain a collapsed dossier")
	var gated_plants: Dictionary = gated_market_rows[0] if gated_market_rows.size() == 1 else {}
	if String(gated_plants.get("stock", "")).contains("在途") \
			or not _find_by_id(gated_plants.get("detail_rows", []), "trade_inbound").is_empty() \
			or not _find_by_id(gated_market.get("insights", []),
				"market_trade_in_transit").is_empty() \
			or String(_find_by_id(gated_market.get("metrics", []),
				"merchant_trade_net").get("subtitle", "")) != "无在途":
		failures.append("zero-flow market dossier leaked cross-cell trade copy")

	var trade_market: Dictionary = view_model._market_category({
		"ok": true,
		"market_id": 0,
		"good_ids": PackedStringArray(["gathered_plants", "cloth", "autonomous_systems"]),
		"good_technology_available": PackedByteArray([1, 1, 0]),
		"good_trade_enabled": PackedByteArray([1, 0, 1]),
		"stock": PackedInt64Array([1000, 2000, 0]),
		"price": PackedInt32Array([10000, 10000, 10000]),
		"demand_ema": PackedInt64Array([0, 0, 0]),
		"business_demand_ema": PackedInt64Array([0, 0, 0]),
		"offered_supply_ema": PackedInt64Array([0, 0, 0]),
		"cost_anchor_price": PackedInt32Array([0, 0, 0]),
		"shortage_q16": PackedInt32Array([0, 0, 0]),
		"trade_inbound": PackedInt64Array([3000, 4000, 5000]),
		"trade_outbound": PackedInt64Array([0, 0, 0]),
		"trade_import_ema": PackedInt64Array([1500, 0, 0]),
		"trade_export_ema": PackedInt64Array([0, 0, 0]),
		"trade_next_arrival_day": 4,
		"merchant_trade_sale_cash": 20000,
		"merchant_trade_purchase_cash": 5000,
	})
	var trade_rows: Array = trade_market.get("market_rows", [])
	if trade_rows.size() != 2:
		failures.append("trade market dossier changed technology gating")
	else:
		var plants: Dictionary = trade_rows[0]
		var cloth: Dictionary = trade_rows[1]
		if String(plants.get("id", "")) != "market_gathered_plants" \
				or String(plants.get("stock", "")) != "1 单位 · 在途" \
				or String(plants.get("stock_plain", "")) != "1 单位" \
				or String(plants.get("trade_inbound", "")) != "3 单位" \
				or String(plants.get("trade_outbound", "")) != "" \
				or String(_find_by_id(plants.get("detail_rows", []),
					"trade_inbound").get("value", "")) != "3 单位" \
				or String(_find_by_id(plants.get("detail_rows", []),
					"trade_import_flow").get("value", "")) != "1.5 单位" \
				or not _find_by_id(plants.get("detail_rows", []),
					"trade_outbound").is_empty():
			failures.append("in-transit good did not expose curated inbound trade facts")
		if String(cloth.get("stock", "")).contains("在途") \
				or String(cloth.get("trade_inbound", "")) != "" \
				or not _find_by_id(cloth.get("detail_rows", []),
					"trade_inbound").is_empty():
			failures.append("trade-disabled good still showed inbound cargo")
	var trade_insight: Dictionary = _find_by_id(
		trade_market.get("insights", []), "market_trade_in_transit")
	var trade_net_card: Dictionary = _find_by_id(
		trade_market.get("metrics", []), "merchant_trade_net")
	if String(trade_insight.get("text", "")) != "1 种物资在途，下一批还有 4 日到货。" \
			or String(trade_net_card.get("subtitle", "")) != "在途 1 种 · 4 日后到货" \
			or (trade_market.get("metrics", []) as Array).size() != 3:
		failures.append("market trade summary cards did not stay curated")

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
		elif not String(suspended_state.get("detail", "")).contains("连续亏损停产") \
				or not String(suspended_state.get("meta", "")).contains("上一经营期利润率 -50.0%") \
				or not String(suspended_state.get("meta", "")).contains("连续亏损 3 期"):
			failures.append("suspended state summary did not expose the cause and prior operating result")
		elif not String((suspended_row.get("finance", {}) as Dictionary).get(
				"warning", "")).contains("停产中"):
			failures.append("suspended finance card still presents zero cashflow without context")

	map.res_timber_reserve_arr[0] = 12600.0
	view_model.build_live_patch(cell, "geography")

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
	view_model.build_live_patch(cell, "geography")
	if not is_equal_approx(float(map.res_timber_reserve_arr[0]), 12600.0):
		failures.append("UI view model mutated simulation reserve data")
	if not is_equal_approx(before_reserve, 12500.0):
		failures.append("test reserve baseline was unexpectedly changed")
	var family_visibility := {
		"enforce_buildings": true, "buildings": {"unlocked_building": true},
		"enforce_goods": true, "goods": {"unlocked_good": true},
		"enforce_professions": true, "professions": {"artisan": true},
	}
	var family_name_view := CellInspectorViewModel.new()
	var family_category: Dictionary = family_name_view._family_category({
		"ok": true,
		"family_handles": PackedInt64Array([7]),
		"surnames": PackedStringArray(["李"]),
		"family_names": PackedStringArray(["长安李氏"]),
		"surname_disambiguators": PackedInt32Array([0]),
		"populations": PackedInt64Array([12]),
		"cash_claims": PackedInt64Array([0]),
		"owned_buildings": PackedInt64Array([1]),
		"notable_person_counts": PackedInt32Array([1]),
		"prestige_levels": PackedInt32Array([1]),
	})
	var family_rows: Array = family_category.get("family_rows", [])
	if family_rows.size() != 1 \
			or String(family_rows[0].get("name", "")) != "长安李氏":
		failures.append("family list did not use origin settlement display names")
	if CellInspectorViewModel._family_behavior_selector_visible(
			0, "locked_building", family_visibility) \
			or CellInspectorViewModel._family_behavior_selector_visible(
			3, "locked_good", family_visibility) \
			or CellInspectorViewModel._family_behavior_selector_visible(
			1, "locked_profession", family_visibility) \
			or not CellInspectorViewModel._family_behavior_selector_visible(
			0, "unlocked_building", family_visibility):
		failures.append("family detail did not filter locked behavior selectors")
	var profession_mask_view := CellInspectorViewModel.new()
	profession_mask_view._generator = ProfessionUnlockGenerator.new()
	var profession_visibility: Dictionary = \
		profession_mask_view._family_behavior_visibility(0)
	var profession_rows: Array = profession_mask_view._family_behavior_rows({
		"behavior_axes": PackedInt32Array([1, 1]),
		"behavior_selector_stable_ids": PackedStringArray([
			"forager", "ai_researcher"]),
		"behavior_selector_display_names": PackedStringArray([
			"采集者", "AI 研究员"]),
		"behavior_factors_q16": PackedInt32Array([65536, 65536]),
	}, 0)
	if not bool(profession_visibility.get("enforce_professions", false)) \
			or not (profession_visibility.get("professions", {}) as Dictionary).has(
				"forager") \
			or (profession_visibility.get("professions", {}) as Dictionary).has(
				"ai_researcher") \
			or profession_rows.size() != 1 \
			or String(profession_rows[0].get("name", "")).find("采集者") < 0 \
			or String(profession_rows[0].get("name", "")).find("AI") >= 0:
		failures.append("family behavior rows listed a locked profession")

	var recipe_view_model := CellInspectorViewModel.new()
	var stone_item := {"building_id": "timber_collector", "materials": []}
	recipe_view_model._decorate_construction_item(
		stone_item, ConstructionRecipeEconomy.new(), {},
		{"chipped_stone_tools": true})
	var stone_inputs: Array = stone_item.get("inputs", [])
	var stone_input_name := String((stone_inputs[0] as Dictionary).get("name", "")) \
		if not stone_inputs.is_empty() else ""
	var stone_input_qty := String((stone_inputs[0] as Dictionary).get("quantity", "")) \
		if not stone_inputs.is_empty() else ""
	if not stone_input_name.begins_with("打制石器") \
			or stone_input_name.contains("金属工具") \
			or stone_input_name.contains("青铜工具") \
			or stone_input_name.contains("精密工具") \
			or stone_input_qty != "0.200 /日":
		failures.append("stone-age construction list still labels logging inputs as metal tools")
	var later_item := {"building_id": "timber_collector", "materials": []}
	recipe_view_model._decorate_construction_item(
		later_item, ConstructionRecipeEconomy.new(), {},
		{"chipped_stone_tools": true, "bronze_tools": true, "tools": true})
	var later_inputs: Array = later_item.get("inputs", [])
	var later_input_name := String((later_inputs[0] as Dictionary).get("name", "")) \
		if not later_inputs.is_empty() else ""
	if not later_input_name.contains("打制石器") \
			or not later_input_name.contains("青铜工具") \
			or not later_input_name.contains("金属工具") \
			or later_input_name.contains("精密工具"):
		failures.append("unlocked logging input substitutes were not listed by current technology")

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


func _resource_profile(resource_id: String):
	for profile in ResourceProfileRegistry.ordered():
		if String(profile.id) == resource_id:
			return profile
	return null


func _resource_icon(resource_id: String) -> StringName:
	return ResourceProfileRegistry.icon_key(_resource_profile(resource_id))


func _expected_density(resource_id: String, reserve: float) -> String:
	var ratio := reserve / ResourceProfileRegistry.reference_reserve(
		_resource_profile(resource_id))
	if ratio < 0.05: return "贫乏"
	if ratio < 0.25: return "稀少"
	if ratio < 0.55: return "可采"
	if ratio < 0.80: return "富集"
	return "丰饶"


func _is_legacy_icon(icon: String) -> bool:
	return icon in ["⚙", "▶", "Ⅱ", "☼", "♣", "◆", "▰", "☁", "✦", "⌖", "≈", "↗", "↟", "✤", "♞", "◈", "◇"]


func _seed_research_signals(map: MapData, cell_idx: int, signal_ids: PackedStringArray,
		values_in: PackedInt32Array) -> void:
	var catalog: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	var dense := PackedInt32Array()
	var values := PackedInt32Array()
	var occupancy_bits_for_cell := 0
	var occupancy_lookup: PackedInt32Array = catalog.get(
		"research_signal_occupancy_bit", PackedInt32Array())
	for i in range(signal_ids.size()):
		var signal_index := ResearchSignalCatalog.signal_index(
			catalog, StringName(signal_ids[i]))
		if signal_index < 0:
			continue
		dense.append(signal_index)
		var value := int(values_in[i]) if i < values_in.size() else 1
		values.append(value)
		if value > 0 and signal_index < occupancy_lookup.size():
			var bit := int(occupancy_lookup[signal_index])
			if bit >= 0 and bit < 32:
				occupancy_bits_for_cell |= 1 << bit
	var cell_n := maxi(cell_idx + 1, 1)
	var offsets := PackedInt32Array()
	offsets.resize(cell_n + 1)
	var out_ids := PackedInt32Array()
	var out_values := PackedInt32Array()
	for map_cell in range(cell_n):
		offsets[map_cell] = out_ids.size()
		if map_cell == cell_idx:
			out_ids.append_array(dense)
			out_values.append_array(values)
	offsets[cell_n] = out_ids.size()
	map.cell_research_signal_offsets = offsets
	map.cell_research_signal_ids = out_ids
	map.cell_research_signal_values = out_values
	var occupancy := PackedInt32Array()
	occupancy.resize(cell_n)
	if cell_idx < occupancy.size():
		occupancy[cell_idx] = occupancy_bits_for_cell
	map.bio_occupancy_bits_arr = occupancy


func _player_text_contains(value, needle: String) -> bool:
	if value is String:
		return (value as String).contains(needle)
	if value is Dictionary:
		for key in value:
			if _player_text_contains(value[key], needle):
				return true
	elif value is Array:
		for item in value:
			if _player_text_contains(item, needle):
				return true
	return false
