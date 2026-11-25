extends RefCounted

## The selected panel follows the map image; other panels consume UI publications.
var _waiting_for_drawn_cell := false


func show_cell_panel(host, cell: HexCell) -> void:
	# 议和窗口开着时地图是交割选格面（PlayerController.select_cell 已经拦过一次，
	# 这里是第二次兜底：任何把点击送到地块档案的路径都不能把窗口顶掉）。
	if host.is_peace_window_open():
		if cell != null:
			host._peace_window.handle_map_cell(int(cell.index))
		return
	if host._colonization_panel != null and host._colonization_panel.visible:
		# 派发界面开着时，地图左键一律交给它：先出发城、后目的地，
		# 不再需要玩家先按面板上的“选点”按钮进入模式。
		if cell != null:
			host._colonization_panel.handle_map_cell(int(cell.index))
		host._colonization_targeting.clear()
		return
	host._cancel_inspector_retry()
	# 地块档案一开，悬停卡就是纯噪音。这里确定性收起，不依赖 visibility_changed：
	# 面板已可见时再选另一格不会发出该信号。
	if host._cell_hover_card != null:
		host._cell_hover_card.dismiss(true)
	if host._right_panel != null:
		host._right_panel.close_detail(false)
	host._object_detail_context.clear()
	host._military_dossier_context.clear()
	host._military_dossier_pending = false
	host._selected_cell = cell
	host._invalidate_live_revision()
	host._last_cached_panel_ms = Time.get_ticks_msec()
	if host._inspector_view_model == null or host._right_panel == null:
		return
	if cell == null:
		hide_cell_panel(host)
		return
	# 只有当前可见的格子才值得开经济追踪：未探索与已探索但看不见的格子都拿不到
	# 经济页签，追踪它只会让 recorder 白算一份。
	_waiting_for_drawn_cell = not VisionSolver.displayed_fields_current(host._map)
	if _waiting_for_drawn_cell:
		host._set_inspector_trace_cell(-1)
		host._right_panel.hide()
		return
	_install_panel(host, cell)


func _install_panel(host, cell: HexCell) -> void:
	_waiting_for_drawn_cell = false
	host._selected_fog_state = VisionSolver.displayed_fog_state(host._map, int(cell.index))
	host._set_inspector_trace_cell(int(cell.index) \
		if host._selected_fog_state == VisionSolver.FOG_VISIBLE else -1)
	host._right_panel.set_model_for_selection(host._inspector_view_model.build(cell))
	# [relayout-on-open 2026-11-02] 面板宽度是按 detail_open() 算的，但以前只在
	# viewport 尺寸变化时重算；地块档案/家族页打开后内容变宽，宽度还停在关闭档
	# （460），于是页签与 KPI 行被屏幕右缘切掉（真机 2670x1200 实测）。
	# 这里在模型换好之后补一次布局。
	host.call_deferred("_layout_right_panel")
	host._selection_context = host._revision_selection_context(
		host._inspector_view_model.live_patch_revision(cell, host._right_panel.current_tab()))
	if host._country_panel != null and host._country_panel.is_panel_open():
		host._inspector_suppressed_for_country = true
		host._right_panel.visible = false
		return
	if not host._right_panel.visible or host._right_panel.has_meta("_ui_active_tween"):
		UIAnimation.fade_slide_in(host._right_panel, Vector2(24.0, 0.0), UITokens.ANIM_MED)


func hide_cell_panel(host) -> void:
	_waiting_for_drawn_cell = false
	host._cancel_inspector_retry()
	host._selected_cell = null
	host._selection_context = ""
	host._inspector_suppressed_for_country = false
	host._military_dossier_context.clear()
	host._military_dossier_pending = false
	if host._right_panel != null:
		host._right_panel.set_directory_available(true)
	host._invalidate_live_revision()
	host._set_inspector_trace_cell(-1)
	if host._right_panel != null:
		host._right_panel.close_detail(false)
		host.call_deferred("_layout_right_panel")
	if host._right_panel != null:
		UIAnimation.fade_slide_out(host._right_panel, Vector2(24.0, 0.0), UITokens.ANIM_FAST)


func refresh_selected_daily_lines(host, force: bool = false, day_idx: int = -1) -> Dictionary:
	if not VisionSolver.displayed_fields_current(host._map):
		return {}
	if _waiting_for_drawn_cell and host._selected_cell != null:
		_install_panel(host, host._selected_cell)
	if host._map != null and host._map.drawn_frame != null:
		refresh_gdp(host)
	if not host._pending_inspector_tab.is_empty() or not host._pending_object_request.is_empty():
		host._schedule_inspector_retry()
	return host._country_component.refresh_selected_daily_lines(host, force, day_idx)


func refresh_gdp(host) -> void:
	if host._selected_cell == null or host._right_panel == null or host._inspector_view_model == null:
		return
	var cell := int(host._selected_cell.index)
	if VisionSolver.displayed_fog_state(host._map, cell) == VisionSolver.FOG_VISIBLE:
		host._right_panel.apply_published_gdp(host._inspector_view_model._gdp_kpi(cell))
