class_name PauseMenu
extends Control

signal continue_requested()
signal return_menu_requested()
signal exit_requested()
signal visibility_requested(open: bool)

var _panel: VBoxContainer
var _status: Label
var _pending_destructive_action: String = ""


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel = %Panel
	for child in _panel.get_children():
		child.queue_free()
	_make_status_label()


func open() -> void:
	visible = true
	_show_main()
	visibility_requested.emit(true)


func close() -> void:
	visible = false
	_pending_destructive_action = ""
	visibility_requested.emit(false)
	continue_requested.emit()


func toggle() -> void:
	if visible: close()
	else: open()


func show_save_failure(action: String, result: Dictionary) -> void:
	_pending_destructive_action = action
	_clear_panel()
	_title("自动存档失败")
	_status.text = String(result.get("message", "自动存档未完成。"))
	_status.visible = true
	_add_button("重试", "regenerate", func() -> void: _retry_pending_action())
	_add_button("放弃保存", "warning", func() -> void: _finish_pending_action())
	_add_button("取消", "close", _show_main)


func _show_main() -> void:
	_pending_destructive_action = ""
	_clear_panel()
	_title("游戏已暂停")
	_add_button("继续", "play", close)
	_add_button("保存游戏", "confirm", _show_save)
	_add_button("加载游戏", "history", _show_load)
	_add_button("设置", "settings", _show_settings)
	_add_button("返回主菜单", "back", func() -> void: return_menu_requested.emit())
	_add_button("退出", "close", func() -> void: exit_requested.emit())
	_panel.add_child(_status)
	_status.visible = false


func _show_save() -> void:
	_clear_panel()
	_title("保存游戏")
	for slot_id in ["manual_1", "manual_2", "manual_3"]:
		_add_button("手动存档 %s" % slot_id.trim_prefix("manual_"), "confirm",
			func() -> void: _save_slot(slot_id))
	_add_button("返回", "back", _show_main)
	_panel.add_child(_status)
	_status.visible = false


func _show_load() -> void:
	_clear_panel()
	_title("加载游戏")
	var save_service := get_node_or_null("/root/GameSave")
	var flow_service := get_node_or_null("/root/GameFlow")
	var slots: Array = save_service.list_slots() if save_service != null else []
	for slot in slots:
		var slot_id := String(slot.slot_id)
		var label := "自动存档" if slot_id == "autosave" else "手动存档 %s" % slot_id.trim_prefix("manual_")
		var button := _add_button(label, "history", func() -> void:
			if flow_service != null:
				flow_service.begin_load_game(slot_id))
		button.disabled = not bool(slot.loadable)
		button.tooltip_text = String(slot.reason)
	_add_button("返回", "back", _show_main)


func _show_settings() -> void:
	_clear_panel()
	_title("设置")
	var settings_service := get_node_or_null("/root/GameSettings")
	var current: Dictionary = settings_service.values() if settings_service != null else {
		"render_quality": "auto", "ui_scale_percent": 100,
		"master_volume": 1.0, "master_muted": false}
	var quality := OptionButton.new()
	for entry in [{"label": "自动画质", "id": "auto"}, {"label": "低画质", "id": "low"},
			{"label": "中画质", "id": "medium"}, {"label": "高画质", "id": "high"}]:
		quality.add_item(entry.label)
		quality.set_item_metadata(quality.item_count - 1, entry.id)
		if entry.id == current.render_quality: quality.select(quality.item_count - 1)
	_panel.add_child(quality)
	var scale := OptionButton.new()
	for value in [80, 100, 125, 150]:
		scale.add_item("界面缩放 %d%%" % value)
		scale.set_item_metadata(scale.item_count - 1, value)
		if value == int(current.ui_scale_percent): scale.select(scale.item_count - 1)
	_panel.add_child(scale)
	var volume := HSlider.new()
	volume.min_value = 0
	volume.max_value = 1
	volume.step = 0.01
	volume.value = float(current.master_volume)
	volume.tooltip_text = "主音量"
	_panel.add_child(volume)
	var mute := CheckBox.new()
	mute.text = "静音"
	mute.button_pressed = bool(current.master_muted)
	_panel.add_child(mute)
	_add_button("应用", "confirm", func() -> void:
		if settings_service != null:
			settings_service.update({"render_quality": quality.get_selected_metadata(),
				"ui_scale_percent": scale.get_selected_metadata(), "master_volume": volume.value,
				"master_muted": mute.button_pressed})
		_show_main())
	_add_button("返回", "back", _show_main)


func _save_slot(slot_id: String) -> void:
	var save_service := get_node_or_null("/root/GameSave")
	var result: Dictionary = await save_service.request_manual_save(slot_id) \
		if save_service != null else {"ok": false, "message": "存档服务不可用。"}
	_status.text = "存档完成。" if bool(result.ok) else String(result.message)
	_status.visible = true


func _retry_pending_action() -> void:
	if _pending_destructive_action == "menu": return_menu_requested.emit()
	elif _pending_destructive_action == "exit": exit_requested.emit()


func _finish_pending_action() -> void:
	var flow_service := get_node_or_null("/root/GameFlow")
	if flow_service == null:
		return
	if _pending_destructive_action == "menu": flow_service.return_to_main_menu()
	elif _pending_destructive_action == "exit": flow_service.quit_game()


func _clear_panel() -> void:
	for child in _panel.get_children(): child.queue_free()
	_make_status_label()


func _make_status_label() -> void:
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", UITokens.WARN)


func _title(text_value: String) -> void:
	var title := Label.new()
	title.text = text_value
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color("d9c58c"))
	_panel.add_child(title)


func _add_button(text_value: String, icon: String, callback: Callable) -> Button:
	var button := Button.new()
	button.custom_minimum_size.y = 44.0
	button.text = ""
	button.tooltip_text = text_value
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	var icon_label := Label.new()
	icon_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	IconButton.apply_to_label(icon_label, StringName(icon), 15)
	icon_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(icon_label)
	var text_label := Label.new()
	text_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_label.text = text_value
	text_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(text_label)
	button.add_child(row)
	button.pressed.connect(callback)
	_panel.add_child(button)
	return button
