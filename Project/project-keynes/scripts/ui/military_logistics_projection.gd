extends RefCounted

## Pure logistics display projection from a committed snapshot and a naming callback.

const Q16 := 65536.0

static func convoy_rows(_day: int, _model: Dictionary, cell_name: Callable, convoys: Array) -> Array:
	var rows: Array = []
	for raw in convoys:
		var convoy := _as_dict(raw)
		var risk := _ratio(convoy.get("risk_q16", 0))
		rows.append({
			"id": int(convoy.get("id", 0)),
			"cell": int(convoy.get("current_cell", -1)),
			"route": "%s → %s" % [cell_name.call(int(convoy.get("current_cell", -1))),
				cell_name.call(int(convoy.get("dest_cell", -1)))],
			"goods": _good_label(_model, int(convoy.get("good", -1))),
			"risk": risk,
			"eta": maxi(0, int(convoy.get("eta_day", 0)) - _day),
		})
	rows.sort_custom(func(a, b): return float(a.risk) > float(b.risk))
	return rows


static func _good_label(_model: Dictionary, dense_id: int) -> String:
	var ordered = _model.get("good_ids", PackedStringArray())
	if not (ordered is PackedStringArray) or dense_id < 0 or dense_id >= ordered.size():
		return "未知物资"
	var stable_id := String(ordered[dense_id])
	var profile = GoodProfileRegistry.profile_by_id(stable_id)
	return String(profile.display_name) if profile != null else stable_id


static func _as_dict(value) -> Dictionary:
	return value if value is Dictionary else {}


static func _ratio(raw) -> float:
	return clampf(float(raw) / Q16, 0.0, 1.0)
