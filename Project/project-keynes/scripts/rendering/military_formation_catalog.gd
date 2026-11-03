extends RefCounted
class_name MilitaryFormationCatalog

## Cold-path adapter between dense MilitaryCore unit ids and the authored visual
## prototype catalog. The renderer never guesses a prototype from unit_class:
## `early_armor`, `tank_corps`, and `drone_swarm` share the native mobile class
## with cavalry, but must use the armored visual rig.

const CATALOG_PATH := "res://data/military/military_visual_catalog.json"

var _catalog: Dictionary = {}
var _actions: Array = []
var _lods: Array = []
var _headcount_bands: Array = []
var _prototypes: Array = []
var _prototype_by_unit_id: Dictionary = {}
var _prototype_by_dense: PackedInt32Array = PackedInt32Array()
var _dense_unit_ids: PackedStringArray = PackedStringArray()
var _ready := false


func load_catalog(path: String = CATALOG_PATH) -> bool:
	_ready = false
	_catalog = {}
	_actions = []
	_lods = []
	_headcount_bands = []
	_prototypes = []
	_prototype_by_unit_id.clear()
	_prototype_by_dense = PackedInt32Array()
	_dense_unit_ids = PackedStringArray()
	if not FileAccess.file_exists(path):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return false
	_catalog = parsed as Dictionary
	if int(_catalog.get("schema", 0)) != 1:
		return false
	_actions = _catalog.get("actions", []) as Array
	_lods = _catalog.get("lod", []) as Array
	_headcount_bands = _catalog.get("headcount_bands", []) as Array
	_prototypes = _catalog.get("prototypes", []) as Array
	if _actions.size() != 4 or _lods.size() != 3 \
			or _headcount_bands.size() != 5 or _prototypes.size() != 4:
		return false
	for prototype_row in _prototypes.size():
		var prototype := _prototypes[prototype_row] as Dictionary
		if int(prototype.get("atlas_row", -1)) != prototype_row:
			return false
		var layouts := prototype.get("layouts", []) as Array
		if layouts.size() != 5:
			return false
		for member_count in layouts.size():
			if (layouts[member_count] as Array).size() != member_count + 1:
				return false
		for unit_value in prototype.get("available_units", []) as Array:
			var unit_id := String(unit_value)
			if unit_id.is_empty() or _prototype_by_unit_id.has(unit_id):
				return false
			_prototype_by_unit_id[unit_id] = prototype_row
	_ready = true
	return true


## `units` is the dense array returned by MilitaryFacade.catalog_view() or
## DCWorldExt.get_military_catalog_view(). Unknown ids stay -1 so one missing
## visual mapping cannot corrupt another unit or sample outside the atlas.
func bind_dense_units(units: Array) -> Dictionary:
	_prototype_by_dense = PackedInt32Array()
	_dense_unit_ids = PackedStringArray()
	if not _ready:
		return {"ok": false, "reason": "formation_catalog_not_ready", "mapped": 0}
	if units.is_empty():
		return {"ok": false, "reason": "dense_unit_catalog_empty", "mapped": 0}
	var max_index := -1
	for row_value in units:
		if not row_value is Dictionary:
			continue
		max_index = maxi(max_index, int((row_value as Dictionary).get("index", -1)))
	if max_index < 0:
		return {"ok": false, "reason": "dense_unit_indices_missing", "mapped": 0}
	_prototype_by_dense.resize(max_index + 1)
	_prototype_by_dense.fill(-1)
	_dense_unit_ids.resize(max_index + 1)
	var mapped := 0
	for row_value in units:
		if not row_value is Dictionary:
			continue
		var row := row_value as Dictionary
		var index := int(row.get("index", -1))
		if index < 0 or index > max_index:
			continue
		var unit_id := String(row.get("id", "")).strip_edges()
		_dense_unit_ids[index] = unit_id
		if not _prototype_by_unit_id.has(unit_id):
			continue
		_prototype_by_dense[index] = int(_prototype_by_unit_id[unit_id])
		mapped += 1
	return {
		"ok": mapped > 0,
		"reason": "" if mapped > 0 else "formation_units_unmapped",
		"mapped": mapped,
		"dense_unit_count": _prototype_by_dense.size(),
	}


func is_ready() -> bool:
	return _ready


func is_bound() -> bool:
	if _prototype_by_dense.is_empty():
		return false
	for value in _prototype_by_dense:
		if value >= 0:
			return true
	return false


func mapped_unit_count() -> int:
	var count := 0
	for value in _prototype_by_dense:
		if value >= 0:
			count += 1
	return count


func dense_unit_count() -> int:
	return _prototype_by_dense.size()


func prototype_row_for_unit(unit: int) -> int:
	if unit < 0 or unit >= _prototype_by_dense.size():
		return -1
	return int(_prototype_by_dense[unit])


func unit_id_for_dense(unit: int) -> String:
	if unit < 0 or unit >= _dense_unit_ids.size():
		return ""
	return _dense_unit_ids[unit]


func prototype_count() -> int:
	return _prototypes.size()


func prototype(prototype_row: int) -> Dictionary:
	if prototype_row < 0 or prototype_row >= _prototypes.size():
		return {}
	return _prototypes[prototype_row] as Dictionary


func layout_for(prototype_row: int, member_count: int) -> Array:
	var row := prototype(prototype_row)
	if row.is_empty():
		return []
	var layouts := row.get("layouts", []) as Array
	if layouts.is_empty():
		return []
	return layouts[clampi(member_count - 1, 0, layouts.size() - 1)] as Array


func sprite_scale(prototype_row: int) -> float:
	return maxf(0.1, float(prototype(prototype_row).get("sprite_scale", 1.0)))


func member_count_for_headcount(headcount: int) -> int:
	for band_value in _headcount_bands:
		var band := band_value as Dictionary
		if headcount >= int(band.get("min", 0)) \
				and headcount <= int(band.get("max", 2147483647)):
			return clampi(int(band.get("members", 1)), 1, 5)
	return 1


func action_row(action_id: String) -> int:
	for index in _actions.size():
		var action := _actions[index] as Dictionary
		if String(action.get("id", "")) == action_id:
			return int(action.get("row", index))
	return 0


## Deterministic largest-remainder assignment. Ties always resolve by source
## index, which the feed already emits as weight-descending/dense-id-ascending.
func allocate_member_buckets(weights: Array, member_count: int) -> PackedInt32Array:
	var buckets := PackedInt32Array()
	buckets.resize(weights.size())
	buckets.fill(0)
	if weights.is_empty() or member_count <= 0:
		return buckets
	var order: Array[int] = []
	for index in weights.size():
		if float(weights[index]) > 0.0:
			order.append(index)
	if order.is_empty():
		for index in mini(member_count, buckets.size()):
			buckets[index] = 1
		return buckets
	order.sort_custom(func(a: int, b: int) -> bool:
		var aw := float(weights[a])
		var bw := float(weights[b])
		if is_equal_approx(aw, bw):
			return a < b
		return aw > bw
	)
	var selected := mini(member_count, order.size())
	for index in selected:
		buckets[order[index]] = 1
	var remaining := member_count - selected
	if remaining <= 0:
		return buckets
	var total_weight := 0.0
	for index in selected:
		total_weight += maxf(0.0, float(weights[order[index]]))
	if total_weight <= 0.000001:
		for index in remaining:
			buckets[order[index % selected]] += 1
		return buckets
	var fractions: Array[Dictionary] = []
	var assigned := 0
	for index in selected:
		var unit_index := order[index]
		var share := float(remaining) * float(weights[unit_index]) / total_weight
		var floor_share := int(floor(share))
		buckets[unit_index] += floor_share
		assigned += floor_share
		fractions.append({
			"index": unit_index,
			"fraction": share - float(floor_share),
		})
	var leftovers := remaining - assigned
	fractions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var af := float(a.get("fraction", 0.0))
		var bf := float(b.get("fraction", 0.0))
		if is_equal_approx(af, bf):
			return int(a.get("index", 0)) < int(b.get("index", 0))
		return af > bf
	)
	for index in leftovers:
		buckets[int(fractions[index].get("index", 0))] += 1
	return buckets
