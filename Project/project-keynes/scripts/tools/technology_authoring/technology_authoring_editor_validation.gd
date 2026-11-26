extends RefCounted

## Updates the authoring validation findings, inspector notices and problems list.

static func _queue_validation(editor: TechnologyAuthoringEditor) -> void:
	editor._validation_timer.start()


static func _run_validation(editor: TechnologyAuthoringEditor) -> void:
	var result := editor._service.validate()
	editor._findings = result.findings
	editor._findings_by_node = TechnologyAuthoringEditor.ServiceScript.group_findings(editor._findings)
	editor._severity_by_node.clear()
	for id in editor._findings_by_node:
		var severity := "warning"
		for value in editor._findings_by_node[id]:
			if String((value as Dictionary).get("severity", "")) == "error":
				severity = "error"
				break
		editor._severity_by_node[String(id)] = severity
	editor._canvas.call("set_problems", editor._severity_by_node)
	editor._rebuild_problems(float(result.msec))
	for id in editor._table_items:
		editor._write_table_row(editor._table_items[id], editor._service.model.node(String(id)))
	editor._rebuild_outline()
	editor._save_button.disabled = not bool(result.ok)
	if not editor._selected.is_empty():
		editor._refresh_inspector()


static func _rebuild_problems(editor: TechnologyAuthoringEditor, msec: float) -> void:
	editor._problems.clear()
	var root := editor._problems.create_item()
	var errors := TechnologyAuthoringEditor.ValidatorScript.error_count(editor._findings)
	editor._problems_label.text = "问题：%d 错误 / %d 警告（校验 %.2fms）" % [
		errors, editor._findings.size() - errors, msec]
	var ordered: Array = editor._findings.duplicate()
	ordered.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_key := "%s|%s" % [
			"0" if String(left.get("severity", "")) == "error" else "1",
			String(left.get("code", ""))]
		var right_key := "%s|%s" % [
			"0" if String(right.get("severity", "")) == "error" else "1",
			String(right.get("code", ""))]
		return left_key < right_key)
	for value in ordered:
		var row: Dictionary = value
		var item := editor._problems.create_item(root)
		var severity := String(row.get("severity", ""))
		item.set_text(0, "%s  %s" % ["错误" if severity == "error" else "警告",
			String(row.get("code", ""))])
		item.set_text(1, String(row.get("node_id", "")))
		item.set_text(2, String(row.get("message", "")))
		item.set_metadata(0, {"node_id": String(row.get("node_id", "")),
			"field": String(row.get("field", ""))})
		item.set_custom_color(0, UITokens.RISK if severity == "error" else UITokens.WARN)


static func _on_copy_problems(editor: TechnologyAuthoringEditor) -> void:
	var lines := PackedStringArray()
	for value in editor._findings:
		var row: Dictionary = value
		lines.append("%s\t%s\t%s\t%s" % [String(row.get("severity", "")),
			String(row.get("code", "")), String(row.get("node_id", "")),
			String(row.get("message", ""))])
	DisplayServer.clipboard_set("\n".join(lines))
	editor._status.text = "已复制 %d 条问题到剪贴板" % editor._findings.size()


# --------------------------------------------------------------------------
# Selection
# --------------------------------------------------------------------------
