extends SceneTree

# Focused 100k-cell release gate. This is intentionally not a CI assertion:
# run on the target machine and compare the printed p95 values with the runtime
# performance charter.

const N := 100_000
const WIDTH := 400
const HEIGHT := 250


func _init() -> void:
	var report := _run_bench()
	print("[bio-vision-native-bench] %s" % JSON.stringify(report))
	quit(0 if bool(report.get("ok", false)) else 1)


func _run_bench() -> Dictionary:
	if not ClassDB.class_exists("DCWorldExt"):
		return {"ok": false, "reason": "DCWorldExt missing"}
	var ext := DCWorldExt.new()
	ext.create_entities(N)
	var neighbors := _neighbors()
	var water := PackedByteArray()
	var vegetation := PackedByteArray()
	var landform := PackedByteArray()
	var river := PackedByteArray()
	var temp := PackedFloat32Array()
	var moisture := PackedFloat32Array()
	var elevation := PackedFloat32Array()
	var province := PackedInt32Array()
	var occupancy := PackedInt32Array()
	water.resize(N); vegetation.resize(N); landform.resize(N); river.resize(N)
	temp.resize(N); moisture.resize(N); elevation.resize(N)
	province.resize(N); occupancy.resize(N)
	for cell in N:
		vegetation[cell] = VegetationType.VEG.TEMPERATE_GRASSLAND
		landform[cell] = LandformType.LF.PLAIN
		river[cell] = 1
		temp[cell] = 0.55
		moisture[cell] = 0.58
		elevation[cell] = 0.20
		province[cell] = 1
	var catalog: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		return {"ok": false, "reason": "bio catalog"}
	var wheat_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.wheat")
	for cell in range(0, N, 20):
		occupancy[cell] = 1 << wheat_bit
	_write_u8(ext, &"cell_is_water", water)
	_write_u8(ext, &"cell_vegetation", vegetation)
	_write_u8(ext, &"cell_landform", landform)
	_write_u8(ext, &"cell_has_river", river)
	_write_f32(ext, &"cell_temp_30d", temp)
	_write_f32(ext, &"cell_moisture", moisture)
	_write_f32(ext, &"cell_elevation", elevation)
	_write_i32(ext, &"cell_province_id", province)
	_write_i32(ext, &"cell_bio_occupancy_bits", occupancy)
	var carrier_slots := PackedStringArray()
	var carrier_ids: PackedStringArray = catalog.get(
		"research_bio_carrier_ids", PackedStringArray())
	var carrier_alt_ids: PackedStringArray = catalog.get(
		"research_bio_carrier_alt_ids", PackedStringArray())
	var unique := {}
	var unique_ids: Array[String] = []
	for raw_id in carrier_ids:
		if not String(raw_id).is_empty() and not unique.has(String(raw_id)):
			unique[String(raw_id)] = unique_ids.size(); unique_ids.append(String(raw_id))
	for raw_id in carrier_alt_ids:
		if not String(raw_id).is_empty() and not unique.has(String(raw_id)):
			unique[String(raw_id)] = unique_ids.size(); unique_ids.append(String(raw_id))
	var carrier_primary := PackedInt32Array(); carrier_primary.resize(carrier_ids.size())
	var carrier_alt := PackedInt32Array(); carrier_alt.resize(carrier_alt_ids.size())
	for i in carrier_ids.size():
		carrier_primary[i] = int(unique.get(String(carrier_ids[i]), -1))
	for i in carrier_alt_ids.size():
		carrier_alt[i] = int(unique.get(String(carrier_alt_ids[i]), -1))
	var reserve := PackedFloat32Array(); reserve.resize(N); reserve.fill(80.0)
	for resource_id in unique_ids:
		for profile in ResourceProfileRegistry.ordered():
			if String(profile.id) != resource_id: continue
			var slot_name := StringName(ResourceProfileRegistry.reserve_cpp_name(profile))
			carrier_slots.append(slot_name)
			_write_f32(ext, slot_name, reserve)
			break
	var bio_config := {
		"cell_count": N, "neighbor_indices": neighbors,
		"species_signal_ids": catalog.research_bio_signal_ids,
		"species_occupancy_bits": catalog.research_bio_occupancy_bits,
		"species_carrier_index": carrier_primary,
		"species_carrier_alt_index": carrier_alt,
		"species_temp_lo": catalog.research_bio_temp_lo,
		"species_temp_hi": catalog.research_bio_temp_hi,
		"species_moist_lo": catalog.research_bio_moist_lo,
		"species_moist_hi": catalog.research_bio_moist_hi,
		"species_elev_lo": catalog.research_bio_elev_lo,
		"species_elev_hi": catalog.research_bio_elev_hi,
		"species_veg_mask0": catalog.research_bio_veg_mask0,
		"species_veg_mask1": catalog.research_bio_veg_mask1,
		"species_flags": catalog.research_bio_flags,
		"species_max_cost": catalog.research_bio_max_cost,
		"species_fill_keep": catalog.research_bio_fill_keep,
		"species_origin_policy": catalog.research_bio_origin_policy,
		"species_guild": catalog.research_bio_guild,
		"species_habitat_class": catalog.research_bio_habitat_class,
		"carrier_slot_names": carrier_slots,
	}
	var configured: Dictionary = ext.configure_bio_occupancy(bio_config)
	if not bool(configured.get("ok", false)):
		return {"ok": false, "reason": configured.get("reason", "bio config")}
	var bio_normal: Array[float] = []
	var bio_diffusion: Array[float] = []
	for sample in 24:
		var result: Dictionary = ext.run_bio_occupancy_pass({
			"cell_count": N, "seed": 77, "day_index": sample + 1,
			"run_diffusion": false, "use_configured_slots": true,
		})
		if not bool(result.get("ok", false)): return result
		if sample >= 4: bio_normal.append(float(result.native_compute_ms))
	for sample in 12:
		var result: Dictionary = ext.run_bio_occupancy_pass({
			"cell_count": N, "seed": 77, "day_index": 100 + sample,
			"run_diffusion": true, "use_configured_slots": true,
		})
		if not bool(result.get("ok", false)): return result
		if sample >= 2: bio_diffusion.append(float(result.native_compute_ms))

	var offsets := PackedInt32Array(); offsets.resize(N + 1)
	var view_height := PackedByteArray(); view_height.resize(N)
	var view_block := PackedByteArray(); view_block.resize(N); view_block.fill(6)
	var vision_config: Dictionary = ext.configure_vision_research({
		"cell_count": N, "neighbor_indices": neighbors,
		"view_height": view_height, "view_block": view_block,
		"signal_offsets": offsets, "signal_ids": PackedInt32Array(),
		"bio_bits": catalog.research_bio_occupancy_bits,
		"bio_signals": catalog.research_bio_signal_ids,
	})
	if not bool(vision_config.get("ok", false)): return vision_config
	var owners := PackedInt32Array(); owners.resize(N); owners.fill(-1)
	for y in range(HEIGHT / 2 - 5, HEIGHT / 2 + 5):
		for x in range(WIDTH / 2 - 5, WIDTH / 2 + 5): owners[y * WIDTH + x] = 0
	var visible := PackedByteArray(); visible.resize(N)
	var explored := PackedByteArray(); explored.resize(N)
	var fog := PackedByteArray(); fog.resize(N)
	var vision_times: Array[float] = []
	var occupancy_snapshot: PackedInt32Array = ext.snapshot_i32(
		ext.component_id(&"cell_bio_occupancy_bits"))
	for sample in 20:
		var result: Dictionary = ext.run_vision_research_pass({
			"player_slot": 0, "remote_observation": true,
			"country_slots": owners, "visible": visible,
			"explored": explored, "fog_k": fog,
			"bio_occupancy_bits": occupancy_snapshot,
		})
		if not bool(result.get("ok", false)): return result
		visible = result.physical_visible; explored = result.explored_arr; fog = result.fog_k_arr
		if sample >= 3: vision_times.append(float(result.elapsed_ms))
	return {
		"ok": true, "cells": N,
		"bio_normal_median_ms": _percentile(bio_normal, 0.50),
		"bio_normal_p95_ms": _percentile(bio_normal, 0.95),
		"bio_diffusion_median_ms": _percentile(bio_diffusion, 0.50),
		"bio_diffusion_p95_ms": _percentile(bio_diffusion, 0.95),
		"vision_median_ms": _percentile(vision_times, 0.50),
		"vision_p95_ms": _percentile(vision_times, 0.95),
	}


func _neighbors() -> PackedInt32Array:
	var out := PackedInt32Array(); out.resize(N * 6); out.fill(-1)
	for y in HEIGHT:
		for x in WIDTH:
			var cell := y * WIDTH + x
			var left := (x - 1 + WIDTH) % WIDTH
			var right := (x + 1) % WIDTH
			out[cell * 6] = y * WIDTH + left
			out[cell * 6 + 1] = y * WIDTH + right
			if y > 0:
				out[cell * 6 + 2] = (y - 1) * WIDTH + x
				out[cell * 6 + 3] = (y - 1) * WIDTH + (right if (y & 1) == 0 else left)
			if y + 1 < HEIGHT:
				out[cell * 6 + 4] = (y + 1) * WIDTH + x
				out[cell * 6 + 5] = (y + 1) * WIDTH + (right if (y & 1) == 0 else left)
	return out


func _write_f32(ext, name: StringName, values: PackedFloat32Array) -> void:
	var slot: int = int(ext.register_component(name, 0, 1, false)); ext.write_f32_range(slot, 0, values)


func _write_i32(ext, name: StringName, values: PackedInt32Array) -> void:
	var slot: int = int(ext.register_component(name, 1, 1, false)); ext.write_i32_range(slot, 0, values)


func _write_u8(ext, name: StringName, values: PackedByteArray) -> void:
	var slot: int = int(ext.register_component(name, 2, 1, false)); ext.write_u8_range(slot, 0, values)


func _percentile(values: Array[float], p: float) -> float:
	values.sort()
	if values.is_empty(): return 0.0
	return values[clampi(ceili(p * values.size()) - 1, 0, values.size() - 1)]
