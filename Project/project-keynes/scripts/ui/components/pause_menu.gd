class_name PauseMenu
extends Control

const MenuButtonScene := preload("res://scenes/ui/pause_menu_button.tscn")
const SettingsFormScene := preload("res://scenes/ui/pause_settings_form.tscn")
const AiSettingsFormScene := preload("res://scenes/ui/pause_ai_settings_form.tscn")
const EventPauseOptions := preload("res://scripts/ui/components/event_pause_options.gd")
const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const NarrativeAiClientScript = preload("res://scripts/narrative/ai/narrative_ai_client.gd")

signal continue_requested()
signal return_menu_requested()
signal exit_requested()
signal visibility_requested(open: bool)

var _panel: VBoxContainer
var _rows: VBoxContainer
var _title_label: Label
var _status: Label
var _frame: PanelContainer
var _center: CenterContainer
var _rows_scroll: ScrollContainer
var _pending_destructive_action: String = ""
var _panel_generation := 0
var event_pause_reader: Callable


func _ready() -> void:
	_panel = get_node_or_null("Center/Frame/Panel") as VBoxContainer
	_title_label = get_node_or_null("Center/Frame/Panel/Title") as Label
	_rows = get_node_or_null("Center/Frame/Panel/Rows") as VBoxContainer
	_status = get_node_or_null("Center/Frame/Panel/Status") as Label
	_frame = get_node_or_null("Center/Frame") as PanelContainer
	_center = get_node_or_null("Center") as CenterContainer
	if _panel == null or _title_label == null or _rows == null or _status == null:
		push_error("PauseMenu 必须通过 pause_menu.tscn 实例化。")
	if TouchUI.is_touch():
		_ensure_rows_scroll.call_deferred()


## 存档列表和画质设置共用面板中的滚动区，标题和状态留在视口内。
func _ensure_rows_scroll() -> void:
	if _rows_scroll != null or _frame == null or _center == null or _panel == null:
		return
	_rows_scroll = UIControlParts.scroll_container()
	_rows_scroll.name = "RowsScroll"
	_rows_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_rows_scroll.follow_focus = true
	_rows_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_rows.get_parent().remove_child(_rows)
	_rows_scroll.add_child(_rows)
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel.add_child(_rows_scroll)
	_panel.move_child(_rows_scroll, 2)
	TouchUI.widen_scrollbars(_rows_scroll)
	resized.connect(_fit_scrolled_panel)
	_fit_scrolled_panel()


func _fit_scrolled_panel() -> void:
	if size.y > 0.0:
		_frame.custom_minimum_size.y = minf(540.0, maxf(0.0, size.y - 24.0))


func open() -> void:
	visible = true
	_show_main()
	call_deferred("_grab_first_focus")
	visibility_requested.emit(true)


func close() -> void:
	_panel_generation += 1
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
	_status.text = "自动存档未完成，可重试或放弃保存。"
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
	var generation := _panel_generation
	var slots: Array = save_service.list_slots() if save_service != null else []
	var buttons := {}
	for slot in slots:
		var slot_id := String(slot.slot_id)
		var label := "自动存档" if slot_id == "autosave" else "手动存档 %s" % slot_id.trim_prefix("manual_")
		var button := _add_button(label, "history", func() -> void:
			if flow_service != null:
				flow_service.begin_load_game(slot_id))
		buttons[slot_id] = button
		button.disabled = true
		button.tooltip_text = "正在检查存档…" if bool(slot.loadable) else String(slot.reason)
	_add_button("返回", "back", _show_main)
	if save_service == null:
		return
	var verified: Array = await save_service.list_slots_verified()
	if generation != _panel_generation:
		return
	for slot in verified:
		var button: Button = buttons.get(String(slot.slot_id))
		if not is_instance_valid(button):
			continue
		button.disabled = not bool(slot.loadable)
		button.tooltip_text = String(slot.reason)
		if bool(slot.loadable) and not bool(slot.get("integrity_checked", false)):
			button.tooltip_text = "载入时将检查存档完整性。"


func _show_settings() -> void:
	_ensure_rows_scroll()
	_clear_panel()
	_title("设置")
	var settings_service := get_node_or_null("/root/GameSettings")
	var current: Dictionary = settings_service.values() if settings_service != null else {
		"render_quality": "auto", "ui_scale_percent": 100,
		"master_volume": 1.0, "master_muted": false}
	var form := SettingsFormScene.instantiate() as VBoxContainer
	_ensure_rows_scroll()
	_rows.add_child(form)
	var event_options := EventPauseOptions.new()
	form.add_child(event_options)
	var initial_event_mask := int(event_pause_reader.call()) if event_pause_reader.is_valid() \
		else int(current.get("event_pause_mask", 255))
	event_options.configure(initial_event_mask)
	var graphics := form.get_node("GraphicsQualityOptions")
	graphics.configure(current)
	if visible:
		graphics.call_deferred("focus_preset")
	var scale := form.get_node("Scale") as OptionButton
	scale.clear()
	var layout := form.get_node_or_null("Layout") as OptionButton
	# 与主菜单同一口径：触摸档给「布局档位 + 再缩放」，桌面档只给百分比。
	var layout_active := false
	if settings_service != null and settings_service.has_method("ui_scaling"):
		var scaling = settings_service.call("ui_scaling")
		layout_active = scaling != null and bool(scaling.call("is_touch_profile"))
	if layout != null:
		layout.visible = layout_active
		layout.clear()
	if layout_active:
		for value in [50, 75, 100, 125, 150, 200]:
			scale.add_item("界面缩放 %d%%" % value)
			scale.set_item_metadata(scale.item_count - 1, value)
			if value == int(current.get("ui_layout_scale", 100)):
				scale.select(scale.item_count - 1)
		if layout != null:
			for entry in [{"label": "界面布局 · 完整", "id": "fit"},
					{"label": "界面布局 · 铺满（推荐）", "id": "fill"},
					{"label": "界面布局 · 紧凑", "id": "dense"}]:
				layout.add_item(String(entry.label))
				layout.set_item_metadata(layout.item_count - 1, entry.id)
				if String(entry.id) == String(current.get("ui_layout_mode", "fill")):
					layout.select(layout.item_count - 1)
	else:
		for value in [80, 100, 125, 150]:
			scale.add_item("界面缩放 %d%%" % value)
			scale.set_item_metadata(scale.item_count - 1, value)
			if value == int(current.ui_scale_percent): scale.select(scale.item_count - 1)
	var volume := form.get_node("Volume") as HSlider
	volume.value = float(current.master_volume)
	var mute := form.get_node("Mute") as CheckBox
	mute.button_pressed = bool(current.master_muted)
	var reduce_motion := form.get_node("ReduceMotion") as CheckBox
	reduce_motion.button_pressed = bool(current.get("reduce_motion",false))
	# AI 生成配置从这里进入：它是玩法设置，必须能在没有任何事件时打开。
	_add_button("AI 生成设置", "settings", _show_ai_settings)
	_add_button("应用", "confirm", func() -> void:
		if settings_service != null:
			var picked = scale.get_selected_metadata()
			var payload: Dictionary = graphics.settings_payload()
			if event_options.value() != initial_event_mask:
				payload["event_pause_mask"] = event_options.value()
			payload.merge({"master_volume": volume.value, "master_muted": mute.button_pressed,
				"reduce_motion": reduce_motion.button_pressed})
			# 触摸档：Scale 装缩放百分比，Layout 装布局档位。桌面档：只有百分比。
			if layout_active:
				payload["ui_layout_scale"] = picked
				if layout != null:
					payload["ui_layout_mode"] = layout.get_selected_metadata()
			else:
				payload["ui_scale_percent"] = picked
			var result: Dictionary = settings_service.update(payload)
			if not bool(result.get("ok", false)):
				_status.text = String(result.get("message", "无法保存设置。"))
				_status.show()
				return
		_show_main())
	_add_button("返回", "back", _show_main)


## AI 生成设置：文本与插画两段，密钥与接口都存本机，不依赖任何事件入口。
func _show_ai_settings() -> void:
	_clear_panel()
	_title("AI 生成")
	if _frame != null:
		_frame.custom_minimum_size.x = 540.0
	var settings_service := get_node_or_null("/root/GameSettings")
	var current: Dictionary = settings_service.values() \
		if settings_service != null and settings_service.has_method("values") else {}
	var keys := NarrativeAiClientScript.load_api_keys()

	var form := AiSettingsFormScene.instantiate() as ScrollContainer
	_rows.add_child(form)
	var enabled := form.get_node("Column/Enabled") as CheckButton
	enabled.button_pressed = bool(current.get("ai_narrative_enabled", false))
	var llm_url := _ai_field(form, "LlmUrl", String(current.get("ai_llm_base_url", "")))
	var llm_model := _ai_field(form, "LlmModel", String(current.get("ai_llm_model", "")))
	var llm_key := _ai_field(form, "LlmKey", String(keys.get("llm_api_key", "")))
	var image_enabled := form.get_node("Column/ImageEnabled") as CheckButton
	image_enabled.button_pressed = bool(current.get("ai_image_enabled", false))
	var img_url := _ai_field(form, "ImageUrl", String(current.get("ai_image_base_url", "")))
	var img_model := _ai_field(form, "ImageModel", String(current.get("ai_image_model", "")))
	var img_key := _ai_field(form, "ImageKey", String(keys.get("image_api_key", "")))
	var status := form.get_node("Column/Status") as Label

	_add_button("保存", "confirm", func() -> void:
		var payload := {
			"ai_narrative_enabled": enabled.button_pressed,
			"ai_llm_base_url": llm_url.text.strip_edges(),
			"ai_llm_model": llm_model.text.strip_edges(),
			"ai_image_enabled": image_enabled.button_pressed,
			"ai_image_base_url": img_url.text.strip_edges(),
			"ai_image_model": img_model.text.strip_edges(),
		}
		var settings_result: Dictionary = {"ok": true}
		if settings_service != null and settings_service.has_method("update"):
			settings_result = settings_service.update(payload, true)
		var keys_result: Dictionary = NarrativeAiClientScript.save_api_keys(
			llm_key.text.strip_edges(), img_key.text.strip_edges())
		var saved_ok := bool(settings_result.get("ok", true)) and bool(keys_result.get("ok", false))
		status.text = "已保存。" if saved_ok else "保存失败，请检查设置文件权限。"
		status.visible = true
	)
	_add_button("返回", "back", _show_settings)


## 字段行在 pause_ai_settings_form.tscn 里，一行一个「标签 + 输入框」。
func _ai_field(form: Control, row: String, value: String) -> LineEdit:
	var edit := form.get_node("Column/%s/Edit" % row) as LineEdit
	edit.text = value
	return edit


func _save_slot(slot_id: String) -> void:
	var save_service := get_node_or_null("/root/GameSave")
	var result: Dictionary = await save_service.request_manual_save(slot_id) \
		if save_service != null else {"ok": false, "message": "存档服务不可用。"}
	_status.text = "存档完成。" if bool(result.ok) else "存档未完成，请重试。"
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
	_panel_generation += 1
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	if _rows_scroll != null:
		_rows_scroll.scroll_vertical = 0
	_status.visible = false
	# AI 设置页需要更宽的字段区；回到其他页面时恢复原宽度。
	if _frame != null:
		_frame.custom_minimum_size.x = 390.0


func _title(text_value: String) -> void:
	_title_label.text = text_value


func _add_button(text_value: String, icon: String, callback: Callable) -> Button:
	var button := MenuButtonScene.instantiate() as Button
	preload("res://scripts/ui/ui_audio_feedback.gd").tag_icon(button, StringName(icon))
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
