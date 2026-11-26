extends RefCounted

## Quantizes published weather fronts to identify changed visual slots.

static func make_signature(front: WeatherFront) -> String:
	if front == null:
		return "null"
	var axis_v: Vector2 = front.normalized_axis()
	return "%d:%d:%d:%d:%d:%d:%d:%d" % [
		int(front.type),
		roundi(front.center.x / 8.0),
		roundi(front.center.y / 8.0),
		roundi(axis_v.angle() / 0.0872665),
		roundi(front.radius / 8.0),
		roundi(clampf(front.intensity, 0.0, 1.0) * 100.0),
		roundi(clampf(front.precip_amount, 0.0, 1.0) * 100.0),
		roundi(clampf(front.cloud_amount, 0.0, 1.0) * 100.0),
	]

static func slot_signatures(fronts: Array) -> PackedStringArray:
	var parts := PackedStringArray()
	parts.resize(fronts.size())
	for front_index in range(fronts.size()):
		parts[front_index] = make_signature(fronts[front_index])
	return parts

static func diff(prev: PackedStringArray, next: PackedStringArray) -> Dictionary:
	var changed_slots := PackedInt32Array()
	var unchanged: int = 0
	var changed: int = 0
	var added: int = 0
	var removed: int = 0
	var max_n: int = maxi(prev.size(), next.size())
	for i in range(max_n):
		var old_sig: String = prev[i] if i < prev.size() else ""
		var new_sig: String = next[i] if i < next.size() else ""
		if old_sig == new_sig:
			unchanged += 1
		else:
			changed_slots.append(i)
			if i >= prev.size():
				added += 1
			elif i >= next.size():
				removed += 1
			else:
				changed += 1
	return {
		"changed_slots": changed_slots,
		"changed_slots_count": changed_slots.size(),
		"unchanged_slots": unchanged,
		"changed_slots_existing": changed,
		"added_slots": added,
		"removed_slots": removed,
	}
