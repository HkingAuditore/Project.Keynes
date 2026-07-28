extends SceneTree

# Headless:
#   godot --headless --path . --script res://tests/terrain_index_edge_bake_test.gd

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("=== terrain index edge bake: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect(false, "DCWorldExt is available")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect(ext != null and ext.has_method("run_bake_terrain_index_pass"),
		"terrain-index pass is exported")
	if ext == null:
		return

	var knobs := _base_knobs()
	var first: Dictionary = ext.call("run_bake_terrain_index_pass", knobs)
	var second: Dictionary = ext.call("run_bake_terrain_index_pass", knobs)
	_expect(not bool(first.get("fallback", true)), "synthetic bake uses native path")
	_expect(_bytes_equal(
		first.get("edge_secondary_index_buffer", PackedByteArray()),
		second.get("edge_secondary_index_buffer", PackedByteArray())),
		"same seed produces byte-identical secondary indices")
	_expect(_bytes_equal(
		first.get("edge_distance_buffer", PackedByteArray()),
		second.get("edge_distance_buffer", PackedByteArray())),
		"same seed produces byte-identical edge distances")
	_validate_primary_and_csr(first, knobs)
	_validate_edge_domains(first, knobs)
	_validate_same_biome_edges(ext, knobs)
	_validate_cross_domain_edges(ext, knobs)

	var invalid: Dictionary = ext.call("run_bake_terrain_index_pass", {"width": 0, "height": 4})
	_expect(bool(invalid.get("fallback", false)), "invalid dimensions fail explicitly")


func _base_knobs() -> Dictionary:
	return {
		"width": 64,
		"height": 36,
		"map_width": 3,
		"map_height": 3,
		"n_cells": 9,
		"origin_x": -15.0,
		"origin_y": -10.0,
		"size_x": 77.942286,
		"size_y": 65.0,
		"hex_size": 15.0,
		"wrap_period_x": 77.942286,
		"seed": 90421,
		"sea_level": 0.50,
		"cell_elevation": PackedFloat32Array([
			0.62, 0.66, 0.70,
			0.58, 0.72, 0.64,
			0.60, 0.68, 0.74,
		]),
		"cell_moisture": PackedFloat32Array([
			0.20, 0.35, 0.55,
			0.42, 0.65, 0.75,
			0.30, 0.48, 0.82,
		]),
		"cell_terrain": PackedByteArray([
			2, 3, 4,
			5, 6, 7,
			10, 12, 25,
		]),
		"cell_vegetation": PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8, 9]),
		"cell_cover": PackedByteArray([0, 1, 2, 3, 4, 5, 6, 7, 8]),
		"offset_to_index": PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7, 8]),
	}


func _validate_primary_and_csr(report: Dictionary, knobs: Dictionary) -> void:
	var p2c: PackedInt32Array = report.get("pixel_to_cell_index", PackedInt32Array())
	var biome: PackedByteArray = report.get("biome_buffer", PackedByteArray())
	var vegetation: PackedByteArray = report.get("vegetation_buffer", PackedByteArray())
	var cover: PackedByteArray = report.get("cover_buffer", PackedByteArray())
	var terrain_by_cell: PackedByteArray = knobs.cell_terrain
	var vegetation_by_cell: PackedByteArray = knobs.cell_vegetation
	var cover_by_cell: PackedByteArray = knobs.cell_cover
	var valid_consistent := p2c.size() == int(knobs.width) * int(knobs.height)
	var valid_count := 0
	for pixel in range(p2c.size()):
		var cid := p2c[pixel]
		if cid < 0:
			continue
		valid_count += 1
		if cid >= terrain_by_cell.size() \
				or biome[pixel] != terrain_by_cell[cid] \
				or vegetation[pixel] != vegetation_by_cell[cid] \
				or cover[pixel] != cover_by_cell[cid]:
			valid_consistent = false
			break
	_expect(valid_consistent, "biome/vegetation/cover share the hard primary cell")

	var first: PackedInt32Array = report.get("cell_first_px", PackedInt32Array())
	var counts: PackedInt32Array = report.get("cell_px_count", PackedInt32Array())
	var flat: PackedInt32Array = report.get("flat_px_indices", PackedInt32Array())
	var seen := PackedByteArray()
	seen.resize(p2c.size())
	var csr_ok := flat.size() == valid_count
	for cid in range(counts.size()):
		var start := first[cid]
		for offset in range(counts[cid]):
			var pixel := flat[start + offset]
			if pixel < 0 or pixel >= p2c.size() or seen[pixel] != 0 or p2c[pixel] != cid:
				csr_ok = false
				continue
			seen[pixel] = 1
	for pixel in range(p2c.size()):
		if (p2c[pixel] >= 0) != (seen[pixel] != 0):
			csr_ok = false
	_expect(csr_ok, "CSR covers every valid primary pixel exactly once")


func _validate_edge_domains(report: Dictionary, knobs: Dictionary) -> void:
	var p2c: PackedInt32Array = report.get("pixel_to_cell_index", PackedInt32Array())
	var secondary: PackedByteArray = report.get(
		"edge_secondary_index_buffer", PackedByteArray())
	var distance: PackedByteArray = report.get("edge_distance_buffer", PackedByteArray())
	var terrain_by_cell: PackedByteArray = knobs.cell_terrain
	var edge_ok := secondary.size() == p2c.size() * 2 and distance.size() == p2c.size()
	var found_edge := false
	for pixel in range(p2c.size()):
		var sid := int(secondary[pixel * 2]) + int(secondary[pixel * 2 + 1]) * 256
		if sid >= 65535:
			if distance[pixel] != 255:
				edge_ok = false
			continue
		found_edge = true
		var pid := p2c[pixel]
		if pid < 0 or sid < 0 or sid >= terrain_by_cell.size() or sid == pid:
			edge_ok = false
			continue
	_expect(edge_ok, "secondary index uses valid neighbors and sentinel distance")
	_expect(found_edge, "synthetic map produces a non-empty edge band")


func _validate_same_biome_edges(ext: Object, base_knobs: Dictionary) -> void:
	var knobs: Dictionary = base_knobs.duplicate(true)
	knobs["cell_terrain"] = PackedByteArray([
		2, 2, 2,
		2, 2, 2,
		2, 2, 2,
	])
	var report: Dictionary = ext.call("run_bake_terrain_index_pass", knobs)
	var secondary: PackedByteArray = report.get(
		"edge_secondary_index_buffer", PackedByteArray())
	var found_same_biome_edge := false
	for pixel in range(secondary.size() / 2):
		var sid := int(secondary[pixel * 2]) + int(secondary[pixel * 2 + 1]) * 256
		if sid < 65535:
			found_same_biome_edge = true
			break
	_expect(found_same_biome_edge, "same-biome cell boundaries also emit visual edge data")


func _validate_cross_domain_edges(ext: Object, base_knobs: Dictionary) -> void:
	var knobs: Dictionary = base_knobs.duplicate(true)
	knobs["cell_terrain"] = PackedByteArray([
		0, 2, 0,
		2, 0, 2,
		0, 2, 0,
	])
	var report: Dictionary = ext.call("run_bake_terrain_index_pass", knobs)
	var primary: PackedInt32Array = report.get("pixel_to_cell_index", PackedInt32Array())
	var secondary: PackedByteArray = report.get(
		"edge_secondary_index_buffer", PackedByteArray())
	var terrain_by_cell: PackedByteArray = knobs.cell_terrain
	var found_cross_domain := false
	for pixel in range(primary.size()):
		var sid := int(secondary[pixel * 2]) + int(secondary[pixel * 2 + 1]) * 256
		var pid := primary[pixel]
		if pid < 0 or sid >= terrain_by_cell.size():
			continue
		var primary_water := terrain_by_cell[pid] in [0, 1, 18, 19, 20, 21]
		var secondary_water := terrain_by_cell[sid] in [0, 1, 18, 19, 20, 21]
		if primary_water != secondary_water:
			found_cross_domain = true
			break
	_expect(found_cross_domain,
		"shared edge field includes cross-domain neighbors for fog/weather consumers")


func _bytes_equal(a: PackedByteArray, b: PackedByteArray) -> bool:
	return a == b


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
