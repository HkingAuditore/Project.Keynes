extends RefCounted

## Applies graph and node edits, including create, duplicate, rename and delete.

static func _on_connect_requested(editor: TechnologyAuthoringEditor, from_id: String, to_id: String) -> void:
	editor._open_text_input("添加硬前置", "前置科技", from_id, "理由（必填）", "",
		"%s 将成为 %s 的硬前置。理由会写入配对的 prerequisite_rationales。" % [from_id, to_id],
		"relation", {"id": to_id, "field": "hard_prerequisite_ids"})


static func _on_reorder_requested(editor: TechnologyAuthoringEditor, era_id: String, ordered_ids: PackedStringArray) -> void:
	editor._service.model.begin_batch("调整 %s 序位" % era_id)
	editor._service.model.reorder_layout(era_id, ordered_ids)
	editor._service.model.commit_batch()
	editor._rebake_canvas()


static func _on_context_requested(editor: TechnologyAuthoringEditor, id: String, screen_position: Vector2) -> void:
	editor._context_target = id
	editor._context_menu.clear()
	editor._context_menu.add_item("聚焦", TechnologyAuthoringEditor.CONTEXT_FOCUS)
	editor._context_menu.add_item("新建后继科技", TechnologyAuthoringEditor.CONTEXT_ADD_SUCCESSOR)
	editor._context_menu.add_item("复制为新科技", TechnologyAuthoringEditor.CONTEXT_DUPLICATE)
	editor._context_menu.add_item("设为本时代里程碑候选", TechnologyAuthoringEditor.CONTEXT_MILESTONE_CANDIDATE)
	editor._context_menu.add_item("改 ID", TechnologyAuthoringEditor.CONTEXT_RENAME)
	editor._context_menu.add_separator()
	editor._context_menu.add_item("删除…", TechnologyAuthoringEditor.CONTEXT_DELETE)
	editor._context_menu.position = Vector2i(screen_position)
	editor._context_menu.popup()


static func _on_context_selected(editor: TechnologyAuthoringEditor, id: int) -> void:
	match id:
		TechnologyAuthoringEditor.CONTEXT_FOCUS:
			editor.select_technology(editor._context_target)
			editor._focus_technology(editor._context_target)
		TechnologyAuthoringEditor.CONTEXT_ADD_SUCCESSOR:
			editor._selected = editor._context_target
			editor._on_new_node_pressed()
		TechnologyAuthoringEditor.CONTEXT_DUPLICATE:
			editor._duplicate_technology(editor._context_target)
		TechnologyAuthoringEditor.CONTEXT_MILESTONE_CANDIDATE:
			editor._add_milestone_candidate(editor._context_target)
		TechnologyAuthoringEditor.CONTEXT_RENAME:
			editor._selected = editor._context_target
			editor._on_rename_pressed()
		TechnologyAuthoringEditor.CONTEXT_DELETE:
			editor._selected = editor._context_target
			editor._on_delete_pressed()


static func _add_milestone_candidate(editor: TechnologyAuthoringEditor, id: String) -> void:
	var row := editor._service.model.node(id)
	var era_id := String(row.get("era_id", ""))
	var era := editor._service.model.meta_row("eras", era_id)
	if era.is_empty():
		return
	var candidates: Array = (era.get("milestone_candidate_ids", []) as Array).duplicate()
	if candidates.has(id):
		editor._status.text = "%s 已经是 %s 的里程碑候选" % [id, era_id]
		return
	candidates.append(id)
	editor._service.model.begin_batch("添加里程碑候选")
	editor._service.model.set_meta_field("eras", era_id, "milestone_candidate_ids", candidates)
	editor._service.model.commit_batch()
	editor._status.text = "%s 已加入 %s 的里程碑候选（共 %d 个）" % [id, era_id, candidates.size()]


# --------------------------------------------------------------------------
# Structural operations
# --------------------------------------------------------------------------


static func _populate_new_node_dialog(editor: TechnologyAuthoringEditor) -> void:
	editor._fill_dialog_option(editor._new_era_option, editor._service.model.meta_array("eras"))
	editor._fill_dialog_option(editor._new_domain_option, editor._service.model.meta_array("domains"))
	editor._fill_dialog_option(editor._new_family_option, editor._service.model.meta_array("backbones")
		+ editor._service.model.meta_array("branch_families"))


static func _fill_dialog_option(editor: TechnologyAuthoringEditor, option: OptionButton, rows: Array) -> void:
	option.clear()
	for index in range(rows.size()):
		var row: Dictionary = rows[index]
		option.add_item("%s（%s）" % [String(row.get("display_name", "")),
			String(row.get("id", ""))], index)
		option.set_item_metadata(index, String(row.get("id", "")))


static func _on_new_node_pressed(editor: TechnologyAuthoringEditor) -> void:
	var anchor := editor._service.model.node(editor._selected)
	editor._new_id_edit.text = "tech."
	editor._new_name_edit.text = ""
	if not anchor.is_empty():
		editor._select_dialog_option(editor._new_era_option, String(anchor.get("era_id", "")))
		editor._select_dialog_option(editor._new_domain_option, String(anchor.get("domain_id", "")))
		editor._select_dialog_option(editor._new_family_option,
			String(anchor.get("branch_family_id", "")))
	editor._new_node_hint.text = "新节点会插入到 %s 之后，并预填全部校验必需字段。" % (
		editor._selected if not editor._selected.is_empty() else "网络末尾")
	editor._new_node_dialog.popup_centered()


static func _select_dialog_option(editor: TechnologyAuthoringEditor, option: OptionButton, id: String) -> void:
	for index in range(option.item_count):
		if String(option.get_item_metadata(index)) == id:
			option.select(index)
			return


static func _dialog_option_value(editor: TechnologyAuthoringEditor, option: OptionButton) -> String:
	if option.get_selected() < 0:
		return ""
	return String(option.get_item_metadata(option.get_selected()))


static func _on_new_node_confirmed(editor: TechnologyAuthoringEditor) -> void:
	var id := editor._new_id_edit.text.strip_edges()
	var reason := editor._service.model.validate_new_id(id)
	if not reason.is_empty():
		editor._show_message("无法创建", reason)
		return
	var display_name := editor._new_name_edit.text.strip_edges()
	if display_name.is_empty():
		editor._show_message("无法创建", "显示名称不能为空。")
		return
	var template := editor._service.model.new_node_template(id, display_name,
		editor._dialog_option_value(editor._new_era_option), editor._dialog_option_value(editor._new_domain_option),
		editor._dialog_option_value(editor._new_family_option))
	editor._service.model.begin_batch("新建科技 %s" % id)
	var added := editor._service.model.add_node(template, editor._selected)
	if not editor._selected.is_empty():
		editor._service.model.add_relation_entry(id, "hard_prerequisite_ids", editor._selected,
			"该科技需要先掌握 %s。" % editor._selected)
	editor._service.model.commit_batch()
	if not bool(added.ok):
		editor._show_message("无法创建", String(added.reason))
		return
	editor.select_technology(id)
	editor._focus_technology(id)
	editor._status.text = "已创建 %s" % id


static func _duplicate_technology(editor: TechnologyAuthoringEditor, id: String) -> void:
	var source := editor._service.model.node(id)
	if source.is_empty():
		return
	var copy: Dictionary = source.duplicate(true)
	var suffix := 2
	var new_id := "%s_copy" % id
	while not editor._service.model.validate_new_id(new_id).is_empty():
		new_id = "%s_copy%d" % [id, suffix]
		suffix += 1
		if suffix > 64:
			return
	copy["id"] = new_id
	copy["display_name"] = "%s（副本）" % String(source.get("display_name", ""))
	copy["is_milestone"] = false
	copy["is_era_key"] = false
	copy["research_routes"] = []
	copy["route_exemption_reason"] = "副本尚未编写替代研究路线。"
	editor._service.model.begin_batch("复制科技 %s" % id)
	editor._service.model.add_node(copy, id)
	editor._service.model.commit_batch()
	editor.select_technology(new_id)
	editor._status.text = "已复制为 %s" % new_id


static func _on_rename_pressed(editor: TechnologyAuthoringEditor) -> void:
	if editor._selected.is_empty():
		editor._show_message("改 ID", "请先选中一个科技。")
		return
	editor._open_text_input("改 ID", "新的稳定 ID", editor._selected, "", "",
		"改 ID 会原子重写所有引用点：硬前置、分支后继、应用目标、研究路线条件、知识基础、时代里程碑与候选、应用交汇。",
		"rename", {"id": editor._selected})


static func _apply_rename(editor: TechnologyAuthoringEditor, old_id: String, new_id: String) -> void:
	editor._service.model.begin_batch("改 ID %s → %s" % [old_id, new_id])
	var result := editor._service.model.rename_node(old_id, new_id)
	if not bool(result.ok):
		editor._service.model.abort_batch()
		editor._show_message("改 ID 失败", String(result.reason))
		return
	editor._service.model.commit_batch()
	editor.select_technology(new_id)
	editor._status.text = "已把 %s 改名为 %s（.tres 标签需要单独同步）" % [old_id, new_id]


static func _on_delete_pressed(editor: TechnologyAuthoringEditor) -> void:
	if editor._selected.is_empty():
		editor._show_message("删除科技", "请先选中一个科技。")
		return
	var preview := editor._service.model.delete_preview(editor._selected)
	var blockers := editor._service.deletion_blockers(editor._selected)
	var lines := PackedStringArray(["将删除 [b]%s[/b]（%s）。" % [
		editor.technology_display_name(editor._selected), editor._selected]])
	var references: Array = preview.references
	if references.is_empty():
		lines.append("没有其他记录引用它。")
	else:
		lines.append("以下 %d 个引用点会被自动修复：" % references.size())
		for value in references:
			var row: Dictionary = value
			lines.append("· %s %s 的 %s%s" % [String(row.owner_kind), String(row.owner_id),
				String(row.field),
				"（%s）" % String(row.label) if not String(row.label).is_empty() else ""])
	for reason in preview.blocking:
		lines.append("[color=#c94f3a]阻止：%s[/color]" % String(reason))
	for blocker_value in blockers:
		lines.append("[color=#c94f3a]阻止：%s[/color]" % String(
			(blocker_value as Dictionary).message))
	if not bool(preview.ok):
		editor._show_message("无法删除", "\n".join(lines))
		return
	if not blockers.is_empty():
		lines.append("")
		lines.append("确认后将先为上述建筑挑选替代解锁科技。")
		editor._confirm_action = "reassign_unlocks"
		editor._confirm_payload = {"id": editor._selected, "blockers": blockers}
		editor._confirm_text.clear()
		editor._confirm_text.bbcode_enabled = true
		editor._confirm_text.append_text("\n".join(lines))
		editor._confirm_dialog.popup_centered()
		return
	editor._confirm_action = "delete"
	editor._confirm_payload = {"id": editor._selected}
	editor._confirm_text.clear()
	editor._confirm_text.bbcode_enabled = true
	editor._confirm_text.append_text("\n".join(lines))
	editor._confirm_dialog.popup_centered()


## A building must keep exactly one primary `tech.*` unlock, so deleting its
## only unlock is offered as a reassignment rather than a dead end.


static func _prompt_replacement_unlock(editor: TechnologyAuthoringEditor, doomed_id: String, blockers: Array) -> void:
	editor.open_technology_picker("为建筑挑选替代解锁科技", func(replacement: String) -> void:
		if replacement == doomed_id:
			editor._show_message("无法指定", "替代科技不能是即将删除的 %s。" % doomed_id)
			return
		var moved := PackedStringArray()
		for blocker_value in blockers:
			var blocker: Dictionary = blocker_value
			var result := editor._service.set_building_primary_technology(String(blocker.id),
				replacement)
			if not bool(result.ok):
				editor._show_message("改写 .tres 失败", String(result.reason))
				return
			moved.append(String(blocker.id))
		editor._rebuild_search_index()
		editor._status.text = "已把 %s 的解锁科技改为 %s，可以继续删除 %s" % [
			", ".join(moved), replacement, doomed_id]
		editor.select_technology(doomed_id)
		editor._on_delete_pressed())


static func _apply_delete(editor: TechnologyAuthoringEditor, id: String) -> void:
	editor._service.model.begin_batch("删除科技 %s" % id)
	var removed := editor._service.model.remove_node(id)
	if not bool(removed.ok):
		editor._service.model.abort_batch()
		editor._show_message("删除失败", String(removed.reason))
		return
	editor._service.model.commit_batch()
	editor._selected = ""
	editor._selection = PackedStringArray()
	editor._inspector.clear()
	editor._status.text = "已删除 %s，并修复 %d 个引用点" % [id, (removed.repaired as Array).size()]


# --------------------------------------------------------------------------
# Undo, save and gates
# --------------------------------------------------------------------------
