class_name PauseMenu
extends Control

const MenuButtonScene := preload("res://scenes/ui/pause_menu_button.tscn")
const SettingsFormScene := preload("res://scenes/ui/pause_settings_form.tscn")

signal continue_requested()
signal return_menu_requested()
signal exit_requested()
signal visibility_requested(open: bool)

var _panel: VBoxContainer
var _rows: VBoxContainer
var _title_label: Label
var _status: Label
var _pending_destructive_action: String = ""


func _ready() -> void:
	_panel = get_node_or_null("Center/Frame/Panel") as VBoxContainer
	_title_label = get_node_or_null("Center/Frame/Panel/Title") as Label
	_rows = get_node_or_null("Center/Frame/Panel/Rows") as VBoxContainer
	_status = get_node_or_null("Center/Frame/Panel/Status") as Label
	if _panel == null or _title_label == null or _rows == null or _status == null:
		push_error("PauseMenu 必须通过 pause_menu.tscn 实例化。")


func open() -> void:
	visible = true
	_show_main()
	call_deferred("_grab_first_focus")
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
	_status.visible = false


func _show_save() -> void:
	_clear_panel()
	_title("保存游戏")
	for slot_id in ["manual_1", "manual_2", "manual_3"]:
		_add_button("手动存档 %s" % slot_id.trim_prefix("manual_"), "confirm",
			func() -> void: _save_slot(slot_id))
	_add_button("返回", "back", _show_main)
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
	var form := SettingsFormScene.instantiate() as VBoxContainer
	_rows.add_child(form)
	var quality := form.get_node("Quality") as OptionButton
	for entry in [{"label": "自动画质", "id": "auto"}, {"label": "低画质", "id": "low"},
			{"label": "中画质", "id": "medium"}, {"label": "高画质", "id": "high"}]:
		quality.add_item(entry.label)
		quality.set_item_metadata(quality.item_count - 1, entry.id)
		if entry.id == current.render_quality: quality.select(quality.item_count - 1)
	var scale := form.get_node("Scale") as OptionButton
	for value in [80, 100, 125, 150]:
		scale.add_item("界面缩放 %d%%" % value)
		scale.set_item_metadata(scale.item_count - 1, value)
		if value == int(current.ui_scale_percent): scale.select(scale.item_count - 1)
	var volume := form.get_node("Volume") as HSlider
	volume.value = float(current.master_volume)
	var mute := form.get_node("Mute") as CheckBox
	mute.button_pressed = bool(current.master_muted)
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
	for child in _rows.get_children():
		child.queue_free()
	_status.visible = false


func _title(text_value: String) -> void:
	_title_label.text = text_value


func _add_button(text_value: String, icon: String, callback: Callable) -> Button:
	var button := MenuButtonScene.instantiate() as Button
	button.tooltip_text = text_value
	var icon_label := button.get_node("Row/Icon") as Label
	IconButton.apply_to_label(icon_label, StringName(icon), 15)
	var text_label := button.get_node("Row/Label") as Label
	text_label.text = text_value
	button.pressed.connect(callback)
	_rows.add_child(button)
	return button


func _grab_first_focus() -> void:
	if not visible or _rows == null:
		return
	for child in _rows.get_children():
		if child is Button and not (child as Button).disabled:
			(child as Button).grab_focus()
			return
