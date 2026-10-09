class_name CountryNamePackProfile
extends Resource

@export var stable_id: StringName = &""
@export var name_ids: PackedStringArray = PackedStringArray()
@export var display_names: PackedStringArray = PackedStringArray()


func validate(required_count: int = 0, excluded_name: String = "") -> Dictionary:
	if stable_id == &"" or name_ids.size() != display_names.size():
		return _error("country_name_pack_invalid")
	var seen_ids := {}
	var seen_names := {}
	var available := 0
	for index in range(name_ids.size()):
		var name_id := String(name_ids[index]).strip_edges()
		var display_name := String(display_names[index]).strip_edges()
		if name_id.is_empty() or display_name.is_empty() \
				or seen_ids.has(name_id) or seen_names.has(display_name):
			return _error("country_name_pack_invalid")
		seen_ids[name_id] = true
		seen_names[display_name] = true
		if display_name != excluded_name:
			available += 1
	if available < required_count:
		return {
			"ok": false,
			"reason": "country_name_pack_too_small",
			"available": available,
			"required": required_count,
		}
	return {"ok": true, "available": available}


func select(seed: int, count: int, excluded_name: String = "") -> Dictionary:
	var validation := validate(count, excluded_name)
	if not bool(validation.get("ok", false)):
		return validation
	var candidates: Array[Dictionary] = []
	for index in range(name_ids.size()):
		var display_name := String(display_names[index]).strip_edges()
		if display_name == excluded_name:
			continue
		var name_id := String(name_ids[index]).strip_edges()
		candidates.append({
			"id": name_id,
			"display_name": display_name,
			"order": _stable_hash(seed, "foreign_country_names/%s" % name_id),
		})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.order) != int(b.order):
			return int(a.order) < int(b.order)
		return String(a.id) < String(b.id))
	var selected_ids := PackedStringArray()
	var selected_names := PackedStringArray()
	for index in range(count):
		selected_ids.append(String(candidates[index].id))
		selected_names.append(String(candidates[index].display_name))
	return {
		"ok": true,
		"name_ids": selected_ids,
		"display_names": selected_names,
	}


static func _stable_hash(seed: int, purpose: String) -> int:
	var value := int(seed) & 0x7fffffff
	for byte in purpose.to_utf8_buffer():
		value = int((value * 16777619) ^ int(byte)) & 0x7fffffff
	return value


static func _error(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
