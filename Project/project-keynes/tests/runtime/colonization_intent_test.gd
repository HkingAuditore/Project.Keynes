extends "res://tests/family/family_colonization_runtime_test.gd"
const SaveEvidence = preload("res://tests/runtime/intent_save_evidence.gd")

func _init() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(catalog.get("ok", false)))
	catalog.erase("ok")
	var fixture := _make_fixture(catalog, 260823, 1000000, {}, PackedStringArray(), 1, 1000000000000)
	var ext: Object = fixture.ext
	var started := _start_single_colonization(ext, int(fixture.country_handle), "intent fixture", 1500)
	_expect("expedition accepted", bool(started.get("ok", false)))
	var report := _run_day(ext, int(started.start_day) + 1)
	_expect("completed and conserved", bool(report.get("done", false)) and not bool(report.get("fatal", false))
		and int(report.get("money_error", -1)) == 0 and int(report.get("goods_error", -1)) == 0
		and int(report.get("population_error", -1)) == 0)
	var restored: Object = ClassDB.instantiate("DCWorldExt")
	_expect("restore map bound", bool(restored.bind_map_data(fixture.map)))
	var modifiers: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	modifiers.erase("ok")
	_expect("restore modifiers configured", bool(restored.configure_modifiers(modifiers, 3).get("ok", false)))
	var effects := EffectCatalogScript.new()
	_expect("restore effects configured", bool(restored.configure_effects(effects.compile_native_catalog()).get("ok", false)))
	_expect("restore Country configured", bool(restored.configure_country(catalog,
		{"country_runtime_mode": "ACTIVE", "starting_technology_ids": catalog.technology_ids}, 3, 260823).get("ok", false)))
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "ACTIVE"
	profile.family_milestone_populations = PackedInt64Array([1, 2, 3, 4, 5, 6, 7, 8])
	profile.family_min_founder_people = 20
	profile.family_founding_choice_mode = "AUTO"
	profile.notable_person_runtime_mode = "ACTIVE"
	profile.starvation_death_rate_q32 = 0
	for domain in range(4):
		_expect("restore modifier domain", bool(restored.restore_modifier_domain(domain, ext.capture_modifier_domain(domain)).get("ok", false)))
	var evidence := SaveEvidence.capture(ext, restored, [8, 9], func() -> Dictionary: return restored.configure_economy(catalog, profile, 3, 260823), [[42047, 1, 3]])
	_expect("save evidence complete", not evidence.is_empty())
	print("COLONIZATION_INTENT_RESULT=" + JSON.stringify(evidence))
	if OS.get_environment("PK_COLONIZATION_INTENT_CAPTURE") != "1":
		_expect("receipts and roundtrip bytes unchanged", JSON.parse_string(JSON.stringify(evidence)) ==
			JSON.parse_string(FileAccess.get_file_as_string("res://tests/runtime/colonization_intent_baseline.json")))
	ext = null
	print("colonization intent: %d failures" % _failures)
	quit(0 if _failures == 0 else 1)
