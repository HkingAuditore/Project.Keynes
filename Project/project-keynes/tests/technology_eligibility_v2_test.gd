extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")

var _failures := 0
var _compiled: Dictionary


func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("technology eligibility v2: SKIP")
		quit(0)
		return
	_compiled = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(_compiled.get("ok", false)))
	var locked := _fixture(PackedStringArray([
		"tech.celestial_calendars", "tech.permanent_settlements",
	]), "resource.clay")
	var locked_writing_state := _state(locked, "tech.writing")
	_expect("revealed kingdom technology remains era-locked",
		locked_writing_state == 1, "state=%d" % locked_writing_state)
	_attempt_enqueue(locked, "tech.writing", 1)
	locked_writing_state = _state(locked, "tech.writing")
	_expect("bottom-level enqueue cannot bypass the era gate",
		locked_writing_state == 1
		and (_snapshot(locked).queue_technology_indices as PackedInt32Array).is_empty(),
		"state=%d queue=%s" % [locked_writing_state,
			str(_snapshot(locked).queue_technology_indices)])

	var opened := _fixture(PackedStringArray([
		"tech.agrarian_society", "tech.celestial_calendars",
		"tech.permanent_settlements",
	]),
		"resource.clay")
	_expect("the prior era milestone opens the whole next era",
		_state(opened, "tech.writing") == 2)
	_attempt_enqueue(opened, "tech.writing", 1)
	_expect("era-open technology queues without a node milestone edge",
		_state(opened, "tech.writing") == 3)

	var gis_completed := PackedStringArray([
		"tech.atomic_modernity", "tech.cartography", "tech.digital_computing",
		"tech.probability_statistics", "tech.satellite_observation",
	])
	var gis := _fixture(gis_completed, "breakthrough.digital_control")
	_expect("GIS ANY_OF accepts one genuine application route",
		_state(gis, "tech.geographic_information_systems") == 2)

	var classification_one := _fixture(PackedStringArray([
		"tech.global_exchange", "tech.natural_philosophy",
		"tech.experimental_science",
	]), "breakthrough.printing")
	_expect("scientific classification AT_LEAST rejects one of three routes",
		_state(classification_one, "tech.scientific_classification") == 1)
	var classification_two := _fixture(PackedStringArray([
		"tech.global_exchange", "tech.natural_philosophy",
		"tech.experimental_science", "tech.learned_societies",
	]), "breakthrough.printing")
	_expect("scientific classification AT_LEAST accepts two of three routes",
		_state(classification_two, "tech.scientific_classification") == 2)
	print("technology eligibility v2: %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)


func _fixture(completed_ids: PackedStringArray, signal_id: String) -> Dictionary:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var facade = CountryFacadeScript.new()
	var configured: Dictionary = facade.configure(ext, 1, 777,
		load("res://data/country/default_country.tres"), _compiled)
	_expect("fixture configures", bool(configured.get("ok", false)))
	var technology_indices := PackedInt32Array()
	var technology_ids: PackedStringArray = _compiled.technology_ids
	for technology_id in completed_ids:
		var index := technology_ids.find(technology_id)
		assert(index >= 0, technology_id)
		technology_indices.append(index)
	var bootstrapped: Dictionary = facade.bootstrap(PackedByteArray([0]), {
		"country_ids": PackedStringArray(["country.eligibility"]),
		"country_names": PackedStringArray(["Eligibility"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, technology_indices.size()]),
		"technology_indices": technology_indices,
	})
	_expect("fixture bootstraps", bool(bootstrapped.get("ok", false)))
	var handle := int(facade.cell_summary(0).country_handle)
	_expect("fixture signal queues", bool(facade.discover_research_signal(
		handle, StringName(signal_id), 0, 1, 0, 1).get("ok", false)))
	_expect("fixture signal commits", bool(ext.run_country_slice(
		{"day_index": 0}).get("done", false)))
	return {"ext": ext, "facade": facade, "handle": handle, "day": 1}


func _attempt_enqueue(fixture: Dictionary, technology_id: String,
		day: int) -> void:
	var technology_index := (_compiled.technology_ids as PackedStringArray).find(
		technology_id)
	var domain := int((_compiled.technology_domain_indices as PackedInt32Array)[technology_index])
	(fixture.facade as Object).enqueue_research(int(fixture.handle),
		StringName(technology_id), domain, -1, day, 100 + day)
	(fixture.ext as Object).run_country_slice({"day_index": day})


func _snapshot(fixture: Dictionary) -> Dictionary:
	return (fixture.facade as Object).research_snapshot(int(fixture.handle))


func _state(fixture: Dictionary, technology_id: String) -> int:
	var index := (_compiled.technology_ids as PackedStringArray).find(technology_id)
	return int((_snapshot(fixture).technology_states as PackedInt32Array)[index])


func _expect(label: String, condition: bool, detail := "") -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s%s" % [label,
			(" (%s)" % detail) if not detail.is_empty() else ""])
