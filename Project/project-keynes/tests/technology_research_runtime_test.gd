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
	var packet := {
		"country_ids": PackedStringArray(["country.test"]),
		"country_names": PackedStringArray(["测试国"]),
		"country_cash": PackedInt64Array([100000000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"treasury_offsets": PackedInt32Array([0, 1]),
		"treasury_good_indices": PackedInt32Array([points_good]),
		"treasury_quantities": PackedInt64Array([10000]),
	}
	_expect("country research bootstraps", bool(facade.bootstrap(
		PackedByteArray([0]), packet).get("ok", false)))
	var handle := int(facade.cell_summary(0).country_handle)
	_expect("weights queue atomically", bool(facade.set_research_weights(
		handle, PackedInt32Array([7000, 3000, 0, 0]), 0, 1).get("ok", false))
		and bool(facade.enqueue_research(handle, &"tech.seasonal_foraging",
			0, -1, 0, 2).get("ok", false))
		and bool(facade.enqueue_research(handle, &"tech.composite_tools",
			1, -1, 0, 3).get("ok", false)))
	var result: Dictionary = ext.run_country_slice({"day_index": 0})
	_expect("research day commits", bool(result.get("ok", false))
		and bool(result.get("done", false)))
	var snapshot: Dictionary = facade.research_snapshot(handle)
	var ids: PackedStringArray = compiled.technology_ids
	var seasonal := ids.find("tech.seasonal_foraging")
	var composite := ids.find("tech.composite_tools")
	_expect("10 points at 70/30 are exactly 7/3",
		int(snapshot.technology_progress[seasonal]) == 7000
		and int(snapshot.technology_progress[composite]) == 3000
		and int(snapshot.technology_points_stock) == 0
		and int(snapshot.consumed_total) == 10000)
	_expect("queue removal preserves progress", bool(facade.remove_research(
		handle, &"tech.seasonal_foraging", 1, 4).get("ok", false)))
	ext.run_country_slice({"day_index": 1})
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
	_expect("PKCN v5 preserves sparse progress queues policy and hash",
		bool(save_begin.get("ok", false)) and int(save_begin.schema_version) == 5
		and bool(save_end.get("ok", false)) and bool(restore_end.get("ok", false))
		and int(restored_snapshot.technology_progress[seasonal]) == 7000
		and restored_snapshot.queue_technology_indices == snapshot.queue_technology_indices
		and restored_snapshot.domain_weights_bp == snapshot.domain_weights_bp
		and int(restored_ext.get_country_state_hash()) == int(ext.get_country_state_hash()))
	print("technology research runtime: %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
