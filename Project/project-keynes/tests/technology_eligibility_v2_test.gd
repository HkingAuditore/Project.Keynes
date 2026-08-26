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
	_expect("stable technology count", ids.size() == 705)
	_expect("route IR is present", (_compiled.get("research_route_ids", PackedStringArray()) as PackedStringArray).size() > 600)

	# Ordinary next-era nodes: reveal, hard prerequisites and one complete route
	# are enough. The previous-era milestone is not a research gate.
	var writing_revealed_only := _fixture(PackedStringArray([
		"tech.celestial_calendars", "tech.permanent_settlements",
	]), PackedStringArray(["development.population.500_90d"]))
	_expect("development-revealed kingdom node stays ineligible without a route",
		_state(writing_revealed_only, "tech.writing") == 1)

	var writing_without_era := _fixture(PackedStringArray([
		"tech.celestial_calendars", "tech.permanent_settlements",
	]), PackedStringArray([
		"development.population.500_90d",
		"development.employment.agriculture.10_90d",
	]))
	_expect("revealed kingdom node is researchable without the agrarian milestone",
		_state(writing_without_era, "tech.writing") == 2)
	_attempt_enqueue(writing_without_era, "tech.writing", int(writing_without_era.day))
	_expect("kingdom node can enter the queue without the agrarian milestone",
		_state(writing_without_era, "tech.writing") == 3)

	var revealed := _fixture(PackedStringArray([
		"tech.agrarian_society", "tech.celestial_calendars",
		"tech.permanent_settlements",
	]), PackedStringArray(["development.population.500_90d"]))
	_expect("milestone plus reveal still requires a complete route",
		_state(revealed, "tech.writing") == 1)

	_discover(revealed, PackedStringArray(["development.employment.agriculture.10_90d"]))
	_expect("one complete research route produces eligible state",
		_state(revealed, "tech.writing") == 2)
	_attempt_enqueue(revealed, "tech.writing", int(revealed.day))
	_expect("eligible node can enter the queue",
		_state(revealed, "tech.writing") == 3)

	var kingdom_milestone_locked := _fixture(PackedStringArray([
		"tech.crop_rotation", "tech.road_engineering",
		"tech.writing", "tech.state_bureaucracy",
	]), PackedStringArray())
	_expect("kingdom milestone stays era-locked without agrarian_society",
		_state(kingdom_milestone_locked, "tech.kingdom_administration") == 1)
	var kingdom_milestone_open := _fixture(PackedStringArray([
		"tech.agrarian_society", "tech.crop_rotation", "tech.road_engineering",
		"tech.writing", "tech.state_bureaucracy",
	]), PackedStringArray())
	_expect("kingdom milestone opens after the previous era and candidate threshold",
		_state(kingdom_milestone_open, "tech.kingdom_administration") == 2)

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

	var flint_locked := _fixture(PackedStringArray(["tech.gathering"]),
		PackedStringArray(["resource.flint"]))
	_expect("flint stays ineligible until a knowledge practice is completed",
		_state(flint_locked, "tech.flint_identification") == 1)
	var flint_open := _fixture(
		PackedStringArray(["tech.gathering", "tech.early_knowledge_institution"]),
		PackedStringArray(["resource.flint"]))
	_expect("the unified institution route opens flint research",
		_state(flint_open, "tech.flint_identification") == 2)

	var seasonal_locked := _fixture(PackedStringArray(["tech.gathering"]),
		PackedStringArray())
	_expect("seasonal foraging stays ineligible until a knowledge practice is completed",
		_state(seasonal_locked, "tech.seasonal_foraging") == 1)
	var seasonal_open := _fixture(
		PackedStringArray(["tech.gathering", "tech.early_knowledge_institution"]),
		PackedStringArray())
	_expect("the unified institution opens seasonal foraging",
		_state(seasonal_open, "tech.seasonal_foraging") == 2)

	var composite_hidden := _fixture(PackedStringArray(["tech.stone_knapping"]),
		PackedStringArray())
	_expect("composite tools stay hidden without stone or flint evidence",
		_state(composite_hidden, "tech.composite_tools") == 0)
	_discover(composite_hidden, PackedStringArray(["resource.stone"]))
	_expect("stone evidence reveals composite tools",
		_state(composite_hidden, "tech.composite_tools") == 2)

	var hide_locked := _fixture(PackedStringArray(["tech.hunting"]),
		PackedStringArray(["resource.wild_game"]))
	_expect("hide scraping stays ineligible on a warm start until knowledge",
		_state(hide_locked, "tech.hide_scraping") == 1)
	var hide_open := _fixture(
		PackedStringArray(["tech.hunting", "tech.early_knowledge_institution"]),
		PackedStringArray(["resource.wild_game"]))
	_expect("the unified institution opens hide scraping",
		_state(hide_open, "tech.hide_scraping") == 2)

	var coastal_open := _fixture(PackedStringArray([
		"tech.early_knowledge_institution", "tech.wild_flax_collection",
	]),
		PackedStringArray(["resource.marine_fish"]))
	_expect("marine evidence opens coastal fishing after knowledge and net fiber",
		_state(coastal_open, "tech.coastal_fishing") == 2)
	var freshwater_open := _fixture(PackedStringArray([
		"tech.early_knowledge_institution", "tech.wild_flax_collection",
	]), PackedStringArray(["resource.freshwater_fish"]))
	_expect("freshwater evidence opens fishing after knowledge and net fiber",
		_state(freshwater_open, "tech.freshwater_fishing") == 2)

	# Regional knowledge buildings provide technology points; their memory type
	# must not become a hard gate for unrelated stone technologies.
	var coastal_alternatives := _fixture(PackedStringArray([
		"tech.early_knowledge_institution", "tech.hunting",
	]), PackedStringArray([
		"resource.timber", "resource.marine_fish",
	]))
	_expect("fire control remains locked without gathering and deadwood collection",
		_state(coastal_alternatives, "tech.fire_control") == 1)
	_expect("husbandry stays hidden without a domesticable animal signal",
		_state(coastal_alternatives, "tech.animal_husbandry") == 0)
	_discover(coastal_alternatives, PackedStringArray(["bio.sheep"]))
	_expect("a domesticable animal signal reveals husbandry",
		_state(coastal_alternatives, "tech.animal_husbandry") == 2)
	var fire_control_open := _fixture(PackedStringArray([
		"tech.early_knowledge_institution", "tech.gathering", "tech.hunting",
		"tech.deadwood_collection",
	]), PackedStringArray(["resource.timber"]))
	_expect("fire control opens after its fuel and food supply foundations",
		_state(fire_control_open, "tech.fire_control") == 2)
	var boats_from_coast := _fixture(PackedStringArray([
		"tech.settled_knowledge", "tech.coastal_fishing",
	]), PackedStringArray(["resource.marine_fish"]))
	_expect("completed coastal fishing alone opens fishing boats",
		_state(boats_from_coast, "tech.fishing_boats") == 2)
	var boats_from_freshwater := _fixture(PackedStringArray([
		"tech.settled_knowledge", "tech.freshwater_fishing",
	]), PackedStringArray(["resource.freshwater_fish"]))
	_expect("completed freshwater fishing alone opens fishing boats",
		_state(boats_from_freshwater, "tech.fishing_boats") == 2)
	var coastal_without_fish := _fixture(PackedStringArray([
		"tech.settled_knowledge", "tech.early_knowledge_institution",
	]), PackedStringArray(["resource.marine_fish", "resource.freshwater_fish"]))
	_expect("fishing boats stay ineligible without either fishing technology",
		_state(coastal_without_fish, "tech.fishing_boats") == 1)

	var coastal_calendar := _fixture(PackedStringArray([
		"tech.early_knowledge_institution", "tech.natural_observation",
		"tech.oral_tradition",
	]), PackedStringArray())
	_expect("the unified institution opens seasonal calendar after its core history",
		_state(coastal_calendar, "tech.seasonal_calendar") == 2)

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
