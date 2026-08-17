extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")


func _init() -> void:
	var dir := DirAccess.open(EconomyCatalogScript.BUILDING_DIR)
	if dir == null:
		push_error("building directory missing")
		quit(1)
		return
	var changed := 0
	var counts := {}
	var files := PackedStringArray(dir.get_files())
	files.sort()
	for file_name in files:
		if not file_name.ends_with(".tres"):
			continue
		var path := EconomyCatalogScript.BUILDING_DIR + "/" + file_name
		var profile = load(path)
		if profile == null:
			push_error("building profile load failed: %s" % path)
			quit(1)
			return
		var sector := _sector_for(profile)
		counts[sector] = int(counts.get(sector, 0)) + 1
		if String(profile.economic_sector_id) == sector:
			continue
		profile.economic_sector_id = sector
		var error := ResourceSaver.save(profile, path)
		if error != OK:
			push_error("building profile save failed: %s (%d)" % [path, error])
			quit(1)
			return
		changed += 1
	print("[PASS] explicit building economic sectors: changed=%d counts=%s" % [changed, counts])
	quit(0)


func _sector_for(profile: Resource) -> String:
	var id := String(profile.id).to_lower()
	var family := String(profile.upgrade_family_id).to_lower()
	if _profile_outputs(profile, "technology_points") \
			or family == "research_institution" \
			or id.contains("research_") or id.contains("laboratory") \
			or id.contains("academy") or id.contains("lorekeeper") \
			or id.contains("learned_society") or id.contains("polytechnic"):
		return "knowledge"
	if id.contains("power_plant") or id in ["electricity_plant", "wind_power_station",
			"hydroelectric_plant", "nuclear_power_plant", "gas_power_plant",
			"oil_power_plant"]:
		return "energy"
	var agriculture_terms := [
		"farm", "field", "paddy", "maize", "wheat", "rice", "tuber", "potato",
		"pasture", "pastoral", "ranch", "livestock", "horse_breed", "wool_shed",
		"fishing", "fish_collector", "hunting", "gathering", "garden", "plantation",
		"cotton_collector", "flax_collector", "spice_plants_collector",
		"rubber_tree_collector", "fertile_soil_collector", "wild_game",
	]
	for term in agriculture_terms:
		if id.contains(term):
			return "agriculture"
	if String(profile.building_kind) == "collector":
		return "extractive"
	return "manufacturing"


func _profile_outputs(profile: Resource, good_id: String) -> bool:
	return profile.output_good_ids.has(good_id)
