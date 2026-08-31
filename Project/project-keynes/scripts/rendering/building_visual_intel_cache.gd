class_name BuildingVisualIntelCache
extends RefCounted

## Player-owned, last-seen building intelligence. Native economy/technology
## remain authoritative; this cache is the only source the renderer may read.

var _cell_to_row := PackedInt32Array()
var _rows: Array[Dictionary] = []
var _free_rows := PackedInt32Array()
var _row_generation := PackedInt32Array()
var _core_buckets := PackedByteArray()
var _revision: int = 0


func configure(cell_count: int) -> void:
	_cell_to_row.resize(maxi(0, cell_count))
	_cell_to_row.fill(-1)
	_rows.clear()
	_free_rows.clear()
	_row_generation.resize(maxi(0, cell_count))
	_row_generation.fill(0)
	_core_buckets.resize(maxi(0, cell_count))
	_core_buckets.fill(0)
	_revision = 0


func cell_count() -> int:
	return _cell_to_row.size()


func revision() -> int:
	return _revision


func has_cell(cell_idx: int) -> bool:
	return cell_idx >= 0 and cell_idx < _cell_to_row.size() \
		and _cell_to_row[cell_idx] >= 0


func row_for_cell(cell_idx: int) -> Dictionary:
	if not has_cell(cell_idx):
		return {}
	return _rows[_cell_to_row[cell_idx]]


func known_cells() -> PackedInt32Array:
	var out := PackedInt32Array()
	for cell in _cell_to_row.size():
		if _cell_to_row[cell] >= 0:
			out.append(cell)
	return out


func settlement_core_buckets() -> PackedByteArray:
	return _core_buckets


func refresh_visible_cells(world_ext: Object, requested_cells: PackedInt32Array,
		visible: PackedByteArray) -> Dictionary:
	if world_ext == null or not world_ext.has_method("get_building_visual_snapshot"):
		return {"ok": false, "reason": "building_visual_native_api_unavailable",
			"changed_cells": PackedInt32Array()}
	var filtered := PackedInt32Array()
	var seen := {}
	for raw_cell in requested_cells:
		var cell := int(raw_cell)
		if cell < 0 or cell >= _cell_to_row.size() or seen.has(cell):
			continue
		if cell >= visible.size() or visible[cell] == 0:
			continue
		seen[cell] = true
		filtered.append(cell)
	filtered.sort()
	if filtered.is_empty():
		return {"ok": true, "changed_cells": PackedInt32Array(),
			"building_generation": 0, "country_era_generation": 0}
	var snapshot: Dictionary = world_ext.get_building_visual_snapshot(filtered)
	if not bool(snapshot.get("ok", false)):
		return snapshot
	return apply_snapshot(snapshot)


func apply_snapshot(snapshot: Dictionary) -> Dictionary:
	var cells := PackedInt32Array(snapshot.get("cell_indices", PackedInt32Array()))
	var countries := PackedInt32Array(snapshot.get("country_slots", PackedInt32Array()))
	var eras := PackedInt32Array(snapshot.get("era_indices", PackedInt32Array()))
	var offsets := PackedInt32Array(snapshot.get("type_offsets", PackedInt32Array()))
	var types := PackedInt32Array(snapshot.get("type_indices", PackedInt32Array()))
	var counts := PackedInt64Array(snapshot.get("counts", PackedInt64Array()))
	if countries.size() != cells.size() or eras.size() != cells.size() \
			or offsets.size() != cells.size() + 1 or offsets.is_empty() \
			or offsets[0] != 0 or offsets[-1] != types.size() \
			or types.size() != counts.size():
		return {"ok": false, "reason": "building_visual_snapshot_shape_invalid"}
	# Validate the complete CSR before touching last-seen intelligence. A corrupt
	# PKFG or stale bridge result must never leave a partially restored cache.
	var previous_cell := -1
	for i in cells.size():
		var cell := cells[i]
		if cell <= previous_cell or cell < 0 or cell >= _cell_to_row.size() \
				or countries[i] < -1 or eras[i] < -1 or eras[i] > 10 \
				or offsets[i] < 0 or offsets[i] > offsets[i + 1]:
			return {"ok": false, "reason": "building_visual_snapshot_csr_invalid"}
		previous_cell = cell
		var previous_type := -1
		for edge in range(offsets[i], offsets[i + 1]):
			if types[edge] < 0 or types[edge] <= previous_type or counts[edge] <= 0:
				return {"ok": false, "reason": "building_visual_snapshot_value_invalid"}
			previous_type = types[edge]
	var changed := PackedInt32Array()
	for i in cells.size():
		var cell := cells[i]
		var row_types := PackedInt32Array()
		var row_counts := PackedInt64Array()
		for edge in range(offsets[i], offsets[i + 1]):
			row_types.append(types[edge])
			row_counts.append(counts[edge])
		var old_signature := int(row_for_cell(cell).get("visual_signature", -1))
		# An unknown era is still valid intelligence.  The technology runtime is
		# authoritative for era discovery; until its first milestone is complete
		# the renderer uses the neutral/unknown style while preserving the known
		# building footprint and counts.
		if row_types.is_empty():
			_remove_cell(cell)
			if old_signature != -1:
				changed.append(cell)
			continue
		var signature := _signature(countries[i], eras[i], row_types, row_counts)
		var total := 0
		for value in row_counts:
			total += int(value)
		var density_bucket := clampi(_floor_log2(1 + total), 0, 15)
		var row := {
			"cell_idx": cell,
			"observed_country_slot": countries[i],
			"observed_era_index": eras[i],
			"type_indices": row_types,
			"counts": row_counts,
			"visual_signature": signature,
			"settlement_core_bucket": density_bucket,
			"dominant_archetype": -1,
		}
		_store_row(cell, row)
		if signature != old_signature:
			changed.append(cell)
	return {"ok": true, "changed_cells": changed,
		"building_generation": int(snapshot.get("building_generation", 0)),
		"country_era_generation": int(snapshot.get("country_era_generation", 0))}


func to_pkfg_fields() -> Dictionary:
	var cells := known_cells()
	var countries := PackedInt32Array()
	var eras := PackedInt32Array()
	var offsets := PackedInt32Array([0])
	var types := PackedInt32Array()
	var counts := PackedInt64Array()
	for cell in cells:
		var row := row_for_cell(cell)
		countries.append(int(row.observed_country_slot))
		eras.append(int(row.observed_era_index))
		types.append_array(PackedInt32Array(row.type_indices))
		counts.append_array(PackedInt64Array(row.counts))
		offsets.append(types.size())
	return {
		"building_intel_cells": cells,
		"building_intel_country_slots": countries,
		"building_intel_era_indices": eras,
		"building_intel_type_offsets": offsets,
		"building_intel_type_indices": types,
		"building_intel_counts": counts,
	}


func restore_pkfg(payload: Dictionary, type_count: int = -1) -> Dictionary:
	var version := int(payload.get("version", 1))
	if version <= 1:
		configure(_cell_to_row.size())
		return {"ok": true, "migrated_from": 1, "rows": 0}
	if version != 2:
		return {"ok": false, "reason": "pkfg_version_unsupported"}
	var snapshot := {
		"cell_indices": payload.get("building_intel_cells", PackedInt32Array()),
		"country_slots": payload.get("building_intel_country_slots", PackedInt32Array()),
		"era_indices": payload.get("building_intel_era_indices", PackedInt32Array()),
		"type_offsets": payload.get("building_intel_type_offsets", PackedInt32Array([0])),
		"type_indices": payload.get("building_intel_type_indices", PackedInt32Array()),
		"counts": payload.get("building_intel_counts", PackedInt64Array()),
	}
	var types := PackedInt32Array(snapshot.type_indices)
	if type_count >= 0:
		for type_idx in types:
			if type_idx < 0 or type_idx >= type_count:
				return {"ok": false, "reason": "pkfg_building_type_out_of_range"}
	var staged := BuildingVisualIntelCache.new()
	staged.configure(_cell_to_row.size())
	var applied := staged.apply_snapshot(snapshot)
	if not bool(applied.get("ok", false)):
		return {"ok": false, "reason": String(applied.get("reason", "pkfg_restore_failed"))}
	_cell_to_row = staged._cell_to_row
	_rows = staged._rows
	_free_rows = staged._free_rows
	_row_generation = staged._row_generation
	_core_buckets = staged._core_buckets
	_revision = staged._revision
	return {"ok": true, "rows": known_cells().size()}


func _store_row(cell: int, row: Dictionary) -> void:
	var row_idx := _cell_to_row[cell]
	if row_idx < 0:
		if not _free_rows.is_empty():
			row_idx = _free_rows[-1]
			_free_rows.resize(_free_rows.size() - 1)
		else:
			row_idx = _rows.size()
			_rows.append({})
		_cell_to_row[cell] = row_idx
	_rows[row_idx] = row
	_core_buckets[cell] = clampi(int(row.get("settlement_core_bucket", 0)), 0, 15)
	_revision += 1
	_row_generation[cell] = _revision


func _remove_cell(cell: int) -> void:
	if not has_cell(cell):
		return
	var row_idx := _cell_to_row[cell]
	_rows[row_idx] = {}
	_free_rows.append(row_idx)
	_cell_to_row[cell] = -1
	_core_buckets[cell] = 0
	_revision += 1
	_row_generation[cell] = _revision


static func _floor_log2(value: int) -> int:
	var result := -1
	var remaining := maxi(0, value)
	while remaining > 0:
		remaining >>= 1
		result += 1
	return maxi(0, result)


static func _signature(country: int, era: int, types: PackedInt32Array,
		counts: PackedInt64Array) -> int:
	# 31-bit FNV-style hash avoids signed overflow differences between targets.
	var value := 0x45D9F3B
	value = ((value ^ country) * 16777619) & 0x7FFFFFFF
	value = ((value ^ era) * 16777619) & 0x7FFFFFFF
	for i in types.size():
		value = ((value ^ types[i]) * 16777619) & 0x7FFFFFFF
		# Geometry reacts to logarithmic scale buckets. Exact economic counts remain
		# in the row for the inspector, but do not rebuild a chunk inside one bucket.
		value = ((value ^ _floor_log2(1 + int(counts[i]))) * 16777619) & 0x7FFFFFFF
	return value
