extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

var failures := 0

func _init() -> void:
	_run()
	quit(0 if failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition: failures += 1

func _run() -> void:
	print("=== building resource chain test ===")
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)): return
	var types: PackedStringArray = compiled.building_type_ids
	var resources: PackedStringArray = compiled.building_resource_ids
	var generation_offsets: PackedInt32Array = compiled.building_resource_generation_offsets
	var behavior_ids: PackedInt32Array = compiled.building_behavior_ids
	var input_offsets: PackedInt32Array = compiled.building_input_offsets
	var resource_offsets: PackedInt32Array = compiled.building_resource_offsets
	var production_resources: PackedInt32Array = compiled.building_production_resource_ids
	var production_modes: PackedInt32Array = compiled.building_production_resource_modes
	var farm_type := types.find("subsistence_farm")
	var corn_farm_type := types.find("landed_estate")
	var mine_type := types.find("coal_mine")
	var textile_type := types.find("textile_workshop")
	_expect("all modern resources enter sorted building catalog",
		resources.size() == 41 and resources.has("coal") and resources.has("arable_land") and
		resources.has("paddy_land") and resources.has("freshwater_fish"))
	_expect("farm uses capacity behavior without generated crop resource",
		behavior_ids[farm_type] == 1 and
		generation_offsets[farm_type + 1] == generation_offsets[farm_type])
	_expect("mine extracts resources while textile is goods-only industrial",
		behavior_ids[mine_type] == 1 and behavior_ids[textile_type] == 0)
	var farm_begin := int(resource_offsets[farm_type])
	var farm_end := int(resource_offsets[farm_type + 1])
	_expect("farm capacity recipe is arable land plus fertile soil",
		farm_end - farm_begin == 2 and
		resources[production_resources[farm_begin]] == "arable_land" and
		resources[production_resources[farm_begin + 1]] == "fertile_soil" and
		production_modes[farm_begin] == 1 and production_modes[farm_begin + 1] == 1)
	_expect("textile workshop consumes textile goods and no natural resource",
		input_offsets[textile_type + 1] - input_offsets[textile_type] == 1 and
		resource_offsets[textile_type + 1] == resource_offsets[textile_type])

	var ext := _new_ext(compiled)
	var native_catalog := compiled.duplicate(true)
	native_catalog.erase("ok")
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	_expect("all-technology test country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, native_catalog, 2, 91))
	_expect("runtime configures", bool(ext.configure_economy(native_catalog, profile, 2, 91).get("ok", false)))
	var farmer_sig := (compiled.signature_keys as PackedStringArray).find("subsistence_farmer|default")
	var landlord_sig := (compiled.signature_keys as PackedStringArray).find("landlord|default")
	var industrialist_sig := (compiled.signature_keys as PackedStringArray).find("industrialist|default")
	var worker_sig := (compiled.signature_keys as PackedStringArray).find("miner|default")
	var merchant_sig := (compiled.signature_keys as PackedStringArray).find("merchant|default")
	var stock := PackedInt64Array()
	stock.resize(2 * (compiled.good_ids as PackedStringArray).size())
	stock.fill(0)
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 1, 1, 1]),
		"signature_ids": PackedInt32Array([farmer_sig, landlord_sig, merchant_sig, industrialist_sig, worker_sig, merchant_sig]),
		"population": PackedInt64Array([1, 1, 10, 5, 20, 10]),
		"funds": PackedInt64Array([10000000, 10000000, 10000000, 10000000, 1000000, 10000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0, 0, 1]),
		"building_type_ids": PackedInt32Array([farm_type, corn_farm_type, mine_type]),
		"building_owner_signature_ids": PackedInt32Array([farmer_sig, landlord_sig, industrialist_sig]),
		"building_counts": PackedInt64Array([1, 1, 1]),
	})
	_expect("resource chain world bootstraps", bool(boot.get("ok", false)))

	var day0 := _run_day(ext, 0)
	var farm: Dictionary = ext.get_building_cell_snapshot(0)
	var mine: Dictionary = ext.get_building_cell_snapshot(1)
	var farm_group := (farm.group_type_ids as PackedInt32Array).find(farm_type)
	var corn_group := (farm.group_type_ids as PackedInt32Array).find(corn_farm_type)
	var full_output := int((farm.last_output as PackedInt64Array)[farm_group])
	_expect("capacity farm produces goods without consuming natural resources",
		full_output > 0 and int((farm.last_resource as PackedInt64Array)[farm_group]) == 0 and
		int((farm.last_resource_generated as PackedInt64Array)[farm_group]) == 0)
	var farm_market: Dictionary = ext.get_market_cell_snapshot(0)
	_expect("wheat and corn production visibly accumulates in local market inventory",
		_good_value(farm_market, "wheat_grain") > 0 and _good_value(farm_market, "corn_grain") > 0 and
		int((farm.last_output as PackedInt64Array)[corn_group]) > 0)
	_expect("mine extracts local coal", int((mine.last_resource as PackedInt64Array)[0]) > 0)
	_expect("resource report separates capacity checks from extraction",
		int(day0.get("building_resource_capacity_checks", 0)) >= 2 and
		int(day0.get("building_resource_consumed", 0)) > 0)
	_set_resource(ext, compiled, "arable_land", 0.5, 0.0)
	var day1 := _run_day(ext, 1)
	farm = ext.get_building_cell_snapshot(0)
	farm_group = (farm.group_type_ids as PackedInt32Array).find(farm_type)
	var constrained_output := int((farm.last_output as PackedInt64Array)[farm_group])
	_expect("insufficient arable capacity reduces output without resource delta",
		constrained_output > 0 and constrained_output < full_output and
		int((farm.last_resource as PackedInt64Array)[farm_group]) == 0 and
		int(day1.get("building_resource_capacity_limited_groups", 0)) > 0)
	_set_resource(ext, compiled, "arable_land", 0.0, 0.0)
	var empty := _run_day(ext, 2)
	farm = ext.get_building_cell_snapshot(0)
	farm_group = (farm.group_type_ids as PackedInt32Array).find(farm_type)
	_expect("zero arable capacity stops farm production",
		int((farm.last_output as PackedInt64Array)[farm_group]) == 0)
	_expect("capacity cycles conserve economy ledgers",
		int(empty.get("population_error", 1)) == 0 and int(empty.get("money_error", 1)) == 0 and
		int(empty.get("goods_error", 1)) == 0)
	_expect("resource production worker/scalar hashes match",
		_run_hash_scenario(compiled, false) == _run_hash_scenario(compiled, true))
	_expect("shore fishery extracts from the real adjacent water cell",
		_run_adjacent_fishery(compiled))
	print("=== building resource chain %s ===" % ("PASS" if failures == 0 else "FAIL"))


func _run_adjacent_fishery(catalog: Dictionary) -> bool:
	var map := MapData.new(3, 1)
	var shore := HexCell.new(0, 0)
	shore.terrain = TerrainType.TERRAIN.PLAIN
	shore.landform = LandformType.LF.PLAIN
	var sea := HexCell.new(1, 0)
	sea.terrain = TerrainType.TERRAIN.OCEAN
	sea.landform = LandformType.LF.OCEAN
	var second_shore := HexCell.new(2, 0)
	second_shore.terrain = TerrainType.TERRAIN.PLAIN
	second_shore.landform = LandformType.LF.PLAIN
	map.set_cell(shore)
	map.set_cell(sea)
	map.set_cell(second_shore)
	map._build_indices()
	map.init_soa_from_bake()
	map.res_marine_fish_reserve_arr[1] = 0.75
	map.resource_habitat_mask_arr[0] = 1
	map.resource_habitat_mask_arr[1] = 2
	map.resource_habitat_mask_arr[2] = 1
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if not bool(ext.bind_map_data(map)):
		return false
	var native_catalog := catalog.duplicate(true)
	native_catalog.erase("ok")
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	if not CountryTestHelper.configure_all_technologies(ext, native_catalog, 3, 94):
		return false
	if not bool(ext.configure_economy(native_catalog, profile, 3, 94).get("ok", false)):
		return false
	var signatures: PackedStringArray = catalog.signature_keys
	var industrialist := signatures.find("industrialist|default")
	var fisher := signatures.find("fisher|default")
	var merchant := signatures.find("merchant|default")
	var fishery := (catalog.building_type_ids as PackedStringArray).find("marine_fish_collector")
	if not bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 2, 2, 2]),
		"signature_ids": PackedInt32Array([industrialist, fisher, merchant,
			industrialist, fisher, merchant]),
		"population": PackedInt64Array([2, 20, 10, 2, 20, 10]),
		"funds": PackedInt64Array([10000000, 1000000, 10000000,
			10000000, 1000000, 10000000]),
	}, {
		"building_cells": PackedInt32Array([0, 2]),
		"building_type_ids": PackedInt32Array([fishery, fishery]),
		"building_owner_signature_ids": PackedInt32Array([industrialist, industrialist]),
		"building_counts": PackedInt64Array([1, 1]),
	}).get("ok", false)):
		return false
	var report := _run_day(ext, 0)
	var building: Dictionary = ext.get_building_cell_snapshot(0)
	var second_building: Dictionary = ext.get_building_cell_snapshot(2)
	var group := (building.group_type_ids as PackedInt32Array).find(fishery)
	var second_group := (second_building.group_type_ids as PackedInt32Array).find(fishery)
	var fish_resource := (catalog.building_resource_ids as PackedStringArray).find("marine_fish")
	var first_extracted := int((building.last_resource as PackedInt64Array)[group]) if group >= 0 else 0
	var second_extracted := int((second_building.last_resource as PackedInt64Array)[second_group]) if second_group >= 0 else 0
	return bool(report.get("done", false)) and group >= 0 and second_group >= 0 and \
		int((building.last_output as PackedInt64Array)[group]) + \
		int((second_building.last_output as PackedInt64Array)[second_group]) > 0 and \
		first_extracted + second_extracted == 750 and \
		int((building.building_resource_accessible_current_reserve as PackedInt64Array)[fish_resource]) == 750 and \
		is_equal_approx(map.res_marine_fish_extra_change_arr[0], 0.0) and \
		is_equal_approx(map.res_marine_fish_extra_change_arr[1], -0.75) and \
		is_equal_approx(map.res_marine_fish_extra_change_arr[2], 0.0)

func _run_half_filled_estate(catalog: Dictionary) -> bool:
	var ext := _new_ext(catalog)
	var native_catalog := catalog.duplicate(true); native_catalog.erase("ok")
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1; profile.market_runtime_mode = "ACTIVE"
	if not CountryTestHelper.configure_all_technologies(ext, native_catalog, 2, 92): return false
	if not bool(ext.configure_economy(native_catalog, profile, 2, 92).get("ok", false)): return false
	var landlord := (catalog.signature_keys as PackedStringArray).find("landlord|default")
	var merchant := (catalog.signature_keys as PackedStringArray).find("merchant|default")
	var estate := (catalog.building_type_ids as PackedStringArray).find("landed_estate")
	_set_resource(ext, catalog, "corn", 100.0, 0.0)
	if not bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]), "signature_ids": PackedInt32Array([landlord, merchant]),
		"population": PackedInt64Array([1, 10]), "funds": PackedInt64Array([10000000, 10000000]),
	}, {"building_cells": PackedInt32Array([0]), "building_type_ids": PackedInt32Array([estate]),
		"building_owner_signature_ids": PackedInt32Array([landlord]), "building_counts": PackedInt64Array([2])
	}).get("ok", false)): return false
	_run_day(ext, 0)
	var snapshot: Dictionary = ext.get_building_cell_snapshot(0)
	return int((snapshot.capacity_q16 as PackedInt64Array)[0]) == 32768 and \
		int((snapshot.last_resource_generated as PackedInt64Array)[0]) == 1050 and \
		int((snapshot.last_resource as PackedInt64Array)[0]) == 1000

func _round_trip_generated(source: Object, catalog: Dictionary, profile: Dictionary) -> bool:
	var country_chunks: Array[PackedByteArray] = []
	var country_begin: Dictionary = source.begin_country_save(4096)
	if not bool(country_begin.get("ok", false)): return false
	while true:
		var country_chunk: PackedByteArray = source.read_country_save_chunk(4096)
		if country_chunk.is_empty(): break
		country_chunks.append(country_chunk)
	if not bool(source.end_country_save().get("ok", false)): return false
	var chunks: Array[PackedByteArray] = []
	var begin: Dictionary = source.begin_economy_save(65536)
	if not bool(begin.get("ok", false)) or int(begin.get("schema_version", 0)) != 11: return false
	while true:
		var chunk: PackedByteArray = source.read_economy_save_chunk(65536)
		if chunk.is_empty(): break
		chunks.append(chunk)
	if not bool(source.end_economy_save().get("ok", false)): return false
	var restored := _new_ext(catalog)
	var native_catalog := catalog.duplicate(true); native_catalog.erase("ok")
	if not CountryTestHelper.configure_all_technologies(restored, native_catalog, 2, 91): return false
	if not bool(restored.begin_country_restore().get("ok", false)): return false
	for chunk in country_chunks:
		if not bool(restored.feed_country_restore_chunk(chunk).get("ok", false)): return false
	if not bool(restored.end_country_restore().get("ok", false)): return false
	if not bool(restored.configure_economy(native_catalog, profile, 2, 91).get("ok", false)): return false
	if not bool(restored.begin_economy_restore().get("ok", false)): return false
	for chunk in chunks:
		if not bool(restored.feed_economy_restore_chunk(chunk).get("ok", false)): return false
	if not bool(restored.end_economy_restore().get("ok", false)): return false
	var snapshot: Dictionary = restored.get_building_cell_snapshot(0)
	return restored.get_economy_state_hash() == source.get_economy_state_hash() and \
		int((snapshot.last_resource_generated as PackedInt64Array)[0]) == 1050

func _run_hash_scenario(catalog: Dictionary, worker_enabled: bool) -> int:
	var ext := _new_ext(catalog)
	var native_catalog := catalog.duplicate(true); native_catalog.erase("ok")
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1; profile.market_runtime_mode = "ACTIVE"
	if not CountryTestHelper.configure_all_technologies(ext, native_catalog, 2, 93): return 0
	profile.worker_enabled = worker_enabled; profile.worker_market_threshold = 1
	if not bool(ext.configure_economy(native_catalog, profile, 2, 93).get("ok", false)): return 0
	var farmer := (catalog.signature_keys as PackedStringArray).find("subsistence_farmer|default")
	var merchant := (catalog.signature_keys as PackedStringArray).find("merchant|default")
	var farm := (catalog.building_type_ids as PackedStringArray).find("subsistence_farm")
	_set_resource(ext, catalog, "arable_land", 100.0, 0.0)
	_set_resource(ext, catalog, "fertile_soil", 100.0, 0.0)
	if not bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]), "signature_ids": PackedInt32Array([farmer, merchant]),
		"population": PackedInt64Array([1, 10]), "funds": PackedInt64Array([10000000, 10000000]),
	}, {"building_cells": PackedInt32Array([0]), "building_type_ids": PackedInt32Array([farm]),
		"building_owner_signature_ids": PackedInt32Array([farmer]), "building_counts": PackedInt64Array([1])
	}).get("ok", false)): return 0
	_run_day(ext, 0)
	return ext.get_economy_state_hash()

func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(2)
	var scalar := PackedFloat32Array([0.5, 0.5])
	for slot_name in [&"cell_temp", &"cell_moisture", &"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	var zero_u8 := PackedByteArray([0, 0])
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation", &"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, zero_u8)
	for i in range((catalog.building_resource_ids as PackedStringArray).size()):
		var reserve_sid: int = ext.register_component(StringName(catalog.building_resource_reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(catalog.building_resource_extra_slots[i]), 0, 1, false)
		var resource_id := String(catalog.building_resource_ids[i])
		var cell_zero := 100.0 if resource_id in ["arable_land", "fertile_soil"] else 0.0
		var cell_one := 15.0 if resource_id == "coal" else 0.0
		var reserve := PackedFloat32Array([cell_zero, cell_one])
		ext.write_f32_range(reserve_sid, 0, reserve)
		ext.write_f32_range(extra_sid, 0, PackedFloat32Array([0.0, 0.0]))
	return ext

func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(256):
		report = ext.run_economy_slice({"day_index": day, "tick_index": day * 1000 + slice})
		if bool(report.get("done", false)): return report
	return report

func _apply_resource_pass(ext: Object, catalog: Dictionary) -> void:
	for resource_id in catalog.building_resource_ids:
		var idx := (catalog.building_resource_ids as PackedStringArray).find(resource_id)
		var reserve_sid: int = ext.component_id(StringName(catalog.building_resource_reserve_slots[idx]))
		var extra_sid: int = ext.component_id(StringName(catalog.building_resource_extra_slots[idx]))
		var reserve: PackedFloat32Array = ext.snapshot_f32(reserve_sid)
		var extra: PackedFloat32Array = ext.snapshot_f32(extra_sid)
		for cell in range(reserve.size()): reserve[cell] = maxf(0.0, reserve[cell] + extra[cell])
		ext.write_f32_range(reserve_sid, 0, reserve)
		ext.write_f32_range(extra_sid, 0, PackedFloat32Array([0.0, 0.0]))

func _set_resource(ext: Object, catalog: Dictionary, resource_id: String, reserve: float, pending: float) -> void:
	var idx := (catalog.building_resource_ids as PackedStringArray).find(resource_id)
	var reserve_sid: int = ext.component_id(StringName(catalog.building_resource_reserve_slots[idx]))
	var extra_sid: int = ext.component_id(StringName(catalog.building_resource_extra_slots[idx]))
	var reserves: PackedFloat32Array = ext.snapshot_f32(reserve_sid)
	var changes: PackedFloat32Array = ext.snapshot_f32(extra_sid)
	reserves[0] = reserve
	changes[0] = pending
	ext.write_f32_range(reserve_sid, 0, reserves)
	ext.write_f32_range(extra_sid, 0, changes)


func _good_value(snapshot: Dictionary, good_id: String) -> int:
	var index := (snapshot.good_ids as PackedStringArray).find(good_id)
	return int((snapshot.stock as PackedInt64Array)[index]) if index >= 0 else 0
