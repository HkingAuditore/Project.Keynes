extends RefCounted

static func _apply_responsive_layout(host) -> void:
	# 移动端：设计像素经 content_scale 换算成 dp（见 scripts/ui/mobile_ui_scaling.gd），
	# 所以这里的 size 已经是**设计像素**，断点阈值可以照旧理解成 1600×960 坐标系。
	# 另外两个只有手机上才会发生的差异要在这里吃掉：
	#   1) 刘海/挖孔安全区（DisplayServer.get_display_safe_area()）；
	#   2) 触摸命中区：短画布上**不能**把按钮做小（桌面 short_h 分支是给矮窗口用的），
	#      移动端反而要把章节按钮抬到 56 设计像素（≈48dp）。
	var touch_ui: Node = host._ui_scaling_node()
	var touch := touch_ui != null and bool(touch_ui.call("is_touch_profile"))
	var insets: Dictionary = host._safe_area_insets(touch_ui)
	var safe_left := float(insets.get("left", 0.0))
	var safe_top := float(insets.get("top", 0.0))
	var safe_right := float(insets.get("right", 0.0))
	var safe_bottom := float(insets.get("bottom", 0.0))
	var narrow: bool = host.size.x < 760.0
	# 「矮而宽」（手机横屏：949×462 这种）不能竖排：竖排会把「国家与开局 / 地图预览」
	# 两张卡片压成一条缝——2220×1080@440dpi 实测左栏只剩 ~40 设计像素高，表单点不到。
	# 竖排只留给「窄且够高」的桌面小窗，行为与改动前一致。
	var compact_spread: bool = host.size.x < 980.0 and host.size.y >= 600.0
	var side_margin := 12 if narrow else (24 if compact_spread else 48)
	var top_margin := 12 if narrow else 28
	var bottom_margin := 38 if narrow else 34
	host._page_margin.add_theme_constant_override("margin_left", side_margin + int(round(safe_left)))
	host._page_margin.add_theme_constant_override("margin_right", side_margin + int(round(safe_right)))
	host._page_margin.add_theme_constant_override("margin_top", top_margin + int(round(safe_top)))
	host._page_margin.add_theme_constant_override("margin_bottom", bottom_margin + int(round(safe_bottom)))
	host._status_label.offset_left = side_margin + safe_left
	host._status_label.offset_right = -(side_margin + safe_right)

	var avail_w := maxf(280.0, host.size.x - float(side_margin * 2) - safe_left - safe_right)
	var avail_h := maxf(320.0, host.size.y - float(top_margin + bottom_margin) - safe_top - safe_bottom)
	if is_instance_valid(host._shader_progress):
		# 左边缘跟页面边距对齐（窄窗口时不会出框）；纵向固定在左下角，
		# 底边比 StatusLabel 的顶边再高一点（-44 vs -34），两行文字不叠。
		var strip_w := minf(host.WEB_PROGRESS_MAX_WIDTH, maxf(host.WEB_PROGRESS_MIN_WIDTH, avail_w))
		host._shader_progress.offset_left = float(side_margin)
		host._shader_progress.offset_right = float(side_margin) + strip_w
	var short_h := avail_h < 450.0
	if host._home_tome_shell != null:
		var shell_w := minf(host.HOME_PANEL_WIDTH, avail_w)
		var shell_h := minf(avail_h - 8.0, clampf(host.size.y * 0.56, 368.0 if short_h else 428.0, 472.0))
		host._home_tome_shell.custom_minimum_size = Vector2(shell_w, shell_h)
		var folio_surface := host._home_tome_shell.get_node_or_null("FolioSurface") as ColorRect
		if folio_surface != null and folio_surface.material is ShaderMaterial:
			var fmat := folio_surface.material as ShaderMaterial
			fmat.set_shader_parameter("panel_size", Vector2(shell_w, shell_h))
			fmat.set_shader_parameter("motion_scale", 0.0 if UIAnimation.reduced_motion() else 1.0)
		var folio_margin := host._home_tome_shell.get_node_or_null("TomeRow/FrontispiecePage/FolioMargin") as MarginContainer
		if folio_margin != null:
			folio_margin.add_theme_constant_override("margin_top", 16 if short_h else 26)
			folio_margin.add_theme_constant_override("margin_bottom", 20 if short_h else 30)
		var folio_col := host._home_tome_shell.get_node_or_null("TomeRow/FrontispiecePage/FolioMargin/Column") as VBoxContainer
		if folio_col != null:
			folio_col.add_theme_constant_override("separation", 6 if short_h else 10)
	if host._home_spine != null:
		host._home_spine.visible = false
	if host._home_hinges != null:
		host._home_hinges.visible = false

	for grid_name in ["PolityGrid", "SourceAndSizeGrid", "DimensionAndSeedGrid"]:
		var grid := host.find_child(grid_name, true, false) as GridContainer
		if grid != null:
			grid.columns = 1 if host.size.x < 920.0 else 2
	if host._layout_cards_row is GridContainer:
		(host._layout_cards_row as GridContainer).columns = 3 if host.size.x < 1080.0 else 5
	# 手机横屏（逻辑高 ~460）时，地图预览卡片的 min height（画布 196 + 标题 + 摘要）
	# 会把整页顶出可视区：页面是 anchors 全铺 + grow=BOTH，溢出会**上下对称**地
	# 顶到屏幕外（实测标题栏被裁掉一半）。这里在「触摸 + 矮」时压缩预览卡片。
	var phone_cramp := touch and avail_h < 520.0
	host._map_preview.get_node("Margin/Column/SummaryGrid").visible = not compact_spread and not phone_cramp
	var preview_canvas_h := 110.0 if phone_cramp else (120.0 if compact_spread else 196.0)
	var preview_map_h := 100.0 if phone_cramp else (120.0 if compact_spread else 182.0)
	host._map_preview.get_node("Margin/Column/CanvasFrame").custom_minimum_size.y = preview_canvas_h
	host._map_preview.get_node("Margin/Column/CanvasFrame/MapCanvas").custom_minimum_size.y = preview_map_h
	host._map_preview.size_flags_vertical = Control.SIZE_SHRINK_BEGIN if (compact_spread or phone_cramp) else Control.SIZE_EXPAND_FILL
	host._right_column.size_flags_vertical = Control.SIZE_SHRINK_BEGIN if compact_spread else Control.SIZE_EXPAND_FILL
	if host._dual_spread != null:
		host._dual_spread.vertical = compact_spread
	if host._right_column != null:
		# 手机上把宽度让给左侧表单（地图预览在 20:9 横屏里本来就压得很扁）。
		var right_ratio := 0.34 if (touch and host.size.x < 1400.0) else 0.48
		host._right_column.custom_minimum_size.x = 0.0 if compact_spread else avail_w * right_ratio
	if host._settings_spread != null:
		host._settings_spread.vertical = compact_spread
	# 大缩放档（125%/150%/200%）把逻辑画布压到 640/480 高，设置页的 ScrollContainer
	# 会被挤到接近 0，表单整块不可见（实测 200% 只剩标题和按钮）。给一个最低高度兜底：
	# 宁可让 Column 溢出到页面外由外层裁切，也不能让玩家看不到选项。
	var settings_scroll := host.get_node_or_null("%SettingsScroll") as ScrollContainer
	if settings_scroll != null:
		settings_scroll.custom_minimum_size.y = 0.0 if compact_spread else 220.0

	var slip_widths: Array[float] = [282.0, 270.0, 260.0, 250.0]
	var slip_heights := PackedFloat32Array([44.0, 42.0, 42.0, 42.0]) if short_h else PackedFloat32Array([52.0, 48.0, 48.0, 48.0])
	# [pc-fit 2026-11-17] 触摸档不再把纸签抬高到 56/54/54/54：那让主菜单按钮比 PC 高 4~6，
	# 且和下方表单的 52 高控件堆在一起，整列高度全变 —— 玩家说的「布局和 PC 对不上」。
	var cmd_idx := 0
	for node in host.get_tree().get_nodes_in_group("main_menu_commands"):
		if node is Button:
			var btn := node as Button
			btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			var target_w: float = minf(slip_widths[mini(cmd_idx, slip_widths.size() - 1)], avail_w - 86.0)
			var target_h: float = float(slip_heights[mini(cmd_idx, slip_heights.size() - 1)])
			btn.custom_minimum_size = Vector2(target_w, target_h)
			var slip := btn.get_node_or_null("SlipSurface") as ColorRect
			if slip != null and slip.material is ShaderMaterial:
				(slip.material as ShaderMaterial).set_shader_parameter("button_size", Vector2(target_w, target_h))
			cmd_idx += 1
	if touch:
		# [pc-fit 2026-11-17] 这里原本把开始/返回/应用、下拉、输入框、滑块、存档行按钮
		# 统一抬到 52 设计像素（它们的主题高度只有 29~44）。结果是手机上的下拉框比 PC
		# 高 80%、整列表单高度全变，和「按 PC 排版等比缩放」的诉求直接冲突。
		# 现在统一回到主题高度；要放大命中区请在 .tscn 里挂 touch_hit_button（不占布局）。
		pass
