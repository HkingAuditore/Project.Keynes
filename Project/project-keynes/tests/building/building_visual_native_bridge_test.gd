extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const BuildingVisualLayerScript = preload("res://scripts/rendering/building_visual_layer.gd")

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
	var social_ok := true
	for key in ["settlement_tiers", "living_levels", "rich_buckets", "poor_buckets"]:
		var column := PackedByteArray(snapshot.get(key, PackedByteArray()))
		social_ok = social_ok and column.size() == 3
	_expect("snapshot carries aligned social band columns", social_ok)
	if social_ok:
		var tiers := PackedByteArray(snapshot.settlement_tiers)
		var living := PackedByteArray(snapshot.living_levels)
		_expect("social bands stay inside their published ranges",
			tiers[0] <= 7 and tiers[2] == 0
			and (living[0] <= 6 or living[0] == 255) and living[2] == 255)
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
	var body_count := int(native_chunk.get("instance_count", 0))
	var decal_count := int(native_chunk.get("decal_instance_count", 0))
	var body_buffer := PackedFloat32Array(native_chunk.get("buffer", PackedFloat32Array()))
	var decal_buffer := PackedFloat32Array(native_chunk.get("decal_buffer", PackedFloat32Array()))
	_expect("C++ building chunk baker returns packed body and ground geometry",
		bool(native_chunk.get("ok", false))
		and String(native_chunk.get("path", "")) == "gdext_building_visual"
		and body_count > 0 and body_count <= 100
		and body_buffer.size() == body_count * 16
		and decal_count > 0 and decal_buffer.size() == decal_count * 16
		and int(native_chunk.get("lot_count", 0)) > 0)
	# custom.b carries cell / (cell_count - 1): cell 0 encodes 0.0, the water
	# cell 1 would encode 0.5.
	var only_land_cell := true
	for i in body_count:
		if body_buffer[i * 16 + 14] > 0.25:
			only_land_cell = false
	_expect("water cell contributes no buildings", only_land_cell)
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
		PackedFloat32Array(native_chunk_again.buffer)
		and PackedFloat32Array(native_chunk.decal_buffer) ==
		PackedFloat32Array(native_chunk_again.decal_buffer))
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
	# An int64-max count saturates settlement density; the planner is then bounded
	# only by the hex and the quality-0 lot budget.
	var huge_instances := int(huge_count.get("instance_count", 0))
	var huge_buffer := PackedFloat32Array(huge_count.get("buffer", PackedFloat32Array()))
	var huge_finite := true
	for v in huge_buffer:
		if is_nan(v) or is_inf(v):
			huge_finite = false
			break
	_expect("C++ density saturates at int64 max with finite geometry",
		bool(huge_count.get("ok", false))
		and huge_instances > 0 and huge_instances <= 100
		and huge_buffer.size() == huge_instances * 16 and huge_finite)
	# Worst-case numeric stress fixture: one 16x16 chunk where every land cell
	# sits at saturated density, so the planned settlements overflow the chunk
	# instance cap. This is far past any plausible map (256 adjacent cells of 100k
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
	_expect("C++ 16x16 stress bake fills exactly the chunk instance cap",
		bool(stress_chunk.get("ok", false))
		and int(stress_chunk.get("instance_count", 0)) == 6144
		and int(stress_chunk.get("candidate_count", 0)) > 6144
		and PackedFloat32Array(stress_chunk.get("buffer", PackedFloat32Array())).size() == 6144 * 16)
	_check_social_layout(ext, catalog)
	_check_layout_cache(stress_knobs, type_to_archetype)


## Housing follows the settlement tier, villas and shanties the rich and poor
## buckets, and industry lots the scale-weighted family mix.
func _check_social_layout(ext: Object, catalog: Dictionary) -> void:
	var layer: BuildingVisualLayer = BuildingVisualLayerScript.new()
	var audit := layer.configure_catalog(catalog)
	_expect("visual family tables derive from the catalog", bool(audit.get("ok", false)))
	var ids := catalog.building_type_ids as PackedStringArray
	var textile := ids.find("textile_mill")
	var paddy := ids.find("tenant_paddy")
	var textile_family := layer.FAMILY_NAMES.find("textile")
	var paddy_family := layer.FAMILY_NAMES.find("paddy")
	var tables := {
		"type_to_archetype": layer._type_to_archetype, "type_to_family": layer._type_to_family,
		"type_to_scale": layer._type_to_scale, "type_to_grade": layer._type_to_grade,
	}
	var bake := func(types: PackedInt32Array, counts: PackedInt64Array,
			social: PackedByteArray) -> Dictionary:
		var knobs := {
			"cell_indices": PackedInt32Array([0]),
			"cell_pos_x": PackedFloat32Array([0.0]), "cell_pos_y": PackedFloat32Array([0.0]),
			"type_offsets": PackedInt32Array([0, types.size()]),
			"type_indices": types, "type_counts": counts,
			"era_indices": PackedInt32Array([5]), "is_water": PackedByteArray([0]),
			"settlement_tiers": PackedByteArray([social[0]]),
			"living_levels": PackedByteArray([social[1]]),
			"rich_buckets": PackedByteArray([social[2]]),
			"poor_buckets": PackedByteArray([social[3]]),
			"quality": 2, "instance_cap": 4096, "hex_size": 22.0, "cell_count": 3,
		}
		knobs.merge(tables)
		return ext.bake_building_visual_chunk(knobs)
	var mixed_types := PackedInt32Array([textile, paddy])
	var hamlet: Dictionary = bake.call(mixed_types, PackedInt64Array([8, 8]),
		PackedByteArray([2, 3, 0, 0]))
	var city: Dictionary = bake.call(mixed_types, PackedInt64Array([8, 8]),
		PackedByteArray([6, 3, 0, 0]))
	_expect("a larger settlement tier draws more houses",
		bool(hamlet.get("ok", false)) and bool(city.get("ok", false))
		and int(hamlet.get("house_count", 0)) > 0
		and int(city.get("house_count", 0)) > int(hamlet.get("house_count", 0)))
	var plain: Dictionary = bake.call(mixed_types, PackedInt64Array([8, 8]),
		PackedByteArray([5, 3, 0, 0]))
	var unequal: Dictionary = bake.call(mixed_types, PackedInt64Array([8, 8]),
		PackedByteArray([5, 3, 3, 3]))
	_expect("rich and poor buckets add villas and shanties",
		int(plain.get("villa_count", -1)) == 0 and int(plain.get("shanty_count", -1)) == 0
		and int(unequal.get("villa_count", 0)) > 0 and int(unequal.get("shanty_count", 0)) > 0)
	var mill_town: Dictionary = bake.call(mixed_types, PackedInt64Array([64, 4]),
		PackedByteArray([4, 3, 0, 0]))
	var rice_town: Dictionary = bake.call(mixed_types, PackedInt64Array([4, 64]),
		PackedByteArray([4, 3, 0, 0]))
	var mill_lots := PackedInt32Array(mill_town.get("family_lots", PackedInt32Array()))
	var rice_lots := PackedInt32Array(rice_town.get("family_lots", PackedInt32Array()))
	_expect("the dominant industry family takes the most lots",
		mill_lots.size() == layer.FAMILY_NAMES.size() and rice_lots.size() == mill_lots.size()
		and mill_lots[textile_family] > mill_lots[paddy_family]
		and rice_lots[paddy_family] > rice_lots[textile_family])
	var small_mill: Dictionary = bake.call(PackedInt32Array([textile]), PackedInt64Array([4]),
		PackedByteArray([4, 3, 0, 0]))
	var big_mill: Dictionary = bake.call(PackedInt32Array([textile]), PackedInt64Array([256]),
		PackedByteArray([4, 3, 0, 0]))
	_expect("more buildings of a family never draw fewer lots",
		int(big_mill.get("lot_count", 0)) >= int(small_mill.get("lot_count", 0))
		and int(big_mill.get("lot_count", 0)) > 0)
	var homes_only: Dictionary = bake.call(PackedInt32Array(), PackedInt64Array(),
		PackedByteArray([4, 3, 0, 0]))
	_expect("a populated cell without buildings still draws its houses",
		bool(homes_only.get("ok", false)) and int(homes_only.get("house_count", 0)) > 0
		and int(homes_only.get("lot_count", -1)) == 0)
	layer.free()


## The per-cell cache must reproduce the chunk planner exactly, plan on its
## worker, and replan only cells whose input changed. Timing is printed, not
## asserted, so the test stays hardware independent.
func _check_layout_cache(stress_knobs: Dictionary, type_to_archetype: PackedByteArray) -> void:
	if not ClassDB.class_exists("NativeBuildingVisualCache"):
		_expect("NativeBuildingVisualCache is registered", false)
		return
	var raw_x := PackedFloat32Array()
	var raw_y := PackedFloat32Array()
	for v in PackedFloat32Array(stress_knobs.cell_pos_x):
		raw_x.append(v / 22.0)
	for v in PackedFloat32Array(stress_knobs.cell_pos_y):
		raw_y.append(v / 22.0)
	var cache: Object = ClassDB.instantiate("NativeBuildingVisualCache")
	var configured: Dictionary = cache.configure({
		"cell_count": 256, "map_width": 16, "chunk_size": 16, "hex_size": 22.0,
		"cell_pos_x": raw_x, "cell_pos_y": raw_y,
		"type_to_archetype": type_to_archetype, "quality": 2,
	})
	_expect("layout cache configures one 16x16 chunk",
		bool(configured.get("ok", false)) and int(configured.get("chunk_count", 0)) == 1)
	var rows := {
		"cell_indices": stress_knobs.cell_indices, "era_indices": stress_knobs.era_indices,
		"is_water": stress_knobs.is_water, "type_offsets": stress_knobs.type_offsets,
		"type_indices": stress_knobs.type_indices, "type_counts": stress_knobs.type_counts,
	}
	var submit_begin := Time.get_ticks_usec()
	var submitted: Dictionary = cache.submit_cells(rows)
	var submit_ms := float(Time.get_ticks_usec() - submit_begin) / 1000.0
	var idle := bool(cache.wait_idle(10000))
	var ready := PackedInt32Array(cache.take_ready_chunks())
	var diag: Dictionary = cache.diagnostics()
	_expect("worker plans all submitted cells and reports the chunk ready",
		bool(submitted.get("ok", false)) and int(submitted.get("accepted", 0)) == 256
		and idle and ready == PackedInt32Array([0])
		and int(diag.get("planned_cells", 0)) == 256)

	var unbounded := stress_knobs.duplicate()
	unbounded["instance_cap"] = 1 << 20
	var reference: Dictionary = (ClassDB.instantiate("DCWorldExt") as Object) \
		.bake_building_visual_chunk(unbounded)
	var assembled: Dictionary = cache.build_chunk(0, 1 << 20)
	_expect("cached cells assemble to exactly the chunk planner output",
		PackedFloat32Array(assembled.buffer) == PackedFloat32Array(reference.buffer)
		and PackedFloat32Array(assembled.decal_buffer) == PackedFloat32Array(reference.decal_buffer))

	var build_samples: Array[float] = []
	var capped: Dictionary = {}
	for _i in 30:
		capped = cache.build_chunk(0, 6144)
		build_samples.append(float(capped.get("elapsed_ms", -1.0)))
	build_samples.sort()
	_expect("over-cap assembly keeps exactly the cap by in-cell rank",
		int(capped.get("instance_count", 0)) == 6144
		and PackedFloat32Array(capped.buffer).size() == 6144 * 16)

	cache.submit_cells(rows)
	cache.wait_idle(10000)
	var after_same: Dictionary = cache.diagnostics()
	_expect("identical resubmission plans nothing",
		int(after_same.get("planned_cells", 0)) == 256
		and int(after_same.get("unchanged_cells", 0)) == 256)
	cache.take_ready_chunks()
	var one_counts := PackedInt64Array(stress_knobs.type_counts).duplicate()
	one_counts[37] = 12
	var one_rows := rows.duplicate()
	one_rows["type_counts"] = one_counts
	var one_submit_begin := Time.get_ticks_usec()
	var one: Dictionary = cache.submit_cells(one_rows)
	var one_submit_ms := float(Time.get_ticks_usec() - one_submit_begin) / 1000.0
	cache.wait_idle(10000)
	var after_one: Dictionary = cache.diagnostics()
	_expect("one changed cell replans only that cell",
		int(one.get("accepted", 0)) == 1
		and int(after_one.get("planned_cells", 0)) == 257
		and PackedInt32Array(cache.take_ready_chunks()) == PackedInt32Array([0]))
	var living := PackedByteArray()
	living.resize(256)
	living.fill(255)
	living[90] = 6
	var social_rows := one_rows.duplicate()
	social_rows["living_levels"] = living
	var social_submit: Dictionary = cache.submit_cells(social_rows)
	cache.wait_idle(10000)
	_expect("a living-level band change replans only that cell",
		int(social_submit.get("accepted", 0)) == 1
		and int(cache.diagnostics().get("planned_cells", 0)) == 258)
	var homes_rows := {
		"cell_indices": PackedInt32Array([37]), "era_indices": PackedInt32Array([10]),
		"is_water": PackedByteArray([0]), "type_offsets": PackedInt32Array([0, 0]),
		"type_indices": PackedInt32Array(), "type_counts": PackedInt64Array(),
		"settlement_tiers": PackedByteArray([4]),
	}
	var homes_submit: Dictionary = cache.submit_cells(homes_rows)
	cache.wait_idle(10000)
	var homes_rows_gone := homes_rows.duplicate()
	homes_rows_gone["settlement_tiers"] = PackedByteArray([0])
	var gone_submit: Dictionary = cache.submit_cells(homes_rows_gone)
	cache.wait_idle(10000)
	var gone_again: Dictionary = cache.submit_cells(homes_rows_gone)
	_expect("a populated cell without buildings stays cached until its people leave",
		int(homes_submit.get("accepted", 0)) == 1 and int(gone_submit.get("accepted", 0)) == 1
		and int(gone_again.get("unchanged", 0)) == 1)
	cache.take_ready_chunks()
	print(("building visual cache: worker %.1f us/cell avg, %.1f us max, %.2f ms for 256 cells; "
		+ "main thread submit(256)=%.4f ms submit(1 of 256)=%.4f ms "
		+ "assemble(6144) median=%.4f ms max=%.4f ms") % [
		float(diag.get("worker_plan_us_avg", -1.0)), float(diag.get("worker_plan_us_max", -1.0)),
		float(diag.get("worker_plan_ms_total", -1.0)), submit_ms, one_submit_ms,
		build_samples[build_samples.size() / 2], build_samples[-1]])
	cache.shutdown()


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
