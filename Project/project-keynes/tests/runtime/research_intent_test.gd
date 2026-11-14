extends "res://tests/technology/technology_procurement_runtime_test.gd"
const SaveEvidence = preload("res://tests/runtime/intent_save_evidence.gd")

func _init() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	_register_environment(ext)
	var country = CountryFacadeScript.new()
	_expect("country configures", bool(country.configure(ext, 1, 9042,
		load("res://data/country/default_country.tres"), compiled).get("ok", false)))
	var gathering := (compiled.technology_ids as PackedStringArray).find(
		"tech.gathering")
	var maize_identification := (compiled.technology_ids as PackedStringArray).find(
		"tech.maize_identification")
	var early_knowledge := (compiled.technology_ids as PackedStringArray).find(
		"tech.early_knowledge_institution")
	var country_packet := {
		"country_ids": PackedStringArray(["country.procurement"]),
		"country_names": PackedStringArray(["Procurement"]),
		"country_cash": PackedInt64Array([100000000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 3]),
		"technology_indices": PackedInt32Array([
			gathering, maize_identification, early_knowledge]),
	}
	_expect("country bootstraps", bool(country.bootstrap(
		PackedByteArray([0]), country_packet).get("ok", false)))
	var handle := int(country.cell_summary(0).country_handle)
	_expect("research evidence queues", bool(country.discover_research_signal(
		handle, &"bio.maize", 0, 1, 0, 1).get("ok", false)))
	_expect("research evidence commits", bool(ext.run_country_slice(
		{"day_index": 0}).get("done", false)))
	_expect("research demand and budget queue", bool(country.enqueue_research(
		handle, &"tech.wild_maize_collection", 0, -1, 1, 10).get("ok", false))
		and bool(country.set_research_budget(handle, true, 10000000, 1, 11).get("ok", false)))
	_expect("policy commits before market settlement",
		bool(ext.run_country_slice({"day_index": 1}).get("done", false)))

	var native_catalog := compiled.duplicate(false)
	native_catalog.erase("ok")
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	# Keep the production default so research consumption is exercised while a
	# multi-day economy epoch is still frozen.
	profile.market_cycle_days = 1
	profile.economy_cadence_force_market_days = 1
	profile.market_runtime_mode = "ACTIVE"
	var economy_config: Dictionary = ext.configure_economy(native_catalog, profile, 1, 9042)
	if not bool(economy_config.get("ok", false)):
		print("  economy configure diagnostic=", economy_config)
	_expect("economy configures", bool(economy_config.get("ok", false)))
	var signatures: PackedStringArray = compiled.signature_keys
	var merchant := signatures.find("merchant|default")
	var stock := PackedInt64Array()
	stock.resize((compiled.good_ids as PackedStringArray).size())
	stock.fill(0)
	var points_good := (compiled.good_ids as PackedStringArray).find("technology_points")
	stock[points_good] = 100000
	_expect("merchant market with technology stock bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([merchant]),
		"population": PackedInt64Array([10]),
		"funds": PackedInt64Array([0]),
	}, {"stock": stock}).get("ok", false)))
	var report := _run_day(ext, 0)
	_expect("completed and conserved", bool(report.get("done", false)) and not bool(report.get("fatal", false))
		and int(report.get("money_error", -1)) == 0 and int(report.get("goods_error", -1)) == 0
		and int(report.get("population_error", -1)) == 0)
	var restored: Object = ClassDB.instantiate("DCWorldExt")
	restored.create_entities(1)
	_register_environment(restored)
	var restored_country = CountryFacadeScript.new()
	_expect("restore Country configured", bool(restored_country.configure(restored, 1, 9042,
		load("res://data/country/default_country.tres"), compiled).get("ok", false)))
	var evidence := SaveEvidence.capture(ext, restored, [1], func() -> Dictionary: return restored.configure_economy(native_catalog, profile, 1, 9042))
	_expect("save evidence complete", not evidence.is_empty())
	print("RESEARCH_INTENT_RESULT=" + JSON.stringify(evidence))
	ext = null
	print("research intent: %d failures" % _failures)
	quit(0 if _failures == 0 else 1)
