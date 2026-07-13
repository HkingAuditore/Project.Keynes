extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

var failures := 0

func _init() -> void:
	_run()
	print("=== modern economy runtime %s ===" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition: failures += 1

func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)): return
	var ext := _new_ext(compiled)
	var native_catalog := compiled.duplicate(true)
	native_catalog.erase("ok")
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	_expect("all-technology production country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, native_catalog, 1, 2200))
	_expect("native runtime configures", bool(ext.configure_economy(
		native_catalog, profile, 1, 2200).get("ok", false)))

	var signatures: PackedStringArray = compiled.signature_keys
	var industrialist := signatures.find("industrialist|default")
	var merchant := signatures.find("merchant|default")
	var miner := signatures.find("miner|default")
	var electrician := signatures.find("electrician|default")
	var goods: PackedStringArray = compiled.good_ids
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock.fill(0)
	stock[goods.find("coal")] = 100000
	stock[goods.find("tools")] = 100000
	stock[goods.find("explosives")] = 100000
	var types: PackedStringArray = compiled.building_type_ids
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0]),
		"signature_ids": PackedInt32Array([industrialist, merchant, miner, electrician]),
		"population": PackedInt64Array([5, 10, 40, 60]),
		"funds": PackedInt64Array([100000000, 100000000, 1000000, 1000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0, 0, 0]),
		"building_type_ids": PackedInt32Array([
			types.find("electricity_plant"), types.find("gold_mine"), types.find("silver_mine")]),
		"building_owner_signature_ids": PackedInt32Array([industrialist, industrialist, industrialist]),
		"building_counts": PackedInt64Array([3, 1, 1]),
	})
	_expect("power and bullion buildings bootstrap", bool(boot.get("ok", false)))
	var report := _run_day(ext, 0)
	if bool(report.get("fatal", false)):
		print("  runtime report: ", report)
	_expect("production cycle commits", bool(report.get("done", false)) and not bool(report.get("fatal", false)))
	var gold_accepted := int(report.get("gold_accepted", 0))
	var silver_accepted := int(report.get("silver_accepted", 0))
	var gold_issued := int(report.get("gold_money_issued", 0))
	var silver_issued := int(report.get("silver_money_issued", 0))
	_expect("gold issues configured value", gold_accepted > 0 and
		gold_issued == gold_accepted * 800000 / 1000)
	_expect("silver issues configured value", silver_accepted > 0 and
		silver_issued == silver_accepted * 10000 / 1000)
	_expect("only bullion contributes anchored mint",
		int(report.get("anchored_money_issued", 0)) == gold_issued + silver_issued)
	var flow_produced := int(report.get("cycle_flow_produced", 0))
	var flow_consumed := int(report.get("cycle_flow_consumed", 0))
	var flow_discarded := int(report.get("cycle_flow_discarded", 0))
	_expect("utility prepass supplies same-cycle electricity",
		flow_produced > 0 and flow_consumed > 0 and flow_produced >= flow_consumed)
	_expect("unused electricity is cleared", flow_discarded == flow_produced - flow_consumed)
	_expect("all ledgers conserve exactly", int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and int(report.get("goods_error", 1)) == 0)
	var market: Dictionary = ext.get_market_cell_snapshot(0)
	_expect("accepted bullion enters merchant inventory",
		_good_value(market, "stock", "gold") == gold_accepted and
		_good_value(market, "stock", "silver") == silver_accepted)
	_expect("cycle-flow inventory does not cross boundary", _good_value(market, "stock", "electricity") == 0)
	_expect("market snapshot exposes metadata",
		(market.good_storage_modes as PackedInt32Array)[goods.find("electricity")] == 1 and
		(market.good_monetary_issue_values as PackedInt64Array)[goods.find("gold")] == 800000)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("building snapshot exposes kind and technology tags",
		(buildings.building_kinds as PackedInt32Array).size() == types.size() and
		(buildings.building_technology_tag_offsets as PackedInt32Array).size() == types.size() + 1 and
		(buildings.building_technology_tags as PackedStringArray).size() > 0)
	_test_technology_gating(compiled, native_catalog)

func _test_technology_gating(compiled: Dictionary, native_catalog: Dictionary) -> void:
	var ext := _new_ext(compiled)
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	_expect("stone-start runtime configures", bool(ext.configure_economy(
		native_catalog, profile, 1, 2201).get("ok", false)))
	var signatures: PackedStringArray = compiled.signature_keys
	_expect("stone-start runtime bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([
			signatures.find("industrialist|default"), signatures.find("merchant|default")]),
		"population": PackedInt64Array([10, 10]),
		"funds": PackedInt64Array([1000000, 1000000]),
	}, {}).get("ok", false)))
	var goods: PackedStringArray = compiled.good_ids
	var types: PackedStringArray = compiled.building_type_ids
	var country_summary: Dictionary = ext.get_country_cell_summary(0)
	var initial_technologies: Dictionary = ext.get_country_snapshot(country_summary.country_handle)
	var market: Dictionary = ext.get_market_cell_snapshot(0)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var deep_type := types.find("deep_space_probe_works")
	_expect("stone start unlocks hunting and gathering",
		(initial_technologies.technology_ids as PackedStringArray).has("tech.hunting") and
		(initial_technologies.technology_ids as PackedStringArray).has("tech.gathering"))
	_expect("deep-space technology starts locked",
		not (initial_technologies.technology_ids as PackedStringArray).has("tech.deep_space_systems"))
	_expect("stone start hides legacy modern goods but exposes gathered food",
		(market.good_technology_available as PackedByteArray)[goods.find("computers")] == 0 and
		(market.good_technology_available as PackedByteArray)[goods.find("gathered_plants")] == 1)
	_expect("technology-locked building is unavailable",
		deep_type >= 0 and (buildings.building_technology_available as PackedByteArray)[deep_type] == 0)
	var technologies: PackedStringArray = compiled.technology_ids
	var grant: Dictionary = ext.submit_country_commands({
		"opcodes": PackedInt32Array([4]),
		"effective_days": PackedInt64Array([0]),
		"sequences": PackedInt64Array([1]),
		"target_handles": PackedInt64Array([country_summary.country_handle]),
		"cell_indices": PackedInt32Array([-1]),
		"aux_i32": PackedInt32Array([technologies.find("tech.deep_space_systems")]),
		"stable_ids": PackedStringArray([""]),
		"display_names": PackedStringArray([""]),
	})
	_expect("technology grant command queues", bool(grant.get("ok", false)))
	_expect("country technology grant commits", bool(ext.run_country_slice({"day_index": 0}).get("done", false)))
	_expect("technology grant cycle commits", bool(_run_day(ext, 0).get("done", false)))
	var unlocked: Dictionary = ext.get_country_snapshot(country_summary.country_handle)
	var unlocked_buildings: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("technology grant becomes committed cell state",
		(unlocked.technology_ids as PackedStringArray).has("tech.deep_space_systems"))
	_expect("granted technology unlocks tagged building",
		(unlocked_buildings.building_technology_available as PackedByteArray)[deep_type] == 1)

func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var scalar := PackedFloat32Array([0.5])
	for slot_name in [&"cell_temp", &"cell_moisture", &"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation", &"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, PackedByteArray([0]))
	var resources: PackedStringArray = catalog.building_resource_ids
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	for i in range(resources.size()):
		var reserve_sid: int = ext.register_component(StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(extra_slots[i]), 0, 1, false)
		var reserve := 1000.0 if resources[i] in ["gold_ore", "silver_ore"] else 0.0
		ext.write_f32_range(reserve_sid, 0, PackedFloat32Array([reserve]))
		ext.write_f32_range(extra_sid, 0, PackedFloat32Array([0.0]))
	return ext

func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(512):
		report = ext.run_economy_slice({"day_index": day, "tick_index": day * 1000 + slice})
		if bool(report.get("done", false)): return report
	return report

func _good_value(snapshot: Dictionary, column: String, good_id: String) -> int:
	var index := (snapshot.good_ids as PackedStringArray).find(good_id)
	return int((snapshot[column] as PackedInt64Array)[index]) if index >= 0 else 0
