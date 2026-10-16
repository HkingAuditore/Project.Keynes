class_name ResourceVisualObservations
extends RefCounted

const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")
const Registry = preload("res://scripts/data/resource_profile_registry.gd")
var rows: Dictionary = {}
var revision := 0
var cell_count := 0
var styles: Array[Dictionary] = []

func configure(count: int) -> void:
	cell_count = count
	styles = Catalog.entries()
	rows.clear()
	revision += 1

# Called only with a published MapData and a currently visible cell. Bands are
# presentation quantities; they never change reserves or the occupancy bitset.
func observe(map: MapData, cell: int, allowed: PackedByteArray, gm: bool = false) -> bool:
	if cell < 0 or cell >= cell_count or allowed.size() != styles.size():
		return false
	if not gm and (cell >= map.visible_arr.size() or map.visible_arr[cell] == 0):
		return false
	var previous: Dictionary = rows.get(cell, {})
	var old: PackedByteArray = previous.get("bands", PackedByteArray())
	var bands := PackedByteArray()
	bands.resize(styles.size())
	var occupancy := int(map.bio_occupancy_bits_arr[cell]) if cell < map.bio_occupancy_bits_arr.size() else 0
	var habitat := int(map.resource_habitat_mask_arr[cell]) if cell < map.resource_habitat_mask_arr.size() else 0
	for i in styles.size():
		if allowed[i] == 0:
			continue
		var e := styles[i]
		if int(e.bit) >= 0:
			bands[i] = 2 if (occupancy & (1 << int(e.bit))) != 0 else 0
		elif e.profile != null and (int(e.habitat_mask) == 0 or (habitat & int(e.habitat_mask)) != 0):
			# Schema lookup and profile normalization are cold catalog work. Never
			# rescan the component schema for each visible cell and resource.
			var values = map.get(e.reserve_field)
			var reserve := float(values[cell]) if values != null and cell < values.size() else 0.0
			var ratio := maxf(0.0, reserve) / maxf(0.0001, float(e.reference))
			var old_band := int(old[i]) if i < old.size() else 0
			bands[i] = abundance_band(ratio, old_band)
	var climate := Color(_value(map.temp_arr, cell, 0.5), _value(map.moisture_arr, cell, 0.5),
		_value(map.snow_cover_arr, cell, 0.0), _value(map.vegetation_vitality_arr, cell, 1.0))
	var changed := old != bands
	rows[cell] = {"bands": bands, "climate": climate}
	if changed:
		revision += 1
	return changed

static func abundance_band(ratio: float, previous: int = 0) -> int:
	if ratio <= 0.000001:
		return 0
	var band := 1
	for boundary in [0.25, 0.70, 1.50]:
		if ratio >= float(boundary):
			band += 1
	if previous > 0 and previous != band:
		var limits := [0.0, 0.25, 0.70, 1.50, INF]
		if ratio >= float(limits[previous - 1]) * 0.9 and ratio <= float(limits[previous]) * 1.1:
			return previous
	return band

func to_fields() -> Dictionary:
	var cells := PackedInt32Array(rows.keys())
	cells.sort()
	var bands := PackedByteArray()
	var climates := PackedColorArray()
	for cell in cells:
		bands.append_array(rows[cell].bands)
		climates.append(rows[cell].climate)
	var ids := PackedStringArray()
	for e in styles:
		ids.append(e.id)
	return {"resource_intel_cells": cells, "resource_intel_style_ids": ids,
		"resource_intel_bands": bands, "resource_intel_climates": climates}

# Validate everything before replacing memory. Stable IDs make style ordering
# independent of the compiled signal/ResourceProfile index order.
func restore(payload: Dictionary) -> Dictionary:
	if int(payload.get("version", 1)) < 4:
		rows.clear()
		revision += 1
		return {"ok": true}
	for key in ["resource_intel_cells", "resource_intel_style_ids", "resource_intel_bands", "resource_intel_climates"]:
		if not payload.has(key):
			return {"ok": false, "reason": "pkfg_resource_intel_missing"}
	if not payload.resource_intel_cells is PackedInt32Array \
			or not payload.resource_intel_style_ids is PackedStringArray \
			or not payload.resource_intel_bands is PackedByteArray \
			or not payload.resource_intel_climates is PackedColorArray:
		return {"ok": false, "reason": "pkfg_resource_intel_types"}
	var cells := PackedInt32Array(payload.resource_intel_cells)
	var ids := PackedStringArray(payload.resource_intel_style_ids)
	var bands := PackedByteArray(payload.resource_intel_bands)
	var climates := PackedColorArray(payload.resource_intel_climates)
	if ids.size() != styles.size() or bands.size() != cells.size() * ids.size() or climates.size() != cells.size():
		return {"ok": false, "reason": "pkfg_resource_intel_shape"}
	var remap := PackedInt32Array()
	var seen := {}
	for e in styles:
		var index := ids.find(e.id)
		if index < 0 or seen.has(index):
			return {"ok": false, "reason": "pkfg_resource_intel_styles"}
		seen[index] = true
		remap.append(index)
	var staged := {}
	var last := -1
	for i in cells.size():
		var cell := cells[i]
		if cell <= last or cell < 0 or cell >= cell_count:
			return {"ok": false, "reason": "pkfg_resource_intel_cells"}
		last = cell
		var climate := climates[i]
		for value in [climate.r, climate.g, climate.b, climate.a]:
			if not is_finite(value) or value < 0.0 or value > 1.0:
				return {"ok": false, "reason": "pkfg_resource_intel_climate"}
		var row_bands := PackedByteArray()
		for index in remap:
			var band := bands[i * ids.size() + index]
			if band > 4:
				return {"ok": false, "reason": "pkfg_resource_intel_band"}
			row_bands.append(band)
		staged[cell] = {"bands": row_bands, "climate": climate}
	rows = staged
	revision += 1
	return {"ok": true}

static func _value(values: PackedFloat32Array, cell: int, fallback: float) -> float:
	return clampf(values[cell], 0.0, 1.0) if cell < values.size() else fallback
