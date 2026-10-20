extends SceneTree

const FILES := [
	"res://../../tmp/tile_data_record_20260731_215141.csv",
	"res://../../tmp/tile_data_record_20260731_225109.csv",
	"res://../../tmp/tile_data_record_20260731_225758.csv",
]

func _init() -> void:
	var failures := 0
	for path in FILES:
		var stats := _audit(path)
		if stats.is_empty():
			failures += 1
			continue
		print("[csv-audit] %s rows=%d cells=%d severe=%d base_terrain_drift=%d base_vegetation_drift=%d" % [
			path, int(stats.rows), int(stats.cells), int(stats.severe),
			int(stats.base_terrain_drift), int(stats.base_vegetation_drift)])
		for pair in stats.severe_pairs:
			print("  severe pair terrain=%d vegetation=%d count=%d cells=%s" % [
				int(pair.terrain), int(pair.vegetation), int(pair.count), str(pair.cells)])
		if int(stats.severe) != 0:
			failures += 1
	print("[csv-audit] files=%d failures=%d" % [FILES.size(), failures])
	quit(1 if failures != 0 else 0)


func _audit(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("cannot open %s" % path)
		return {}
	var header: PackedStringArray = file.get_csv_line()
	var columns := {}
	for i in range(header.size()):
		columns[String(header[i])] = i
	for required in ["cell_index", "terrain_arr", "vegetation_arr", "base_terrain_arr", "base_vegetation_arr"]:
		if not columns.has(required):
			push_error("%s missing %s" % [path, required])
			return {}
	var rows := 0
	var cells := {}
	var severe := 0
	var base_terrain_drift := 0
	var base_vegetation_drift := 0
	var pair_counts := {}
	var pair_cells := {}
	while not file.eof_reached():
		var fields: PackedStringArray = file.get_csv_line()
		if fields.is_empty() or fields.size() < header.size():
			continue
		rows += 1
		var cell := int(fields[int(columns["cell_index"])])
		cells[cell] = true
		var terrain := int(fields[int(columns["terrain_arr"])])
		var vegetation := int(fields[int(columns["vegetation_arr"])])
		var base_terrain := int(fields[int(columns["base_terrain_arr"])])
		var base_vegetation := int(fields[int(columns["base_vegetation_arr"])])
		if terrain != base_terrain:
			base_terrain_drift += 1
		if vegetation != base_vegetation:
			base_vegetation_drift += 1
		if VegetationType.needs_biome_reconciliation(terrain, vegetation):
			severe += 1
			var key := "%d|%d" % [terrain, vegetation]
			pair_counts[key] = int(pair_counts.get(key, 0)) + 1
			var sample: Array = pair_cells.get(key, [])
			if sample.size() < 8:
				sample.append(cell)
			pair_cells[key] = sample
	var severe_pairs: Array = []
	for key in pair_counts:
		var parts := String(key).split("|")
		severe_pairs.append({
			"terrain": int(parts[0]),
			"vegetation": int(parts[1]),
			"count": int(pair_counts[key]),
			"cells": pair_cells[key],
		})
	severe_pairs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.count) > int(b.count))
	return {
		"rows": rows,
		"cells": cells.size(),
		"severe": severe,
		"base_terrain_drift": base_terrain_drift,
		"base_vegetation_drift": base_vegetation_drift,
		"severe_pairs": severe_pairs,
	}
