extends RefCounted

## Builds the selected-cell view and its committed live-patch payloads.


static func build(owner: CellInspectorViewModel, cell: HexCell) -> Dictionary:
	if cell == null or owner._map == null:
		return {}
	var idx := int(cell.index)
	var fog := VisionSolver.displayed_fog_state(owner._map, idx)
	if fog in [VisionSolver.FOG_UNAVAILABLE, VisionSolver.FOG_UNEXPLORED]:
		return CellInspectorViewModel._Geography.drawn_cell_summary(cell, fog == VisionSolver.FOG_UNEXPLORED)
	var intel_visible := fog == VisionSolver.FOG_VISIBLE
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	var terrain_v := owner._Geography_delegate._terrain(owner, cell, idx)
	var landform_v := owner._landform(cell, idx)
	var vegetation_v := owner._Geography_delegate._vegetation(owner, cell, idx)
	var cover_v := owner._cover(cell, idx)
	var temp := owner._temp(cell, idx)
	owner._Geography_delegate._record_temperature_sample(owner, idx, owner._Geography_delegate._current_sample_day(owner), temp)
	var moist := owner._Geography_delegate._moisture(owner, cell, idx)
	var base_moist := owner._Geography_delegate._base_moisture(owner, cell, idx)
	var elev := owner._elevation(cell, idx)
	var wf := owner._weather_field(cell, idx)
	var vitality := owner._Geography_delegate._vitality(owner, cell, landform_v)
	var snow := owner._Geography_delegate._snow_cover(owner, cell, idx)
	var is_water := LandformType.is_water(landform_v)
	var passable_land := TerrainType.is_passable_land(terrain_v)
	var population_summary := owner._Overview_delegate._population_summary(owner, idx) if intel_visible else {}
	var country_summary := owner._Overview_delegate._country_summary(owner, idx) if intel_visible else {}
	var habitability := owner._Geography_delegate._habitability_score(owner, temp, moist, vitality, elev, passable_land, is_water)
	var tabs := [{"id": "geography", "label": "地理", "icon": "geo"}]
	if intel_visible:
		tabs.append_array([
			# 民情并入人口页：阶层行自带组织阶段，进入示威 / 叛乱时页首警示。
			{"id": "population", "label": "人口", "icon": "population.crowd"},
			{"id": "families", "label": "家族", "icon": "family.house"},
			{"id": "market", "label": "市场", "icon": "resource"},
			{"id": "buildings", "label": "建筑", "icon": "building"},
		])
		# 军事页签只在有军事绑定、且这是陆地格时出现：水域永远不会归属任何国家。
		if not LandformType.is_water(owner._landform(cell, idx)) and owner._military_facade() != null:
			tabs.append({"id": "military", "label": "军事", "icon": "country.military"})
	var geography_category := owner._geography_information_category(cell, idx, terrain_v,
		landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist,
		wf, snow, vitality, passable_land, is_water)
	if intel_visible:
		owner._Overview_delegate._append_resources_to_geography(owner, geography_category, idx, is_water)
	return {
		"cell_index": idx,
		"header": owner._build_header(off, terrain_v, landform_v, country_summary,
			population_summary, intel_visible, owner._has_river(cell, idx)),
		"kpis": owner._kpis(intel_visible, temp, moist, habitability, is_water,
			population_summary, country_summary, idx),
		"colonization_action": owner._colonization_action(
			idx, intel_visible, passable_land, is_water, country_summary),
		"tabs": tabs,
		"categories": {
			"geography": geography_category,
		},
	}



static func _build_unexplored_model(owner: CellInspectorViewModel, cell: HexCell) -> Dictionary:
	return CellInspectorViewModel._Geography.drawn_cell_summary(cell, true)



static func drawn_cell_summary(owner: CellInspectorViewModel, cell: HexCell) -> Dictionary:
	return CellInspectorViewModel._Geography.drawn_cell_summary(cell,
		VisionSolver.displayed_fog_state(owner._map, int(cell.index)) == VisionSolver.FOG_UNEXPLORED)



static func live_patch_revision(owner: CellInspectorViewModel, cell: HexCell, current_tab: String) -> Dictionary:
	if cell == null or owner._map == null:
		return {}
	var idx := int(cell.index)
	var tab_id := current_tab if current_tab != "" else "geography"
	var fog := VisionSolver.displayed_fog_state(owner._map, idx)
	var intel_visible := fog == VisionSolver.FOG_VISIBLE
	var population_summary := owner._Overview_delegate._population_summary(owner, idx) if intel_visible else {}
	var country_summary := owner._Overview_delegate._country_summary(owner, idx) if intel_visible else {}
	var tax_policy_version := owner._cell_tax_policy_version(idx) \
		if intel_visible and tab_id in ["population", "market", "buildings"] else -1
	# fog 参与哈希：视野状态一变，页签集合也变，面板必须整体重建而不是打补丁。
	var common_state := [
		fog,
		idx,
		owner._Geography_delegate._terrain(owner, cell, idx),
		owner._landform(cell, idx),
		owner._temp(cell, idx),
		owner._Geography_delegate._moisture(owner, cell, idx),
		owner._elevation(cell, idx),
		owner._Geography_delegate._vitality(owner, cell, owner._landform(cell, idx)),
		bool(population_summary.get("ok", false)),
		int(population_summary.get("population", 0)),
		int(population_summary.get("cohort_count", 0)),
		int(population_summary.get("funds", 0)),
		int(population_summary.get("epoch_income", 0)),
		int(population_summary.get("epoch_expense", 0)),
		int(population_summary.get("state_day", -1)),
		int(population_summary.get("satisfaction_q16", 0)),
		# 页头「满意度」读的是格级综合值：它变了而生存没变时也必须打补丁。
		int(roundf(owner._Overview_delegate._cell_composite_satisfaction(owner, idx) * 1000.0)) if intel_visible else -1,
		int(population_summary.get("job_capacity", 0)),
		int(population_summary.get("jobs_filled", 0)),
		int(population_summary.get("employed_population", 0)),
		int(population_summary.get("unemployed_population", 0)),
		int(population_summary.get("carrying_k_eff", 0)),
		int(population_summary.get("food_access_q16", 0)),
		int(population_summary.get("prosperity_generation", 0)),
		int(population_summary.get("name_roll_generation", 0)),
		String(population_summary.get("settlement_name", "")),
		String(country_summary.get("country_name", "")),
		int(country_summary.get("cash", 0)),
		int(country_summary.get("nonzero_good_count", 0)),
		int(country_summary.get("technology_count", 0)),
	]
	return {
		"tab_id": tab_id,
		"selection_context": "%d/%d/%d" % [
			fog,
			1 if bool(country_summary.get("owned", false)) else 0,
			int(country_summary.get("country_handle", -1)),
		],
		"tabs_signature": "geography|population|families|market|buildings" \
			if intel_visible else "geography",
		"common_hash": hash(common_state),
		"category_generation": int(population_summary.get(
			"settlement_generation", -1)) if tab_id == "population" \
			else tax_policy_version \
			if tab_id == "market" or tab_id == "buildings" else -1,
		"tax_policy_version": tax_policy_version,
		"population_summary": population_summary,
	}



static func build_live_patch(owner: CellInspectorViewModel,
		cell: HexCell,
		current_tab: String,
		include_category: bool = true,
		population_summary_override: Dictionary = {},
		include_details: bool = true
) -> Dictionary:
	if cell == null or owner._map == null:
		return {}
	var idx := int(cell.index)
	var fog := VisionSolver.displayed_fog_state(owner._map, idx)
	if fog in [VisionSolver.FOG_UNAVAILABLE, VisionSolver.FOG_UNEXPLORED]:
		return CellInspectorViewModel._Geography.drawn_cell_summary(cell, fog == VisionSolver.FOG_UNEXPLORED)
	var intel_visible := fog == VisionSolver.FOG_VISIBLE
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	var terrain_v := owner._Geography_delegate._terrain(owner, cell, idx)
	var landform_v := owner._landform(cell, idx)
	var vegetation_v := owner._Geography_delegate._vegetation(owner, cell, idx)
	var cover_v := owner._cover(cell, idx)
	var temp := owner._temp(cell, idx)
	owner._Geography_delegate._record_temperature_sample(owner, idx, owner._Geography_delegate._current_sample_day(owner), temp)
	var moist := owner._Geography_delegate._moisture(owner, cell, idx)
	var base_moist := owner._Geography_delegate._base_moisture(owner, cell, idx)
	var elev := owner._elevation(cell, idx)
	var wf := owner._weather_field(cell, idx)
	var vitality := owner._Geography_delegate._vitality(owner, cell, landform_v)
	var snow := owner._Geography_delegate._snow_cover(owner, cell, idx)
	var is_water := LandformType.is_water(landform_v)
	var passable_land := TerrainType.is_passable_land(terrain_v)
	var habitability := owner._Geography_delegate._habitability_score(owner, temp, moist, vitality, elev, passable_land, is_water)
	var tab_id := current_tab if current_tab != "" else "geography"
	if not intel_visible:
		tab_id = "geography"
	var population_summary: Dictionary
	var country_summary := owner._Overview_delegate._country_summary(owner, idx) if intel_visible else {}
	var category: Dictionary
	if not intel_visible:
		if include_category:
			category = owner._geography_information_category(cell, idx, terrain_v,
				landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist,
				wf, snow, vitality, passable_land, is_water)
	elif tab_id == "population":
		if include_category:
			# 列表 live patch 不拉需求预览和市场价；对象详情仍走完整 snapshot。
			population_summary = owner._Overview_delegate._population_snapshot(owner, idx, include_details)
			var market := owner._Overview_delegate._market_snapshot(owner, idx) if include_details else {}
			category = owner._population_category(population_summary, market, idx)
			category = owner._decorate_category_with_tax(idx, tab_id, category)
			if bool(category.get("data_pending", false)):
				population_summary = owner._Overview_delegate._population_summary(owner, idx)
		else:
			population_summary = population_summary_override if not \
				population_summary_override.is_empty() else owner._Overview_delegate._population_summary(owner, idx)
	else:
		population_summary = owner._Overview_delegate._population_summary(owner, idx)
		if include_category:
			category = owner._geography_information_category(cell, idx, terrain_v,
				landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist,
				wf, snow, vitality, passable_land, is_water) if tab_id == "geography" \
				else owner.build_tab_category(cell, tab_id)
			if tab_id == "geography":
				owner._Overview_delegate._append_resources_to_geography(owner, category, idx, is_water)
	if include_category and category.is_empty():
		tab_id = "geography"
		category = owner._geography_information_category(cell, idx, terrain_v,
			landform_v, vegetation_v, cover_v, elev, temp, moist, base_moist,
			wf, snow, vitality, passable_land, is_water)
		if intel_visible:
			owner._Overview_delegate._append_resources_to_geography(owner, category, idx, is_water)
	var patch := {
		"header": owner._build_header(off, terrain_v, landform_v, country_summary,
			population_summary, intel_visible, owner._has_river(cell, idx)),
		"kpis": owner._kpis(intel_visible, temp, moist, habitability, is_water,
			population_summary, country_summary, idx),
		"tab_id": tab_id,
	}
	if include_category:
		patch["category"] = category
	return patch



static func build_tab_category(owner: CellInspectorViewModel, cell: HexCell, tab_id: String) -> Dictionary:
	if cell == null or owner._map == null:
		return {}
	var idx := int(cell.index)
	var fog := VisionSolver.displayed_fog_state(owner._map, idx)
	if fog <= VisionSolver.FOG_UNEXPLORED or (fog != VisionSolver.FOG_VISIBLE and tab_id != "geography"):
		owner._category_cache.clear()
		return {}
	if idx != owner._category_cache_cell:
		owner._category_cache_cell = idx
		owner._category_cache.clear()
	var category := owner._build_tab_category(cell, tab_id)
	if bool(category.get("data_pending", false)):
		var cached: Dictionary = owner._category_cache.get(tab_id, {})
		if not cached.is_empty():
			category = cached.duplicate(true)
			category["data_pending"] = true
	elif not category.is_empty():
		owner._category_cache[tab_id] = category.duplicate(true)
	return category



static func _build_tab_category(owner: CellInspectorViewModel, cell: HexCell, tab_id: String) -> Dictionary:
	if cell == null or owner._map == null:
		return {}
	var idx := int(cell.index)
	# 兜底：页签栏本来就不会给出被门控掉的页签，但延迟请求可能跨越一次视野变化。
	var fog := VisionSolver.displayed_fog_state(owner._map, idx)
	if fog <= VisionSolver.FOG_UNEXPLORED or (fog != VisionSolver.FOG_VISIBLE and tab_id != "geography"):
		return {}
	match tab_id:
		"population":
			return owner._decorate_category_with_tax(idx, tab_id,
				owner._population_category(owner._Overview_delegate._population_snapshot(owner, idx), owner._Overview_delegate._market_snapshot(owner, idx), idx))
		"families":
			return owner._family_category(owner._Overview_delegate._family_cell_snapshot(owner, idx))
		"market":
			return owner._decorate_category_with_tax(idx, tab_id,
				owner._market_category(owner._Overview_delegate._market_snapshot(owner, idx)))
		"buildings":
			return owner._decorate_category_with_tax(idx, tab_id,
				owner._building_category(owner._Overview_delegate._building_snapshot(owner, idx), idx))
		"natural_resources":
			var visibility := owner._resource_visibility_context(idx)
			return owner._resources_category(owner._resource_state(
				idx, LandformType.is_water(owner._landform(cell, idx)), visibility),
				visibility)
		"military":
			return owner._military_category(idx)
		"geography":
			var terrain_v := owner._Geography_delegate._terrain(owner, cell, idx)
			var landform_v := owner._landform(cell, idx)
			var vegetation_v := owner._Geography_delegate._vegetation(owner, cell, idx)
			var cover_v := owner._cover(cell, idx)
			var temp := owner._temp(cell, idx)
			var moist := owner._Geography_delegate._moisture(owner, cell, idx)
			var base_moist := owner._Geography_delegate._base_moisture(owner, cell, idx)
			var elev := owner._elevation(cell, idx)
			var is_water := LandformType.is_water(landform_v)
			var category := owner._geography_information_category(
				cell, idx, terrain_v, landform_v, vegetation_v, cover_v, elev,
				temp, moist, base_moist, owner._weather_field(cell, idx),
				owner._Geography_delegate._snow_cover(owner, cell, idx), owner._Geography_delegate._vitality(owner, cell, landform_v),
				TerrainType.is_passable_land(terrain_v), is_water)
			if VisionSolver.displayed_fog_state(owner._map, idx) == VisionSolver.FOG_VISIBLE:
				owner._Overview_delegate._append_resources_to_geography(owner, category, idx, is_water)
			return category
	return {}
