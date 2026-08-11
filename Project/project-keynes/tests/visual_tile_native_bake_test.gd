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
		"height": 20 * 20 * 4,
		"terrain_normal": 20 * 20 * 2,
		"map_index": 20 * 20 * 4,
		"water_depth": 20 * 20,
		"terrain_detail": 20 * 20,
		"edge_neighbor": 20 * 20 * 2,
		"edge_distance": 20 * 20,
	}
	for field in expected:
		var data: PackedByteArray = first.get(field, PackedByteArray())
		if data.size() != int(expected[field]):
			push_error("visual_tile_native_bake_test: %s size=%d expected=%d (height-flow-pack: rebuild gdext if height still N*2)" % [
				field, data.size(), int(expected[field])])
			quit(1)
			return
	if first.has("flow") and PackedByteArray(first.get("flow")).size() > 0:
		push_error("visual_tile_native_bake_test: separate flow payload still present; expected packed into height.B")
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
	if not _test_normal_resolution_invariance(ext):
		quit(1)
		return
	if not _test_edge_distance_resolution_invariance(ext):
		quit(1)
		return
	if not _test_canal_height_alpha_and_partial_payload(ext):
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


func _test_normal_resolution_invariance(ext: Object) -> bool:
	var low := _make_knobs()
	low["wrap_period_x"] = 0.0
	low["origin_x"] = 0.0
	low["origin_y"] = 0.0
	low["size_x"] = 40.0
	low["size_y"] = 30.0
	low["baseline_origin_x"] = 0.0
	low["baseline_origin_y"] = 0.0
	low["baseline_size_x"] = 40.0
	low["baseline_size_y"] = 30.0
	low["normal_reference_radius_px"] = 4
	low.erase("normal_radius_px")
	var baseline: PackedFloat32Array = low["baseline_height_buffer"]
	var baseline_width: int = int(low["baseline_width"])
	var baseline_height: int = int(low["baseline_height"])
	for y in range(baseline_height):
		for x in range(baseline_width):
			baseline[y * baseline_width + x] = 0.66 + 0.28 * \
				float(x) / float(baseline_width - 1)
	low["baseline_height_buffer"] = baseline
	var high: Dictionary = low.duplicate(true)
	high["width"] = int(low["width"]) * 2
	high["height"] = int(low["height"]) * 2

	var low_result: Dictionary = ext.run_bake_visual_tile_layer_pass(low)
	var high_result: Dictionary = ext.run_bake_visual_tile_layer_pass(high)
	if bool(low_result.get("fallback", true)) or bool(high_result.get("fallback", true)):
		push_error("visual_tile_native_bake_test: normal invariance bake failed")
		return false
	var low_nx := _average_normal_x(
		low_result, int(low["width"]), int(low["height"]))
	var high_nx := _average_normal_x(
		high_result, int(high["width"]), int(high["height"]))
	if absf(low_nx - high_nx) > 2.5 / 255.0:
		push_error("visual_tile_native_bake_test: normal changed with resolution low=%.6f high=%.6f" % [
			low_nx, high_nx])
		return false
	if int(high_result.get("normal_radius_x_px", 0)) \
			<= int(low_result.get("normal_radius_x_px", 0)):
		push_error("visual_tile_native_bake_test: normal world radius was not preserved")
		return false
	return true


func _average_normal_x(result: Dictionary, width: int, height: int) -> float:
	var data: PackedByteArray = result.get("terrain_normal", PackedByteArray())
	var x0: int = int(width / 4)
	var x1: int = width - x0
	var y0: int = int(height / 4)
	var y1: int = height - y0
	var total := 0.0
	var count := 0
	for y in range(y0, y1):
		for x in range(x0, x1):
			total += float(data[(y * width + x) * 2]) / 255.0 * 2.0 - 1.0
			count += 1
	return total / float(maxi(count, 1))


func _test_edge_distance_resolution_invariance(ext: Object) -> bool:
	var low := _make_knobs()
	low["wrap_period_x"] = 0.0
	low["origin_x"] = 0.0
	low["origin_y"] = 0.0
	low["size_x"] = 40.0
	low["size_y"] = 30.0
	var high: Dictionary = low.duplicate(true)
	# An odd scale factor makes every low-resolution texel center coincide with
	# one high-resolution texel center, so this compares identical world points.
	high["width"] = int(low["width"]) * 3
	high["height"] = int(low["height"]) * 3

	var low_result: Dictionary = ext.run_bake_visual_tile_layer_pass(low)
	var high_result: Dictionary = ext.run_bake_visual_tile_layer_pass(high)
	if bool(low_result.get("fallback", true)) or bool(high_result.get("fallback", true)):
		push_error("visual_tile_native_bake_test: edge-distance invariance bake failed")
		return false
	if String(low_result.get("edge_distance_units", "")) != "normalized_hex_center_gap" \
			or absf(float(low_result.get("edge_distance_saturate_hex", 0.0)) - 0.90) > 1e-6:
		push_error("visual_tile_native_bake_test: edge-distance world-unit contract missing")
		return false

	var low_distance: PackedByteArray = low_result.get("edge_distance", PackedByteArray())
	var high_distance: PackedByteArray = high_result.get("edge_distance", PackedByteArray())
	var low_neighbor: PackedByteArray = low_result.get("edge_neighbor", PackedByteArray())
	var high_neighbor: PackedByteArray = high_result.get("edge_neighbor", PackedByteArray())
	var low_width: int = int(low["width"])
	var low_height: int = int(low["height"])
	var high_width: int = int(high["width"])
	for y in range(low_height):
		for x in range(low_width):
			var low_index := y * low_width + x
			var high_index := (y * 3 + 1) * high_width + (x * 3 + 1)
			if absi(int(low_distance[low_index]) - int(high_distance[high_index])) > 1:
				push_error("visual_tile_native_bake_test: edge distance changed with resolution")
				return false
			for channel in range(2):
				if low_neighbor[low_index * 2 + channel] != high_neighbor[high_index * 2 + channel]:
					push_error("visual_tile_native_bake_test: edge neighbor changed with resolution")
					return false
	return true


func _test_canal_height_alpha_and_partial_payload(ext: Object) -> bool:
	var plain_knobs := _make_knobs()
	var canal_knobs: Dictionary = plain_knobs.duplicate(true)
	var mask: PackedByteArray = canal_knobs["cell_canal_edge_mask"]
	mask[4] = 1 << 0
	mask[5] = 1 << 3
	canal_knobs["cell_canal_edge_mask"] = mask
	canal_knobs["canal_refresh_only"] = true
	var plain: Dictionary = ext.run_bake_visual_tile_layer_pass(plain_knobs)
	var canal: Dictionary = ext.run_bake_visual_tile_layer_pass(canal_knobs)
	if bool(plain.get("fallback", true)) or bool(canal.get("fallback", true)):
		push_error("visual_tile_native_bake_test: canal bake fallback")
		return false
	if canal.has("map_index") or canal.has("water_depth") \
			or canal.has("terrain_detail") or canal.has("edge_neighbor"):
		push_error("visual_tile_native_bake_test: canal refresh uploaded non-height fields")
		return false
	var plain_height: PackedByteArray = plain.get("height", PackedByteArray())
	var canal_height: PackedByteArray = canal.get("height", PackedByteArray())
	var canal_pixels := 0
	var carved_pixels := 0
	for pixel in range(int(mini(plain_height.size(), canal_height.size()) / 4)):
		var offset := pixel * 4
		if canal_height[offset + 3] > 0:
			canal_pixels += 1
		var before := (int(plain_height[offset]) << 8) | int(plain_height[offset + 1])
		var after := (int(canal_height[offset]) << 8) | int(canal_height[offset + 1])
		if after < before:
			carved_pixels += 1
	if canal_pixels <= 0 or carved_pixels <= 0:
		push_error("visual_tile_native_bake_test: canal SDF/carve absent pixels=%d carved=%d" % [
			canal_pixels, carved_pixels])
		return false
	return true


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
	var canal_mask := PackedByteArray()
	var cell_pos_x := PackedFloat32Array()
	var cell_pos_y := PackedFloat32Array()
	var neighbors := PackedInt32Array()
	elevation.resize(n_cells)
	moisture.resize(n_cells)
	terrain.resize(n_cells)
	vegetation.resize(n_cells)
	cover.resize(n_cells)
	water_depth.resize(n_cells)
	landform.resize(n_cells)
	offset_to_index.resize(n_cells)
	canal_mask.resize(n_cells)
	cell_pos_x.resize(n_cells)
	cell_pos_y.resize(n_cells)
	neighbors.resize(n_cells * 6)
	neighbors.fill(-1)
	for i in range(n_cells):
		elevation[i] = 0.68 + float(i % map_width) * 0.025
		moisture[i] = 0.45
		terrain[i] = 2
		vegetation[i] = 0
		cover[i] = 0
		water_depth[i] = 0.0
		landform[i] = 0
		offset_to_index[i] = i
		var row: int = floori(float(i) / float(map_width))
		var col: int = i % map_width
		var q: int = col - int((row - (row & 1)) / 2)
		cell_pos_x[i] = 1.7320508 * (float(q) + float(row) * 0.5)
		cell_pos_y[i] = 1.5 * float(row)
	neighbors[4 * 6] = 5
	neighbors[5 * 6 + 3] = 4
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
		"cell_canal_edge_mask": canal_mask,
		"cell_pos_x": cell_pos_x,
		"cell_pos_y": cell_pos_y,
		"neighbor_indices": neighbors,
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
