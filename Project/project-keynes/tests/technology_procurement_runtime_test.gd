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
	_register_environment(ext)
	var country = CountryFacadeScript.new()
	_expect("country configures", bool(country.configure(ext, 1, 9042,
		load("res://data/country/default_country.tres"), compiled).get("ok", false)))
	var country_packet := {
		"country_ids": PackedStringArray(["country.procurement"]),
		"country_names": PackedStringArray(["Procurement"]),
		"country_cash": PackedInt64Array([100000000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
	}
	_expect("country bootstraps", bool(country.bootstrap(
		PackedByteArray([0]), country_packet).get("ok", false)))
	var handle := int(country.cell_summary(0).country_handle)
	_expect("research demand and budget queue", bool(country.enqueue_research(
		handle, &"tech.seasonal_foraging", 0, -1, 0, 1).get("ok", false))
		and bool(country.set_research_budget(handle, true, 10000000, 0, 2).get("ok", false)))
	_expect("policy commits before market settlement",
		bool(ext.run_country_slice({"day_index": 0}).get("done", false)))

	var native_catalog := compiled.duplicate(false)
	native_catalog.erase("ok")
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	_expect("economy configures", bool(ext.configure_economy(
		native_catalog, profile, 1, 9042).get("ok", false)))
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
	var before := country.research_snapshot(handle)
	var before_cash := int(country.snapshot(handle).cash)
	var report := _run_day(ext, 0)
	var after_purchase := country.research_snapshot(handle)
	var after_cash := int(country.snapshot(handle).cash)
	if int(report.get("government_research_procured_points", 0)) <= 0:
		print("  procurement diagnostic=", {
			"done": report.get("done"), "fatal": report.get("fatal"),
			"stage": report.get("stage"), "reason": report.get("reason"),
			"points": report.get("government_research_procured_points"),
			"orders": report.get("government_research_procurement_orders"),
			"cash": report.get("government_research_procurement_cash"),
			"before": before, "after": after_purchase})
	_expect("government buys remaining market technology points",
		bool(report.get("done", false))
		and int(report.get("government_research_procured_points", 0)) > 0
		and int(after_purchase.technology_points_stock) > int(before.technology_points_stock)
		and after_cash < before_cash
		and int(report.get("money_error", 1)) == 0
		and int(report.get("goods_error", 1)) == 0)
	var purchased := int(after_purchase.technology_points_stock)
	var research_day: Dictionary = ext.run_country_slice({"day_index": 1})
	var after_research: Dictionary = country.research_snapshot(handle)
	_expect("purchased stock enters research on the next country day",
		bool(research_day.get("done", false))
		and int(after_research.consumed_total) == purchased / 4
		and int(after_research.deferred_unallocated_points) == purchased * 3 / 4)
	print("technology procurement runtime: %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)

func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(512):
		report = ext.run_economy_slice({"day_index": day, "tick_index": day * 1000 + slice})
		if bool(report.get("done", false)):
			return report
	return report

func _register_environment(ext: Object) -> void:
	for slot_name in [&"cell_temp", &"cell_moisture", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid := int(ext.register_component(slot_name, 0, 1, false))
		ext.write_f32_range(sid, 0, PackedFloat32Array([0.5]))
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid := int(ext.register_component(slot_name, 2, 1, false))
		ext.write_u8_range(sid, 0, PackedByteArray([0]))

func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
