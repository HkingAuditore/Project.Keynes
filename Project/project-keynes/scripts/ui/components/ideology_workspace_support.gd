extends RefCounted


static func _support_details(host, live: Dictionary, location: int) -> Array[Dictionary]:
	var supports: Array[Dictionary] = []
	if location == 2:
		return supports
	var direction = 0 if location == 0 else 1
	var rows: Array = live.get("support", [])
	if direction < rows.size():
		var row: Dictionary = (rows[direction] as Dictionary).duplicate()
		row["action"] = "推行" if direction == 0 else "撤回"
		row["reason"] = "关键阶层未达到最低支持要求" \
			if int(row.get("blocking_class", -1)) >= 0 else ""
		supports.append(row)
	return supports


const CLASS_DISPLAY_NAMES := {
	"farmer": "农民阶层",
	"worker": "工人阶层",
	"technology": "科技阶层",
	"military": "军事阶层",
	"general": "普通阶层",
}


static func _class_label(host, class_index: int) -> String:
	var class_ids: PackedStringArray = host._catalog.get(
		"political_class_ids", PackedStringArray())
	if class_index >= 0 and class_index < class_ids.size():
		var key := String(class_ids[class_index])
		return String(CLASS_DISPLAY_NAMES.get(key, key))
	return "阶层 %d" % class_index


static func _support_breakdown(host, live: Dictionary, location: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if location == 2:
		return out
	var direction := 0 if location == 0 else 1
	var support_rows: Array = live.get("support", [])
	if direction < support_rows.size() \
			and not bool((support_rows[direction] as Dictionary).get("available", false)):
		return out
	var classes: Array = live.get("classes", [])
	if classes.is_empty():
		return out
	var total_influence := int(live.get("total_influence", 0))
	if total_influence <= 0:
		for item in classes:
			total_influence += maxi(0, int((item as Dictionary).get("influence", 0)))
	for item in classes:
		var entry := item as Dictionary
		var class_index := int(entry.get("class_index", -1))
		var inf := maxi(0, int(entry.get("influence", 0)))
		var stances: Array = entry.get("stances", [])
		var contribs: Array = entry.get("contributions", [])
		var stance_q16 := int(stances[direction]) if direction < stances.size() else 0
		var raw_contrib := int(contribs[direction]) if direction < contribs.size() else 0
		var score_contrib_q16 := int(round(float(raw_contrib) / float(total_influence))) \
			if total_influence > 0 else 0
		var share_pct := int(round(float(inf) * 100.0 / float(total_influence))) \
			if total_influence > 0 else 0
		out.append({
			"class_index": class_index,
			"label": _class_label(host, class_index),
			"stance_q16": stance_q16,
			"influence": inf,
			"share_pct": share_pct,
			"contribution_q16": score_contrib_q16,
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ca := absi(int(a.get("contribution_q16", 0)))
		var cb := absi(int(b.get("contribution_q16", 0)))
		if ca != cb:
			return ca > cb
		var sa := absi(int(a.get("stance_q16", 0)))
		var sb := absi(int(b.get("stance_q16", 0)))
		if sa != sb:
			return sa > sb
		return int(a.get("class_index", 0)) < int(b.get("class_index", 0))
	)
	return out


static func _refresh_live_explain(host, known: PackedInt32Array) -> void:
	host._live_explain = host._facade.explain_ideologies(host._country_handle, known) \
		if host._facade != null and host._facade.has_method("explain_ideologies") else {}
	host._live_by_id.clear()
	if not bool(host._live_explain.get("ok", false)):
		return
	var ids: PackedInt32Array = host._live_explain.get("ideology_ids", PackedInt32Array())
	var support: PackedInt32Array = host._live_explain.get("support_q16", PackedInt32Array())
	var thresholds: PackedInt32Array = host._live_explain.get("support_thresholds_q16", PackedInt32Array())
	var blockers: PackedInt32Array = host._live_explain.get("support_blocking_classes", PackedInt32Array())
	var available: PackedByteArray = host._live_explain.get("support_available", PackedByteArray())
	var allowed: PackedByteArray = host._live_explain.get("support_allowed", PackedByteArray())
	var equip_allowed: PackedByteArray = host._live_explain.get("equip_allowed", PackedByteArray())
	var unequip_allowed: PackedByteArray = host._live_explain.get("unequip_allowed", PackedByteArray())
	var promote_allowed: PackedByteArray = host._live_explain.get("promote_allowed", PackedByteArray())
	var stance_offsets: PackedInt32Array = host._live_explain.get("stance_offsets", PackedInt32Array())
	var stance_classes: PackedInt32Array = host._live_explain.get("stance_class_indices", PackedInt32Array())
	var influence: PackedInt64Array = host._live_explain.get("class_influence", PackedInt64Array())
	var adopt_stances: PackedInt32Array = host._live_explain.get("adopt_stances_q16", PackedInt32Array())
	var repeal_stances: PackedInt32Array = host._live_explain.get("repeal_stances_q16", PackedInt32Array())
	var promote_stances: PackedInt32Array = host._live_explain.get("promote_stances_q16", PackedInt32Array())
	var adopt_contributions: PackedInt64Array = host._live_explain.get("adopt_contributions", PackedInt64Array())
	var repeal_contributions: PackedInt64Array = host._live_explain.get("repeal_contributions", PackedInt64Array())
	var promote_contributions: PackedInt64Array = host._live_explain.get("promote_contributions", PackedInt64Array())
	var total_influence := int(host._live_explain.get("total_influence", 0))
	for index in ids.size():
		var support_rows: Array[Dictionary] = []
		for direction in 3:
			var row = index * 3 + direction
			support_rows.append({
				"support_q16": int(support[row]) if row < support.size() else 0,
				"threshold_q16": int(thresholds[row]) if row < thresholds.size() else 0,
				"blocking_class": int(blockers[row]) if row < blockers.size() else -1,
				"available": row < available.size() and available[row] != 0,
				"allowed": row < allowed.size() and allowed[row] != 0,
			})
		var class_rows: Array[Dictionary] = []
		var stance_begin = int(stance_offsets[index]) if index < stance_offsets.size() else 0
		var stance_end = int(stance_offsets[index + 1]) \
			if index + 1 < stance_offsets.size() else stance_begin
		for row in range(stance_begin, stance_end):
			var row_inf := int(influence[row]) if row < influence.size() else 0
			var row_contribs := [
				int(adopt_contributions[row]) if row < adopt_contributions.size() else 0,
				int(repeal_contributions[row]) if row < repeal_contributions.size() else 0,
				int(promote_contributions[row]) if row < promote_contributions.size() else 0,
			]
			var row_stances := [
				int(adopt_stances[row]) if row < adopt_stances.size() else (
					int(round(float(row_contribs[0]) / float(row_inf))) if row_inf > 0 else 0),
				int(repeal_stances[row]) if row < repeal_stances.size() else (
					int(round(float(row_contribs[1]) / float(row_inf))) if row_inf > 0 else 0),
				int(promote_stances[row]) if row < promote_stances.size() else (
					int(round(float(row_contribs[2]) / float(row_inf))) if row_inf > 0 else 0),
			]
			class_rows.append({
				"class_index": int(stance_classes[row]),
				"influence": row_inf,
				"stances": row_stances,
				"contributions": row_contribs,
			})
		host._live_by_id[int(ids[index])] = {
			"support": support_rows,
			"classes": class_rows,
			"total_influence": total_influence,
			"equip_allowed": index < equip_allowed.size() and equip_allowed[index] != 0,
			"unequip_allowed": index < unequip_allowed.size() and unequip_allowed[index] != 0,
			"promote_allowed": index < promote_allowed.size() and promote_allowed[index] != 0,
		}


static func tooltip(host, live: Dictionary, direction: int) -> String:
	var summary: String = host._support_summary(live, direction)
	var classes: Array = live.get("classes", [])
	if classes.is_empty():
		return summary
	var total_influence := int(live.get("total_influence", 0))
	if total_influence <= 0:
		for item in classes:
			total_influence += maxi(0, int((item as Dictionary).get("influence", 0)))
	var parts := PackedStringArray()
	for item in classes:
		var entry := item as Dictionary
		var stances: Array = entry.get("stances", [])
		var contribs: Array = entry.get("contributions", [])
		var stance := int(stances[direction]) if direction < stances.size() else 0
		var raw_contrib := int(contribs[direction]) if direction < contribs.size() else 0
		var score_contrib := int(round(float(raw_contrib) / float(total_influence))) \
			if total_influence > 0 else 0
		var attitude := "赞成" if stance > 0 else ("反对" if stance < 0 else "中立")
		var label := _class_label(
			host, int(entry.get("class_index", -1)))
		parts.append("%s %s(%s, 贡献 %s)" % [
			label, attitude, host._q16_signed(stance), host._q16_signed(score_contrib)])
	if parts.is_empty():
		return summary
	return "%s\n%s" % [summary, " · ".join(parts)]
