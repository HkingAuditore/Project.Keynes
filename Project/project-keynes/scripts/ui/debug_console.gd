# debug_console.gd
# 可开合的 Debug 控制台面板：把原本分散在 F6/F7/F8 快捷键与 @export 开关里
# 的调试选项集中到一个 UI 上，面向开发者与美术调参。
#
# 打开方式：主场景按 ` 或 F1（由 main.gd._unhandled_key_input 触发）。
# 节点结构（运行时动态构建，不依赖 .tscn 里的 children）：
#   PanelContainer (self, mouse_filter = STOP)
#     └ MarginContainer
#         └ ScrollContainer
#             └ VBoxContainer
#                 ├ Header Label（带关闭 X）
#                 ├ Overlay 分组（折叠）
#                 ├ 模拟开关 分组（折叠）
#                 ├ 视觉开关 分组（折叠）
#                 ├ 诊断动作 分组（折叠）
#                 └ Telemetry 分组（折叠）
#
# DebugConsole **不持有 MapData 引用**——所有数据都通过 `_main` 回调读取，
# 保证 MapData 被替换（R 键 regenerate）时不会出现悬挂引用。

class_name DebugConsole
extends "res://scripts/ui/debug_console_lab.gd"

# 玩家场景只复用性能监视、快照与两类录制器，不暴露旧 debug lab 的
# overlay/模拟开关，避免要求 WorldRuntimeHost 伪装成完整 main.gd。
var runtime_diagnostics_only: bool = false

const GM_REFRESH_SECONDS := 0.5
const GM_TABS := [
	{"id": "overview", "label": "总览", "icon": &"summary.overview"},
	{"id": "selected", "label": "选中对象", "icon": &"system.target"},
	{"id": "commands", "label": "指令", "icon": &"system.settings"},
	{"id": "toggles", "label": "开关", "icon": &"geography.surface"},
	{"id": "recording", "label": "记录", "icon": &"action.history"},
]

var _gm_tabs: CategoryTabs
var _gm_pages: Dictionary = {}
var _gm_data_labels: Dictionary = {}
var _gm_capabilities: Dictionary = {}
var _gm_command_input: LineEdit
var _gm_suggestions: ItemList
var _gm_command_help: Label
var _gm_confirmation: ConfirmationDialog
var _gm_pending_command: Dictionary = {}
var _gm_history: Array = []
var _gm_history_cursor := 0
var _gm_toggle_container: VBoxContainer
var _gm_toggle_buttons: Dictionary = {}
var _gm_action_buttons: Dictionary = {}
var _gm_local_toggle_getter: Callable
var _gm_local_toggle_setter: Callable

const GmTodSunPadScript = preload("res://scripts/ui/gm_tod_sun_pad.gd")

var _gm_tod_sun_pad
var _telemetry_timer: Timer

# --- 布局常量 -------------------------------------------------------------
const PANEL_WIDTH: float = 360.0


func _ready() -> void:
	# UI 拦截：控制台内点击不应穿透到地块选中（验收 4.6）
	mouse_filter = Control.MouseFilter.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(0.0 if console_mode == ConsoleMode.PLAYER_GM else PANEL_WIDTH, 0.0)
	visible = false
	# 停靠位置（TopBar 高度约 36px，空出 40 给 Label 与阴影）
	# 这里不硬编码 anchor，交由父容器或 main 侧的锚点配置；但给一个兜底 offset
	if console_mode == ConsoleMode.LEGACY_DEBUG_LAB:
		position = Vector2(8, 44)
	_build_ui()
	# Telemetry 低频定时器：Debug 面板只读缓存状态，避免打开面板后每秒制造 UI/字典开销。
	_telemetry_timer = Timer.new()
	_telemetry_timer.wait_time = GM_REFRESH_SECONDS if console_mode == ConsoleMode.PLAYER_GM else 2.0

	_telemetry_timer.autostart = false
	_telemetry_timer.timeout.connect(_on_gm_refresh_tick if console_mode == ConsoleMode.PLAYER_GM else _on_telemetry_tick)
	add_child(_telemetry_timer)
	visibility_changed.connect(_on_visibility_changed)


# 由 main.gd 注入。建议在 _ready 之后立即调用，确保 UI 构建完成后就能刷新状态。
func set_main(m: Node) -> void:
	if _main != null and _main.has_signal("gm_action_completed"):
		var old_callback := Callable(self, "_on_gm_action_completed")
		if _main.is_connected("gm_action_completed", old_callback):
			_main.disconnect("gm_action_completed", old_callback)
	_main = m
	if _main != null and _main.has_signal("gm_action_completed"):
		var callback := Callable(self, "_on_gm_action_completed")
		if not _main.is_connected("gm_action_completed", callback):
			_main.connect("gm_action_completed", callback)
	# 在注入 main 时创建 PerfRecorder 并双向挂接：DebugConsole 持有它（控制开关），
	# main 在 fast_tick 末尾调它的 on_fast_tick。两端任一释放都不会留悬挂引用，
	# 因为 PerfRecorder 是 RefCounted。
	if _perf_recorder == null:
		_perf_recorder = PerfRecorderScript.new()
	if _perf_recorder.has_method("bind_main"):
		_perf_recorder.call("bind_main", m)
	if m != null and m.has_method("set_perf_recorder"):
		m.call("set_perf_recorder", _perf_recorder)
	if _tile_data_recorder == null:
		_tile_data_recorder = TileDataRecorderScript.new()
	if _tile_data_recorder.has_method("bind_main"):
		_tile_data_recorder.call("bind_main", m)
	if m != null and m.has_method("set_tile_data_recorder"):
		m.call("set_tile_data_recorder", _tile_data_recorder)
	# 经济数据录制器：与地块录制器并列挂接，共享 main 的 fast_tick 注入点。
	if _economy_data_recorder == null:
		_economy_data_recorder = EconomyDataRecorderScript.new()
	if _economy_data_recorder.has_method("bind_main"):
		_economy_data_recorder.call("bind_main", m)
	if m != null and m.has_method("set_economy_data_recorder"):
		m.call("set_economy_data_recorder", _economy_data_recorder)
	if console_mode == ConsoleMode.PLAYER_GM:
		_gm_load_capabilities()
		_gm_refresh_current_page()
	else:
		_refresh_from_state()


func set_gm_local_toggle_provider(getter: Callable, setter: Callable) -> void:
	_gm_local_toggle_getter = getter
	_gm_local_toggle_setter = setter
	if console_mode == ConsoleMode.PLAYER_GM:
		_gm_load_capabilities()


func refresh_gm_capabilities() -> void:
	if console_mode == ConsoleMode.PLAYER_GM:
		_gm_load_capabilities()


func open_panel() -> void:
	if visible:
		return
	refresh_gm_capabilities()
	UIAnimation.fade_slide_in(self, Vector2(-28.0, 0.0))
	_gm_refresh_current_page()


func close_panel() -> void:
	UIAnimation.fade_slide_out(self, Vector2(-28.0, 0.0))


func is_panel_open() -> bool:
	return visible


func _build_ui() -> void:
	if console_mode == ConsoleMode.PLAYER_GM:
		_build_player_gm_ui()
		return
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.ScrollMode.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 520)
	margin.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 6)
	scroll.add_child(vbox)

	# ── 标题行
	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title := Label.new()
	title.text = "GM 性能面板" if runtime_diagnostics_only else "调试控制台"
	title.add_theme_font_size_override("font_size", 18)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "X"
	close_btn.pressed.connect(func() -> void: visible = false)
	header.add_child(close_btn)
	vbox.add_child(header)
	vbox.add_child(HSeparator.new())

	if runtime_diagnostics_only:
		_build_telemetry_group(vbox)
		return

	_build_overlay_group(vbox)
	vbox.add_child(HSeparator.new())
	_build_sim_group(vbox)
	vbox.add_child(HSeparator.new())
	_build_visual_group(vbox)
	vbox.add_child(HSeparator.new())
	_build_tod_group(vbox)
	vbox.add_child(HSeparator.new())
	_build_diagnose_group(vbox)
	vbox.add_child(HSeparator.new())
	_build_experiments_group(vbox)
	vbox.add_child(HSeparator.new())
	_build_migration_group(vbox)
	vbox.add_child(HSeparator.new())
	_build_telemetry_group(vbox)


func _build_player_gm_ui() -> void:
	ConsolePresentation._build_player_gm_ui(self)


func _new_gm_page(parent: Control, page_id: String) -> VBoxContainer:
	return ConsolePresentation._new_gm_page(self, parent, page_id)


func _build_gm_data_page(parent: Control, page_id: String) -> void:
	ConsolePresentation._build_gm_data_page(self, parent, page_id)


func _build_gm_command_page(parent: Control) -> void:
	var page := _new_gm_page(parent, "commands")
	_gm_command_help = Label.new()
	_gm_command_help.text = "输入 help 查看白名单指令，输入 clear 清空输出。"
	_gm_command_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_gm_command_help.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	page.add_child(_gm_command_help)
	var money_row := HBoxContainer.new()
	var money_amount := SpinBox.new()
	money_amount.name = "GMTreasuryAmount"
	money_amount.min_value = 1.0
	money_amount.max_value = 1000000000.0
	money_amount.value = 10000.0
	money_amount.step = 1.0
	money_amount.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	money_amount.tooltip_text = "增加到玩家国库的货币数量，下一游戏日生效"
	money_row.add_child(money_amount)
	var mint_button := Button.new()
	mint_button.text = "刷钱到国库"
	mint_button.pressed.connect(func() -> void:
		_gm_command_input.text = "economy.mint_to_treasury amount=%d" % int(money_amount.value)
		_submit_gm_command())
	money_row.add_child(mint_button)
	page.add_child(money_row)
	var speed_row := HBoxContainer.new()
	var speed_options := OptionButton.new()
	speed_options.name = "GMSpeedOptions"
	speed_options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for speed in WorldRuntimeHost.GM_SPEED_PRESETS:
		speed_options.add_item("%d 倍速" % int(speed), int(speed))
	speed_options.select(5)
	speed_row.add_child(speed_options)
	var speed_button := Button.new()
	speed_button.text = "设置 GM 倍速"
	speed_button.pressed.connect(func() -> void:
		_gm_command_input.text = "time.speed value=%d" % speed_options.get_selected_id()
		_submit_gm_command())
	speed_row.add_child(speed_button)
	page.add_child(speed_row)
	var input_row := HBoxContainer.new()
	_gm_command_input = LineEdit.new()
	_gm_command_input.placeholder_text = "<command_id> key=value"
	_gm_command_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_gm_command_input.text_changed.connect(_on_gm_command_text_changed)
	_gm_command_input.text_submitted.connect(func(_line: String) -> void: _submit_gm_command())
	_gm_command_input.gui_input.connect(_on_gm_command_input_event)
	input_row.add_child(_gm_command_input)
	var run_button := Button.new()
	run_button.tooltip_text = "解析并执行指令"
	run_button.custom_minimum_size = Vector2(38.0, 34.0)
	IconButton.apply(run_button, &"action.confirm", 15)
	run_button.pressed.connect(_submit_gm_command)
	input_row.add_child(run_button)
	page.add_child(input_row)
	_gm_suggestions = ItemList.new()
	_gm_suggestions.custom_minimum_size = Vector2(0.0, 96.0)
	_gm_suggestions.visible = false
	_gm_suggestions.item_selected.connect(_on_gm_suggestion_selected)
	page.add_child(_gm_suggestions)
	_gm_command_output = RichTextLabel.new()
	_gm_command_output.bbcode_enabled = false
	_gm_command_output.selection_enabled = true
	_gm_command_output.scroll_following = true
	_gm_command_output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_gm_command_output.add_theme_color_override("default_color", UITokens.TEXT_MAIN)
	page.add_child(_gm_command_output)
	_gm_confirmation = ConfirmationDialog.new()
	_gm_confirmation.title = "确认 GM 指令"
	_gm_confirmation.ok_button_text = "确认提交"
	_gm_confirmation.cancel_button_text = "取消"
	_gm_confirmation.confirmed.connect(_execute_pending_gm_command)
	add_child(_gm_confirmation)


func _build_gm_toggle_page(parent: Control) -> void:
	ConsolePresentation._build_gm_toggle_page(self, parent)


func _add_gm_recorder_row(parent: VBoxContainer, recorder_id: String,
		label_text: String, callback: Callable) -> void:
	ConsolePresentation._add_gm_recorder_row(self, parent, recorder_id, label_text, callback)


func _on_gm_tab_selected(tab_id: String) -> void:
	_show_gm_page(tab_id)
	_gm_refresh_current_page()


func _show_gm_page(page_id: String) -> void:
	for key in _gm_pages.keys():
		var page := _gm_pages[key] as Control
		if page != null:
			page.visible = String(key) == page_id
	var shown := _gm_pages.get(page_id) as Control
	if shown != null:
		UIAnimation.crossfade(shown)


func _gm_load_capabilities() -> void:
	_gm_capabilities = _main.call("get_gm_capabilities") \
		if _main != null and _main.has_method("get_gm_capabilities") else {"commands": [], "toggles": []}
	var toggles: Array = Array(_gm_capabilities.get("toggles", [])).duplicate()
	toggles.append({"id": "diagnostics.perf_hud", "label": "性能显示", "group": "诊断", "local": true})
	_gm_capabilities["toggles"] = toggles
	_rebuild_gm_toggle_controls(toggles)
	var usage := PackedStringArray()
	for command in _gm_capabilities.get("commands", []):
		usage.append(GMPanelViewModel.describe_command(command))
	if _gm_command_help != null:
		_gm_command_help.tooltip_text = "\n".join(usage)


func _rebuild_gm_toggle_controls(toggles: Array) -> void:
	ConsolePresentation._rebuild_gm_toggle_controls(self, toggles)


func _add_gm_capability_action_row(spec: Dictionary) -> void:
	ConsolePresentation._add_gm_capability_action_row(self, spec)


func _on_gm_capability_action_pressed(action_id: String) -> void:
	if action_id != "diagnostics.dump_flow_tex_report":
		_append_gm_output("未知诊断动作：%s" % action_id, true)
		return
	if _main == null or not _main.has_method("dump_flow_tex_report"):
		_append_gm_output("当前运行时不支持 FlowTex 完整诊断", true)
		return
	_append_gm_output("FlowTex：正在采集 CPU、材质与 GPU 诊断帧…", false)
	# 隐藏 GM 面板，避免它覆盖 debug view 的位条和灰阶采样区域。
	var was_visible := visible
	visible = false
	var result = await _main.call("dump_flow_tex_report")
	visible = was_visible
	if result is Dictionary:
		_append_gm_output(String(result.get("message", "FlowTex 诊断完成")),
			not bool(result.get("ok", false)))
	else:
		_append_gm_output("FlowTex 诊断完成，详情见控制台日志", false)


func _add_gm_atlas_probe_recorder_row(parent: Control) -> void:
	ConsolePresentation._add_gm_atlas_probe_recorder_row(self, parent)


func _on_gm_refresh_tick() -> void:
	if visible:
		_gm_refresh_current_page()


func _gm_refresh_current_page() -> void:
	if console_mode != ConsoleMode.PLAYER_GM or not visible:
		return
	var page_id := _gm_tabs.current_tab() if _gm_tabs != null else "overview"
	if page_id == "overview" or page_id == "selected":
		_refresh_gm_data_page(page_id)
	elif page_id == "toggles":
		_refresh_gm_toggles()
	elif page_id == "recording":
		_refresh_gm_recorders()


func _refresh_gm_data_page(section: String) -> void:
	var label := _gm_data_labels.get(section) as RichTextLabel
	if label == null:
		return
	var snapshot: Dictionary = _main.call("get_gm_snapshot", section, {}) \
		if _main != null and _main.has_method("get_gm_snapshot") else {
			"ok": false, "message": "数据尚未就绪，请稍后再试。"}
	var lines := PackedStringArray()
	for raw_section in GMPanelViewModel.format_snapshot(section, snapshot):
		var section_model: Dictionary = raw_section
		lines.append(String(section_model.get("title", "")))
		for raw_row in section_model.get("rows", []):
			var row: Dictionary = raw_row
			lines.append("  %-18s %s" % [row.get("label", ""), row.get("value", "")])
		lines.append("")
	label.text = "\n".join(lines)


func _refresh_gm_toggles() -> void:
	_suppress_sync_signals = true
	for toggle_id in _gm_toggle_buttons.keys():
		var result := _get_gm_toggle_state(String(toggle_id))
		var button := _gm_toggle_buttons[toggle_id] as CheckBox
		if button != null:
			button.disabled = not bool(result.get("ok", false))
			if bool(result.get("ok", false)):
				button.set_pressed_no_signal(bool(result.get("enabled", false)))
	_suppress_sync_signals = false
	_sync_gm_tod_sun_pad()


func _sync_gm_tod_sun_pad() -> void:
	if _gm_tod_sun_pad == null:
		return
	if _main == null or not _main.has_method("get_gm_tod_sun_preview"):
		_gm_tod_sun_pad.set_available(false)
		return
	_gm_tod_sun_pad.set_available(true)
	var state: Variant = _main.call("get_gm_tod_sun_preview")
	if state is Dictionary:
		_gm_tod_sun_pad.apply_runtime_state(state)


func _on_gm_tod_sun_preview_requested(active: bool, uv: Vector2, height_scale: float) -> void:
	if _main == null or not _main.has_method("set_gm_tod_sun_preview"):
		return
	var state: Variant = _main.call("set_gm_tod_sun_preview", active, uv, height_scale)
	if state is Dictionary and not bool(state.get("ok", false)):
		_append_gm_output(String(state.get("message", "太阳预览失败")), true)
		return
	if _gm_tod_sun_pad != null and state is Dictionary and not active:
		_gm_tod_sun_pad.apply_runtime_state(state)


func _get_gm_toggle_state(toggle_id: String) -> Dictionary:
	if toggle_id == "diagnostics.perf_hud":
		return _gm_local_toggle_getter.call(toggle_id) if _gm_local_toggle_getter.is_valid() else {
			"ok": false, "message": "本地开关不可用"}
	return _main.call("get_gm_toggle_state", toggle_id) \
		if _main != null and _main.has_method("get_gm_toggle_state") else {"ok": false}


func _on_gm_toggle_changed(enabled: bool, toggle_id: String) -> void:
	if _suppress_sync_signals:
		return
	var result: Dictionary
	if toggle_id == "diagnostics.perf_hud":
		result = _gm_local_toggle_setter.call(toggle_id, enabled) \
			if _gm_local_toggle_setter.is_valid() else {"ok": false, "message": "本地开关不可用"}
	else:
		result = _main.call("set_gm_toggle", toggle_id, enabled) \
			if _main != null and _main.has_method("set_gm_toggle") else {"ok": false}
	_append_gm_output(String(result.get("message", "开关已更新" if result.get("ok", false) else "开关更新失败")),
		not bool(result.get("ok", false)))
	_refresh_gm_toggles()


func _on_gm_command_text_changed(line: String) -> void:
	if _gm_suggestions == null:
		return
	_gm_suggestions.clear()
	var commands: Array = _gm_capabilities.get("commands", [])
	for suggestion in GMPanelViewModel.command_suggestions(line, commands):
		_gm_suggestions.add_item(suggestion)
	_gm_suggestions.visible = _gm_suggestions.item_count > 0 and line.strip_edges() != ""


func _on_gm_suggestion_selected(index: int) -> void:
	if _gm_command_input == null or _gm_suggestions == null:
		return
	var suggestion := _gm_suggestions.get_item_text(index)
	var line := _gm_command_input.text
	var split_at := line.rfind(" ")
	_gm_command_input.text = suggestion if split_at < 0 else line.substr(0, split_at + 1) + suggestion
	_gm_command_input.caret_column = _gm_command_input.text.length()
	_gm_command_input.grab_focus()
	_on_gm_command_text_changed(_gm_command_input.text)


func _on_gm_command_input_event(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo or _gm_history.is_empty():
		return
	if event.keycode == KEY_UP:
		_gm_history_cursor = maxi(_gm_history_cursor - 1, 0)
	elif event.keycode == KEY_DOWN:
		_gm_history_cursor = mini(_gm_history_cursor + 1, _gm_history.size())
	else:
		return
	_gm_command_input.text = "" if _gm_history_cursor >= _gm_history.size() else \
		GMPanelViewModel.history_entry(_gm_history, _gm_history_cursor)
	_gm_command_input.caret_column = _gm_command_input.text.length()
	get_viewport().set_input_as_handled()


func _submit_gm_command() -> void:
	var line := _gm_command_input.text.strip_edges() if _gm_command_input != null else ""
	if line == "clear":
		_gm_output_lines.clear()
		_gm_command_output.text = ""
		_gm_command_input.clear()
		return
	if line == "help":
		var usages := PackedStringArray(["可用指令："])
		for command in _gm_capabilities.get("commands", []):
			usages.append("  " + GMPanelViewModel.describe_command(command))
		_append_gm_output("\n".join(usages), false)
		_gm_command_input.clear()
		return
	var checked := GMPanelViewModel.validate_command(
		GMPanelViewModel.parse_command(line), _gm_capabilities.get("commands", []))
	if not bool(checked.get("ok", false)):
		_append_gm_output(String(checked.get("message", "指令解析失败")), true)
		return
	_gm_history = GMPanelViewModel.push_history(_gm_history, line)
	_gm_history_cursor = _gm_history.size()
	_gm_suggestions.visible = false
	var spec: Dictionary = checked.get("spec", {})
	if bool(spec.get("destructive", false)):
		_gm_pending_command = checked
		_gm_confirmation.dialog_text = _format_gm_confirmation(checked)
		_gm_confirmation.popup_centered(Vector2i(500, 260))
	else:
		_execute_gm_checked_command(checked)


func _format_gm_confirmation(checked: Dictionary) -> String:
	var args: Dictionary = checked.get("args", {})
	var lines := PackedStringArray([
		"指令：%s" % checked.get("command_id", ""),
		"参数：",
	])
	var keys := args.keys()
	keys.sort()
	for key in keys:
		lines.append("  %s = %s" % [key, args[key]])
	var day := int(args.get("day", _gm_current_day() + 1))
	lines.append("目标：%s" % ("玩家国库" if checked.get("command_id", "") == "economy.mint_to_treasury"
		else _gm_command_target(args)))
	lines.append("生效日：第 %d 游戏日" % day)
	return "\n".join(lines)


func _gm_command_target(args: Dictionary) -> String:
	for key in ["cell", "country_handle", "cohort_handle", "owner_handle"]:
		if args.has(key):
			return "%s=%s" % [key, args[key]]
	return "当前选中对象"


func _gm_current_day() -> int:
	if _main == null or not _main.has_method("get_gm_snapshot"):
		return -1
	var snapshot: Dictionary = _main.call("get_gm_snapshot", "overview", {})
	return int((snapshot.get("data", {}) as Dictionary).get("clock", {}).get("day_index", -1))


func _execute_pending_gm_command() -> void:
	if _gm_pending_command.is_empty():
		return
	_execute_gm_checked_command(_gm_pending_command)
	_gm_pending_command.clear()


func _execute_gm_checked_command(checked: Dictionary) -> void:
	var result: Dictionary = _main.call("execute_gm_command",
		String(checked.get("command_id", "")), checked.get("args", {})) \
		if _main != null and _main.has_method("execute_gm_command") else {
			"ok": false, "message": "运行时不支持 GM 指令。"}
	_append_gm_output(String(result.get("message", "无返回信息")), not bool(result.get("ok", false)))
	if _gm_command_input != null:
		_gm_command_input.clear()
	_gm_refresh_current_page()


func _on_gm_action_completed(action_id: String, result: Dictionary) -> void:
	if console_mode != ConsoleMode.PLAYER_GM:
		return
	var prefix := "点击接管" if action_id == "country.click_claim_territory" else action_id
	_append_gm_output("%s：%s" % [prefix, String(result.get("message", "无返回信息"))],
		not bool(result.get("ok", false)))


# 性能 / 渲染实验开关：原 F3/F4/F5/F9/F10/F11/F12/L 热键的 UI 等价入口。
# toggle 类用带状态回显的 CheckBox（勾选态 = 该开关当前真值，热键/按钮任意路径改动
# 都会在面板下次同步时回显）；dump_render_profile 是一次性 dump，保留为按钮。
# 每项 = [展示名, main 上的 toggle 方法名, get_debug_toggle_state 的 state key]
const EXPERIMENT_TOGGLES: Array = [
	["性能小窗可见（F4）", "toggle_perf_mini_hud", "perf_mini_hud"],
	["主地形着色器关闭（F9）", "toggle_world_shader_disabled", "world_shader_disabled"],
	["天气层隐藏（F10）", "toggle_weather_layer_visible", "weather_hidden"],
	["冻结热力图每日重绘（F5）", "toggle_overlay_refresh_disabled", "overlay_refresh_disabled"],
	["禁用图集上传（F11）", "toggle_dynamic_visual_atlas_upload", "atlas_upload_disabled"],
	["图集强制 256（否=512，F12，会重绘）", "toggle_atlas_resolution", "atlas_quarter_size"],
	["诊断日志（L）", "toggle_diagnostic_logging_debug", "diagnostic_logging"],
]


func _add_action_button(parent: VBoxContainer, text: String, method: StringName, args: Array = []) -> void:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size.y = 34.0
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.pressed.connect(func() -> void: _call_main_action(method, args))
	parent.add_child(btn)


func _call_main_action(method: StringName, args: Array = []) -> void:
	if _main == null or not _main.has_method(method):
		push_warning("[DebugConsole] main action missing: %s" % String(method))
		return
	_main.callv(method, args)


func _on_visibility_changed() -> void:
	if console_mode == ConsoleMode.PLAYER_GM:
		if visible:
			_gm_refresh_current_page()
			if _telemetry_timer != null:
				_telemetry_timer.start()
		elif _telemetry_timer != null:
			_telemetry_timer.stop()
		return
	if visible:
		_state_sync_dirty = true
		_sync_state_if_dirty()
		_on_telemetry_tick()

		if _telemetry_timer != null:
			_telemetry_timer.start()
	else:
		if _telemetry_timer != null:
			_telemetry_timer.stop()
	if _main != null and _main.has_method("set_debug_tod_sun_handle_visible"):
		_main.call("set_debug_tod_sun_handle_visible", visible)
