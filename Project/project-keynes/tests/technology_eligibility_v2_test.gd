extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")

var _failures := 0
var _compiled: Dictionary


func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("technology eligibility v3: SKIP")
		quit(0)
		return
	_compiled = EconomyCatalogScript.compile_native_catalog()
	_expect("schema v3 catalog compiles", bool(_compiled.get("ok", false)))
	var ids: PackedStringArray = _compiled.get("technology_ids", PackedStringArray())
	_expect("stable technology count", ids.size() == 361)
	_expect("route IR is present", (_compiled.get("research_route_ids", PackedStringArray()) as PackedStringArray).size() > 600)

	# Era milestone is a hard gate, while the node's discovery signal and one
	# complete route are separate gates. This is the core v3 eligibility contract.
	var before_milestone := _fixture(PackedStringArray([
		"tech.celestial_calendars", "tech.permanent_settlements",
	]), PackedStringArray(["development.population.500_90d"]))
	_expect("development-revealed kingdom node remains era-locked",
		_state(before_milestone, "tech.writing") == 1)

	var revealed := _fixture(PackedStringArray([
		"tech.agrarian_society", "tech.celestial_calendars",
		"tech.permanent_settlements",
	]), PackedStringArray(["development.population.500_90d"]))
	_expect("milestone plus reveal produces revealed state",
		_state(revealed, "tech.writing") == 1)

	_discover(revealed, PackedStringArray(["development.employment.agriculture.10_90d"]))
	_expect("one complete research route produces eligible state",
		_state(revealed, "tech.writing") == 2)
	_attempt_enqueue(revealed, "tech.writing", int(revealed.day))
	_expect("eligible node can enter the queue",
		_state(revealed, "tech.writing") == 3)

	# The plantation sample has three route packages; the land-institution route
	# is executable without cotton/spice discovery signals.
	var plantation := _fixture(PackedStringArray([
		"tech.imperial_integration", "tech.global_exchange",
		"tech.commodity_crop_management", "tech.commercial_tenancy",
		"tech.estate_accounting",
	]), PackedStringArray([
		"development.commodity_crop_variety_2",
	]))
	_expect("plantation reveal waits for both development facts",
		_state(plantation, "tech.estate_plantation_management") == 0)
	_discover(plantation, PackedStringArray([
		"development.commodity_crop_facilities_4_180d",
	]))
	# The first route is already complete; its state is now eligible without the
	# target's own plantation buildings or bio.cotton/bio.spice signals.
	_expect("plantation land-institution route is eligible",
		_state(plantation, "tech.estate_plantation_management") == 2)

	print("technology eligibility v3: %s" % ("PASS" if _failures == 0 else "FAIL"))
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


func _attempt_enqueue(fixture: Dictionary, technology_id: String, day: int) -> void:
	var technology_index := (_compiled.technology_ids as PackedStringArray).find(technology_id)
	var domain := int((_compiled.technology_domain_indices as PackedInt32Array)[technology_index])
	var submitted: Dictionary = (fixture.facade as Object).enqueue_research(int(fixture.handle),
		StringName(technology_id), domain, -1, day, 1000 + day)
	_expect("eligible enqueue command submits", bool(submitted.get("ok", false)))
	var report: Dictionary = (fixture.ext as Object).run_country_slice({"day_index": day})
	_expect("eligible enqueue command commits", bool(report.get("ok", false)))


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
