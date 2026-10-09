class_name PersonGivenNamePackProfile
extends Resource

@export var stable_id: StringName = &"default_zh"
@export var given_name_ids: PackedStringArray
@export var given_name_text: PackedStringArray
@export var weights: PackedInt32Array


func compile_native_columns() -> Dictionary:
	if stable_id == &"" or given_name_ids.is_empty() \
			or given_name_ids.size() != given_name_text.size() \
			or given_name_ids.size() != weights.size():
		return {"ok": false, "reason": "person_given_name_pack_invalid"}
	var previous := ""
	for i in given_name_ids.size():
		var current := String(given_name_ids[i]).strip_edges()
		if current == "" or String(given_name_text[i]).strip_edges() == "" \
				or weights[i] <= 0 or (i > 0 and previous >= current):
			return {"ok": false, "reason": "person_given_name_pack_not_sorted_unique"}
		previous = current
	var columns := {
		"person_given_name_pack_id": String(stable_id),
		"person_given_name_ids": given_name_ids,
		"person_given_name_text": given_name_text,
		"person_given_name_weights": weights,
	}
	columns["person_catalog_hash"] = hash(columns)
	if int(columns.person_catalog_hash) == 0:
		columns["person_catalog_hash"] = 1
	columns["ok"] = true
	return columns
