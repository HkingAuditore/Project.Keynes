extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("building visual native bridge: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var compiled := EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var ext := _new_ext(catalog, 3)
	var country_profile := {"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray()}
	_expect("country runtime configures",
		bool(ext.configure_country(catalog, country_profile, 3, 551).get("ok", false)))
	var milestones: PackedInt32Array = catalog.technology_era_milestone_indices
	var country_packet := {
		"country_ids": PackedStringArray(["country.visual_test"]),
		"country_names": PackedStringArray(["Visual Test"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 2]),
		"territory_cells": PackedInt32Array([0, 1]),
		"technology_offsets": PackedInt32Array([0, milestones.size()]),
		"technology_indices": milestones,
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}
	_expect("country with all exact era milestones bootstraps",
		bool(ext.bootstrap_country(country_packet, PackedByteArray([0, 0, 0])).get("ok", false)))
	var economy_profile = load("res://data/economy/default_economy.tres").to_native_profile()
	economy_profile.market_runtime_mode = "OFF"
	economy_profile.family_runtime_mode = "OFF"
	_expect("economy runtime configures",
		bool(ext.configure_economy(catalog, economy_profile, 3, 551).get("ok", false)))
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan := signatures.find("artisan|default")
	var merchant := signatures.find("merchant|default")
	var workshop := (catalog.building_type_ids as PackedStringArray).find("knapping_workshop")
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([artisan, merchant]),
		"population": PackedInt64Array([4, 1]),
		"funds": PackedInt64Array([1000000, 1000000]),
	}, {
		"building_cells": PackedInt32Array([0, 0]),
		"building_type_ids": PackedInt32Array([workshop, workshop]),
		"building_owner_signature_ids": PackedInt32Array([artisan, artisan]),
		"building_counts": PackedInt64Array([2, 5]),
	})
	_expect("duplicate authoritative building groups bootstrap", bool(boot.get("ok", false)))
	if not bool(boot.get("ok", false)):
		return
	var hash_before := int(ext.get_economy_state_hash())
	var snapshot: Dictionary = ext.get_building_visual_snapshot(
		PackedInt32Array([2, 0, 1, 0]))
	_expect("batch request sorts and deduplicates cells",
		bool(snapshot.get("ok", false))
		and (snapshot.cell_indices as PackedInt32Array) == PackedInt32Array([0, 1, 2]))
	_expect("empty requested cells preserve aligned CSR rows",
		(snapshot.type_offsets as PackedInt32Array) == PackedInt32Array([0, 1, 1, 1]))
	_expect("same cell and type aggregate across authoritative rows",
		(snapshot.type_indices as PackedInt32Array) == PackedInt32Array([workshop])
		and (snapshot.counts as PackedInt64Array) == PackedInt64Array([7]))
	_expect("country ownership and deepest catalog milestone compose at cold bridge",
		(snapshot.country_slots as PackedInt32Array) == PackedInt32Array([0, 0, -1])
		and (snapshot.era_indices as PackedInt32Array) == PackedInt32Array([10, 10, -1]))
	_expect("visual queries never alter economy state hash",
		int(ext.get_economy_state_hash()) == hash_before)
	var dirty: Dictionary = ext.consume_building_visual_dirty_cells()
	_expect("bootstrap does not invent a construction dirty event",
		bool(dirty.get("ok", false)) and (dirty.dirty_cells as PackedInt32Array).is_empty())
	var era_dirty: Dictionary = ext.consume_country_visual_era_dirty_slots()
	_expect("bootstrap era derivation does not impersonate a completed-tech event",
		bool(era_dirty.get("ok", false)) and (era_dirty.country_slots as PackedInt32Array).is_empty())
	var type_to_archetype := PackedByteArray()
	type_to_archetype.resize(catalog.building_type_ids.size())
	type_to_archetype.fill(2)
	var native_chunk: Dictionary = ext.bake_building_visual_chunk({
		"cell_indices": PackedInt32Array([0, 1]),
		"cell_pos_x": PackedFloat32Array([0.0, 22.0]),
		"cell_pos_y": PackedFloat32Array([0.0, 0.0]),
		"type_offsets": PackedInt32Array([0, 1, 2]),
		"type_indices": PackedInt32Array([workshop, workshop]),
		"type_counts": PackedInt64Array([32, 32]),
		"era_indices": PackedInt32Array([10, 10]),
		"type_to_archetype": type_to_archetype,
		"is_water": PackedByteArray([0, 1]),
		"quality": 1, "instance_cap": 100,
		"hex_size": 22.0, "cell_count": 3,
	})
	# 32 buildings sit at density 0.304 on the settlement ladder, which rounds to
	# 7 compounds; the water cell contributes none.
	_expect("C++ building chunk baker returns packed geometry",
		bool(native_chunk.get("ok", false))
		and String(native_chunk.get("path", "")) == "gdext_building_visual"
		and int(native_chunk.get("instance_count", 0)) == 7
		and PackedFloat32Array(native_chunk.get("buffer", PackedFloat32Array())).size() == 112)
	var native_chunk_again: Dictionary = ext.bake_building_visual_chunk({
		"cell_indices": PackedInt32Array([0, 1]),
		"cell_pos_x": PackedFloat32Array([0.0, 22.0]),
		"cell_pos_y": PackedFloat32Array([0.0, 0.0]),
		"type_offsets": PackedInt32Array([0, 1, 2]),
		"type_indices": PackedInt32Array([workshop, workshop]),
		"type_counts": PackedInt64Array([32, 32]),
		"era_indices": PackedInt32Array([10, 10]),
		"type_to_archetype": type_to_archetype,
		"is_water": PackedByteArray([0, 1]),
		"quality": 1, "instance_cap": 100,
		"hex_size": 22.0, "cell_count": 3,
	})
	_expect("C++ chunk baker is deterministic",
		PackedFloat32Array(native_chunk.buffer) ==
		PackedFloat32Array(native_chunk_again.buffer))
	var malformed: Dictionary = ext.bake_building_visual_chunk({
		"cell_indices": PackedInt32Array([0, 1]),
		"cell_pos_x": PackedFloat32Array([0.0, 22.0]),
		"cell_pos_y": PackedFloat32Array([0.0, 0.0]),
		"type_offsets": PackedInt32Array([0, 2, 1]),
		"type_indices": PackedInt32Array([workshop]),
		"type_counts": PackedInt64Array([1]),
		"era_indices": PackedInt32Array([10, 10]),
		"type_to_archetype": type_to_archetype,
		"is_water": PackedByteArray([0, 0]),
		"quality": 1, "instance_cap": 100,
		"hex_size": 22.0, "cell_count": 3,
	})
	_expect("C++ chunk baker rejects a non-monotonic CSR shape",
		not bool(malformed.get("ok", false))
		and String(malformed.get("reason", "")) ==
			"building_visual_chunk_offsets_not_monotonic")
	var huge_count: Dictionary = ext.bake_building_visual_chunk({
		"cell_indices": PackedInt32Array([0]),
		"cell_pos_x": PackedFloat32Array([0.0]),
		"cell_pos_y": PackedFloat32Array([0.0]),
		"type_offsets": PackedInt32Array([0, 1]),
		"type_indices": PackedInt32Array([workshop]),
		"type_counts": PackedInt64Array([9223372036854775807]),
		"era_indices": PackedInt32Array([10]),
		"type_to_archetype": type_to_archetype,
		"is_water": PackedByteArray([0]),
		"quality": 0, "instance_cap": 100,
		"hex_size": 22.0, "cell_count": 3,
	})
	# An int64-max count saturates the ladder, so the compound count is decided
	# purely by the quality cap: NEAR_CAP[0] = 8.
	_expect("C++ count bucketing saturates at int64 max",
		bool(huge_count.get("ok", false))
		and int(huge_count.get("instance_count", 0)) == 8
		and PackedFloat32Array(huge_count.get("buffer", PackedFloat32Array())).size() == 128)
	# Worst-case numeric stress fixture: one 16x16 chunk where every land cell
	# sits at the top of the density ladder, so each draws the full 24-compound
	# budget. This is far past any plausible map (256 adjacent cells of 100k
	# buildings each); it exists to bound the bake, not to describe gameplay.
	# Print the native timing without making the test hardware dependent; the
	# runtime diagnostic owns the 1.5 ms performance gate.
	var stress_cells := PackedInt32Array()
	var stress_x := PackedFloat32Array()
	var stress_y := PackedFloat32Array()
	var stress_eras := PackedInt32Array()
	var stress_water := PackedByteArray()
	var stress_offsets := PackedInt32Array([0])
	var stress_types := PackedInt32Array()
	var stress_counts := PackedInt64Array()
	for row in 16:
		for col in 16:
			stress_cells.append(row * 16 + col)
			stress_x.append(float(col) * 22.0)
			stress_y.append(float(row) * 22.0)
			stress_eras.append(10)
			stress_water.append(0)
			stress_types.append(workshop)
			stress_counts.append(100000)
			stress_offsets.append(stress_types.size())
	var stress_knobs := {
		"cell_indices": stress_cells, "cell_pos_x": stress_x,
		"cell_pos_y": stress_y, "type_offsets": stress_offsets,
		"type_indices": stress_types, "type_counts": stress_counts,
		"era_indices": stress_eras, "type_to_archetype": type_to_archetype,
		"is_water": stress_water, "quality": 2, "instance_cap": 6144,
		"hex_size": 22.0, "cell_count": 256,
	}
	var stress_chunk: Dictionary = ext.bake_building_visual_chunk(stress_knobs)
	var stress_samples: Array[float] = []
	for _sample_index in 30:
		var sample: Dictionary = stress_chunk if _sample_index == 0 \
			else ext.bake_building_visual_chunk(stress_knobs)
		stress_samples.append(float(sample.get("elapsed_ms", -1.0)))
	var ordered_stress := stress_samples.duplicate()
	ordered_stress.sort()
	var stress_sum := 0.0
	for sample_ms in stress_samples:
		stress_sum += sample_ms
	var stress_p95_index := clampi(ceili(float(ordered_stress.size()) * 0.95) - 1,
		0, maxi(0, ordered_stress.size() - 1))
	print(("building visual native stress: avg=%.4f ms p95=%.4f ms max=%.4f ms "
		+ "instances=%d candidates=%d") % [
		stress_sum / maxf(1.0, float(stress_samples.size())),
		float(ordered_stress[stress_p95_index]),
		float(ordered_stress[-1]),
		int(stress_chunk.get("instance_count", 0)),
		int(stress_chunk.get("candidate_count", 0)),
	])
	_expect("C++ 16x16 stress bake keeps the full compound budget",
		bool(stress_chunk.get("ok", false))
		and int(stress_chunk.get("instance_count", 0)) == 6144
		and int(stress_chunk.get("candidate_count", 0)) == 49152)


func _new_ext(catalog: Dictionary, cell_count: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cell_count)
	var scalar := PackedFloat32Array()
	scalar.resize(cell_count)
	scalar.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	var zero_u8 := PackedByteArray()
	zero_u8.resize(cell_count)
	zero_u8.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, zero_u8)
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	var resource_ids: PackedStringArray = catalog.building_resource_ids
	for i in resource_ids.size():
		var reserve_sid: int = ext.register_component(StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(extra_slots[i]), 0, 1, false)
		var reserve := PackedFloat32Array()
		reserve.resize(cell_count)
		reserve.fill(1000.0)
		var extra := PackedFloat32Array()
		extra.resize(cell_count)
		ext.write_f32_range(reserve_sid, 0, reserve)
		ext.write_f32_range(extra_sid, 0, extra)
	return ext


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1
		push_error(label)
