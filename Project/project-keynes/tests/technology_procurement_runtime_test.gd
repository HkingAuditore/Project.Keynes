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
	var gathering := (compiled.technology_ids as PackedStringArray).find(
		"tech.gathering")
	var maize_identification := (compiled.technology_ids as PackedStringArray).find(
		"tech.maize_identification")
	var early_knowledge := (compiled.technology_ids as PackedStringArray).find(
		"tech.early_knowledge_institution")
	var country_packet := {
		"country_ids": PackedStringArray(["country.procurement"]),
		"country_names": PackedStringArray(["Procurement"]),
		"country_cash": PackedInt64Array([100000000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 3]),
		"technology_indices": PackedInt32Array([
			gathering, maize_identification, early_knowledge]),
	}
	_expect("country bootstraps", bool(country.bootstrap(
		PackedByteArray([0]), country_packet).get("ok", false)))
	var handle := int(country.cell_summary(0).country_handle)
	_expect("research evidence queues", bool(country.discover_research_signal(
		handle, &"bio.maize", 0, 1, 0, 1).get("ok", false)))
	_expect("research evidence commits", bool(ext.run_country_slice(
		{"day_index": 0}).get("done", false)))
	_expect("research demand and budget queue", bool(country.enqueue_research(
		handle, &"tech.wild_maize_collection", 0, -1, 1, 10).get("ok", false))
		and bool(country.set_research_budget(handle, true, 10000000, 1, 11).get("ok", false)))
	_expect("policy commits before market settlement",
		bool(ext.run_country_slice({"day_index": 1}).get("done", false)))

	var native_catalog := compiled.duplicate(false)
	native_catalog.erase("ok")
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	# Keep the production default so research consumption is exercised while a
	# multi-day economy epoch is still frozen.
	profile.market_cycle_days = 5
	profile.market_runtime_mode = "ACTIVE"
	var economy_config: Dictionary = ext.configure_economy(native_catalog, profile, 1, 9042)
	if not bool(economy_config.get("ok", false)):
		print("  economy configure diagnostic=", economy_config)
	_expect("economy configures", bool(economy_config.get("ok", false)))
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
	# A newly bootstrapped economy begins at its own sample day zero even when
	# the country fixture used an earlier day to commit discovery evidence.
	var report := _run_until_procurement(ext, 0)
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
		not bool(report.get("fatal", false))
		and int(report.get("government_research_procured_points", 0)) > 0
		and int(after_purchase.technology_points_stock) > int(before.technology_points_stock)
		and after_cash < before_cash
		and int(report.get("market_cycle_days", 0)) == 1)
	var purchased := int(after_purchase.technology_points_stock)
	var research_day: Dictionary = ext.run_country_slice({"day_index": 2})
	var after_research: Dictionary = country.research_snapshot(handle)
	var first_share := purchased / 4
	_expect("purchased stock enters research on the next country day",
		bool(research_day.get("done", false))
		and int(after_research.consumed_total) == first_share
		and int(after_research.deferred_unallocated_points) == 0
		and int(after_research.technology_points_stock) == purchased - first_share)
	var research_day2: Dictionary = ext.run_country_slice({"day_index": 3})
	var after_research2: Dictionary = country.research_snapshot(handle)
	var second_share := (purchased - first_share) / 4
	_expect("empty-domain shares remain available on later research days",
		bool(research_day2.get("done", false))
		and int(after_research2.consumed_total) == first_share + second_share
		and int(after_research2.deferred_unallocated_points) == 0)
	var in_flight: Dictionary = ext.run_economy_slice({"day_index": 2, "tick_index": 2000})
	_expect("research consumption is accepted during the frozen epoch",
		not bool(in_flight.get("fatal", false))
		and not bool(in_flight.get("done", false)))
	var closing := _run_day(ext, 4)
	var research_consumed_in_epoch := int(after_research2.consumed_total) - int(before.consumed_total)
	_expect("in-epoch research goods stay conserved",
		bool(closing.get("done", false))
		and not bool(closing.get("fatal", false))
		and int(closing.get("goods_error", 1)) == 0
		and int(closing.get("country_research_goods_consumed", 0)) == research_consumed_in_epoch)
	_test_dead_merchant_skips_procurement_without_fatal(compiled)
	print("technology procurement runtime: %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)

func _test_dead_merchant_skips_procurement_without_fatal(compiled: Dictionary) -> void:
	var catalog: Dictionary = compiled.duplicate(true)
	catalog.erase("ok")
	var signatures: PackedStringArray = catalog.signature_keys
	var worker := signatures.find("worker|default")
	var merchant := signatures.find("merchant|default")
	var death_rates: PackedInt64Array = catalog.signature_death_rate_q32.duplicate()
	death_rates.fill(0)
	death_rates[merchant] = 4294967296
	catalog.signature_death_rate_q32 = death_rates
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	_register_environment(ext)
	var country = CountryFacadeScript.new()
	_expect("dead-merchant country configures", bool(country.configure(ext, 1, 9043,
		load("res://data/country/default_country.tres"), catalog).get("ok", false)))
	var gathering := (catalog.technology_ids as PackedStringArray).find("tech.gathering")
	var maize_identification := (catalog.technology_ids as PackedStringArray).find(
		"tech.maize_identification")
	var early_knowledge := (catalog.technology_ids as PackedStringArray).find(
		"tech.early_knowledge_institution")
	_expect("dead-merchant country bootstraps", bool(country.bootstrap(
		PackedByteArray([0]), {
			"country_ids": PackedStringArray(["country.dead_merchant_procurement"]),
			"country_names": PackedStringArray(["DeadMerchantProcurement"]),
			"country_cash": PackedInt64Array([100000000]),
			"territory_offsets": PackedInt32Array([0, 1]),
			"territory_cells": PackedInt32Array([0]),
			"technology_offsets": PackedInt32Array([0, 3]),
			"technology_indices": PackedInt32Array([
				gathering, maize_identification, early_knowledge]),
		}).get("ok", false)))
	var handle := int(country.cell_summary(0).country_handle)
	_expect("dead-merchant research evidence queues", bool(country.discover_research_signal(
		handle, &"bio.maize", 0, 1, 0, 1).get("ok", false)))
	_expect("dead-merchant research evidence commits", bool(ext.run_country_slice(
		{"day_index": 0}).get("done", false)))
	_expect("dead-merchant research demand and budget queue", bool(country.enqueue_research(
		handle, &"tech.wild_maize_collection", 0, -1, 1, 10).get("ok", false))
		and bool(country.set_research_budget(handle, true, 10000000, 1, 11).get("ok", false)))
	_expect("dead-merchant policy commits",
		bool(ext.run_country_slice({"day_index": 1}).get("done", false)))
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	_expect("dead-merchant economy configures", bool(ext.configure_economy(
		catalog, profile, 1, 9043).get("ok", false)))
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000000)
	_expect("dead-merchant market bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([worker, merchant]),
		"population": PackedInt64Array([20, 1]),
		"funds": PackedInt64Array([1000000000000, 1000000000000]),
	}, {"stock": stock}).get("ok", false)))
	var death_cycle := _run_day(ext, 0)
	if bool(death_cycle.get("fatal", false)) or int(death_cycle.get("money_error", 0)) != 0:
		print("  dead-merchant procurement diagnostic=", {
			"done": death_cycle.get("done"), "fatal": death_cycle.get("fatal"),
			"reason": death_cycle.get("fatal_reason"), "stage": death_cycle.get("stage"),
			"points": death_cycle.get("government_research_procured_points"),
			"repairs": death_cycle.get("merchant_repairs"),
			"money_error": death_cycle.get("money_error"),
			"goods_error": death_cycle.get("goods_error"),
			"population_error": death_cycle.get("population_error")})
	_expect("dead merchant does not fatal government research procurement",
		bool(death_cycle.get("done", false))
		and not bool(death_cycle.get("fatal", false))
		and String(death_cycle.get("fatal_reason", "")) == ""
		and int(death_cycle.get("money_error", 1)) == 0
		and int(death_cycle.get("goods_error", 1)) == 0
		and int(death_cycle.get("population_error", 1)) == 0)
	var population: Dictionary = ext.get_population_cell_snapshot(0)
	var living_merchants := 0
	for flag in population.get("merchant_flags", PackedByteArray()) as PackedByteArray:
		living_merchants += int(flag)
	_expect("structural repair restores a living merchant after skipped procurement",
		living_merchants >= 1
		and int(death_cycle.get("merchant_repairs", 0)) > 0)
	var repaired := _run_day(ext, 1)
	_expect("repeated merchant death still conserves after skipped procurement",
		bool(repaired.get("done", false))
		and not bool(repaired.get("fatal", false))
		and int(repaired.get("money_error", 1)) == 0
		and int(repaired.get("goods_error", 1)) == 0
		and int(repaired.get("population_error", 1)) == 0)

func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(512):
		report = ext.run_economy_slice({"day_index": day, "tick_index": day * 1000 + slice})
		if bool(report.get("done", false)):
			return report
	return report

func _run_until_procurement(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(512):
		report = ext.run_economy_slice({"day_index": day, "tick_index": day * 1000 + slice})
		if bool(report.get("fatal", false)) or \
				int(report.get("government_research_procured_points", 0)) > 0:
			return report
	return report

func _register_environment(ext: Object) -> void:
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
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
