extends RefCounted


static func set_tax_override_group_basis_points(host, handle: int, kind: int,
		building_ids: PackedStringArray, rate_basis_points: int,
		effective_day: int, sequence: int) -> Dictionary:
	if not host.is_configured():
		return {"ok": false, "reason": "country facade is not configured"}
	if building_ids.is_empty():
		return {"ok": false, "reason": "empty tax group"}
	var commands: Array[Dictionary] = []
	for index in building_ids.size():
		var item_id := building_ids[index]
		var item: int = host._tax_item_index(kind, item_id)
		if item < 0:
			# 整组一起拒，不留半组改写。
			return {"ok": false, "reason": "unknown tax item: %s" % String(item_id)}
		commands.append({
			"opcode": host.Opcode.SET_TAX_OVERRIDE,
			"target_handle": handle,
			"tax_kind": kind,
			"tax_item": item,
			"stable_id": String(item_id),
			"tax_rate_basis_points": rate_basis_points,
			"tax_assessment_mode": host.TAX_MODE_PERCENT_BP,
			"effective_day": effective_day,
			"sequence": sequence,
		})
	var result: Dictionary = host.submit(commands)
	result["group_size"] = commands.size()
	return result


static func clear_tax_override_group(host, handle: int, kind: int,
		building_ids: PackedStringArray, effective_day: int,
		sequence: int) -> Dictionary:
	if not host.is_configured():
		return {"ok": false, "reason": "country facade is not configured"}
	if building_ids.is_empty():
		return {"ok": false, "reason": "empty tax group"}
	var commands: Array[Dictionary] = []
	for index in building_ids.size():
		var item_id := building_ids[index]
		var item: int = host._tax_item_index(kind, item_id)
		if item < 0:
			return {"ok": false, "reason": "unknown tax item: %s" % String(item_id)}
		commands.append({
			"opcode": host.Opcode.CLEAR_TAX_OVERRIDE,
			"target_handle": handle,
			"tax_kind": kind,
			"tax_item": item,
			"stable_id": String(item_id),
			"effective_day": effective_day,
			"sequence": sequence,
		})
	var result: Dictionary = host.submit(commands)
	result["group_size"] = commands.size()
	return result


static func set_tax_overrides_batch(host, handle: int, kind: int,
		item_ids: PackedStringArray, rates_basis_points: PackedInt32Array,
		effective_day: int, sequence: int) -> Dictionary:
	if not host.is_configured():
		return {"ok": false, "reason": "country facade is not configured"}
	if item_ids.is_empty() or item_ids.size() != rates_basis_points.size():
		return {"ok": false, "reason": "tax batch shape mismatch"}
	var commands: Array[Dictionary] = []
	for index in item_ids.size():
		var item_id := item_ids[index]
		var item: int = host._tax_item_index(kind, item_id)
		if item < 0:
			return {"ok": false, "reason": "unknown tax item: %s" % String(item_id)}
		commands.append({
			"opcode": host.Opcode.SET_TAX_OVERRIDE,
			"target_handle": handle,
			"tax_kind": kind,
			"tax_item": item,
			"stable_id": String(item_id),
			"tax_rate_basis_points": int(rates_basis_points[index]),
			"tax_assessment_mode": host.TAX_MODE_PERCENT_BP,
			"effective_day": effective_day,
			"sequence": sequence,
		})
	var result: Dictionary = host.submit(commands)
	result["group_size"] = commands.size()
	return result
