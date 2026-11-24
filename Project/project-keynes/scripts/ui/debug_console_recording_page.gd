extends RefCounted


static func _build_gm_recording_page(host, parent: Control) -> void:
	var page: VBoxContainer = host._new_gm_page(parent, "recording")
	var hint := UIControlParts.label()
	hint.text = "记录器沿用现有 CSV 导出路径；再次点击对应按钮停止并导出。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	page.add_child(hint)
	host._add_gm_recorder_row(page, "performance", "性能采样", host._on_btn_toggle_record)
	host._add_gm_recorder_row(page, "tiles", "地块全量", host._on_btn_toggle_tile_record)

	var dims := UIControlParts.h_box_container()
	dims.add_theme_constant_override("separation", UITokens.SPACE_SM)
	host._economy_record_checkboxes.clear()
	for pair in [["summary", "汇总"], ["cohorts", "阶层"], ["buildings", "建筑"],
			["resources", "资源"], ["market", "市场"]]:
		var checkbox := UIControlParts.check_box()
		checkbox.text = String(pair[1])
		checkbox.button_pressed = true
		checkbox.pressed.connect(host._on_economy_dim_toggled.bind(String(pair[0]), checkbox))
		host._economy_record_checkboxes[String(pair[0])] = checkbox
		dims.add_child(checkbox)
	page.add_child(dims)
	host._economy_current_cell_checkbox = UIControlParts.check_box()
	host._economy_current_cell_checkbox.text = "仅当前地块"
	host._economy_current_cell_checkbox.toggled.connect(func(_pressed: bool) -> void: host._on_economy_scope_toggled())
	page.add_child(host._economy_current_cell_checkbox)
	host._add_gm_recorder_row(page, "economy", "经济周期", host._on_btn_toggle_economy_record)

	var snapshot_row := UIControlParts.h_box_container()
	var snapshot_button := UIControlParts.button()
	snapshot_button.tooltip_text = "导出当前性能快照"
	snapshot_button.custom_minimum_size = Vector2(38.0, 34.0)
	IconButton.apply(snapshot_button, &"action.save", 15)
	snapshot_button.pressed.connect(host._on_gm_snapshot_pressed)
	snapshot_row.add_child(snapshot_button)
	var snapshot_label := UIControlParts.label()
	snapshot_label.text = "导出当前调度与性能快照"
	snapshot_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	snapshot_row.add_child(snapshot_label)
	page.add_child(snapshot_row)
	host._snapshot_btn = snapshot_button

	var profile_row := UIControlParts.h_box_container()
	var profile_button := UIControlParts.button()
	profile_button.tooltip_text = "采样 120 帧的帧墙钟/渲染指标，打印到控制台（编辑器输出面板 / stdout）"
	profile_button.custom_minimum_size = Vector2(38.0, 34.0)
	IconButton.apply(profile_button, &"summary.overview", 15)
	profile_button.pressed.connect(host._on_gm_render_profile_pressed)
	profile_row.add_child(profile_button)
	var profile_label := UIControlParts.label()
	profile_label.text = "Dump 渲染性能监视器（120 帧采样 → 控制台）"
	profile_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	profile_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	profile_row.add_child(profile_label)
	page.add_child(profile_row)

	host._add_gm_atlas_probe_recorder_row(page)

	var log_dir_row := UIControlParts.h_box_container()
	log_dir_row.add_theme_constant_override("separation", UITokens.SPACE_SM)
	var log_dir_button := UIControlParts.button()
	log_dir_button.name = "GMOpenLogDirButton"
	log_dir_button.tooltip_text = "打开日志输出文件夹（%s）" % host._resolve_log_output_dir()
	log_dir_button.custom_minimum_size = Vector2(38.0, 34.0)
	IconButton.apply(log_dir_button, &"action.chevron_right", 15)
	log_dir_button.pressed.connect(host._on_gm_open_log_dir_pressed)
	log_dir_row.add_child(log_dir_button)
	var log_dir_label := UIControlParts.label()
	log_dir_label.text = "打开日志文件夹"
	log_dir_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_dir_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	log_dir_row.add_child(log_dir_label)
	page.add_child(log_dir_row)
	host._open_log_dir_btn = log_dir_button
	host._open_log_dir_label = log_dir_label
