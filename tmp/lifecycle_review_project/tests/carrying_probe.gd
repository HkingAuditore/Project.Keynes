extends SceneTree
# Diagnostic probe: measure the carrying-capacity quantities that the CSV
# recorder does not persist. Read-only; prints evidence for the birth-rate
# investigation. Safe to delete once the question is settled.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

# cell 1860 opening reserves, from the v25 recorder export.
const RESERVES := {
	"timber": 5297452.5,
	"stone": 127103000.0,
	"fertile_soil": 277584.47,
	"coal": 276426340.0,
	"oil": 6509428.0,
	"natural_gas": 10527929.0,
	"copper_ore": 19693108.0,
	"gold_ore": 6098777.5,
	"silver_ore": 6993223.0,
	"clay": 25722010.0,
	"wild_game": 108003.51,
	"marine_fish": 346230.2,
	"arable_land": 125000.0,
	"pasture": 160000.0,
	"lead_ore": 14270431.0,
	"zinc_ore": 11163374.0,
	"sulfur": 14565309.0,
	"flint": 73696984.0,
}

# cell 1860 building groups: dense type id -> (count, owner signature id).
const GROUPS := [
	[62, 3, 13],
	[72, 1, 26],
	[103, 12, 13],
	[297, 2, 26],
	[357, 2, 17],
]

const CYCLES := 80


func _init() -> void:
	_run()
	quit(0)


func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(compiled.get("ok", false)) or not ClassDB.class_exists("DCWorldExt"):
		print("catalog or extension unavailable")
		return
	var type_ids := compiled.building_type_ids as PackedStringArray
	print("building_type_count=%d" % type_ids.size())
	for entry in GROUPS:
		var dense: int = entry[0]
		print("  dense type %d -> %s" % [dense,
			type_ids[dense] if dense < type_ids.size() else "<out of range>"])

	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	print("profile.market_cycle_days=%d" % int(profile.market_cycle_days))

	var ext := _new_ext(1, compiled)
	var seed := 31337
	if not CountryTestHelper.configure_all_technologies(ext, compiled, 1, seed):
		print("configure_all_technologies failed")
		return
	var configured: Dictionary = ext.configure_economy(compiled, profile, 1, seed)
	if not bool(configured.get("ok", false)):
		print("configure_economy failed: %s" % str(configured))
		return

	for resource_id in RESERVES:
		_set_resource(ext, compiled, resource_id, float(RESERVES[resource_id]))

	var sig_keys := compiled.signature_keys as PackedStringArray
	var sig_profs := compiled.signature_profession_ids as PackedInt32Array
	var owner_profs := compiled.building_owner_profession_ids as PackedInt32Array
	var profession_ids := compiled.profession_ids as PackedStringArray

	# Map dense profession id -> a signature index that carries it.
	var prof_to_sig := {}
	for i in range(sig_keys.size()):
		var p: int = sig_profs[i]
		if not prof_to_sig.has(p):
			prof_to_sig[p] = i

	var cells := PackedInt32Array()
	var types := PackedInt32Array()
	var owners := PackedInt32Array()
	var counts := PackedInt64Array()
	var used_sigs := {}
	for entry in GROUPS:
		var dense_type: int = entry[0]
		var prof: int = owner_profs[dense_type] if dense_type < owner_profs.size() else -1
		if not prof_to_sig.has(prof):
			print("  skip type %d (%s): no signature for profession %d (%s)" % [
				dense_type, type_ids[dense_type], prof,
				profession_ids[prof] if prof >= 0 and prof < profession_ids.size() else "?"])
			continue
		var sig: int = prof_to_sig[prof]
		cells.append(0)
		types.append(dense_type)
		owners.append(sig)
		counts.append(entry[1])
		used_sigs[sig] = true
		print("  type %-3d %-24s owner_prof=%-3d %-18s sig=%d" % [
			dense_type, type_ids[dense_type], prof,
			profession_ids[prof] if prof >= 0 and prof < profession_ids.size() else "?",
			sig])
	if cells.is_empty():
		print("no usable building types")
		return

	# Bootstrap population across the owner professions plus a merchant.
	var boot_cells := PackedInt32Array()
	var boot_sigs := PackedInt32Array()
	var boot_pops := PackedInt64Array()
	var boot_funds := PackedInt64Array()
	for sig in used_sigs:
		boot_cells.append(0)
		boot_sigs.append(sig)
		boot_pops.append(4)
		boot_funds.append(0)
	var merchant_sig := sig_keys.find("merchant|default")
	if merchant_sig >= 0:
		boot_cells.append(0)
		boot_sigs.append(merchant_sig)
		boot_pops.append(1)
		boot_funds.append(200000000)
	print("bootstrapped cohorts=%d signatures=%s" % [boot_cells.size(), str(boot_sigs)])

	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": boot_cells,
		"signature_ids": boot_sigs,
		"population": boot_pops,
		"funds": boot_funds,
	}, {
		"building_cells": cells,
		"building_type_ids": types,
		"building_owner_signature_ids": owners,
		"building_counts": counts,
	})
	var ok := bool(boot.get("ok", false))
	print("bootstrap_economy=%s" % str(boot))
	if not ok:
		return

	print("")
	print("%5s %6s %14s %14s %14s %10s %10s %10s %10s %8s %8s" % [
		"cyc", "pop", "local_eq/day", "eff_eq/day", "stock_eq",
		"k_geo", "k_eff", "load_q16", "access_q16", "births", "deaths"])
	var total_births := 0
	var total_deaths := 0
	for cycle in range(CYCLES):
		var report := _run_cycle(ext, cycle)
		if bool(report.get("fatal", false)):
			print("FATAL at cycle %d: %s" % [cycle,
				String(report.get("fatal_reason", ""))])
			return
		total_births += int(report.get("births", 0))
		total_deaths += int(report.get("deaths", 0))
		if cycle % 8 != 0 and cycle != CYCLES - 1:
			continue
		var s: Dictionary = ext.get_population_cell_summary(0)
		print("%5d %6d %14d %14d %14d %10d %10d %10d %10d %8d %8d" % [
			cycle,
			int(s.get("population", 0)),
			int(s.get("local_food_output_eq_per_day", 0)),
			int(s.get("effective_food_supply_eq_per_day", 0)),
			int(s.get("food_stock_eq", 0)),
			int(s.get("carrying_k_geo", 0)),
			int(s.get("carrying_k_eff", 0)),
			int(s.get("population_load_q16", 0)),
			int(s.get("food_access_q16", 0)),
			total_births,
			total_deaths])
	print("")
	print("totals: births=%d deaths=%d over %d cycles" % [
		total_births, total_deaths, CYCLES])
	_dump_implied_denominator(ext, compiled)

	# What the authored survival plan says one person needs per day.
	print("")
	print("authored survival_household base_qty_per_person: "
		+ "staple_food=440 protein=144 produce=240 -> sum=824 subunits/person/day")


# food_stock_capacity_persons = (food_stock_eq / buffer_days) / survival_per_person
# so survival_per_person can be recovered whenever stock is non-zero.
func _dump_implied_denominator(ext: Object, compiled: Dictionary) -> void:
	var s: Dictionary = ext.get_population_cell_summary(0)
	var stock_eq := int(s.get("food_stock_eq", 0))
	var stock_persons := int(s.get("food_stock_capacity_persons", 0))
	var local_daily := int(s.get("local_food_output_eq_per_day", 0))
	var k_geo := int(s.get("carrying_k_geo", 0))
	print("reported carrying_survival_food_per_person = %d" % int(
		s.get("carrying_survival_food_per_person", -1)))
	print("implied _carrying_survival_food_per_person:")
	if stock_persons > 0:
		print("  from stock: %d / (30 * %d) = %.1f" % [
			stock_eq, stock_persons, float(stock_eq) / (30.0 * float(stock_persons))])
	if k_geo > 0:
		print("  from local: %d / %d = %.1f" % [
			local_daily, k_geo, float(local_daily) / float(k_geo)])
	print("  expected if food_need_count * Q16_ONE: %d" % (3 * 65536))
	print("  expected if sum(base_qty_per_person of food needs): 824")


func _run_cycle(ext: Object, cycle: int) -> Dictionary:
	var report: Dictionary = {}
	for slice in range(256):
		report = ext.run_economy_slice({
			"day_index": cycle * 5,
			"tick_index": slice,
		})
		if bool(report.get("done", false)):
			return report
	return report


func _set_resource(ext: Object, catalog: Dictionary, resource_id: String,
		reserve: float) -> void:
	var idx := (catalog.building_resource_ids as PackedStringArray).find(resource_id)
	if idx < 0:
		return
	var reserve_sid: int = ext.component_id(
		StringName(catalog.building_resource_reserve_slots[idx]))
	var extra_sid: int = ext.component_id(
		StringName(catalog.building_resource_extra_slots[idx]))
	var reserves: PackedFloat32Array = ext.snapshot_f32(reserve_sid)
	var changes: PackedFloat32Array = ext.snapshot_f32(extra_sid)
	reserves[0] = reserve
	changes[0] = 0.0
	ext.write_f32_range(reserve_sid, 0, reserves)
	ext.write_f32_range(extra_sid, 0, changes)


func _new_ext(cells: int, catalog: Dictionary = {}) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	var climate := PackedFloat32Array()
	climate.resize(cells)
	climate.fill(0.5)
	var zero_f := PackedFloat32Array()
	zero_f.resize(cells)
	zero_f.fill(0.0)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip"]:
		var slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(slot, 0, climate)
	for slot_name in [&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
		var slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(slot, 0, zero_f)
	var terrain := PackedByteArray()
	terrain.resize(cells)
	terrain.fill(2)
	var landform := PackedByteArray()
	landform.resize(cells)
	landform.fill(LandformType.LF.PLAIN)
	var vegetation := PackedByteArray()
	vegetation.resize(cells)
	vegetation.fill(VegetationType.VEG.TEMPERATE_GRASSLAND)
	var zeros_u8 := PackedByteArray()
	zeros_u8.resize(cells)
	zeros_u8.fill(0)
	var terrain_sid: int = ext.register_component(&"cell_terrain", 2, 1, false)
	ext.write_u8_range(terrain_sid, 0, terrain)
	var landform_sid: int = ext.register_component(&"cell_landform", 2, 1, false)
	ext.write_u8_range(landform_sid, 0, landform)
	var vegetation_sid: int = ext.register_component(&"cell_vegetation", 2, 1, false)
	ext.write_u8_range(vegetation_sid, 0, vegetation)
	var water_sid: int = ext.register_component(&"cell_is_water", 2, 1, false)
	ext.write_u8_range(water_sid, 0, zeros_u8)
	var river_sid: int = ext.register_component(&"cell_has_river", 2, 1, false)
	ext.write_u8_range(river_sid, 0, zeros_u8)
	if not catalog.is_empty():
		var reserve_slots: PackedStringArray = catalog.get(
			"building_resource_reserve_slots", PackedStringArray())
		var extra_slots: PackedStringArray = catalog.get(
			"building_resource_extra_slots", PackedStringArray())
		for i in range(reserve_slots.size()):
			var reserve_sid2: int = ext.register_component(
				StringName(reserve_slots[i]), 0, 1, false)
			var extra_sid2: int = ext.register_component(
				StringName(extra_slots[i]), 0, 1, false)
			ext.write_f32_range(reserve_sid2, 0, zero_f)
			ext.write_f32_range(extra_sid2, 0, zero_f)
	return ext
