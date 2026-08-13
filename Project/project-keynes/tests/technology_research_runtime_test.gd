extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")

var _failures := 0

func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		quit()
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var facade = CountryFacadeScript.new()
	var profile := load("res://data/country/default_country.tres")
	_expect("country research configures", bool(facade.configure(
		ext, 1, 42, profile, compiled).get("ok", false)))
	var goods: PackedStringArray = compiled.good_ids
	var points_good := goods.find("technology_points")
	var ids: PackedStringArray = compiled.technology_ids
	var gathering := ids.find("tech.gathering")
	var stone_knapping := ids.find("tech.stone_knapping")
	var settled_knowledge := ids.find("tech.settled_knowledge")
	var previous_maize := ids.find("tech.wild_maize_collection")
	var previous_maritime := ids.find("tech.fishing_boats")
	var kiln_firing := ids.find("tech.kiln_firing")
	var packet := {
		"country_ids": PackedStringArray(["country.test"]),
		"country_names": PackedStringArray(["测试国"]),
		"country_cash": PackedInt64Array([100000000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		# Research eligibility comes from completed technology prerequisites.
		# Signals may reveal another node, but never substitute for this chain.
		"technology_offsets": PackedInt32Array([0, 5]),
		"technology_indices": PackedInt32Array([
			gathering, stone_knapping, settled_knowledge,
			previous_maize, previous_maritime]),
		"treasury_offsets": PackedInt32Array([0, 1]),
		"treasury_good_indices": PackedInt32Array([points_good]),
		"treasury_quantities": PackedInt64Array([10000]),
	}
	_expect("country research bootstraps", bool(facade.bootstrap(
		PackedByteArray([0]), packet).get("ok", false)))
	var handle := int(facade.cell_summary(0).country_handle)
	_expect("discovery inspiration queues", bool(facade.discover_research_signal(
		handle, &"bio.maize", 0, 1, 0, 1).get("ok", false))
		and bool(facade.discover_research_signal(
			handle, &"landform.coast", 0, 1, 0, 2).get("ok", false))
		and bool(facade.discover_research_signal(
			handle, &"resource.clay", 0, 1, 0, 3).get("ok", false)))
	_expect("discovery inspiration commits", bool(ext.run_country_slice(
		{"day_index": 0}).get("done", false)))
	var revealed_snapshot: Dictionary = facade.research_snapshot(handle)
	_expect("inspiration reveals but cannot bypass a hard prerequisite",
		int(revealed_snapshot.technology_states[kiln_firing]) == 1)
	_expect("weights queue atomically", bool(facade.set_research_weights(
		handle, PackedInt32Array([7000, 3000, 0, 0]), 1, 10).get("ok", false))
		and bool(facade.enqueue_research(handle, &"tech.maize_garden_horticulture",
			0, -1, 1, 11).get("ok", false))
		and bool(facade.enqueue_research(handle, &"tech.ground_stone_tools",
			1, -1, 1, 12).get("ok", false)))
	var result: Dictionary = ext.run_country_slice({"day_index": 1})
	_expect("research day commits", bool(result.get("ok", false))
		and bool(result.get("done", false)))
	var snapshot: Dictionary = facade.research_snapshot(handle)
	var seasonal := ids.find("tech.maize_garden_horticulture")
	var composite := ids.find("tech.ground_stone_tools")
	_expect("10 points at 70/30 are exactly 7/3",
		int(snapshot.technology_progress[seasonal]) == 7000
		and int(snapshot.technology_progress[composite]) == 3000
		and int(snapshot.technology_points_stock) == 0
		and int(snapshot.consumed_total) == 10000)
	_expect("completed route prerequisites permit research",
		int(snapshot.technology_states[previous_maize]) == 5
		and int(snapshot.technology_states[previous_maritime]) == 5
		and int(snapshot.technology_progress[seasonal]) == 7000
		and int(snapshot.technology_progress[composite]) == 3000)
	_expect("queue removal preserves progress", bool(facade.remove_research(
		handle, &"tech.maize_garden_horticulture", 2, 20).get("ok", false)))
	ext.run_country_slice({"day_index": 2})
	snapshot = facade.research_snapshot(handle)
	_expect("sparse progress survives dequeue",
		int(snapshot.technology_progress[seasonal]) == 7000)
	var save_begin: Dictionary = ext.begin_country_save(4096)
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_country_save_chunk(4096)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	var save_end: Dictionary = ext.end_country_save()
	var restored_ext: Object = ClassDB.instantiate("DCWorldExt")
	restored_ext.create_entities(1)
	var restored_facade = CountryFacadeScript.new()
	restored_facade.configure(restored_ext, 1, 42, profile, compiled)
	restored_facade.bootstrap(PackedByteArray([0]), packet)
	restored_ext.begin_country_restore()
	for chunk in chunks:
		restored_ext.feed_country_restore_chunk(chunk)
	var restore_end: Dictionary = restored_ext.end_country_restore()
	var restored_handle := int(restored_facade.cell_summary(0).country_handle)
	var restored_snapshot: Dictionary = restored_facade.research_snapshot(restored_handle)
	_expect("PKCN v11 preserves sparse progress queues policy and hash",
		bool(save_begin.get("ok", false)) and int(save_begin.schema_version) == 11
		and bool(save_end.get("ok", false)) and bool(restore_end.get("ok", false))
		and int(restored_snapshot.technology_progress[seasonal]) == 7000
		and restored_snapshot.queue_technology_indices == snapshot.queue_technology_indices
		and restored_snapshot.domain_weights_bp == snapshot.domain_weights_bp
		and int(restored_ext.get_country_state_hash()) == int(ext.get_country_state_hash()))
	var incompatible_catalog := compiled.duplicate(true)
	incompatible_catalog["technology_content_binding_hash"] = int(
		compiled.technology_content_binding_hash) + 1
	var incompatible_ext: Object = ClassDB.instantiate("DCWorldExt")
	incompatible_ext.create_entities(1)
	var incompatible_facade = CountryFacadeScript.new()
	incompatible_facade.configure(incompatible_ext, 1, 42, profile, incompatible_catalog)
	incompatible_facade.bootstrap(PackedByteArray([0]), packet)
	incompatible_ext.begin_country_restore()
	for chunk in chunks:
		incompatible_ext.feed_country_restore_chunk(chunk)
	var incompatible_restore: Dictionary = incompatible_ext.end_country_restore()
	_expect("content binding changes reject PKCN with catalog_hash_mismatch",
		not bool(incompatible_restore.get("ok", false)) and String(
			incompatible_restore.get("reason", "")) == "catalog_hash_mismatch")
	var trigger_incompatible_catalog := compiled.duplicate(true)
	trigger_incompatible_catalog["technology_trigger_definition_hash"] = int(
		compiled.technology_trigger_definition_hash) + 1
	var trigger_incompatible_ext: Object = ClassDB.instantiate("DCWorldExt")
	trigger_incompatible_ext.create_entities(1)
	var trigger_incompatible_facade = CountryFacadeScript.new()
	trigger_incompatible_facade.configure(trigger_incompatible_ext, 1, 42, profile,
		trigger_incompatible_catalog)
	trigger_incompatible_facade.bootstrap(PackedByteArray([0]), packet)
	trigger_incompatible_ext.begin_country_restore()
	for chunk in chunks:
		trigger_incompatible_ext.feed_country_restore_chunk(chunk)
	var trigger_incompatible_restore: Dictionary = \
		trigger_incompatible_ext.end_country_restore()
	_expect("Trigger definition changes reject PKCN with catalog_hash_mismatch",
		not bool(trigger_incompatible_restore.get("ok", false)) and String(
			trigger_incompatible_restore.get("reason", "")) == "catalog_hash_mismatch")
	print("technology research runtime: %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
