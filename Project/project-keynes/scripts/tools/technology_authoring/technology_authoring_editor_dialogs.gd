extends RefCounted

## Presents and handles authoring notices, confirmation dialogs, text input and the searchable picker.

static func _show_message(editor: TechnologyAuthoringEditor, title: String, body: String) -> void:
	editor._message_dialog.title = title
	editor._message_text.clear()
	editor._message_text.bbcode_enabled = true
	editor._message_text.append_text(body)
	editor._message_dialog.popup_centered()


static func _on_confirm_accepted(editor: TechnologyAuthoringEditor) -> void:
	match editor._confirm_action:
		"delete": editor._apply_delete(String(editor._confirm_payload.id))
		"reload": editor._load_everything()
		"reassign_unlocks": editor._prompt_replacement_unlock(String(editor._confirm_payload.id),
			editor._confirm_payload.blockers as Array)
		"save_draft": editor._apply_draft_save()
	editor._confirm_action = ""
	editor._confirm_payload = {}


static func _open_text_input(editor: TechnologyAuthoringEditor, title: String, primary_label: String, primary: String,
		secondary_label: String, secondary: String, hint: String,
		action: String, payload: Dictionary) -> void:
	editor._text_input_action = action
	editor._text_input_payload = payload
	editor._text_dialog.title = title
	editor._primary_label.text = primary_label
	editor._primary_edit.text = primary
	editor._secondary_label.text = secondary_label
	editor._secondary_edit.text = secondary
	var secondary_visible := not secondary_label.is_empty()
	editor._secondary_edit.visible = secondary_visible
	editor._secondary_label.visible = secondary_visible
	editor._hint_label.text = hint
	editor._text_dialog.popup_centered()


static func _on_text_input_accepted(editor: TechnologyAuthoringEditor) -> void:
	var primary := editor._primary_edit.text.strip_edges()
	var secondary := editor._secondary_edit.text.strip_edges()
	match editor._text_input_action:
		"relation":
			if secondary.is_empty():
				editor._show_message("需要理由", "配对的理由数组不能为空，闸门会拒绝。")
				return
			editor._apply_relation_entry(editor._text_input_payload, primary, secondary)
		"rename":
			editor._apply_rename(String(editor._text_input_payload.id), primary)
	editor._text_input_action = ""
	editor._text_input_payload = {}


static func _open_picker(editor: TechnologyAuthoringEditor, title: String, options: PackedStringArray,
		labels: PackedStringArray, callback: Callable) -> void:
	editor._picker_options = options
	editor._picker_labels = labels
	editor._picker_callback = callback
	editor._picker_title.text = title
	editor._picker_query.text = ""
	editor._refresh_picker()
	editor._picker_popup.popup_centered(Vector2i(560, 460))
	editor._picker_query.grab_focus()


static func _refresh_picker(editor: TechnologyAuthoringEditor) -> void:
	var needle := editor._picker_query.text.strip_edges().to_lower()
	editor._picker_list.clear()
	for index in range(editor._picker_options.size()):
		var id := String(editor._picker_options[index])
		var label := String(editor._picker_labels[index]) if index < editor._picker_labels.size() else id
		if not needle.is_empty() and not label.to_lower().contains(needle) \
				and not id.to_lower().contains(needle):
			continue
		editor._picker_list.add_item(label)
		editor._picker_list.set_item_metadata(editor._picker_list.item_count - 1, id)
		if editor._picker_list.item_count >= 400:
			break


static func _on_picker_activated(editor: TechnologyAuthoringEditor, index: int) -> void:
	var id := String(editor._picker_list.get_item_metadata(index))
	editor._picker_popup.hide()
	if editor._picker_callback.is_valid():
		editor._picker_callback.call(id)
	editor._picker_callback = Callable()
