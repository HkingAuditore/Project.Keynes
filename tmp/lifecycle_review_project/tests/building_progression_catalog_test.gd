extends SceneTree

const BuildingProfileScript = preload("res://scripts/data/building_profile.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")


func _profile(id: String, step := 0, rank := 0, role := "",
		predecessors := PackedStringArray()) -> Resource:
	var profile = BuildingProfileScript.new()
	profile.id = id
	if step > 0:
		profile.industry_chain_id = &"tuber_cultivation"
		profile.progression_step = step
		profile.maturity_rank = rank
		profile.maturity_display_name = "产业阶段"
		profile.progression_role = role
		profile.predecessor_building_ids = predecessors
	return profile


func _init() -> void:
	var legacy = _profile("legacy")
	assert(bool(EconomyCatalogScript.validate_building_progression_profiles([legacy]).get("ok", false)))
	var entry = _profile("wild_tuber_patch", 1, 1, "entry")
	var garden = _profile("household_tuber_garden", 2, 2, "mainline",
		PackedStringArray(["wild_tuber_patch"]))
	var farm = _profile("potato_farm", 3, 3, "terminal",
		PackedStringArray(["household_tuber_garden"]))
	farm.terminal_reason = "进入规模化农场阶段"
	var valid := EconomyCatalogScript.validate_building_progression_profiles([entry, garden, farm])
	assert(bool(valid.get("ok", false)), str(valid))
	assert(valid.building_progression_predecessor_offsets == PackedInt32Array([0, 0, 1, 2]))
	assert(valid.building_progression_predecessor_indices == PackedInt32Array([0, 1]))
	var invalid := [entry.duplicate(true), garden.duplicate(true)]
	invalid[0].maturity_rank = 2
	invalid[1].maturity_rank = 1
	assert(not bool(EconomyCatalogScript.validate_building_progression_profiles(invalid).get("ok", false)))
	invalid = [entry.duplicate(true), garden.duplicate(true)]
	invalid[1].predecessor_building_ids = PackedStringArray(["missing"])
	assert(not bool(EconomyCatalogScript.validate_building_progression_profiles(invalid).get("ok", false)))
	print("building_progression_catalog_test: PASS")
	quit()
