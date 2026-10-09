extends SceneTree


func _initialize() -> void:
	var map := MapData.new(1, 1)
	var cell := HexCell.new(0, 0)
	cell.index = 0
	cell.terrain = TerrainType.TERRAIN.STEPPE
	cell.landform = LandformType.LF.PLAIN
	cell.vegetation = VegetationType.VEG.TROPICAL_DRY_FOREST
	cell.base_vegetation = VegetationType.VEG.TROPICAL_DRY_FOREST
	cell.cover = CoverType.CV.NONE
	cell.elevation = 0.55
	cell.moisture = 0.66
	cell.base_moisture = 0.30
	cell.temperature = 0.90
	cell.vegetation_vitality = 0.85

	var view_model := CellInspectorViewModel.new()
	view_model.set_context(map, null, null, null, 0.42, 22.0)
	var model := view_model.build(cell)
	var geography: Dictionary = model.get("categories", {}).get("geography", {})
	var physical := _find_section(geography.get("sections", []), "physical_geography")
	var climate := _find_section(geography.get("sections", []), "climate_hydrology")
	var ecology := _find_section(geography.get("sections", []), "vegetation_ecology")
	var climate_zone := _find_metric(climate.get("metrics", []), "geography_terrain")
	var vegetation := _find_metric(ecology.get("metrics", []), "ecology_vegetation")

	var failures := PackedStringArray()
	var expected_title := "%s · %s" % [
		LandformType.name_cn(int(cell.landform)), TerrainType.terrain_name_cn(int(cell.terrain))]
	if String(model.get("header", {}).get("title", "")) != expected_title:
		failures.append("header contains a redundant climate-zone label")
	if not _find_metric(physical.get("metrics", []), "geography_terrain").is_empty():
		failures.append("climate zone is still rendered as physical terrain")
	if String(climate_zone.get("title", "")) != "气候区" \
			or String(climate_zone.get("value", "")) != "温带草原":
		failures.append("biome axis is not rendered as climate zone")
	if String(vegetation.get("title", "")) != "当前植被" \
			or String(vegetation.get("value", "")) != "热带季雨林":
		failures.append("vegetation axis is not rendered as current vegetation")

	if failures.is_empty():
		print("[inspector-geography-semantics] PASS")
		quit(0)
		return
	for failure in failures:
		push_error("[inspector-geography-semantics] FAIL: %s" % failure)
	quit(1)


func _find_section(sections: Array, section_id: String) -> Dictionary:
	for raw in sections:
		var section: Dictionary = raw
		if String(section.get("id", "")) == section_id:
			return section
	return {}


func _find_metric(metrics: Array, metric_id: String) -> Dictionary:
	for raw in metrics:
		var metric: Dictionary = raw
		if String(metric.get("id", "")) == metric_id:
			return metric
	return {}
