extends SceneTree

# Headless probe for the phase-6 activity classifier. Boots a synthetic economy
# and prints the T0-T3 histogram over time so the tier distribution can be
# inspected before dormancy is switched on.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

const CELL_COUNT := 120
const DAYS := 120


func _init() -> void:
	_run()
	quit(0)


func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		push_error("[tier-probe] catalog compile failed")
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "OFF"
	var ext := _new_ext(compiled)
	CountryTestHelper.configure_all_technologies(ext, catalog, CELL_COUNT, 92015)
	if not bool(ext.configure_economy(catalog, profile, CELL_COUNT, 92015).get(
			"ok", false)):
		push_error("[tier-probe] configure_economy failed")
		return
	if not _bootstrap(ext, compiled):
		push_error("[tier-probe] bootstrap failed")
		return

	for day in range(DAYS):
		var slices := 0
		while slices < 128:
			var report: Dictionary = ext.run_economy_slice({
				"day_index": day, "slice_budget_ms": 4.0,
			})
			slices += 1
			if bool(report.get("done", true)):
				break
		if day % 20 == 0 or day == DAYS - 1:
			var r: Dictionary = ext.get_economy_report()
			print("[tier-probe/day] ", JSON.stringify({
				"day": day,
				"t0": int(r.get("tier_t0_cells", 0)),
				"t1": int(r.get("tier_t1_cells", 0)),
				"t2": int(r.get("tier_t2_cells", 0)),
				"t3": int(r.get("tier_t3_cells", 0)),
				"forced_wakes": int(r.get("tier_forced_wakes", 0)),
				"cap_days": int(r.get("tier_dormancy_cap_days", 0)),
				"elapsed_lost_total": int(r.get("total_elapsed_days_lost", 0)),
				"peak_spread": int(r.get("peak_elapsed_days_spread_cells", 0)),
				"reasons": r.get("tier_reasons", {}),
			}))


func _bootstrap(ext: Object, compiled: Dictionary) -> bool:
	var merchant := (compiled.signature_keys as PackedStringArray).find(
		"merchant|default")
	var cells := PackedInt32Array()
	var signatures := PackedInt32Array()
	var population := PackedInt64Array()
	var funds := PackedInt64Array()
	cells.resize(CELL_COUNT)
	signatures.resize(CELL_COUNT)
	population.resize(CELL_COUNT)
	funds.resize(CELL_COUNT)
	for cell in range(CELL_COUNT):
		cells[cell] = cell
		signatures[cell] = merchant
		population[cell] = 10
		funds[cell] = 1000000
	var goods: int = (compiled.good_ids as PackedStringArray).size()
	var stock := PackedInt64Array()
	var prices := PackedInt32Array()
	stock.resize(CELL_COUNT * goods)
	stock.fill(0)
	var gathered := (compiled.good_ids as PackedStringArray).find(
		"gathered_plants")
	prices.resize(CELL_COUNT * goods)
	for cell in range(CELL_COUNT):
		for good in range(goods):
			prices[cell * goods + good] = int(
				(compiled.good_default_price as PackedInt32Array)[good])
		if gathered >= 0:
			stock[cell * goods + gathered] = 100000000
	return bool(ext.bootstrap_economy({
		"cell_indices": cells,
		"signature_ids": signatures,
		"population": population,
		"funds": funds,
	}, {"stock": stock, "price": prices}).get("ok", false))


func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELL_COUNT)
	var scalar := PackedFloat32Array()
	scalar.resize(CELL_COUNT)
	scalar.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip",
			&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	var terrain := PackedByteArray()
	terrain.resize(CELL_COUNT)
	terrain.fill(2)
	var zeros_u8 := PackedByteArray()
	zeros_u8.resize(CELL_COUNT)
	zeros_u8.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0,
			terrain if slot_name == &"cell_terrain" else zeros_u8)
	var zeros := PackedFloat32Array()
	zeros.resize(CELL_COUNT)
	zeros.fill(0.0)
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	for i in range(reserve_slots.size()):
		var reserve_sid: int = ext.register_component(
			StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(
			StringName(extra_slots[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, zeros)
		ext.write_f32_range(extra_sid, 0, zeros)
	return ext
