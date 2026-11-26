extends "res://scripts/ui/game_ui/world_panel_routes.gd"

## Lays out the HUD and routes map overlays and modal workspaces.


func _on_military_layer_toggled(layer_id: StringName, enabled: bool) -> void:
	_overlay_component._on_military_layer_toggled(self, layer_id, enabled)


func set_colonization_route_layer(layer: ColonizationRouteLayer) -> void:
	_overlay_component.set_colonization_route_layer(self, layer)


func _configure_cell_hover_card() -> void:
	_overlay_component._configure_cell_hover_card(self)


func toggle_gm_panel() -> void:
	_overlay_component.toggle_gm_panel(self)


func is_gm_available() -> bool:
	return _overlay_component.is_gm_available(self)


func set_all_ui_suppressed(enabled: bool) -> void:
	_overlay_component.set_all_ui_suppressed(self, enabled)


func toggle_perf_hud() -> void:
	_overlay_component.toggle_perf_hud(self)


func update_time_state(
		year_idx: int,
		month: int,
		day_of_month: int,
		paused: bool,
		speed: float
) -> void:
	_overlay_component.update_time_state(self, year_idx, month, day_of_month, paused, speed)


func set_world_summary(width: int, height: int, cells: int, seed: int) -> void:
	_overlay_component.set_world_summary(self, width, height, cells, seed)


func set_day_night_enabled(enabled: bool) -> void:
	_overlay_component.set_day_night_enabled(self, enabled)


func show_loading(message: String) -> void:
	_overlay_component.show_loading(self, message)


func set_generation_progress(stage: String, fraction: float) -> void:
	_overlay_component.set_generation_progress(self, stage, fraction)


func hide_loading() -> void:
	_overlay_component.hide_loading(self)


func map_safe_area() -> Rect2:
	return _hud_layout().map_safe_area()


## 刘海/挖孔/圆角：把整棵 UI（UIRoot 及其下 HUDLayer/PanelLayer/ModalLayer）整体内缩。
## 安全区来自 DisplayServer.get_display_safe_area()，MobileUIScaling 已换算成设计像素；
## 桌面/Web 上恒为 0，因此这里对桌面是完全的 no-op。地图（Node2D）不内缩——
## 让地图继续铺满全屏、只把可点控件避让开，是廉价且不会出现黑边的做法。
func _apply_ui_safe_area() -> void:
	_hud_layout()._apply_ui_safe_area()


## 常驻 HUD 栏内按钮的最小高度（设计像素）。按当前移动档位换算：
## 52 × 0.5dp/单位 ≈ 26dp（440dpi + 总缩放 1.375）。这里刻意不追到 44dp——
## 两条栏的高度是 anchor+offset 写死的（80 / 86），按钮再高就会溢出栏外；
## 真要抬到 44dp 必须同时改 PlayerTopBar.BAR_HEIGHT、CountryActionBar.BAR_HEIGHT
## 和 _base_map_safe_area()，属于 HUD 另一条线的工作。面板类控件统一走 TouchUI。
## [pc-fit 2026-11-17] 0 = 不再抬高栏内按钮：顶栏/主操作栏的高度是 anchor+offset
## 写死的 80 / 86 设计像素，PC 上的按钮就是长在那个框里的。触摸档把按钮抬到 52
## 会让它们比栏体还高、上下顶出边框 —— 玩家说的「按钮离奇地高」有一部分来自这里。
## 保留这个调用是为了让栏自身仍能在尺寸变化时走一遍（apply_touch_metrics 用 maxf，
## 传 0 等于不设下限）。
const TOUCH_MIN_HEIGHT := 0.0


## 手机横屏：顶栏的日期块/资源块原本只有 48 设计像素高（≈40dp），主操作栏 66（≈59dp）已经够。
## 只抬这两条常驻栏；面板内部密集的按钮在 ScrollContainer 里，改了反而容易撑破卡片。
func _apply_touch_hud_metrics() -> void:
	return TouchMetrics._apply_touch_hud_metrics(self)


## 面板层触摸命中区。桌面档 TouchUI 内部直接 return，等于 no-op。
## 顶栏 / 主操作栏已经由上面的 apply_touch_metrics(TOUCH_MIN_HEIGHT) 处理：
## 它们的高度是 anchor+offset 写死的 80 / 86 设计像素，内部按钮若抬到 88 会溢出栏外，
## 所以用 skip_names 跳过（要抬到 44dp 必须同步改 BAR_HEIGHT 与地图安全区）。
func _watch_touch_panels() -> void:
	var options := {"skip_names": ["PlayerTopBar", "CountryActionBar"]}
	for path in ["UIRoot/HUDLayer", "UIRoot/PanelLayer", "UIRoot/ModalLayer", "UIRoot/DebugLayer"]:
		var layer := get_node_or_null(path)
		if layer != null:
			TouchUI.watch(layer, options)
	if _right_panel != null:
		TouchUI.watch(_right_panel)


func _base_map_safe_area() -> Rect2:
	return _hud_layout()._base_map_safe_area()


func dismiss_overlay_menu() -> bool:
	return _overlay_component.dismiss_overlay_menu(self)


func toggle_pause_menu() -> void:
	_overlay_component.toggle_pause_menu(self)


func show_exit_save_failure(action: String, result: Dictionary) -> void:
	_overlay_component.show_exit_save_failure(self, action, result)


func _ensure_narrative_ui() -> void:
	var modal_layer := get_node_or_null("UIRoot/ModalLayer") as Control
	if modal_layer == null:
		return
	if _narrative_event_dialog == null:
		_narrative_event_dialog = NarrativeEventDialogScript.new()
		_narrative_event_dialog.name = "NarrativeEventDialog"
		modal_layer.add_child(_narrative_event_dialog)
		_narrative_event_dialog.option_selected.connect(
			func(offer_id: int, generation: int, idx: int) -> void:
				narrative_event_option_selected.emit(offer_id, generation, idx)
		)
		_narrative_event_dialog.outcome_acknowledged.connect(
			func() -> void:
				narrative_event_outcome_acknowledged.emit()
		)
		_narrative_event_dialog.locate_cell_requested.connect(
			_locate_cell_from_family_founding
		)
		_narrative_event_dialog.chronicle_requested.connect(
			func() -> void:
				narrative_chronicle_requested.emit()
		)
	if _narrative_chronicle_panel == null:
		_narrative_chronicle_panel = NarrativeChroniclePanelScript.new()
		_narrative_chronicle_panel.name = "NarrativeChroniclePanel"
		modal_layer.add_child(_narrative_chronicle_panel)
		_narrative_chronicle_panel.visibility_changed.connect(func() -> void:
			if not _narrative_chronicle_panel.visible:
				notify_workspace_closed())
		_narrative_chronicle_panel.locate_cell_requested.connect(
			func(cell_idx: int) -> void:
				_narrative_chronicle_panel.close_panel()
				_locate_cell_from_family_founding(cell_idx)
		)
	if _pause_menu != null and _pause_menu.get_parent() == modal_layer:
		modal_layer.move_child(_pause_menu, modal_layer.get_child_count() - 1)


func _ensure_cell_hover_card() -> void:
	_overlay_component._ensure_cell_hover_card(self)


func _layout_family_founding_dialog() -> void:
	_hud_layout()._layout_family_founding_dialog()


func _on_map_overlay_requested(request: Dictionary) -> void:
	_overlay_component._on_map_overlay_requested(self, request)


func _on_map_overlay_cleared() -> void:
	_overlay_component._on_map_overlay_cleared(self)


func _on_inspector_visibility_changed() -> void:
	if _right_panel != null and not _right_panel.visible and _player_controller != null:
		_player_controller.cancel_military_arm_order()
	# 地块档案一开，悬停卡就是纯噪音；确定性关掉，不等下一帧轮询。
	if _right_panel != null and _right_panel.visible and _cell_hover_card != null:
		_cell_hover_card.dismiss(true)
	_layout_right_panel()
	_layout_overlay_legend()
	_layout_country_action_bar()
	_layout_gm_panel()
	_layout_family_founding_dialog()


func _on_inspector_detail_visibility_changed(open: bool) -> void:
	if not open:
		if _player_controller != null:
			_player_controller.cancel_military_arm_order()
			if not _military_dossier_context.is_empty():
				_player_controller.clear_military_map_selection()
		if _right_panel != null:
			_right_panel.set_directory_available(true)
		_object_detail_context.clear()
		_pending_object_request.clear()
		_military_dossier_context.clear()
		_military_dossier_pending = false
		# 营造 / 家族档案 / 军务档案都走这条关闭回路。
		notify_workspace_closed()
	_layout_right_panel()
	_layout_overlay_legend()
	_layout_country_action_bar()
	_layout_gm_panel()
	_layout_family_founding_dialog()
	if open and _base_map_safe_area().size.x >= MAP_REMAINING_MIN_WIDTH \
			and _player_controller != null and _player_controller.has_method(
			"ensure_selected_visible"):
		_player_controller.ensure_selected_visible()


func _layout_overlay_legend() -> void:
	_hud_layout()._layout_overlay_legend()


func _layout_country_action_bar() -> void:
	_hud_layout()._layout_country_action_bar()


func _layout_research_toast() -> void:
	_hud_layout()._layout_research_toast()


func _layout_gm_panel() -> void:
	_hud_layout()._layout_gm_panel()


# [web-layout-guard] PlayerTopBar / RightPanel 之前完全依赖 .tscn 里静态烘焙的
# anchor+offset（从未在运行时被脚本重新应用过）。CountryActionBar/OverlayLegend/
# GMPanel 三者虽然各自出于自己的动态需求（跟随姊妹面板可见性、紧凑模式阈值等）
# 早就在跑"取实时 viewport 尺寸 → set_anchors_preset → 写 offset"这条路径，
# 但客观上也顺带验证了这条路径在当前运行环境下是可靠的。这里让顶栏/详情面板走
# 同一条已验证路径兜底，不再单纯依赖引擎在 Web 上是否可靠地对声明式 anchor
# 做持续重新解算——即使原声明式 anchor 一直正常，这里重新套用同样的数值也是
# 幂等的，不会有副作用。
func _layout_top_bar() -> void:
	_hud_layout()._layout_top_bar()


## [web-layout-guard] 左侧地图图层工具条（MapOverlayToolbar）是这套静态布局里
## 最后一个只靠 .tscn 烘焙 anchor+offset、却没有任何运行期重新结算的 HUD 节点。
## Web 上已经证明这类节点拿不到声明式布局：PlayerTopBar / RightPanel 之前就是同一
## 症状，后来靠运行期兜底修好；工具条漏在外面，于是它的 rect 落成默认的 (0,0)，
## PrimaryPanel 被摆到屏幕左上角，正好盖住顶栏左侧的日历图标和日期纸框
## （截图里的"图标和日历重合"）。
##
## 这里和顶栏/详情面板走完全相同的路径：取实时值 → set_anchors_preset → 写
## offset。数值与 .tscn 里的声明保持一致（左 16 / 顶 顶栏高度+12 / 右 -16 /
## 底 -16），所以在桌面端是幂等的；顶栏高度用实时 size 而不是常量，是为了让
## 后续顶栏变高时工具条自动让位。
func _layout_map_overlay_toolbar() -> void:
	_hud_layout()._layout_map_overlay_toolbar()


## 当前是否触摸档（手机/平板）。桌面返回 false，所有触摸专用版面改动都是 no-op。
func touch_layout_enabled() -> bool:
	return _overlay_component.touch_layout_enabled(self)


func _dump_panel_children(node: Node, depth: int) -> void:
	_hud_layout()._dump_panel_children(node, depth)


func _layout_right_panel() -> void:
	_hud_layout()._layout_right_panel()


static func panel_content_min_width(panel: Control) -> float:
	return GameHudLayout.panel_content_min_width(panel)


static func resolve_panel_content_width(viewport_width: float,
		requested_width: float, content_min_width: float) -> float:
	return GameHudLayout.resolve_panel_content_width(
		viewport_width, requested_width, content_min_width)


static func inspector_layout_for_width(viewport_width: float,
		detail_open: bool, family_open: bool = false) -> Dictionary:
	return GameHudLayout.inspector_layout_for_width(viewport_width, detail_open, family_open)


# 排查 Web 构建"详情框/状态栏跑到左上角"问题用的一次性诊断输出；不影响任何
# 表现，纯打日志，方便下次直接从控制台里比对具体数值而不用再靠截图猜。
#
# 目前最大嫌疑：Windows 高 DPI 缩放下 Godot Web 默认 hidpi=true，canvas 像素
# 缓冲区尺寸会按 window.devicePixelRatio 放大，但引擎内部给 UI 锚点用的视口
# 逻辑尺寸未必跟着同步（godotengine/godot#93106 这一类已知问题）——地图相机
# 视图本身按视口自适应，看不出异常，锚定 UI 却会被挤压到左上角一小块。
# export_presets.cfg 的 html/head_include 已经在引擎脚本跑之前把
# window.devicePixelRatio 钉死成 1 来regress 这个根因；这里额外把浏览器端实测到
# 的 devicePixelRatio 打出来，用来确认那个钉子是否真的生效（预期看到 1.000）。
func _log_ui_layout_diagnostics(tag: String) -> void:
	_hud_layout()._log_ui_layout_diagnostics(tag)


func _hud_layout():
	return _overlay_component._hud_layout(self)


func can_open_annual_report() -> bool:
	if not is_instance_valid(_annual_report_workspace) or not _annual_report_workspace.is_inside_tree():
		return false
	var modal_layer := _annual_report_workspace.get_parent() as Control
	return modal_layer != null and modal_layer.is_visible_in_tree()


func _announce_annual_report_workspace() -> void:
	if can_open_annual_report():
		annual_report_workspace_available.emit()


func show_annual_report(model: Dictionary, ceremonial: bool) -> void:
	_overlay_component.show_annual_report(self, model, ceremonial)


func set_annual_history(rows: Array, offset: int, has_more: bool) -> void:
	_overlay_component.set_annual_history(self, rows, offset, has_more)


func is_annual_report_open() -> bool:
	return _overlay_component.is_annual_report_open(self)


func close_annual_report() -> void:
	_overlay_component.close_annual_report(self)


## [popup-deferral 2026-11-20] 玩家正开着自己的窗口（国家卷宗 / 营造 / 家族档案 /
## 军务档案 / 派遣 / 议和 / 史册 / GM / 时代纸笺）。叙事弹窗读它决定是否先静置。
func is_player_workspace_open() -> bool:
	return _overlay_component.is_player_workspace_open(self)


## 上面那些窗口关掉后的回调入口，让静置的事件在同一时刻接上展示。
func notify_workspace_closed() -> void:
	_overlay_component.notify_workspace_closed(self)


func show_narrative_event_offer(offer: Dictionary) -> void:
	_overlay_component.show_narrative_event_offer(self, offer)


func show_narrative_event_outcome(resolution: Dictionary) -> void:
	_overlay_component.show_narrative_event_outcome(self, resolution)


func show_narrative_event_error(message: String) -> void:
	_overlay_component.show_narrative_event_error(self, message)


func set_narrative_event_illustration(tex: Texture2D) -> void:
	_overlay_component.set_narrative_event_illustration(self, tex)


func close_narrative_event_offer() -> void:
	_overlay_component.close_narrative_event_offer(self)


func is_narrative_event_modal_open() -> bool:
	return _overlay_component.is_narrative_event_modal_open(self)


func show_narrative_chronicle(records: Array) -> void:
	_overlay_component.show_narrative_chronicle(self, records)


func close_narrative_chronicle() -> void:
	_overlay_component.close_narrative_chronicle(self)


func is_narrative_chronicle_open() -> bool:
	return _overlay_component.is_narrative_chronicle_open(self)
