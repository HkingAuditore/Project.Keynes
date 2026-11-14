extends RefCounted

## Display helpers borrow the host per call; state and signal receivers stay there.


static func _build_player_gm_ui(host) -> void:
	host.theme_type_variation = &"PKPanel"
	var margin = UIControlParts.margin_container()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_MD)
	margin.add_theme_constant_override("margin_top", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_MD)
	margin.add_theme_constant_override("margin_bottom", UITokens.SPACE_MD)
	host.add_child(margin)
	var root = UIControlParts.v_box_container()
	root.add_theme_constant_override("separation", UITokens.SPACE_SM)
	margin.add_child(root)

	var header = UIControlParts.h_box_container()
	var title = UIControlParts.label()
	title.text = "GM 管理面板"
	title.add_theme_font_override("font", UITokens.font_with_weight(700))
	title.add_theme_font_size_override("font_size", UITokens.FONT_TITLE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_button = UIControlParts.button()
	close_button.tooltip_text = "关闭 GM 面板"
	close_button.custom_minimum_size = Vector2(34.0, 32.0)
	IconButton.apply(close_button, &"action.close", 15)
	close_button.pressed.connect(host.close_panel)
	header.add_child(close_button)
	root.add_child(header)

	host._gm_tabs = CategoryTabs.new()
	host._gm_tabs.set_tabs(host.GM_TABS, "overview")
	host._gm_tabs.tab_selected.connect(host._on_gm_tab_selected)
	root.add_child(host._gm_tabs)

	var page_stack = UIControlParts.v_box_container()
	page_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(page_stack)
	host._build_gm_data_page(page_stack, "overview")
	host._build_gm_data_page(page_stack, "selected")
	host._build_gm_command_page(page_stack)
	host._build_gm_toggle_page(page_stack)
	host._build_gm_recording_page(page_stack)
	host._show_gm_page("overview")


static func _new_gm_page(host, parent: Control, page_id: String) -> VBoxContainer:
	var page = UIControlParts.v_box_container()
	page.name = page_id.capitalize()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", UITokens.SPACE_SM)
	parent.add_child(page)
	host._gm_pages[page_id] = page
	return page


static func _build_gm_data_page(host, parent: Control, page_id: String) -> void:
	var page = host._new_gm_page(parent, page_id)
	var scroll = UIControlParts.scroll_container()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(scroll)
	var text = UIControlParts.rich_text_label()
	text.bbcode_enabled = false
	text.fit_content = true
	text.scroll_active = false
	text.selection_enabled = true
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_font_size_override("normal_font_size", UITokens.FONT_BODY)
	text.add_theme_color_override("default_color", UITokens.TEXT_MAIN)
	scroll.add_child(text)
	host._gm_data_labels[page_id] = text


static func _build_gm_toggle_page(host, parent: Control) -> void:
	var page = host._new_gm_page(parent, "toggles")
	var hint = UIControlParts.label()
	hint.text = "此页只显示当前运行时状态；打开面板不会应用开关，只有手动点击才会修改。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	page.add_child(hint)
	var scroll = UIControlParts.scroll_container()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(scroll)
	host._gm_toggle_container = UIControlParts.v_box_container()
	host._gm_toggle_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host._gm_toggle_container.add_theme_constant_override("separation", UITokens.SPACE_SM)
	scroll.add_child(host._gm_toggle_container)


static func _add_gm_recorder_row(host, parent: VBoxContainer, recorder_id: String,
		label_text: String, callback: Callable) -> void:
	var row = UIControlParts.h_box_container()
	row.add_theme_constant_override("separation", UITokens.SPACE_SM)
	var button = UIControlParts.button()
	button.tooltip_text = "开始或停止%s记录" % label_text
	button.custom_minimum_size = Vector2(38.0, 34.0)
	IconButton.apply(button, &"action.history", 15)
	button.pressed.connect(host._on_gm_recorder_pressed.bind(recorder_id, callback, button))
	row.add_child(button)
	var status = UIControlParts.label()
	status.text = "%s · 已停止" % label_text
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(status)
	parent.add_child(row)
	host._gm_record_status_labels[recorder_id] = status
	match recorder_id:
		"performance": host._record_btn = button
		"tiles": host._tile_record_btn = button
		"economy": host._economy_record_btn = button


static func _rebuild_gm_toggle_controls(host, toggles: Array) -> void:
	if host._gm_toggle_container == null:
		return
	for child in host._gm_toggle_container.get_children():
		host._gm_toggle_container.remove_child(child)
		child.queue_free()
	host._gm_toggle_buttons.clear()
	host._gm_action_buttons.clear()
	host._gm_tod_sun_pad = host.GmTodSunPadScript.new()
	host._gm_tod_sun_pad.sun_preview_requested.connect(host._on_gm_tod_sun_preview_requested)
	host._gm_toggle_container.add_child(host._gm_tod_sun_pad)
	host._sync_gm_tod_sun_pad()
	var last_group = ""
	for raw in toggles:
		var spec: Dictionary = raw
		var group = String(spec.get("group", "其他"))
		if group != last_group:
			var header = host._make_section_header(group)
			host._gm_toggle_container.add_child(header)
			last_group = group
		var control_kind = String(spec.get("kind", "toggle"))
		if control_kind == "button":
			host._add_gm_capability_action_row(spec)
			continue
		var toggle = UIControlParts.check_box()
		var toggle_id = String(spec.get("id", ""))
		toggle.text = String(spec.get("label", toggle_id))
		toggle.toggled.connect(host._on_gm_toggle_changed.bind(toggle_id))
		host._gm_toggle_container.add_child(toggle)
		host._gm_toggle_buttons[toggle_id] = toggle


static func _add_gm_capability_action_row(host, spec: Dictionary) -> void:
	var action_id = String(spec.get("id", ""))
	var row = UIControlParts.h_box_container()
	row.add_theme_constant_override("separation", UITokens.SPACE_SM)
	var button = UIControlParts.button()
	button.custom_minimum_size = Vector2(38.0, 34.0)
	button.tooltip_text = String(spec.get("tooltip", spec.get("label", action_id)))
	IconButton.apply(button, StringName(spec.get("icon", &"summary.overview")), 15)
	button.pressed.connect(host._on_gm_capability_action_pressed.bind(action_id))
	row.add_child(button)
	var label = UIControlParts.label()
	label.text = String(spec.get("label", action_id))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(label)
	host._gm_toggle_container.add_child(row)
	host._gm_action_buttons[action_id] = button


static func _add_gm_atlas_probe_recorder_row(host, parent: Control) -> void:
	var row = UIControlParts.h_box_container()
	var button = UIControlParts.button()
	button.tooltip_text = "开始录制；再次点击时停止并导出 Atlas 河谷采样 CSV"
	button.custom_minimum_size = Vector2(38.0, 34.0)
	IconButton.apply(button, &"action.history", 15)
	button.pressed.connect(host._on_gm_atlas_river_probe_record_pressed)
	row.add_child(button)
	var label = UIControlParts.label()
	label.text = "Atlas 河谷采样 · 已停止"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	parent.add_child(row)
	host._atlas_river_probe_dump_btn = button
	host._atlas_river_probe_status_label = label


static func _build_overlay_group(host, parent: VBoxContainer) -> void:
	var section = host._make_section_header("Overlay（数据热力图）")
	parent.add_child(section)

	# Overlay 错误提示（shader 加载失败 / bake 报错时显示）
	host._overlay_error_label = UIControlParts.label()
	host._overlay_error_label.add_theme_color_override("font_color", Color(0.95, 0.35, 0.30))
	host._overlay_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	host._overlay_error_label.visible = false
	parent.add_child(host._overlay_error_label)

	var row_mode = UIControlParts.h_box_container()
	var mode_label = UIControlParts.label()
	mode_label.text = "通道："
	mode_label.custom_minimum_size.x = 70.0
	row_mode.add_child(mode_label)
	host._overlay_option_btn = UIControlParts.option_button()
	host._overlay_option_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 现在恒定注入所有 ordered_modes，防御交给 main._apply_overlay_mode：开关关闭
	# 时仍选中 demo channel 会被运行时回退到 NONE 并 push_warning。
	for mode in OverlayMode.ordered_modes():
		host._overlay_option_btn.add_item(OverlayMode.display_name(mode), mode)
	host._overlay_option_btn.item_selected.connect(host._on_overlay_option_selected)
	row_mode.add_child(host._overlay_option_btn)
	parent.add_child(row_mode)

	var row_alpha = UIControlParts.h_box_container()
	host._overlay_alpha_label = UIControlParts.label()
	host._overlay_alpha_label.text = "透明度 0.70"
	host._overlay_alpha_label.custom_minimum_size.x = 110.0
	row_alpha.add_child(host._overlay_alpha_label)
	host._overlay_alpha_slider = UIControlParts.h_slider()
	host._overlay_alpha_slider.min_value = 0.0
	host._overlay_alpha_slider.max_value = 1.0
	host._overlay_alpha_slider.step = 0.01
	host._overlay_alpha_slider.value = 0.7
	host._overlay_alpha_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host._overlay_alpha_slider.value_changed.connect(host._on_overlay_alpha_changed)
	row_alpha.add_child(host._overlay_alpha_slider)
	parent.add_child(row_alpha)


static func _build_sim_group(host, parent: VBoxContainer) -> void:
	parent.add_child(host._make_section_header("模拟开关（F8 等价，真日射常开）"))
	for entry in host.SIM_SWITCHES:
		var field: String = entry[0]
		var label_text: String = entry[1]
		var cb = UIControlParts.check_box()
		cb.text = label_text
		cb.toggled.connect(host._on_sim_switch_toggled.bind(field))
		parent.add_child(cb)
		host._sim_checkboxes[field] = cb


static func _build_visual_group(host, parent: VBoxContainer) -> void:
	parent.add_child(host._make_section_header("视觉开关"))
	for entry in host.VISUAL_SWITCHES:
		var field: String = entry[0]
		var label_text: String = entry[1]
		var setter: String = entry[2]
		var cb = UIControlParts.check_box()
		cb.text = label_text
		cb.toggled.connect(host._on_visual_switch_toggled.bind(field, setter))
		parent.add_child(cb)
		host._visual_checkboxes[field] = cb


static func _build_tod_group(host, parent: VBoxContainer) -> void:
	parent.add_child(host._make_section_header("TOD 调试"))
	host._tod_mode_label = UIControlParts.label()
	host._tod_mode_label.text = "模式：—"
	parent.add_child(host._tod_mode_label)

	var row_angle = UIControlParts.h_box_container()
	host._tod_light_angle_label = UIControlParts.label()
	host._tod_light_angle_label.text = "光线方位 -60°"
	host._tod_light_angle_label.custom_minimum_size.x = 118.0
	row_angle.add_child(host._tod_light_angle_label)
	host._tod_light_angle_slider = UIControlParts.h_slider()
	host._tod_light_angle_slider.min_value = -180.0
	host._tod_light_angle_slider.max_value = 180.0
	host._tod_light_angle_slider.step = 1.0
	host._tod_light_angle_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host._tod_light_angle_slider.value_changed.connect(host._on_tod_light_angle_changed)
	row_angle.add_child(host._tod_light_angle_slider)
	parent.add_child(row_angle)

	var row_elevation = UIControlParts.h_box_container()
	host._tod_light_elevation_label = UIControlParts.label()
	host._tod_light_elevation_label.text = "光线高度 37°"
	host._tod_light_elevation_label.custom_minimum_size.x = 118.0
	row_elevation.add_child(host._tod_light_elevation_label)
	host._tod_light_elevation_slider = UIControlParts.h_slider()
	host._tod_light_elevation_slider.min_value = 8.0
	host._tod_light_elevation_slider.max_value = 85.0
	host._tod_light_elevation_slider.step = 1.0
	host._tod_light_elevation_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host._tod_light_elevation_slider.value_changed.connect(host._on_tod_light_elevation_changed)
	row_elevation.add_child(host._tod_light_elevation_slider)
	parent.add_child(row_elevation)

	host._tod_sun_position_label = UIControlParts.label()
	host._tod_sun_position_label.text = "太阳位置：拖动地图上的太阳按钮"
	host._tod_sun_position_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(host._tod_sun_position_label)

	var row_height = UIControlParts.h_box_container()
	host._tod_sun_height_scale_label = UIControlParts.label()
	host._tod_sun_height_scale_label.text = "太阳高度 x1.00"
	host._tod_sun_height_scale_label.custom_minimum_size.x = 118.0
	row_height.add_child(host._tod_sun_height_scale_label)
	host._tod_sun_height_scale_slider = UIControlParts.h_slider()
	host._tod_sun_height_scale_slider.min_value = 0.2
	host._tod_sun_height_scale_slider.max_value = 1.5
	host._tod_sun_height_scale_slider.step = 0.01
	host._tod_sun_height_scale_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host._tod_sun_height_scale_slider.value_changed.connect(host._on_tod_sun_height_scale_changed)
	row_height.add_child(host._tod_sun_height_scale_slider)
	parent.add_child(row_height)


static func _build_diagnose_group(host, parent: VBoxContainer) -> void:
	parent.add_child(host._make_section_header("移动端调试动作"))
	host._add_action_button(parent, "重新生成地图（R）", &"regenerate_debug_map")
	host._add_action_button(parent, "适配视口（F）", &"fit_debug_map")
	host._add_action_button(parent, "切换涌现耦合（F8）", &"toggle_emergent_debug_switches")
	host._add_action_button(parent, "切换洋流高对比（F6）", &"toggle_ocean_current_debug")

	parent.add_child(host._make_section_header("诊断打印"))
	var btn_ocean = UIControlParts.button()
	btn_ocean.text = "打印洋流热输运摘要（F7）"
	btn_ocean.custom_minimum_size.y = 34.0
	btn_ocean.pressed.connect(host._on_btn_diagnose_ocean)
	parent.add_child(btn_ocean)

	var btn_temp = UIControlParts.button()
	btn_temp.text = "打印选中地块温度分解"
	btn_temp.custom_minimum_size.y = 34.0
	btn_temp.pressed.connect(host._on_btn_diagnose_temperature)
	parent.add_child(btn_temp)

	host._add_action_button(parent, "打印数据标志（F11）", &"print_data_core_flags_debug")
	host._add_action_button(parent, "打印天气校验快照（F12）", &"print_validate_weather_snapshot_debug")
	host._add_action_button(parent, "打印性能结论", &"print_perf_verdict_debug")
	host._add_action_button(parent, "切换材质贴图门禁视图（绿=激活）", &"toggle_terrain_material_gate_debug")

	parent.add_child(host._make_section_header("数据与压测"))
	host._add_action_button(parent, "切换天气数据（F9）", &"toggle_data_core_weather_debug")
	host._add_action_button(parent, "切换总数据开关（F10）", &"toggle_data_core_master_debug")
	host._add_action_button(parent, "启动 30 帧压测导出（F2）", &"start_soak_dump_debug")
	host._add_action_button(parent, "启动同源对照 30 帧（F3）", &"start_soak_ab_same_source_debug")
	host._add_action_button(parent, "启动旧版对照（Shift+F3）", &"start_soak_ab_vs_legacy_debug")
	host._add_action_button(parent, "线程对照矩阵（30+1000 帧）", &"start_soak_ab_thread_batch_debug")
	host._add_action_button(parent, "取消压测 / 导出（Alt+F3）", &"cancel_soak_debug")

	parent.add_child(host._make_section_header("选择"))
	var btn_clear = UIControlParts.button()
	btn_clear.text = "清空当前选中"
	btn_clear.custom_minimum_size.y = 34.0
	btn_clear.pressed.connect(host._on_btn_clear_selection)
	parent.add_child(btn_clear)


static func _build_experiments_group(host, parent: VBoxContainer) -> void:
	parent.add_child(host._make_section_header("性能 / 渲染实验（原 60FPS 调查热键）"))
	host._add_action_button(parent, "导出渲染性能监视器（F3）", &"dump_render_profile")
	host._add_action_button(parent, "循环天气调试视图", &"cycle_weather_debug_view")
	for entry in host.EXPERIMENT_TOGGLES:
		var label_text: String = entry[0]
		var method: String = entry[1]
		var key: String = entry[2]
		var cb = UIControlParts.check_box()
		cb.text = label_text
		cb.toggled.connect(host._on_experiment_toggle.bind(method, key))
		parent.add_child(cb)
		host._toggle_checkboxes[key] = cb


static func _build_migration_group(host, parent: VBoxContainer) -> void:
	parent.add_child(host._make_section_header("生成迁移验收"))
	host._add_action_button(parent, "异步气候基准 · 蒸腾（B）", &"run_async_climate_bench_debug", ["transp"])
	host._add_action_button(parent, "异步气候基准 · A 组（V）", &"run_async_climate_bench_debug", ["pass_a"])


static func _build_telemetry_group(host, parent: VBoxContainer) -> void:
	parent.add_child(host._make_section_header("实时监视（Telemetry）"))

	# 2026-05-19：Telemetry 控制条 ── 暂停 / 快照导出
	# 暂停：冻结所有 telemetry label 的刷新，方便观察某一帧的精确数据
	# 快照：把当前 SUS report + 30-tick 窗口统计 dump 成 res://tmp/perf_snapshot_*.json
	var ctrl_row = UIControlParts.h_box_container()
	ctrl_row.add_theme_constant_override("separation", 6)
	host._pause_btn = UIControlParts.button()
	IconButton.apply_with_text(host._pause_btn, (&"action.play" if host._telemetry_paused else &"action.pause"), host._gm_sanitize_legacy_status("⏸ 暂停刷新"), 14)
	host._pause_btn.tooltip_text = "暂停后性能文本冻结，方便复制/截图当前快照"
	host._pause_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host._pause_btn.pressed.connect(host._on_btn_toggle_pause)
	ctrl_row.add_child(host._pause_btn)
	host._snapshot_btn = UIControlParts.button()
	IconButton.apply_with_text(host._snapshot_btn, &"action.save", host._gm_sanitize_legacy_status("📸 快照→文件"), 14)
	host._snapshot_btn.tooltip_text = "导出当前性能记录到文件"
	host._snapshot_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host._snapshot_btn.pressed.connect(host._on_btn_snapshot)
	ctrl_row.add_child(host._snapshot_btn)
	# 录制按钮：再次点击触发 stop_and_export，CSV 桌面落盘到 ../../tmp，
	# mobile 落盘到 user://perf，避免 Android APK 资源目录不可写。
	host._record_btn = UIControlParts.button()
	IconButton.apply_with_text(host._record_btn, &"action.history", host._gm_sanitize_legacy_status("⏺ 开始录制"), 14)
	host._record_btn.tooltip_text = "录制每帧核心耗时；完整分项仅低频采样 → 桌面 ../../tmp；手机 user://perf"
	host._record_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host._record_btn.pressed.connect(host._on_btn_toggle_record)
	ctrl_row.add_child(host._record_btn)
	parent.add_child(ctrl_row)

	var tile_ctrl_row = UIControlParts.h_box_container()
	tile_ctrl_row.add_theme_constant_override("separation", 6)
	host._tile_record_btn = UIControlParts.button()
	IconButton.apply_with_text(host._tile_record_btn, &"action.history", host._gm_sanitize_legacy_status("⏺ 开始地块全量录制"), 14)
	host._tile_record_btn.tooltip_text = "录制每帧、每个地块的所有可用字段；会同步写入大型 CSV → 桌面 ../../tmp；手机 user://tile_data"
	host._tile_record_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host._tile_record_btn.pressed.connect(host._on_btn_toggle_tile_record)
	tile_ctrl_row.add_child(host._tile_record_btn)
	parent.add_child(tile_ctrl_row)

	# 经济数据录制：每个经济 epoch（5 天提交）写一组 CSV，维度可独立开关。
	var econ_dims: Array = [
		["summary", "汇总"], ["cohorts", "阶层"], ["buildings", "建筑"],
		["resources", "自然资源"], ["market", "物资"],
	]
	var econ_chk_row = UIControlParts.h_box_container()
	econ_chk_row.add_theme_constant_override("separation", 10)
	host._economy_record_checkboxes.clear()
	for dim_pair in econ_dims:
		var dim_key: String = dim_pair[0]
		var dim_label: String = dim_pair[1]
		var chk = UIControlParts.check_box()
		chk.text = dim_label
		chk.button_pressed = true
		chk.tooltip_text = "录制维度开关：%s" % dim_key
		chk.pressed.connect(host._on_economy_dim_toggled.bind(dim_key, chk))
		host._economy_record_checkboxes[dim_key] = chk
		econ_chk_row.add_child(chk)
	parent.add_child(econ_chk_row)

	var econ_scope_row = UIControlParts.h_box_container()
	econ_scope_row.add_theme_constant_override("separation", 6)
	host._economy_current_cell_checkbox = UIControlParts.check_box()
	host._economy_current_cell_checkbox.text = "仅录制当前地块"
	host._economy_current_cell_checkbox.tooltip_text = \
		"开始时锁定当前选中地块；汇总表仍是全局，其余四表只写该地块"
	host._economy_current_cell_checkbox.pressed.connect(host._on_economy_scope_toggled)
	econ_scope_row.add_child(host._economy_current_cell_checkbox)
	parent.add_child(econ_scope_row)

	var econ_ctrl_row = UIControlParts.h_box_container()
	econ_ctrl_row.add_theme_constant_override("separation", 6)
	host._economy_record_btn = UIControlParts.button()
	IconButton.apply_with_text(host._economy_record_btn, &"action.history", host._gm_sanitize_legacy_status("⏺ 开始经济录制"), 14)
	host._economy_record_btn.tooltip_text = "每个经济 epoch 写一组 CSV（汇总/阶层/建筑/自然资源/物资，按上方开关）→ 桌面 ../../tmp；手机 user://economy_data"
	host._economy_record_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host._economy_record_btn.pressed.connect(host._on_btn_toggle_economy_record)
	econ_ctrl_row.add_child(host._economy_record_btn)
	parent.add_child(econ_ctrl_row)

	host._telemetry_vbox = UIControlParts.v_box_container()
	host._telemetry_vbox.add_theme_constant_override("separation", 4)
	parent.add_child(host._telemetry_vbox)
	# 预注册常用 Label
	host._add_telemetry_label("fast_tick", "fast_tick #0: 0ms")
	host._add_telemetry_label("sus_summary", "SUS: —")
	host._add_telemetry_label("sus_largest", "largest: —")
	host._add_telemetry_label("sus_jobs", "jobs: —")
	host._add_telemetry_label("sim_breakdowns", "breakdown: —")

	# 2026-05-19：30-tick 滚动窗口 Top-N（按 max_ms 降序，看长期热点）
	# 比 sus_jobs 的 last-tick 视图更稳定，能识别"偶发慢 job"和"持续慢 job"
	host._add_telemetry_label("sus_topn", "top by max_ms (window): —")

	host._add_telemetry_label("overlay_bake", "overlay bake: — ms")
	host._add_telemetry_label("overlay_stats", "overlay stats: —")
	host._add_telemetry_label("overlay_invalid", "invalid cells: 0")
	host._add_telemetry_label("overlay_buckets", "")


static func _add_telemetry_label(host, key: String, initial: String) -> void:
	var lb = UIControlParts.label()
	lb.text = initial
	lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	host._telemetry_vbox.add_child(lb)
	host._telemetry_labels[key] = lb


static func _make_section_header(host, text: String) -> Label:
	var lb = UIControlParts.label()
	lb.text = text
	lb.add_theme_font_size_override("font_size", 14)
	lb.add_theme_color_override("font_color", Color(0.78, 0.86, 1.00))
	return lb


static func _refresh_from_state(host) -> void:
	host._suppress_sync_signals = true

	if host.runtime_diagnostics_only:
		host._suppress_sync_signals = false
		return

	# Overlay mode
	if host._main != null and host._main.has_method("get_overlay_mode"):
		var cur_mode: int = int(host._main.call("get_overlay_mode"))
		# OptionButton item_id = mode
		for i in range(host._overlay_option_btn.item_count):
			if host._overlay_option_btn.get_item_id(i) == cur_mode:
				if host._overlay_option_btn.selected != i:
					host._overlay_option_btn.select(i)
				break

	# Overlay alpha
	if host._main != null and host._main.has_method("get_overlay_alpha"):
		var a: float = float(host._main.call("get_overlay_alpha"))
		if not is_equal_approx(float(host._overlay_alpha_slider.value), a):
			host._overlay_alpha_slider.value = a
		var alpha_text = "透明度 %.2f" % a
		if host._overlay_alpha_label.text != alpha_text:
			host._overlay_alpha_label.text = alpha_text


	host._refresh_overlay_error_line()

	# 模拟开关：读 ClimateProfile 真值
	var gen = host._get_generator()
	var cp = gen._c() if gen != null and gen.has_method("_c") else null
	for entry in host.SIM_SWITCHES:
		var field: String = entry[0]
		var cb: CheckBox = host._sim_checkboxes.get(field, null)
		if cb == null:
			continue
		if cp == null:
			if not cb.disabled:
				cb.disabled = true
		else:
			if cb.disabled:
				cb.disabled = false
			var pressed = bool(cp.get(field))
			if cb.button_pressed != pressed:
				cb.button_pressed = pressed


	# 视觉开关：从 main.gd 的 @export 字段直接读；ocean_current_debug 特殊——
	# renderer.get_ocean_current_debug() 才是权威真值（F6 可能绕过 main 修改）。
	var renderer = host._get_renderer()
	for entry in host.VISUAL_SWITCHES:
		var field: String = entry[0]
		var cb: CheckBox = host._visual_checkboxes.get(field, null)
		if cb == null:
			continue
		var val: bool = false
		if field == "ocean_current_debug" and renderer != null and renderer.has_method("get_ocean_current_debug"):
			val = bool(renderer.get_ocean_current_debug())
		elif host._main != null:
			val = bool(host._main.get(field))
		if cb.button_pressed != val:
			cb.button_pressed = val

	host._refresh_tod_controls()

	# 性能 / 渲染实验 toggle：从 main.get_debug_toggle_state 读回真值回显
	if host._main != null and host._main.has_method("get_debug_toggle_state"):
		for key in host._toggle_checkboxes.keys():
			var tcb: CheckBox = host._toggle_checkboxes.get(key, null)
			if tcb == null:
				continue
			var truth: bool = bool(host._main.call("get_debug_toggle_state", key))
			if tcb.button_pressed != truth:
				tcb.button_pressed = truth

	# 未生成地图：置灰诊断动作相关（通过比对 get_current_map() 是否为 null）
	var has_map: bool = host._main != null \
		and host._main.has_method("get_current_map") \
		and host._main.call("get_current_map") != null
	# OptionButton/滑条允许切换（切到 NONE 无害），但诊断按钮需要 map
	# 这里通过 tooltip 提示而不强制禁用——避免打开控制台时一片灰色看不清

	host._suppress_sync_signals = false


static func _refresh_tod_controls(host) -> void:
	if host._tod_mode_label == null:
		return
	var day_night: bool = false
	if host._main != null:
		day_night = bool(host._main.get("day_night_enabled"))
	host._tod_mode_label.text = "模式：%s" % ("昼夜太阳位置" if day_night else "永昼光线角度")

	var angle: float = 0.0
	if host._main != null and host._main.has_method("get_debug_tod_light_angle_deg"):
		angle = float(host._main.call("get_debug_tod_light_angle_deg"))
	if host._tod_light_angle_slider != null and not is_equal_approx(float(host._tod_light_angle_slider.value), angle):
		host._tod_light_angle_slider.value = angle
	if host._tod_light_angle_label != null:
		host._tod_light_angle_label.text = "光线方位 %d°" % int(round(angle))

	var elevation: float = 0.0
	if host._main != null and host._main.has_method("get_debug_tod_light_elevation_deg"):
		elevation = float(host._main.call("get_debug_tod_light_elevation_deg"))
	if host._tod_light_elevation_slider != null and not is_equal_approx(float(host._tod_light_elevation_slider.value), elevation):
		host._tod_light_elevation_slider.value = elevation
	if host._tod_light_elevation_label != null:
		host._tod_light_elevation_label.text = "光线高度 %d°" % int(round(elevation))

	if host._tod_sun_position_label != null:
		if day_night:
			var sun_uv = Vector2(0.25, 0.5)
			if host._main != null and host._main.has_method("get_debug_tod_sun_uv"):
				sun_uv = host._main.call("get_debug_tod_sun_uv")
			host._tod_sun_position_label.text = host._format_tod_sun_uv(sun_uv)
		else:
			host._tod_sun_position_label.text = "太阳位置：启用昼夜后可拖动地图上的太阳按钮"

	var height_scale: float = 1.0
	if host._main != null and host._main.has_method("get_debug_tod_sun_height_scale"):
		height_scale = float(host._main.call("get_debug_tod_sun_height_scale"))
	if host._tod_sun_height_scale_slider != null and not is_equal_approx(float(host._tod_sun_height_scale_slider.value), height_scale):
		host._tod_sun_height_scale_slider.value = height_scale
	if host._tod_sun_height_scale_label != null:
		host._tod_sun_height_scale_label.text = "太阳高度 x%.2f" % height_scale

	if host._tod_light_angle_slider != null:
		host._tod_light_angle_slider.editable = not day_night
	if host._tod_light_elevation_slider != null:
		host._tod_light_elevation_slider.editable = not day_night
	if host._tod_sun_height_scale_slider != null:
		host._tod_sun_height_scale_slider.editable = day_night
	if host._main != null and host._main.has_method("set_debug_tod_sun_handle_visible"):
		host._main.call("set_debug_tod_sun_handle_visible", host.visible and day_night)


static func _refresh_overlay_error_line(host) -> void:
	if host._overlay_error_label == null:
		return
	var msg: String = ""
	if host._main != null and host._main.has_method("get_overlay_error_msg"):
		msg = str(host._main.call("get_overlay_error_msg"))
	if msg == "":
		host._overlay_error_label.visible = false
		host._overlay_error_label.text = ""
	else:
		host._overlay_error_label.visible = true
		host._overlay_error_label.text = "图层已停用：%s" % msg


static func _refresh_sim_perf_lines(host) -> void:
	var summary: Dictionary = {}

	if host._main.has_method("get_sus_last_tick_summary"):
		var raw_summary = host._main.call("get_sus_last_tick_summary")
		if raw_summary is Dictionary:
			summary = raw_summary
	if summary.is_empty():
		host._set_tele("sus_summary", "SUS: —")
		host._set_tele("sus_largest", "largest: —")
	else:
		host._set_tele("sus_summary", "SUS tick=%s source=%s total=%.2fms jobs=%d/%d slices=%d p95=%.2fms" % [
			str(summary.get("tick_index", "—")),
			str(summary.get("source", "—")),
			float(summary.get("total_ms", 0.0)),
			int(summary.get("jobs_ran", 0)),
			int(summary.get("jobs_skipped", 0)),
			int(summary.get("slices_total", 0)),
			float(summary.get("sus_sim_p95_300", 0.0)),
		])
		host._set_tele("sus_largest", "largest: %s %.2fms stage=%s/%s path=%s" % [
			str(summary.get("largest_slice_job", "—")),
			float(summary.get("largest_slice_ms", 0.0)),
			str(summary.get("largest_slice_stage", "")),
			str(summary.get("largest_slice_substage", "")),
			str(summary.get("largest_slice_path", "")),
		])

	host._perf_detail_tick += 1
	if host._perf_detail_tick % 2 != 1:
		return

	var report: Dictionary = {}
	if host._main.has_method("get_sus_last_tick_report"):
		var raw_report = host._main.call("get_sus_last_tick_report")
		if raw_report is Dictionary:
			report = raw_report
	host._set_tele("sus_jobs", host._format_sus_jobs(report))

	var breakdowns: Dictionary = {}
	if host._main.has_method("get_sim_breakdowns"):
		var raw_breakdowns = host._main.call("get_sim_breakdowns")
		if raw_breakdowns is Dictionary:
			breakdowns = raw_breakdowns
	host._set_tele("sim_breakdowns", host._format_sim_breakdowns(breakdowns))

	# 2026-05-19：30-tick 滚动窗口 Top-N。比 last-tick 列表更稳定，
	# 能识别"持续慢 Job"vs"偶发慢 Job"，是性能调优的主要参考视图。
	host._set_tele("sus_topn", host._format_topn_jobs())
	# 录制中按钮文案随帧数刷新（"⏹ 停止并导出（已录 N 帧）"），
	# 复用 _telemetry_timer，不新建 Timer。
	host._refresh_record_btn_text()
	host._refresh_tile_record_btn_text()
	host._refresh_economy_record_btn_text()


static func _format_buckets(host, mode: int, buckets: Dictionary) -> String:
	if buckets == null or buckets.is_empty():
		return ""
	var parts: PackedStringArray = PackedStringArray()
	var keys: Array = buckets.keys()
	keys.sort()
	for k in keys:
		var bname: String = ""
		if mode == OverlayMode.MODE.CLIMATE_ZONE:
			var idx: int = clampi(int(k), 0, OverlayMode.CLIMATE_ZONE_NAMES.size() - 1)
			bname = OverlayMode.CLIMATE_ZONE_NAMES[idx]
		elif mode == OverlayMode.MODE.WEATHER:
			var widx: int = clampi(int(k), 0, OverlayMode.WEATHER_NAMES.size() - 1)
			bname = OverlayMode.WEATHER_NAMES[widx]
		elif mode == OverlayMode.MODE.BIOME_GROUP:
			var bidx: int = clampi(int(k), 0, OverlayMode.BIOME_GROUP_NAMES.size() - 1)
			bname = OverlayMode.BIOME_GROUP_NAMES[bidx]
		elif mode == OverlayMode.MODE.LANDFORM:
			var lidx: int = clampi(int(k), 0, OverlayMode.LANDFORM_NAMES.size() - 1)
			bname = OverlayMode.LANDFORM_NAMES[lidx]
		else:
			bname = str(k)
		parts.append("%s %d" % [bname, int(buckets[k])])
	return " / ".join(parts)


static func _set_tele(host, key: String, text: String) -> void:
	var lb: Label = host._telemetry_labels.get(key, null)
	if lb == null:
		return
	if lb.text != text:
		lb.text = text
	var want_visible = text != ""
	if lb.visible != want_visible:
		lb.visible = want_visible
