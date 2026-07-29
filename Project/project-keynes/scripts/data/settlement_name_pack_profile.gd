class_name SettlementNamePackProfile
extends Resource

@export var stable_id: StringName = &"default_zh"
@export var prefix_ids: PackedStringArray
@export var prefix_text: PackedStringArray
@export var prefix_weights: PackedInt32Array
@export var prefix_alias_ids: PackedStringArray
@export var prefix_alias_targets: PackedStringArray
@export var root_ids: PackedStringArray
@export var root_text: PackedStringArray
@export var root_weights: PackedInt32Array
@export var root_alias_ids: PackedStringArray
@export var root_alias_targets: PackedStringArray
@export var suffix_ids: PackedStringArray
@export var suffix_text: PackedStringArray
@export var suffix_weights: PackedInt32Array
@export var suffix_alias_ids: PackedStringArray
@export var suffix_alias_targets: PackedStringArray


func compile_native_columns() -> Dictionary:
	if stable_id == &"" or not _valid_part(prefix_ids, prefix_text, prefix_weights) \
			or not _valid_part(root_ids, root_text, root_weights) \
			or not _valid_part(suffix_ids, suffix_text, suffix_weights) \
			or not _valid_aliases(prefix_alias_ids, prefix_alias_targets, prefix_ids) \
			or not _valid_aliases(root_alias_ids, root_alias_targets, root_ids) \
			or not _valid_aliases(suffix_alias_ids, suffix_alias_targets, suffix_ids):
		return {"ok": false, "reason": "settlement_name_pack_invalid"}
	var combinations := prefix_ids.size() * root_ids.size() * suffix_ids.size()
	if combinations < 4096:
		return {"ok": false, "reason": "settlement_name_pack_too_small"}
	return {
		"ok": true,
		"settlement_name_pack_id": String(stable_id),
		"settlement_prefix_ids": prefix_ids,
		"settlement_prefix_text": prefix_text,
		"settlement_prefix_weights": prefix_weights,
		"settlement_prefix_alias_ids": prefix_alias_ids,
		"settlement_prefix_alias_targets": prefix_alias_targets,
		"settlement_root_ids": root_ids,
		"settlement_root_text": root_text,
		"settlement_root_weights": root_weights,
		"settlement_root_alias_ids": root_alias_ids,
		"settlement_root_alias_targets": root_alias_targets,
		"settlement_suffix_ids": suffix_ids,
		"settlement_suffix_text": suffix_text,
		"settlement_suffix_weights": suffix_weights,
		"settlement_suffix_alias_ids": suffix_alias_ids,
		"settlement_suffix_alias_targets": suffix_alias_targets,
		"settlement_catalog_hash": hash([
			stable_id, prefix_ids, prefix_text, prefix_weights,
			prefix_alias_ids, prefix_alias_targets,
			root_ids, root_text, root_weights,
			root_alias_ids, root_alias_targets,
			suffix_ids, suffix_text, suffix_weights,
			suffix_alias_ids, suffix_alias_targets]),
	}


static func _valid_part(ids: PackedStringArray, text: PackedStringArray,
		weights: PackedInt32Array) -> bool:
	if ids.is_empty() or ids.size() != text.size() or ids.size() != weights.size():
		return false
	for index in range(ids.size()):
		if ids[index].is_empty() or weights[index] <= 0:
			return false
	return true


static func _valid_aliases(aliases: PackedStringArray,
		targets: PackedStringArray, ids: PackedStringArray) -> bool:
	if aliases.size() != targets.size():
		return false
	var seen := {}
	for index in range(aliases.size()):
		if aliases[index].is_empty() or seen.has(aliases[index]) \
				or ids.find(targets[index]) < 0:
			return false
		seen[aliases[index]] = true
	return true
