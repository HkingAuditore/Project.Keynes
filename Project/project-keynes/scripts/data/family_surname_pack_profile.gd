class_name FamilySurnamePackProfile
extends Resource

@export var stable_id: StringName = &"default_zh"
@export var surname_ids: PackedStringArray
@export var surname_text: PackedStringArray
@export var weights: PackedInt32Array


func compile_native_columns() -> Dictionary:
	if stable_id == &"" or surname_ids.is_empty() \
			or surname_ids.size() != surname_text.size() \
			or surname_ids.size() != weights.size():
		return {"ok": false, "reason": "family_surname_pack_invalid"}
	var previous := ""
	for i in surname_ids.size():
		var current := String(surname_ids[i]).strip_edges()
		if current == "" or String(surname_text[i]).strip_edges() == "" \
				or weights[i] <= 0 or (i > 0 and previous >= current):
			return {"ok": false, "reason": "family_surname_pack_not_sorted_unique"}
		previous = current
	var columns := {
		"family_surname_pack_id": String(stable_id),
		"family_surname_ids": surname_ids,
		"family_surname_text": surname_text,
		"family_surname_weights": weights,
	}
	columns["family_catalog_hash"] = hash(columns)
	if int(columns.family_catalog_hash) == 0:
		columns["family_catalog_hash"] = 1
	columns["ok"] = true
	return columns
