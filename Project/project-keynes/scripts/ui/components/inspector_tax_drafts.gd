extends RefCounted

static func _restore_lane_pending(pending_tax: Dictionary, tax_key: Callable, editor: TaxLaneEditor, lane: Dictionary) -> void:
	if editor == null:
		return
	var item_key := "default" if String(lane.get("scope", "item")) == "default" \
		else String(lane.get("item_id", ""))
	var key: String = tax_key.call(String(lane.get("kind", "")), item_key)
	if pending_tax.has(key):
		editor.mark_pending(
			int(pending_tax[key].get("rate", lane.get("base", 0))),
			int(pending_tax[key].get("mode", lane.get("mode", 0))))


static func _capture_tax_drafts(draft_tax: Dictionary, tax_editors: Dictionary, pending_tax: Dictionary) -> void:
	draft_tax.clear()
	for key_value in tax_editors.keys():
		var key := String(key_value)
		if pending_tax.has(key):
			continue
		for editor_value in tax_editors[key]:
			var editor := editor_value as TaxLaneEditor
			if editor == null or not editor.is_editing():
				continue
			draft_tax[key] = editor.displayed_rate()
			break


static func _restore_tax_drafts(draft_tax: Dictionary, tax_editors: Dictionary, pending_tax: Dictionary) -> void:
	if draft_tax.is_empty():
		return
	for key_value in draft_tax.keys():
		var key := String(key_value)
		if pending_tax.has(key):
			continue
		var rate := int(draft_tax[key])
		for editor_value in tax_editors.get(key, []):
			var editor := editor_value as TaxLaneEditor
			if editor != null and not editor.is_pending():
				editor.apply_draft(rate)
	draft_tax.clear()


static func _pending_visible_in_snapshot(
		key: String,
		pending: Dictionary,
		context: Dictionary,
		category: Dictionary
) -> bool:
	var op := String(pending.get("op", "set"))
	var parts := key.split("/")
	if parts.size() < 3:
		return false
	var lane := _find_snapshot_tax_lane(parts[1], parts[2], context, category)
	if lane.is_empty():
		return false
	if op == "clear":
		return not bool(lane.get("has_override", true))
	return bool(lane.get("has_override", false)) \
		and int(lane.get("base", -999)) == int(pending.get("rate", -1))


static func _find_snapshot_tax_lane(
		kind: String,
		item_key: String,
		context: Dictionary,
		category: Dictionary
) -> Dictionary:
	if item_key == "default":
		for lane_value in context.get("default_lanes", []):
			var lane: Dictionary = lane_value
			if String(lane.get("kind", "")) == kind:
				return lane
		return {}
	for row_key in ["cohort_rows", "market_rows", "building_rows"]:
		for row_value in category.get(row_key, []):
			for lane_value in (row_value as Dictionary).get("tax_lanes", []):
				var lane: Dictionary = lane_value
				if String(lane.get("kind", "")) == kind \
						and String(lane.get("item_id", "")) == item_key:
					return lane
	if context.has("reset_targets"):
		for lane in context.get("default_lanes", []):
			if String(lane.get("kind", "")) != kind:
				continue
			for target in context.get("reset_targets", []):
				if String(target.kind) == kind and String(target.item_id) == item_key:
					return {"has_override": true}
			return {"has_override": false}
	return {}
