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
