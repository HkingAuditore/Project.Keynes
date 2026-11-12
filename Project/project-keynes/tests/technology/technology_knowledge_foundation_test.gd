extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")
var _failures := 0
var _compiled: Dictionary


func _init() -> void:
	assert(ClassDB.class_exists("DCWorldExt"), "native research runtime is required")
	_compiled = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(_compiled.get("ok", false)))
	var starters: PackedStringArray = _compiled.starter_eligible_technology_ids
	var signals := PackedStringArray(["resource.iron_ore", "resource.coal", "resource.timber",
		"development.trade.goods_2", "development.buildings.active_4_180d"])
	var blocked := _fixture(starters, signals)
	_expect("early knowledge institution is the first research opportunity",
		_state(blocked, "tech.early_knowledge_institution") == 2)
	for id in ["tech.iron_ore_identification", "tech.coal_outcrop_identification", "tech.market_institutions"]:
		_expect("resource sighting only reveals: %s" % id, _state(blocked, id) == 1)
		_attempt_enqueue(blocked, id, int(blocked.day), false)
		blocked.day = int(blocked.day) + 1
		_expect("missing institution prevents enqueue: %s" % id, _state(blocked, id) == 1)
	var completed := starters.duplicate()
	completed.append("tech.early_knowledge_institution")
	completed.append("tech.stone_knapping")
	completed.append("tech.natural_observation")
	completed.append("tech.fire_control")
	var ready := _fixture(completed, signals)
	for id in ["tech.iron_ore_identification", "tech.coal_outcrop_identification", "tech.market_institutions"]:
		_expect("institution and tools enable research without an era milestone: %s" % id,
			_state(ready, id) == 2)
		_attempt_enqueue(ready, id, int(ready.day))
		ready.day = int(ready.day) + 1
		_expect("eligible resource identification queues: %s" % id, _state(ready, id) == 3)
	_assert_professional_prerequisites()
	print("knowledge institution prerequisite: %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)


func _fixture(completed_ids: PackedStringArray, signal_ids: PackedStringArray) -> Dictionary:
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
	_discover({"facade": facade, "ext": ext, "handle": handle, "day": 1}, signal_ids)
	return {"ext": ext, "facade": facade, "handle": handle, "day": 2}


func _discover(fixture: Dictionary, signal_ids: PackedStringArray) -> void:
	var facade: Object = fixture.facade
	var handle := int(fixture.handle)
	var day := int(fixture.get("day", 1))
	var sequence := 100
	for signal_id in signal_ids:
		var result: Dictionary = facade.discover_research_signal(
			handle, StringName(signal_id), 0, 1, day, sequence)
		_expect("signal queues: %s" % signal_id, bool(result.get("ok", false)))
		sequence += 1
	if signal_ids.is_empty():
		return
	_expect("signals commit", bool((fixture.ext as Object).run_country_slice(
		{"day_index": day}).get("done", false)))
	fixture.day = day + 1


func _attempt_enqueue(fixture: Dictionary, technology_id: String, day: int,
		expected_ok := true) -> void:
	var technology_index := (_compiled.technology_ids as PackedStringArray).find(technology_id)
	var domain := int((_compiled.technology_domain_indices as PackedInt32Array)[technology_index])
	var submitted: Dictionary = (fixture.facade as Object).enqueue_research(int(fixture.handle),
		StringName(technology_id), domain, -1, day, 1000 + day)
	_expect("enqueue command submits", bool(submitted.get("ok", false)))
	var report: Dictionary = (fixture.ext as Object).run_country_slice({"day_index": day})
	_expect("enqueue admission matches prerequisites", bool(report.get("ok", false)) == expected_ok)


func _state(fixture: Dictionary, technology_id: String) -> int:
	var index := (_compiled.technology_ids as PackedStringArray).find(technology_id)
	return int((fixture.facade as Object).research_snapshot(int(fixture.handle))
		.technology_states[index])


func _expect(label: String, condition: bool, detail := "") -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s%s" % [label,
			(" (%s)" % detail) if not detail.is_empty() else ""])


func _assert_professional_prerequisites() -> void:
	var required_by_target := {
		"tech.iron_ore_identification": ["tech.stone_knapping", "tech.natural_observation"],
		"tech.coal_outcrop_identification": ["tech.stone_knapping", "tech.fire_control"],
		"tech.copper_annealing": ["tech.fire_control"],
		"tech.bronze_casting": ["tech.kiln_firing"],
		"tech.hearth_preservation": ["tech.fire_control"],
		"tech.fishing_boats": ["tech.stone_knapping"],
		"tech.maize_selection": ["tech.maize_propagation"],
		"tech.dryland_farming": ["tech.rainfed_wheat_cultivation"],
	}
	var network: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		"res://data/technology/technology_network.json"))
	var rows := {}
	for row in network.nodes:
		rows[String(row.id)] = row
	for target in required_by_target:
		var evidence := PackedStringArray()
		_collect_signals(rows[target].get("reveal_condition", {}), evidence)
		for route in rows[target].get("research_routes", []):
			_collect_signals(route.get("condition", {}), evidence)
		var all_others: PackedStringArray = (_compiled.technology_ids as PackedStringArray).duplicate()
		all_others.remove_at(all_others.find(target))
		# Grant other knowledge deliberately to isolate each irreplaceable prerequisite.
		for required in required_by_target[target]:
			var missing := all_others.duplicate()
			missing.remove_at(missing.find(required))
			var blocked := _fixture(missing, evidence)
			_expect("all routes stay locked without %s: %s" % [required, target],
				_state(blocked, target) == 1)
			_attempt_enqueue(blocked, target, int(blocked.day), false)
		var ready := _fixture(all_others, evidence)
		_expect("complete knowledge enables %s" % target, _state(ready, target) == 2)
		_attempt_enqueue(ready, target, int(ready.day))
		_expect("complete knowledge queues %s" % target, _state(ready, target) == 3)


func _collect_signals(condition: Dictionary, out: PackedStringArray) -> void:
	if int(condition.get("kind", -1)) == 1:
		var id := String(condition.id)
		if not out.has(id):
			out.append(id)
	for child in condition.get("children", []):
		_collect_signals(child, out)
