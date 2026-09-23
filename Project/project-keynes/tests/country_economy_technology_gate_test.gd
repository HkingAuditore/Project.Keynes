extends SceneTree

# Live building_technology_available must follow Country has_technology().
# Under Country worker authority that pins country_asset_snapshot (same as
# copy_economy_snapshot); this fixture covers the sync-path unlock contract for
# early_knowledge_institution which previously presented as 「技术停用」.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("country economy technology gate: %d checks, %d failures" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect("DCWorldExt available", false)
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var native := compiled.duplicate(true)
	native.erase("ok")
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var scalar := PackedFloat32Array([0.5])
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, PackedByteArray([0]))
	var resources: PackedStringArray = compiled.building_resource_ids
	var reserve_slots: PackedStringArray = compiled.building_resource_reserve_slots
	var extra_slots: PackedStringArray = compiled.building_resource_extra_slots
	for i in range(resources.size()):
		var reserve_sid: int = ext.register_component(
			StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(
			StringName(extra_slots[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, PackedFloat32Array([1000000.0]))
		ext.write_f32_range(extra_sid, 0, PackedFloat32Array([0.0]))

	var starters := PackedStringArray([
		"tech.gathering", "tech.hunting", "tech.deadwood_collection",
		"tech.early_trade",
	])
	var country_profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": starters,
	}
	_expect("country configures", bool(ext.configure_country(
		native, country_profile, 1, 20260922).get("ok", false)))
	_expect("country bootstraps", bool(ext.bootstrap_country(
		{}, PackedByteArray([0])).get("ok", false)))
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	_expect("economy configures", bool(ext.configure_economy(
		native, profile, 1, 20260922).get("ok", false)))
	var signatures: PackedStringArray = compiled.signature_keys
	_expect("economy bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([
			signatures.find("forager|default"),
			signatures.find("merchant|default")]),
		"population": PackedInt64Array([10, 10]),
		"funds": PackedInt64Array([1000000, 1000000]),
	}, {}).get("ok", false)))

	var types: PackedStringArray = compiled.building_type_ids
	var knowledge_type := types.find("early_knowledge_institution")
	_expect("early knowledge institution is catalogued", knowledge_type >= 0)
	var locked: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("institution starts technology-locked",
		knowledge_type >= 0 and
		(locked.building_technology_available as PackedByteArray)[knowledge_type] == 0)

	var technologies: PackedStringArray = compiled.technology_ids
	var tech := technologies.find("tech.early_knowledge_institution")
	var summary: Dictionary = ext.get_country_cell_summary(0)
	_expect("cell has a country", bool(summary.get("ok", false)))
	var queued: Dictionary = ext.submit_country_commands({
		"opcodes": PackedInt32Array([4]),
		"effective_days": PackedInt64Array([0]),
		"sequences": PackedInt64Array([1]),
		"target_handles": PackedInt64Array([int(summary.country_handle)]),
		"cell_indices": PackedInt32Array([-1]),
		"aux_i32": PackedInt32Array([tech]),
		"domain_i32": PackedInt32Array([-1]),
		"position_i32": PackedInt32Array([-1]),
		"weight0_bp": PackedInt32Array([0]),
		"weight1_bp": PackedInt32Array([0]),
		"weight2_bp": PackedInt32Array([0]),
		"weight3_bp": PackedInt32Array([0]),
		"value_i64": PackedInt64Array([0]),
		"stable_ids": PackedStringArray([""]),
		"display_names": PackedStringArray([""]),
	})
	_expect("grant queues", bool(queued.get("ok", false)))
	_expect("grant pending day commits",
		bool(ext.run_country_slice({"day_index": 0}).get("done", false)))
	_expect("grant activates next day",
		bool(ext.run_country_slice({"day_index": 1}).get("done", false)))
	var report := {}
	for slice in range(512):
		report = ext.run_economy_slice({"day_index": 1, "tick_index": 1000 + slice})
		if bool(report.get("done", false)):
			break
	_expect("economy observes activation day", bool(report.get("done", false)))
	var unlocked_country: Dictionary = ext.get_country_snapshot(
		int(summary.country_handle))
	var unlocked_buildings: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("country lists early knowledge as completed",
		(unlocked_country.technology_ids as PackedStringArray).has(
			"tech.early_knowledge_institution"))
	_expect("live building gate unlocks early knowledge institution",
		knowledge_type >= 0 and
		(unlocked_buildings.building_technology_available as PackedByteArray)[
			knowledge_type] == 1)
