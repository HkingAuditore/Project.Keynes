extends SceneTree

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")

func _init() -> void:
	var catalog: Dictionary = TechnologyCatalogScript.compile_native_catalog()
	assert(bool(catalog.get("ok", false)), str(catalog))
	assert((catalog.technology_ids as PackedStringArray).size() == 81)
	assert((catalog.starting_technology_ids as PackedStringArray).size() == 4)
	assert((catalog.technology_era_ids_ordered as PackedStringArray).size() == 11)
	assert((catalog.technology_domain_ids as PackedStringArray).size() == 4)
	var researchable := 0
	var milestones := 0
	for i in range(catalog.technology_ids.size()):
		if int(catalog.technology_costs[i]) > 0:
			researchable += 1
		if (int(catalog.technology_flags[i]) & 2) != 0:
			milestones += 1
			assert(int(catalog.technology_milestone_required_counts[i]) == 2)
			assert(int(catalog.technology_milestone_offsets[i + 1]) - int(catalog.technology_milestone_offsets[i]) == 4)
	assert(researchable == 77)
	assert(milestones == 11)
	print("[PASS] authoritative technology catalog: 81 definitions / 77 researchable")
	quit(0)
