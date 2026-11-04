extends SceneTree

const Catalog = preload("res://scripts/economy/economy_catalog.gd")
const Country = preload("res://tests/country/country_test_helper.gd")
var checks := 0
var failures := 0

func _init() -> void:
	var catalog := Catalog.compile_native_catalog()
	_expect("catalog compiles", bool(catalog.get("ok", false)))
	catalog.erase("ok")
	for reverse in [false, true]:
		var ext := _configured(catalog)
		var packet := _packet(catalog, PackedInt64Array([0, 1]), reverse)
		var result: Dictionary = ext.bootstrap_economy(_population(catalog), packet)
		_expect("explicit staffing is accepted", bool(result.get("ok", false)))
		var snapshot: Dictionary = ext.get_building_cell_snapshot(0)
		var types: PackedInt32Array = snapshot.group_type_ids
		var filled: PackedInt64Array = snapshot.filled_owner
		var gathering := (catalog.building_type_ids as PackedStringArray).find("gathering_ground")
		var deadwood := (catalog.building_type_ids as PackedStringArray).find("deadwood_gathering_camp")
		_expect("food keeps its operator regardless of packet or catalog order",
			filled[types.find(gathering)] == 1 and filled[types.find(deadwood)] == 0)
		var pop: Dictionary = ext.get_population_cell_snapshot(0)
		_expect("population is conserved", int(pop.population) == 2)
	for fills in [PackedInt64Array([0]), PackedInt64Array([-1, 1]),
			PackedInt64Array([0, 2]), PackedInt64Array([1, 1])]:
		var ext := _configured(catalog)
		var result: Dictionary = ext.bootstrap_economy(_population(catalog), _packet(catalog, fills, false))
		_expect("bad length, negative, over-capacity and over-population allocations fail",
			not bool(result.get("ok", false)) and String(result.get("reason", "")) in
			["building_bootstrap_column_size_mismatch", "building_bootstrap_owner_fill_invalid"])
	print("bootstrap owner allocation: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _configured(catalog: Dictionary) -> Object:
	var ext := _new_ext(catalog)
	_expect("country configures", Country.configure_all_technologies(ext, catalog, 1, 42))
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "OFF"
	_expect("economy configures", bool(ext.configure_economy(catalog, profile, 1, 42).get("ok", false)))
	return ext

func _population(catalog: Dictionary) -> Dictionary:
	var signatures: PackedStringArray = catalog.signature_keys
	return {"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([signatures.find("forager|default"), signatures.find("merchant|default")]),
		"population": PackedInt64Array([1, 1]), "funds": PackedInt64Array([1000, 1000])}

func _packet(catalog: Dictionary, fill: PackedInt64Array, reverse: bool) -> Dictionary:
	var ids: PackedStringArray = catalog.building_type_ids
	var types := PackedInt32Array([ids.find("deadwood_gathering_camp"), ids.find("gathering_ground")])
	var counts := PackedInt64Array([1, 1])
	if reverse:
		types.reverse()
		fill.reverse()
	var signature := (catalog.signature_keys as PackedStringArray).find("forager|default")
	return {"building_cells": PackedInt32Array([0, 0]), "building_type_ids": types,
		"building_owner_signature_ids": PackedInt32Array([signature, signature]),
		"building_counts": counts, "building_owner_fill": fill}

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[FAIL] " + label)

func _new_ext(catalog: Dictionary, cell_count: int = 1) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cell_count)
	var scalar := PackedFloat32Array()
	scalar.resize(cell_count)
	scalar.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation", &"cell_temp_365d"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	var zero_u8 := PackedByteArray()
	zero_u8.resize(cell_count)
	zero_u8.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation", &"cell_is_water", &"cell_has_river", &"cell_weather_type", &"cell_cover"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, zero_u8)
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	var resource_ids: PackedStringArray = catalog.building_resource_ids
	var ecology_capacities: PackedInt64Array = \
		catalog.building_resource_ecology_capacity
	for i in range(resource_ids.size()):
		var reserve_sid: int = ext.register_component(StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(extra_slots[i]), 0, 1, false)
		var reserve := PackedFloat32Array()
		reserve.resize(cell_count)
		reserve.fill(maxf(1000.0,
			float(ecology_capacities[i]) / 1000.0 if
			i < ecology_capacities.size() else 1000.0))
		var extra := PackedFloat32Array()
		extra.resize(cell_count)
		extra.fill(0.0)
		ext.write_f32_range(reserve_sid, 0, reserve)
		ext.write_f32_range(extra_sid, 0, extra)
	return ext

