extends SceneTree


func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("visual_tile_native_bake_test: SKIP (DCWorldExt unavailable)")
		quit(0)
		return
	var ext := DCWorldExt.new()
	if not ext.has_method("run_bake_visual_tile_layer_pass"):
		push_error("visual_tile_native_bake_test: visual tile method missing")
		quit(1)
		return
	var knobs := _make_knobs()
	var first: Dictionary = ext.run_bake_visual_tile_layer_pass(knobs)
	var second: Dictionary = ext.run_bake_visual_tile_layer_pass(knobs)
	if bool(first.get("fallback", true)) or bool(second.get("fallback", true)):
		push_error("visual_tile_native_bake_test: native fallback: %s / %s" % [
			first.get("reason", "?"), second.get("reason", "?")])
		quit(1)
		return
	var expected := {
		"height": 20 * 20 * 2,
		"terrain_normal": 20 * 20 * 2,
		"map_index": 20 * 20 * 4,
		"flow": 20 * 20,
		"water_depth": 20 * 20,
		"terrain_detail": 20 * 20,
		"edge_neighbor": 20 * 20 * 2,
		"edge_distance": 20 * 20,
	}
	for field in expected:
		var data: PackedByteArray = first.get(field, PackedByteArray())
		if data.size() != int(expected[field]):
			push_error("visual_tile_native_bake_test: %s size=%d expected=%d" % [
				field, data.size(), int(expected[field])])
			quit(1)
			return
	if first.get("hashes", {}) != second.get("hashes", {}):
		push_error("visual_tile_native_bake_test: deterministic hashes differ")
		quit(1)
		return
	if bool(first.get("csr_emitted", true)):
		push_error("visual_tile_native_bake_test: high-resolution CSR was emitted")
		quit(1)
		return
	if ext.has_method("run_resample_visual_horizon_layer_pass"):
		if not _test_horizon_resample(ext):
			quit(1)
			return
	else:
		print("visual_tile_native_bake_test: horizon resample SKIP (stale DLL)")
	print("visual_tile_native_bake_test: PASS %s" % JSON.stringify(first.get("hashes", {})))
	quit(0)


func _test_horizon_resample(ext: Object) -> bool:
	var source := PackedByteArray()
	source.resize(4 * 2 * 4)
	for y in range(2):
		for x in range(4):
			var offset := (y * 4 + x) * 4
			for channel in range(4):
				source[offset + channel] = x * 32 + y * 8 + channel
	var knobs := {
		"generation_id": 29,
		"layer_id": 3,
		"source_data": source,
		"source_width": 4,
		"source_height": 2,
		"source_origin_x": 0.0,
		"source_origin_y": 0.0,
		"source_size_x": 4.0,
		"source_size_y": 2.0,
		"width": 6,
		"height": 2,
		"origin_x": -1.0,
		"origin_y": 0.0,
		"size_x": 6.0,
		"size_y": 2.0,
		"wrap_period_x": 4.0,
	}
	var first: Dictionary = ext.run_resample_visual_horizon_layer_pass(knobs)
	var second: Dictionary = ext.run_resample_visual_horizon_layer_pass(knobs)
	if bool(first.get("fallback", true)) or bool(second.get("fallback", true)):
		push_error("visual_tile_native_bake_test: horizon resample fallback: %s / %s" % [
			first.get("reason", "?"), second.get("reason", "?")])
		return false
	var data: PackedByteArray = first.get("data", PackedByteArray())
	if data.size() != 6 * 2 * 4:
		push_error("visual_tile_native_bake_test: horizon resample size=%d" % data.size())
		return false
	if first.get("hash", 0) != second.get("hash", 1):
		push_error("visual_tile_native_bake_test: horizon resample hash differs")
		return false
	if int(first.get("generation_id", -1)) != 29 or int(first.get("layer_id", -1)) != 3:
		push_error("visual_tile_native_bake_test: horizon resample identity mismatch")
		return false
	# The physical row covers [-1, 5). Its two gutter samples must wrap to
	# source columns 3 and 0 respectively.
	for y in range(2):
		var first_dst := (y * 6) * 4
		var last_dst := (y * 6 + 5) * 4
		var source_last := (y * 4 + 3) * 4
		var source_first := (y * 4) * 4
		for channel in range(4):
			if data[first_dst + channel] != source[source_last + channel] \
					or data[last_dst + channel] != source[source_first + channel]:
				push_error("visual_tile_native_bake_test: horizon wrap gutter mismatch")
				return false
	return true


func _make_knobs() -> Dictionary:
	var map_width := 4
	var map_height := 3
	var n_cells := map_width * map_height
	var elevation := PackedFloat32Array()
	var moisture := PackedFloat32Array()
	var terrain := PackedByteArray()
	var vegetation := PackedByteArray()
	var cover := PackedByteArray()
	var water_depth := PackedFloat32Array()
	var landform := PackedByteArray()
	var offset_to_index := PackedInt32Array()
	elevation.resize(n_cells)
	moisture.resize(n_cells)
	terrain.resize(n_cells)
	vegetation.resize(n_cells)
	cover.resize(n_cells)
	water_depth.resize(n_cells)
	landform.resize(n_cells)
	offset_to_index.resize(n_cells)
	for i in range(n_cells):
		elevation[i] = 0.68 + float(i % map_width) * 0.025
		moisture[i] = 0.45
		terrain[i] = 2
		vegetation[i] = 0
		cover[i] = 0
		water_depth[i] = 0.0
		landform[i] = 0
		offset_to_index[i] = i
	var baseline_width := 32
	var baseline_height := 16
	var baseline := PackedFloat32Array()
	var baseline_flow := PackedFloat32Array()
	var baseline_water := PackedByteArray()
	baseline.resize(baseline_width * baseline_height)
	baseline_flow.resize(baseline.size())
	baseline_water.resize(baseline.size())
	for y in range(baseline_height):
		for x in range(baseline_width):
			var index := y * baseline_width + x
			baseline[index] = 0.68 + float(x) / float(baseline_width - 1) * 0.08
			baseline_flow[index] = 0.0
			baseline_water[index] = 0
	return {
		"generation_id": 11,
		"layer_id": 0,
		"width": 20,
		"height": 20,
		"origin_x": 0.0,
		"origin_y": 0.0,
		"size_x": 40.0,
		"size_y": 30.0,
		"map_width": map_width,
		"map_height": map_height,
		"n_cells": n_cells,
		"hex_size": 10.0,
		"seed": 12345,
		"wrap_period_x": 69.282032,
		"sea_level": 0.64,
		"cell_elevation": elevation,
		"cell_moisture": moisture,
		"cell_terrain": terrain,
		"cell_vegetation": vegetation,
		"cell_cover": cover,
		"cell_water_depth": water_depth,
		"cell_landform": landform,
		"offset_to_index": offset_to_index,
		"baseline_width": baseline_width,
		"baseline_height": baseline_height,
		"baseline_origin_x": -10.0,
		"baseline_origin_y": -10.0,
		"baseline_size_x": 90.0,
		"baseline_size_y": 50.0,
		"baseline_height_buffer": baseline,
		"baseline_flow_buffer": baseline_flow,
		"baseline_water_depth_buffer": baseline_water,
		"algorithm_halo_px": 8,
		"residual_amp": 0.0,
		"river_stroke_hex_factor": 0.035,
		"sdf_max_dist_px": 5.0,
		"shore_carve_amp": 0.06,
		"shore_carve_band": 6,
		"coast_sdf_max_dist_px": 12.0,
		"normal_radius_px": 2,
		"normal_slope_gain": 8.0,
	}
