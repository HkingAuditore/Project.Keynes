class_name ResourceVisualObservations
extends RefCounted

const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")
const Registry = preload("res://scripts/data/resource_profile_registry.gd")
const ABUNDANCE_BOUNDARIES := [0.25, 0.70, 1.50]
const ABUNDANCE_LIMITS := [0.0, 0.25, 0.70, 1.50, INF]
var rows: Dictionary = {}
var revision := 0
var cell_count := 0
var styles: Array[Dictionary] = []
# Catalog-only inputs, rebuilt with configure. Live reserve arrays are never
# retained here: each observation reads the currently published MapData.
var _occupancy_masks := PackedInt64Array()
var _habitat_masks := PackedInt64Array()
var _has_profile := PackedByteArray()
var _reserve_fields: Array[StringName] = []
var _references := PackedFloat64Array()

func configure(count: int) -> void:
	cell_count = count
	styles = Catalog.entries()
	_occupancy_masks.clear()
	_habitat_masks.clear()
	_has_profile.clear()
	_reserve_fields.clear()
	_references.clear()
	for entry in styles:
		var bit := int(entry.bit)
		_occupancy_masks.append((1 << bit) if bit >= 0 else 0)
		_habitat_masks.append(int(entry.get("habitat_mask", 0)))
		_has_profile.append(1 if entry.profile != null else 0)
		_reserve_fields.append(StringName(entry.get("reserve_field", "")))
		_references.append(maxf(0.0001, float(entry.get("reference", 1.0))))
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
		var occupancy_mask := _occupancy_masks[i]
		var habitat_mask := _habitat_masks[i]
		if occupancy_mask != 0:
			bands[i] = 2 if (occupancy & occupancy_mask) != 0 else 0
		elif _has_profile[i] != 0 and (habitat_mask == 0 or (habitat & habitat_mask) != 0):
			var published = map.get(_reserve_fields[i])
			var reserve := 0.0
			if published != null:
				var values: PackedFloat32Array = published
				if cell < values.size():
					reserve = float(values[cell])
			var ratio := maxf(0.0, reserve) / _references[i]
			var old_band := int(old[i]) if i < old.size() else 0
			bands[i] = abundance_band(ratio, old_band)
	var changed := old != bands
	if changed or previous.is_empty():
		rows[cell] = {"bands": bands, "climate": _climate(map, cell)}
	else:
		previous["climate"] = _climate(map, cell)
	if changed:
		revision += 1
	return changed

## Climate publication does not rebuild the 51-entry abundance row or geometry.
## Unknown visible cells still need their first full observation.
func observe_climate(map: MapData, cell: int, gm: bool = false) -> bool:
	if cell < 0 or cell >= cell_count or not rows.has(cell):
		return false
	if not gm and (cell >= map.visible_arr.size() or map.visible_arr[cell] == 0):
		return false
	var climate := _climate(map, cell)
	if rows[cell].climate == climate:
		return false
	rows[cell].climate = climate
	return true

static func _climate(map: MapData, cell: int) -> Color:
	return Color(_value(map.temp_arr, cell, 0.5), _value(map.moisture_arr, cell, 0.5),
		_value(map.snow_cover_arr, cell, 0.0), _value(map.vegetation_vitality_arr, cell, 1.0))

static func abundance_band(ratio: float, previous: int = 0) -> int:
	if ratio <= 0.000001:
		return 0
	var band := 1
	for boundary in ABUNDANCE_BOUNDARIES:
		if ratio >= float(boundary):
			band += 1
	if previous > 0 and previous != band:
		if ratio >= float(ABUNDANCE_LIMITS[previous - 1]) * 0.9 and ratio <= float(ABUNDANCE_LIMITS[previous]) * 1.1:
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
