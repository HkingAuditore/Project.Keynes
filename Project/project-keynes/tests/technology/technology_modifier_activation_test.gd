extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

var _failures := 0

func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		quit()
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var modifiers = ModifierFacadeScript.new()
	_expect("modifier catalog configures", bool(modifiers.configure(ext, 4).get("ok", false)))
	var country = CountryFacadeScript.new()
	_expect("country configures", bool(country.configure(ext, 1, 9043,
		load("res://data/country/default_country.tres"), compiled).get("ok", false)))
	var points_good := (compiled.good_ids as PackedStringArray).find("technology_points")
	var gathering := (compiled.technology_ids as PackedStringArray).find(
		"tech.gathering")
	var maize_identification := (compiled.technology_ids as PackedStringArray).find(
		"tech.maize_identification")
	var early_knowledge := (compiled.technology_ids as PackedStringArray).find(
		"tech.early_knowledge_institution")
	_expect("country bootstraps", bool(country.bootstrap(PackedByteArray([0]), {
		"country_ids": PackedStringArray(["country.modifier"]),
		"country_names": PackedStringArray(["Modifier"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 3]),
		"technology_indices": PackedInt32Array([
			gathering, maize_identification, early_knowledge]),
		"treasury_offsets": PackedInt32Array([0, 1]),
		"treasury_good_indices": PackedInt32Array([points_good]),
		"treasury_quantities": PackedInt64Array([10000000]),
	}).get("ok", false)))
	var handle := int(country.cell_summary(0).country_handle)
	_expect("research evidence queues", bool(country.discover_research_signal(
		handle, &"bio.maize", 0, 1, 0, 1).get("ok", false)))
	_expect("research evidence commits", bool(ext.run_country_slice(
		{"day_index": 0}).get("done", false)))
	_expect("single-domain completion queues", bool(country.set_research_weights(
		handle, PackedInt32Array([10000, 0, 0, 0]), 1, 10).get("ok", false))
		and bool(country.enqueue_research(handle, &"tech.wild_maize_collection",
			0, -1, 1, 11).get("ok", false)))
	_expect("completion enters pending state", bool(ext.run_country_slice(
		{"day_index": 1}).get("done", false)))
	var ids: PackedStringArray = compiled.technology_ids
	var tech := ids.find("tech.wild_maize_collection")
	var pending: Dictionary = country.research_snapshot(handle)
	_expect("pending state does not expose completion tag",
		int(pending.technology_states[tech]) == 4
		and not (country.snapshot(handle).technology_ids as PackedStringArray).has(
			"tech.wild_maize_collection"))
	var term_offsets: PackedInt32Array = compiled.technology_modifier_term_offsets
	var term_stats: PackedStringArray = compiled.technology_modifier_term_stat_keys
	var term_values: PackedFloat64Array = compiled.technology_modifier_term_values
	var term_index := int(term_offsets[tech])
	var stat := String(term_stats[term_index])
	var expected_delta := float(term_values[term_index])
	var before := float(ext.evaluate_modifier_stat(1, handle, 0, stat, 1.0))
	_expect("pending state has no numerical effect", is_equal_approx(before, 1.0))
	_expect("next day activates technology atomically", bool(ext.run_country_slice(
		{"day_index": 2}).get("done", false)))
	var completed: Dictionary = country.research_snapshot(handle)
	var effective := float(ext.evaluate_modifier_stat(1, handle, 0, stat, 1.0))
	_expect("completion tag and modifier become visible together",
		int(completed.technology_states[tech]) == 5
		and (country.snapshot(handle).technology_ids as PackedStringArray).has(
			"tech.wild_maize_collection")
		and is_equal_approx(effective, 1.0 + expected_delta))
	var explain: Dictionary = modifiers.explain_stat(1, handle, 0, stat, 1.0)
	_expect("technology modifier remains explainable",
		float(explain.get("effective_value", 1.0)) == effective
		and (explain.get("handles", PackedInt64Array()) as PackedInt64Array).size() == 1)
	_expect("later days do not double-apply UNIQUE_SOURCE", bool(ext.run_country_slice(
		{"day_index": 3}).get("done", false))
		and is_equal_approx(float(ext.evaluate_modifier_stat(
			1, handle, 0, stat, 1.0)), effective))
	print("technology modifier activation: %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
