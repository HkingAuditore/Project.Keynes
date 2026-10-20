extends SceneTree

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")

func _init() -> void:
	var catalog: Dictionary = TechnologyCatalogScript.compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		print("[TECH_CATALOG_ERROR] ", JSON.stringify(catalog))
		quit(1)
		return
	print("[TECH_CATALOG_OK] nodes=", (catalog.technology_ids as PackedStringArray).size(),
		" starting=", (catalog.starting_technology_ids as PackedStringArray).size(),
		" eligible=", (catalog.starter_eligible_technology_ids as PackedStringArray).size())
	quit(0)
