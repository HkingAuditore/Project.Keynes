extends SceneTree
func _init() -> void:
	var catalog := EconomyCatalog.compile_native_catalog()
	var result := {}
	for key in ["building_ids", "building_employee_offsets", "building_employee_slots", "building_employee_profession_ids", "profession_ids"]:
		result[key] = catalog.get(key)
	var f := FileAccess.open("res://tmp/manual2_building_catalog.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(result))
	quit()
