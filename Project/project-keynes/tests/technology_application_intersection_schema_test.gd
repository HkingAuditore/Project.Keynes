extends SceneTree

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")


func _init() -> void:
	var network := {
		"schema_version": 4,
		"eras": [{"id": "agrarian"}],
		"domains": [{"id": "agriculture"}],
		"backbones": [],
		"branch_families": [{"id": "branch.tuber_highland"}],
		"nodes": [{"id": "tech.potato_propagation"}, {"id": "tech.rainfed_field_system"}],
		"application_intersections": [{
			"id": "app.rainfed_tuber_gardening",
			"display_name": "雨养块茎园艺",
			"era_id": "agrarian",
			"domain_id": "agriculture",
			"industry_chain_id": "branch.tuber_highland",
			"layout_order": 1.0,
			"required_technology_ids": ["tech.potato_propagation", "tech.rainfed_field_system"],
			"building_ids": ["household_tuber_garden"],
		}],
	}
	var valid := TechnologyCatalogScript.validate_application_intersections(network)
	assert(bool(valid.get("ok", false)), str(valid))
	var duplicate := network.duplicate(true)
	duplicate.application_intersections.append(duplicate.application_intersections[0].duplicate(true))
	assert(not bool(TechnologyCatalogScript.validate_application_intersections(duplicate).get("ok", false)))
	var unknown := network.duplicate(true)
	unknown.application_intersections[0].required_technology_ids[1] = "tech.unknown"
	assert(not bool(TechnologyCatalogScript.validate_application_intersections(unknown).get("ok", false)))
	var legacy := network.duplicate(true)
	legacy.schema_version = 3
	legacy.erase("application_intersections")
	assert(bool(TechnologyCatalogScript.validate_application_intersections(legacy).get("ok", false)))
	print("technology_application_intersection_schema_test: PASS")
	quit()
