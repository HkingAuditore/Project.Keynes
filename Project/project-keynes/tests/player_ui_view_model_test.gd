extends SceneTree


func _initialize() -> void:
	var failures := PackedStringArray()
	var map := MapData.new(1, 1)
	map.res_timber_reserve_arr = PackedFloat32Array([12500.0])
	map.res_iron_ore_reserve_arr = PackedFloat32Array([10000.0])
	map.res_sheep_reserve_arr = PackedFloat32Array([8.0])

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

	if model.is_empty():
		failures.append("view model returned an empty model")
	if String(model.get("header", {}).get("subtitle", "")).contains("cube"):
		failures.append("player header still exposes debug cube text")
	if String(model.get("header", {}).get("subtitle", "")).contains("档案 #"):
		failures.append("player header still exposes a redundant dossier number")
	var tabs: Array = model.get("tabs", [])
	if tabs.size() != 4:
		failures.append("expected four dossier tabs")
	var expected_tabs := ["geography", "population", "market", "natural_resources"]
	var expected_labels := ["地理信息", "人口信息", "市场信息", "自然资源"]
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
		failures.append("summary should contain climate, population, market, and resources")
	for summary_id in ["summary_climate", "summary_population", "summary_market", "summary_resource"]:
		if _find_by_id(model.get("summary_cards", []), summary_id).is_empty():
			failures.append("summary missing %s" % summary_id)

	var categories: Dictionary = model.get("categories", {})
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
	if resource_rows.size() != ResourceProfileRegistry.count():
		failures.append("resource dossier must retain all registry rows for stable live updates")
	for raw in resource_rows:
		var row: Dictionary = raw
		if String(row.get("id", "")).is_empty():
			failures.append("resource row missing stable id")
		if _is_legacy_icon(String(row.get("icon", ""))):
			failures.append("resource row uses a legacy Unicode icon")
	var timber_row := _find_by_id(resource_rows, "timber")
	var iron_row := _find_by_id(resource_rows, "iron_ore")
	var sheep_row := _find_by_id(resource_rows, "sheep")
	if String(timber_row.get("density", "")) != "丰饶":
		failures.append("timber density did not use its resource-specific reference scale")
	if String(iron_row.get("density", "")) != "贫乏":
		failures.append("iron density still behaves like a raw absolute threshold")
	if String(sheep_row.get("density", "")) != "稀少":
		failures.append("sheep density did not use its resource-specific reference scale")

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
		"demand_good_offsets": PackedInt32Array([0, 2]),
		"demand_good_indices": PackedInt32Array([0, 1]),
		"demand_per_capita_daily": PackedInt64Array([800, 40]),
		"demand_good_stable_ids": PackedStringArray(["grain", "cloth"]),
		"demand_preview_environment_ready": true,
	})
	var cohort_rows: Array = population_category.get("cohort_rows", [])
	if cohort_rows.size() != 1 or not String(cohort_rows[0].get("wealth", "")).contains("40"):
		failures.append("population dossier did not calculate per-capita wealth")
	elif (cohort_rows[0].get("demand_rows", []) as Array).filter(
		func(row: Dictionary) -> bool: return bool(row.get("visible", false))
	).size() != 2:
		failures.append("population dossier did not expose all non-zero per-capita demands")

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

	map.res_timber_reserve_arr[0] = 12600.0
	var changed := view_model.build_live_patch(cell, "natural_resources")
	var changed_card := _find_by_id(changed.get("summary_cards", []), "summary_resource")
	if String(changed_card.get("trend", "")) != "trend_up":
		failures.append("resource increase did not produce semantic trend_up")

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
	var reset := view_model.build_live_patch(cell, "natural_resources")
	var reset_card := _find_by_id(reset.get("summary_cards", []), "summary_resource")
	if String(reset_card.get("trend", "")) != "trend_flat":
		failures.append("world context reset did not clear resource delta cache")
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
