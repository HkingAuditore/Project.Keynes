extends "res://tests/economy/treasury_construction_runtime_test.gd"
const SaveEvidence = preload("res://tests/runtime/intent_save_evidence.gd")

func _init() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(catalog.get("ok", false)))
	catalog.erase("ok")
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 5
	var ext := _fixture(catalog, profile, 1000000000000)
	_expect("fixture commits", bool(_run_day(ext, 0).get("done", false)))
	var handle := int(ext.get_country_cell_summary(0).country_handle)
	var candidate := _eligible_candidate(ext, catalog, handle)
	_expect("nonzero construction quote", candidate >= 0)
	_expect("construction submitted", bool(_submit(ext, handle, candidate, 701).get("ok", false)))
	var report := _run_day(ext, 1)
	_expect("completed and conserved", bool(report.get("done", false)) and not bool(report.get("fatal", false))
		and int(report.get("money_error", -1)) == 0 and int(report.get("goods_error", -1)) == 0
		and int(report.get("population_error", -1)) == 0)
	var restored := _new_ext(catalog)
	_expect("restore Country configured", bool(restored.configure_country(catalog, {"country_runtime_mode": "ACTIVE"}, 1, 914).get("ok", false)))
	var evidence := SaveEvidence.capture(ext, restored, [9], func() -> Dictionary: return restored.configure_economy(catalog, profile, 1, 914))
	print("TREASURY_SPEND_RESULT=" + JSON.stringify(evidence))
	ext = null
	print("treasury spend intent: %d failures" % _failures)
	quit(0 if _failures == 0 else 1)
