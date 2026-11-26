extends RefCounted

## Coordinates network saving, import/export gate actions and catalog metadata editing.

static func _on_draft_save_pressed(editor: TechnologyAuthoringEditor) -> void:
	var errors := TechnologyAuthoringEditor.ValidatorScript.error_count(editor._findings)
	if errors == 0:
		editor._on_save_pressed()
		return
	editor._confirm_action = "save_draft"
	editor._confirm_payload = {}
	editor._confirm_text.clear()
	editor._confirm_text.bbcode_enabled = true
	editor._confirm_text.append_text("\n".join(PackedStringArray([
		"仍有 [b]%d[/b] 条错误未修完。" % errors,
		"草稿会写入 %s（先备份为 .bak），但 CLI 闸门仍会拒绝它，不要就此提交。" % TechnologyAuthoringEditor.ServiceScript.NETWORK_PATH,
		"",
		TechnologyAuthoringEditor.ServiceScript.SAVE_WARNING,
	])))
	editor._confirm_dialog.popup_centered()


static func _apply_draft_save(editor: TechnologyAuthoringEditor) -> void:
	var result := editor._service.save_draft()
	if not bool(result.ok):
		editor._show_message("草稿保存失败", String(result.get("reason", "")))
		return
	editor._status.text = "已保存草稿 %s（%d 字节，仍有错误）" % [String(result.path),
		int(result.get("bytes", 0))]
	editor._rebake_canvas()
	editor._run_validation()


static func _on_save_pressed(editor: TechnologyAuthoringEditor) -> void:
	var result := editor._service.save()
	if not bool(result.ok):
		editor._show_message("保存被拒绝", "%s\n\n错误必须先修完；问题栏已列出全部条目。" % String(
			result.get("reason", "")))
		return
	editor._status.text = "已保存 %s" % String(result.path)
	editor._show_message("已保存", "%s\n\n%s" % [String(result.path), String(result.warning)])
	editor._rebake_canvas()
	editor._run_validation()


static func _on_reload_pressed(editor: TechnologyAuthoringEditor) -> void:
	if editor._service.model.is_dirty():
		editor._confirm_action = "reload"
		editor._confirm_payload = {}
		editor._confirm_text.clear()
		editor._confirm_text.bbcode_enabled = true
		editor._confirm_text.append_text("有未保存的改动，重新载入会丢弃它们。继续？")
		editor._confirm_dialog.popup_centered()
		return
	editor._load_everything()


static func _on_gate_pressed(editor: TechnologyAuthoringEditor) -> void:
	editor._status.text = "正在运行 CLI 闸门…"
	var result := editor._service.run_gate(true)
	editor._show_message("CLI 闸门（退出码 %d）" % int(result.code), String(result.output))
	editor._status.text = "CLI 闸门 %s" % ("通过" if bool(result.ok) else "失败")


static func _on_report_pressed(editor: TechnologyAuthoringEditor) -> void:
	var result := editor._service.export_report()
	editor._show_message("导出报告（退出码 %d）" % int(result.code), String(result.output))


# --------------------------------------------------------------------------
# Meta editors
# --------------------------------------------------------------------------


static func _open_meta_dialog(editor: TechnologyAuthoringEditor, mode: String) -> void:
	editor._meta_mode = mode
	editor._rebuild_meta_tree()
	editor._meta_hint.text = "直接编辑「值」列。数组按顿号或逗号分隔；时代的候选需 8–18 个、candidate_required 需 4–7。" \
		if mode == "eras" else "直接编辑「值」列。应用交汇的 required_technology_ids 至少 2 个已存在的科技。"
	editor._meta_dialog.get_ok_button().text = "关闭"
	editor._meta_dialog.title = "时代与里程碑" if mode == "eras" else "分支族与应用交汇"
	editor._meta_dialog.popup_centered()


static func _rebuild_meta_tree(editor: TechnologyAuthoringEditor) -> void:
	editor._meta_tree.clear()
	editor._meta_tree.columns = 4
	editor._meta_tree.column_titles_visible = true
	editor._meta_tree.set_column_title(0, "记录")
	editor._meta_tree.set_column_title(1, "字段")
	editor._meta_tree.set_column_title(2, "值")
	editor._meta_tree.set_column_title(3, "说明")
	editor._meta_tree.set_column_custom_minimum_width(0, 200)
	editor._meta_tree.set_column_custom_minimum_width(1, 200)
	editor._meta_tree.set_column_expand(2, true)
	var root := editor._meta_tree.create_item()
	if editor._meta_mode == "eras":
		editor._meta_section("eras", ["display_name", "milestone_id", "entry_milestone_id",
			"candidate_required", "milestone_candidate_ids"], root)
		return
	editor._meta_section("backbones", ["display_name"], root)
	editor._meta_section("branch_families", ["display_name"], root)
	editor._meta_section("application_intersections", ["display_name", "era_id", "domain_id",
		"branch_family_id", "layout_lane", "required_technology_ids", "building_ids"], root)


static func _meta_section(editor: TechnologyAuthoringEditor, key: String, fields: Array, root: TreeItem) -> void:
	var header := editor._meta_tree.create_item(root)
	header.set_text(0, "%s（%d）" % [key, editor._service.model.meta_array(key).size()])
	header.set_selectable(0, false)
	header.set_collapsed(key == "application_intersections")
	for row_value in editor._service.model.meta_array(key):
		var row: Dictionary = row_value
		var id := String(row.get("id", ""))
		var item := editor._meta_tree.create_item(header)
		item.set_text(0, id)
		item.set_selectable(0, false)
		item.set_collapsed(true)
		for field_value in fields:
			var field := String(field_value)
			if not row.has(field):
				continue
			var child := editor._meta_tree.create_item(item)
			child.set_text(0, id)
			child.set_text(1, field)
			child.set_text(2, editor._meta_display(row[field]))
			child.set_editable(2, true)
			child.set_metadata(2, {"key": key, "id": id, "field": field,
				"array": row[field] is Array})
			if field == "milestone_candidate_ids":
				var count := (row[field] as Array).size()
				child.set_text(3, "%d 个候选，必须在 8–18 之间" % count)
				if count < 8 or count > 18:
					child.set_custom_color(3, UITokens.RISK)
			elif field == "candidate_required":
				child.set_text(3, "必须在 4–7 之间")
				var required := int(row[field])
				if required < 4 or required > 7:
					child.set_custom_color(3, UITokens.RISK)
			elif field == "entry_milestone_id":
				child.set_text(3, "由上一时代 milestone_id 自动维护")
				child.set_editable(2, false)
		editor._meta_tree.create_item(item)


static func _meta_display(editor: TechnologyAuthoringEditor, value: Variant) -> String:
	if value is Array:
		var parts := PackedStringArray()
		for item in value as Array:
			parts.append(String(item))
		return ", ".join(parts)
	if value is float:
		return str(int(value)) if is_equal_approx(value, floorf(value)) else str(value)
	return String(value)


static func _on_meta_edited(editor: TechnologyAuthoringEditor) -> void:
	var item := editor._meta_tree.get_edited()
	if item == null:
		return
	var metadata: Variant = item.get_metadata(2)
	if not metadata is Dictionary:
		return
	var info: Dictionary = metadata
	var text := item.get_text(2)
	var value: Variant = text
	if bool(info.array):
		var out: Array = []
		for token in text.replace("、", ",").split(","):
			var trimmed := String(token).strip_edges()
			if not trimmed.is_empty():
				out.append(trimmed)
		value = out
	elif text.is_valid_float():
		value = float(text)
	editor._service.model.begin_batch("编辑 %s.%s" % [String(info.key), String(info.field)])
	editor._service.model.set_meta_field(String(info.key), String(info.id),
		String(info.field), value)
	if String(info.field) == "milestone_id":
		editor._service.model.repair_era_entry_chain()
	editor._service.model.commit_batch()
	editor._rebuild_meta_tree()


# --------------------------------------------------------------------------
# Dialog plumbing
# --------------------------------------------------------------------------
