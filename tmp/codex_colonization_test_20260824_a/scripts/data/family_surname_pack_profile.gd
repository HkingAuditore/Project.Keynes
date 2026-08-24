class_name FamilySurnamePackProfile
extends Resource

## Optional parallel culture-group metadata. When omitted, the legacy surname
## columns are exposed as one default group for backwards-compatible content.
@export var culture_group_ids: PackedStringArray = PackedStringArray()
@export var culture_group_display_names: PackedStringArray = PackedStringArray()
@export var culture_group_naming_formats: PackedStringArray = PackedStringArray()
@export var culture_group_separators: PackedStringArray = PackedStringArray()
@export var culture_group_suffixes: PackedStringArray = PackedStringArray()
@export var surname_culture_group_ids: PackedStringArray = PackedStringArray()

@export var stable_id: StringName = &"default_zh"
@export var surname_ids: PackedStringArray
@export var surname_text: PackedStringArray
@export var weights: PackedInt32Array


func compile_native_columns() -> Dictionary:
	if stable_id == &"" or surname_ids.is_empty() \
			or surname_ids.size() != surname_text.size() \
			or surname_ids.size() != weights.size():
		return {"ok": false, "reason": "family_surname_pack_invalid"}
	for i in surname_ids.size():
		var current := String(surname_ids[i]).strip_edges()
		if current == "" or String(surname_text[i]).strip_edges() == "" \
				or weights[i] <= 0:
			return {"ok": false, "reason": "family_surname_pack_not_sorted_unique"}
	var columns := {
		"family_surname_pack_id": String(stable_id),
		"family_surname_ids": surname_ids,
		"family_surname_text": surname_text,
		"family_surname_weights": weights,
	}
	var groups := culture_group_ids
	if groups.is_empty():
		groups = PackedStringArray(["default"])
	var display_names := culture_group_display_names
	if display_names.is_empty():
		display_names = PackedStringArray(["默认文化"])
	var formats := culture_group_naming_formats
	if formats.is_empty():
		formats = PackedStringArray(["CITY_SURNAME_SUFFIX"])
	var separators := culture_group_separators
	if separators.is_empty():
		separators = PackedStringArray(["-"])
	var suffixes := culture_group_suffixes
	if suffixes.is_empty():
		suffixes = PackedStringArray(["氏"])
	if groups.size() != display_names.size() or groups.size() != formats.size() \
			or groups.size() != separators.size() or groups.size() != suffixes.size():
		return {"ok": false, "reason": "family_culture_group_columns_mismatch"}
	var previous_group := ""
	for group_id in groups:
		var normalized_group := String(group_id).strip_edges()
		if normalized_group.is_empty() or (previous_group != "" and previous_group >= normalized_group):
			return {"ok": false, "reason": "family_culture_groups_not_sorted_unique"}
		previous_group = normalized_group
	var surname_groups := surname_culture_group_ids
	if surname_groups.is_empty():
		surname_groups.resize(surname_ids.size())
		surname_groups.fill(groups[0])
	if surname_groups.size() != surname_ids.size():
		return {"ok": false, "reason": "family_surname_culture_group_columns_mismatch"}
	for group_id in surname_groups:
		if not groups.has(String(group_id)):
			return {"ok": false, "reason": "family_surname_culture_group_unknown"}
	var previous_surname_key := ""
	for i in surname_ids.size():
		var surname_key := "%s\u001f%s" % [String(surname_groups[i]), String(surname_ids[i])]
		if i > 0 and previous_surname_key >= surname_key:
			return {"ok": false, "reason": "family_surname_pack_not_sorted_unique"}
		previous_surname_key = surname_key
	columns["family_culture_group_ids"] = groups
	columns["family_culture_group_display_names"] = display_names
	columns["family_culture_group_naming_formats"] = formats
	columns["family_culture_group_separators"] = separators
	columns["family_culture_group_suffixes"] = suffixes
	var surname_group_indices := PackedInt32Array()
	for group_id in surname_groups:
		surname_group_indices.append(groups.find(String(group_id)))
	columns["family_surname_culture_group_ids"] = surname_group_indices
	columns["family_catalog_hash"] = hash(columns)
	if int(columns.family_catalog_hash) == 0:
		columns.family_catalog_hash = 1
	columns["family_catalog_hash"] = hash(columns)
	if int(columns.family_catalog_hash) == 0:
		columns["family_catalog_hash"] = 1
	columns["ok"] = true
	return columns
