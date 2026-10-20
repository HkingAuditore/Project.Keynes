extends "res://tests/economy_cadence_runtime_test.gd"


func _init() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("food snapshot catalog and native runtime available",
		bool(compiled.get("ok", false)) and ClassDB.class_exists("DCWorldExt"))
	if bool(compiled.get("ok", false)) and ClassDB.class_exists("DCWorldExt"):
		_test_food_access_between_settlements(compiled)
		_test_food_shortage_and_cadence_change(compiled)
		_test_food_production_between_settlements(compiled)
	print("=== economy food snapshot %s ===" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)
