extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const EffectFacadeScript = preload("res://scripts/effect/effect_facade.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

var _failures := 0

func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("technology_pending_activation_scheduler_test: SKIP")
		quit(0)
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var modifiers = ModifierFacadeScript.new()
	_expect("modifier catalog configures", bool(modifiers.configure(ext, 4).get("ok", false)))
	var effect := EffectFacadeScript.new()
	_expect("effect catalog configures", bool(effect.configure(
		ext, null, EffectDomainCatalogScript.build()).get("ok", false)))
	var country = CountryFacadeScript.new()
	_expect("country configures", bool(country.configure(ext, 1, 9044,
		load("res://data/country/default_country.tres"), compiled).get("ok", false)))
	effect.register_domain_adapters(modifiers, country, null)
	var points_good := (compiled.good_ids as PackedStringArray).find("technology_points")
	var gathering := (compiled.technology_ids as PackedStringArray).find("tech.gathering")
	var maize_identification := (compiled.technology_ids as PackedStringArray).find(
		"tech.maize_identification")
	var oral_memory := (compiled.technology_ids as PackedStringArray).find(
		"tech.oral_memory_practice")
	var phenology_observation := (compiled.technology_ids as PackedStringArray).find(
		"tech.phenology_observation")
	_expect("country bootstraps", bool(country.bootstrap(PackedByteArray([0]), {
		"country_ids": PackedStringArray(["country.scheduler"]),
		"country_names": PackedStringArray(["Scheduler"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 4]),
		"technology_indices": PackedInt32Array([
			gathering, maize_identification, oral_memory, phenology_observation]),
		"treasury_offsets": PackedInt32Array([0, 1]),
		"treasury_good_indices": PackedInt32Array([points_good]),
		"treasury_quantities": PackedInt64Array([10000000]),
	}).get("ok", false)))
	var handle := int(country.cell_summary(0).country_handle)
	_expect("research evidence queues", bool(country.discover_research_signal(
		handle, &"bio.maize", 0, 1, 0, 1).get("ok", false)))
	_run_production_day(ext, 0)
	_expect("single-domain completion queues", bool(country.set_research_weights(
		handle, PackedInt32Array([10000, 0, 0, 0]), 1, 10).get("ok", false))
		and bool(country.enqueue_research(handle, &"tech.wild_maize_collection",
			0, -1, 1, 11).get("ok", false)))
	_run_production_day(ext, 1)
	var ids: PackedStringArray = compiled.technology_ids
	var tech := ids.find("tech.wild_maize_collection")
	var pending: Dictionary = country.research_snapshot(handle)
	_expect("research completion stays pending on the completion day",
		int(pending.technology_states[tech]) == 4
		and not (country.snapshot(handle).technology_ids as PackedStringArray).has(
			"tech.wild_maize_collection"))
	var pending_report: Dictionary = country.report()
	var rebuilds_after_completion := int(pending_report.get(
		"research_queue_rebuilds", -1))
	_expect("pending activation queue contains only the completed technology",
		int(pending_report.get("research_queue_size", -1)) == 1)
	_run_production_day(ext, 2)
	var completed: Dictionary = country.research_snapshot(handle)
	_expect("next production morning activates after Effect ACK",
		int(completed.technology_states[tech]) == 5
		and (country.snapshot(handle).technology_ids as PackedStringArray).has(
			"tech.wild_maize_collection"))
	var activated_report: Dictionary = country.report()
	_expect("activation removes the technology from the pending queue",
		int(activated_report.get("research_queue_size", -1)) == 0)
	_expect("activation updates the queue incrementally",
		int(activated_report.get("research_queue_rebuilds", -2)) ==
			rebuilds_after_completion)
	_run_production_day(ext, 3)
	_expect("later production days keep the completed tag",
		int(country.research_snapshot(handle).technology_states[tech]) == 5)
	_expect("idle research day does not rebuild the full queue index",
		int(country.report().get("research_queue_rebuilds", -2)) ==
			rebuilds_after_completion)
	_run_single_queue_same_day_activation(compiled)
	_run_stuck_pending_recovery(compiled)
	print("technology_pending_activation_scheduler_test: %s" % (
		"PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)

func _run_single_queue_same_day_activation(compiled: Dictionary) -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var modifiers = ModifierFacadeScript.new()
	_expect("single-item modifier catalog configures", bool(modifiers.configure(ext, 4).get("ok", false)))
	var effect := EffectFacadeScript.new()
	_expect("single-item effect catalog configures", bool(effect.configure(
		ext, null, EffectDomainCatalogScript.build()).get("ok", false)))
	var country = CountryFacadeScript.new()
	_expect("single-item country configures", bool(country.configure(ext, 1, 9047,
		load("res://data/country/default_country.tres"), compiled).get("ok", false)))
	effect.register_domain_adapters(modifiers, country, null)
	var ids: PackedStringArray = compiled.technology_ids
	var points_good := (compiled.good_ids as PackedStringArray).find("technology_points")
	var gathering := ids.find("tech.gathering")
	var maize_identification := ids.find("tech.maize_identification")
	var oral_memory := ids.find("tech.oral_memory_practice")
	var phenology_observation := ids.find("tech.phenology_observation")
	var tech := ids.find("tech.wild_maize_collection")
	_expect("single-item country bootstraps", bool(country.bootstrap(PackedByteArray([0]), {
		"country_ids": PackedStringArray(["country.single_item"]),
		"country_names": PackedStringArray(["Single item"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 4]),
		"technology_indices": PackedInt32Array([
			gathering, maize_identification, oral_memory, phenology_observation]),
		"treasury_offsets": PackedInt32Array([0, 1]),
		"treasury_good_indices": PackedInt32Array([points_good]),
		"treasury_quantities": PackedInt64Array([10000000]),
	}).get("ok", false)))
	var handle := int(country.cell_summary(0).country_handle)
	_expect("single-item maize evidence commits", bool(country.discover_research_signal(
		handle, &"bio.maize", 0, 1, 0, 1).get("ok", false)))
	_run_production_day(ext, 0)
	_expect("single-item queue accepts one technology", bool(country.set_research_weights(
		handle, PackedInt32Array([10000, 0, 0, 0]), 1, 10).get("ok", false))
		and bool(country.enqueue_research(handle, &"tech.wild_maize_collection",
			0, -1, 1, 11).get("ok", false)))
	_run_production_day(ext, 1)
	var pending: Dictionary = country.research_snapshot(handle)
	_expect("single-item completion is pending before ACK drain",
		int(pending.technology_states[tech]) == 4)
	_expect("pending completion keeps the country scheduled on the same day",
		bool(ext.country_should_run(1)))
	# The production continuation has already drained Effect/Modifier. A
	# second country pass on the same day must activate the pending node without
	# requiring a new enqueue command.
	_expect("same-day country continuation commits", bool(ext.run_country_slice(
		{"day_index": 1}).get("done", false)))
	var completed: Dictionary = country.research_snapshot(handle)
	_expect("single-item research completes without a new command",
		int(completed.technology_states[tech]) == 5
		and (completed.queue_technology_indices as PackedInt32Array).is_empty()
		and int(completed.completed_total) == 1
		and not bool(ext.country_should_run(1)))

func _run_stuck_pending_recovery(compiled: Dictionary) -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var modifiers = ModifierFacadeScript.new()
	_expect("recovery modifier configures", bool(modifiers.configure(ext, 4).get("ok", false)))
	var effect := EffectFacadeScript.new()
	_expect("recovery effect configures", bool(effect.configure(
		ext, null, EffectDomainCatalogScript.build()).get("ok", false)))
	var country = CountryFacadeScript.new()
	_expect("recovery country configures", bool(country.configure(ext, 1, 9045,
		load("res://data/country/default_country.tres"), compiled).get("ok", false)))
	effect.register_domain_adapters(modifiers, country, null)
	var points_good := (compiled.good_ids as PackedStringArray).find("technology_points")
	var hunting := (compiled.technology_ids as PackedStringArray).find("tech.hunting")
	var oral_memory := (compiled.technology_ids as PackedStringArray).find(
		"tech.oral_memory_practice")
	var phenology_observation := (compiled.technology_ids as PackedStringArray).find(
		"tech.phenology_observation")
	_expect("recovery bootstraps", bool(country.bootstrap(PackedByteArray([0]), {
		"country_ids": PackedStringArray(["country.recovery"]),
		"country_names": PackedStringArray(["Recovery"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 3]),
		"technology_indices": PackedInt32Array([
			hunting, oral_memory, phenology_observation]),
		"treasury_offsets": PackedInt32Array([0, 1]),
		"treasury_good_indices": PackedInt32Array([points_good]),
		"treasury_quantities": PackedInt64Array([10000000]),
	}).get("ok", false)))
	var handle := int(country.cell_summary(0).country_handle)
	_expect("recovery queues animal husbandry", bool(country.set_research_weights(
		handle, PackedInt32Array([10000, 0, 0, 0]), 1, 10).get("ok", false))
		and bool(country.enqueue_research(handle, &"tech.animal_husbandry",
			0, -1, 1, 11).get("ok", false)))
	_run_production_day(ext, 0)
	_run_production_day(ext, 1)
	var tech := (compiled.technology_ids as PackedStringArray).find("tech.animal_husbandry")
	_expect("animal husbandry completion stays pending",
		int(country.research_snapshot(handle).technology_states[tech]) == 4)
	_expect("country-only day 2", bool(ext.run_country_slice(
		{"day_index": 2}).get("done", false)))
	_expect("UNIQUE_SOURCE already applied completes without another Effect morning",
		int(country.research_snapshot(handle).technology_states[tech]) == 5
		and (country.snapshot(handle).technology_ids as PackedStringArray).has(
			"tech.animal_husbandry"))
	_run_missed_effect_nudge_recovery(compiled)

func _run_missed_effect_nudge_recovery(compiled: Dictionary) -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var modifiers = ModifierFacadeScript.new()
	_expect("nudge modifier configures", bool(modifiers.configure(ext, 4).get("ok", false)))
	var effect := EffectFacadeScript.new()
	_expect("nudge effect configures", bool(effect.configure(
		ext, null, EffectDomainCatalogScript.build()).get("ok", false)))
	var country = CountryFacadeScript.new()
	_expect("nudge country configures", bool(country.configure(ext, 1, 9046,
		load("res://data/country/default_country.tres"), compiled).get("ok", false)))
	effect.register_domain_adapters(modifiers, country, null)
	var points_good := (compiled.good_ids as PackedStringArray).find("technology_points")
	var hunting := (compiled.technology_ids as PackedStringArray).find("tech.hunting")
	var oral_memory := (compiled.technology_ids as PackedStringArray).find(
		"tech.oral_memory_practice")
	var phenology_observation := (compiled.technology_ids as PackedStringArray).find(
		"tech.phenology_observation")
	_expect("nudge bootstraps", bool(country.bootstrap(PackedByteArray([0]), {
		"country_ids": PackedStringArray(["country.nudge"]),
		"country_names": PackedStringArray(["Nudge"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 3]),
		"technology_indices": PackedInt32Array([
			hunting, oral_memory, phenology_observation]),
		"treasury_offsets": PackedInt32Array([0, 1]),
		"treasury_good_indices": PackedInt32Array([points_good]),
		"treasury_quantities": PackedInt64Array([10000000]),
	}).get("ok", false)))
	var handle := int(country.cell_summary(0).country_handle)
	_expect("nudge queues animal husbandry", bool(country.set_research_weights(
		handle, PackedInt32Array([10000, 0, 0, 0]), 1, 10).get("ok", false))
		and bool(country.enqueue_research(handle, &"tech.animal_husbandry",
			0, -1, 1, 11).get("ok", false)))
	_run_production_day_no_drain(ext, 0)
	_run_production_day_no_drain(ext, 1)
	var tech := (compiled.technology_ids as PackedStringArray).find("tech.animal_husbandry")
	_expect("nudge completion stays pending",
		int(country.research_snapshot(handle).technology_states[tech]) == 4)
	_expect("nudge country-only day 2", bool(ext.run_country_slice(
		{"day_index": 2}).get("done", false)))
	_expect("missed ACK remains pending until the chain is serviced",
		int(country.research_snapshot(handle).technology_states[tech]) == 4)
	_run_production_day(ext, 2)
	_expect("nudge activation completes without a new research command",
		int(country.research_snapshot(handle).technology_states[tech]) == 5
		and (country.snapshot(handle).technology_ids as PackedStringArray).has(
			"tech.animal_husbandry"))

func _run_production_day(ext: Object, day: int) -> void:
	_expect("effect day %d" % day, bool(ext.run_effect_daily(day).get("ok", false)))
	ext.dispatch_effect_native_modifier()
	if ext.has_method("dispatch_effect_native_country"):
		ext.dispatch_effect_native_country()
	if ext.has_method("dispatch_effect_native_economy"):
		ext.dispatch_effect_native_economy()
	ext.dispatch_effect_native_gameplay()
	_expect("modifier day %d" % day, bool(ext.run_modifier_daily(day).get("ok", false)))
	ext.ack_effect_native_modifier()
	if ext.has_method("ack_effect_native_country"):
		ext.ack_effect_native_country()
	ext.run_gameplay_effects(day)
	ext.ack_effect_native_gameplay()
	var country_slice: Dictionary = ext.run_country_slice({"day_index": day})
	_expect("country day %d" % day, bool(country_slice.get("done", false)))
	if ext.has_method("ack_effect_native_country"):
		ext.ack_effect_native_country()
	# Production continuation drains Effect→Modifier→gameplay after Country
	# when a newly registered technology instance is still due.
	if bool(country_slice.get("country_day_barrier", false)) \
			or (ext.has_method("effect_should_run") and bool(ext.effect_should_run(day))):
		for _pass in range(8):
			if ext.has_method("effect_should_run") and not bool(ext.effect_should_run(day)) \
					and ext.has_method("modifier_should_run") \
					and not bool(ext.modifier_should_run(day)) \
					and ext.has_method("gameplay_effect_should_run") \
					and not bool(ext.gameplay_effect_should_run(day)):
				break
			_expect("effect drain day %d pass" % day, bool(ext.run_effect_daily(day).get("ok", false)))
			ext.dispatch_effect_native_modifier()
			if ext.has_method("dispatch_effect_native_country"):
				ext.dispatch_effect_native_country()
			if ext.has_method("dispatch_effect_native_economy"):
				ext.dispatch_effect_native_economy()
			ext.dispatch_effect_native_gameplay()
			_expect("modifier drain day %d pass" % day, bool(ext.run_modifier_daily(day).get("ok", false)))
			ext.ack_effect_native_modifier()
			ext.run_gameplay_effects(day)
			ext.ack_effect_native_gameplay()

func _run_production_day_no_drain(ext: Object, day: int) -> void:
	_expect("effect no-drain day %d" % day, bool(ext.run_effect_daily(day).get("ok", false)))
	ext.dispatch_effect_native_modifier()
	if ext.has_method("dispatch_effect_native_country"):
		ext.dispatch_effect_native_country()
	if ext.has_method("dispatch_effect_native_economy"):
		ext.dispatch_effect_native_economy()
	ext.dispatch_effect_native_gameplay()
	_expect("modifier no-drain day %d" % day, bool(ext.run_modifier_daily(day).get("ok", false)))
	ext.ack_effect_native_modifier()
	if ext.has_method("ack_effect_native_country"):
		ext.ack_effect_native_country()
	ext.run_gameplay_effects(day)
	ext.ack_effect_native_gameplay()
	_expect("country no-drain day %d" % day, bool(ext.run_country_slice(
		{"day_index": day}).get("done", false)))
	if ext.has_method("ack_effect_native_country"):
		ext.ack_effect_native_country()

func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
		return
	_failures += 1
	push_error("[FAIL] %s" % label)
