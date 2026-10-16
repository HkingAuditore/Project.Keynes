extends "res://tests/satisfaction_runtime_test.gd"

## Focused purchasing-power regression, independent of unrelated full-world
## replay hash/cadence failures in the older comprehensive test suites.
func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("purchasing-power catalog compiles", bool(compiled.get("ok", false)))
	_expect("native economy is available", ClassDB.class_exists("DCWorldExt"))
	if not bool(compiled.get("ok", false)) or not ClassDB.class_exists("DCWorldExt"):
		return
	_test_catalog_columns(compiled)
	_test_purchasing_power(compiled)
	_test_class_weight_differentiation(compiled)
	_test_dimensions_and_gate(compiled)
	_test_explain_and_attractiveness(compiled)
	_test_save_round_trip(compiled, false)
