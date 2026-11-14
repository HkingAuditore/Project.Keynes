extends RefCounted

## Places existing HUD controls and computes map-safe rectangles. Receives individual controls; owns only overflow diagnostic state.

const DETAIL_LAYOUT_BREAKPOINT := UITokens.DETAIL_BREAKPOINT_COMPACT + UITokens.ARCHIVE_EDGE_INSET * 2.0

const DETAIL_PANEL_MAX_WIDTH := 1040.0

const DETAIL_PANEL_MIN_WIDTH := 860.0

const FAMILY_DETAIL_MAX_WIDTH := 900.0

const FAMILY_DETAIL_MIN_WIDTH := 620.0

const GM_PANEL_MIN_WIDTH := 300.0

const GM_PANEL_TARGET_WIDTH := 560.0

const MAP_REMAINING_MIN_WIDTH := 320.0

const OVERLAY_LEGEND_WIDTH := 198.0

const OVERLAY_TOOLBAR_TOP_GAP := UITokens.SPACE_MD

const RIGHT_PANEL_WIDTH := 460.0

const TouchUI = preload("res://scripts/ui/touch_ui.gd")

var _panel_diag_printed: bool = false
var _panel_right_limit: float = 0.0
var _colonization_panel: ColonizationPlannerPanel
var _country_action_bar: CountryActionBar
var _family_founding_dialog: FamilyFoundingDialog
var _gm_console: DebugConsole
var _map_overlay_legend: OverlayLegend
var _map_overlay_toolbar: MapOverlayToolbar
var _military_dossier_context: Dictionary = {}
var _peace_window = null
var _research_toast: ResearchToast
var _right_panel: InspectorPanel
var _top_bar: PlayerTopBar

var _viewport: Viewport
var _window: Window
var _ui_root: Control
var _settings: Node

func map_safe_area() -> Rect2:
	var safe := _base_map_safe_area()
	if _peace_window != null and _peace_window.visible:
		# The peace window docks left, so the camera may not frame a target under it.
		var peace_edge: float = _peace_window.get_global_rect().end.x + UITokens.SPACE_MD
		var peace_inset: float = clampf(peace_edge - safe.position.x, 0.0,
			maxf(safe.size.x - 1.0, 0.0))
		safe.position.x += peace_inset
		safe.size.x -= peace_inset
	if _colonization_panel != null and _colonization_panel.visible:
		var edge := _colonization_panel.get_global_rect().end.x + UITokens.SPACE_MD
		var inset := clampf(edge - safe.position.x, 0.0, maxf(safe.size.x - 1.0, 0.0))
		safe.position.x += inset
		safe.size.x -= inset
	if _family_founding_dialog != null:
		var occupied_edge := _family_founding_dialog.map_reserved_right_edge()
		if occupied_edge > safe.position.x:
			var inset := minf(occupied_edge + UITokens.SPACE_MD - safe.position.x,
				maxf(safe.size.x - 1.0, 0.0))
			safe.position.x += inset
			safe.size.x -= inset
	return safe


func _apply_ui_safe_area() -> void:
	var ui_root := _ui_root as Control
	if ui_root == null:
		return
	var insets := {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	var settings := _settings
	if settings != null and settings.has_method("ui_scaling"):
		var scaling = settings.call("ui_scaling")
		if scaling != null:
			insets = scaling.call("safe_insets")
	ui_root.offset_left = float(insets.get("left", 0.0))
	ui_root.offset_top = float(insets.get("top", 0.0))
	ui_root.offset_right = -float(insets.get("right", 0.0))
	ui_root.offset_bottom = -float(insets.get("bottom", 0.0))


func _base_map_safe_area() -> Rect2:
	var viewport_size := _viewport.get_visible_rect().size
	var top_height := PlayerTopBar.BAR_HEIGHT + 4.0
	if _top_bar != null and _top_bar.size.y > 0.0:
		top_height = _top_bar.size.y + 4.0
	var right_width := 0.0
	if _right_panel != null and _right_panel.visible:
		right_width = (_right_panel.size.x if _right_panel.size.x > 0.0 else RIGHT_PANEL_WIDTH) \
			+ UITokens.ARCHIVE_EDGE_INSET + UITokens.SPACE_MD
	var left_width := _map_overlay_toolbar.primary_safe_width() \
		if _map_overlay_toolbar != null else 0.0
	var bottom_height := CountryActionBar.BAR_HEIGHT + UITokens.ARCHIVE_EDGE_INSET
	return Rect2(
		Vector2(left_width, top_height),
		Vector2(
			maxf(viewport_size.x - right_width - left_width, 1.0),
			maxf(viewport_size.y - top_height - bottom_height, 1.0)
		)
	)


func _layout_family_founding_dialog() -> void:
	if _family_founding_dialog == null:
		return
	_family_founding_dialog.set_inspector_obscures(
		_right_panel != null and _right_panel.visible and _right_panel.detail_open())
	# The dossier is placed against HUD bounds; camera bounds additionally exclude it.
	_family_founding_dialog.set_safe_area(_base_map_safe_area())


func _layout_overlay_legend() -> void:
	if _map_overlay_legend == null:
		return
	var compact_detail := _right_panel != null and _right_panel.detail_open() \
		and _base_map_safe_area().size.x < OVERLAY_LEGEND_WIDTH + UITokens.SPACE_MD * 2.0
	_map_overlay_legend.modulate.a = 0.0 if compact_detail else 1.0
	_map_overlay_legend.mouse_filter = Control.MOUSE_FILTER_IGNORE \
		if compact_detail else Control.MOUSE_FILTER_PASS
	var right_inset := UITokens.ARCHIVE_EDGE_INSET
	if _right_panel != null and _right_panel.visible:
		var panel_width := _right_panel.size.x
		if panel_width <= 0.0:
			panel_width = RIGHT_PANEL_WIDTH
		right_inset += panel_width + UITokens.SPACE_MD + UITokens.ARCHIVE_EDGE_INSET
	_map_overlay_legend.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_map_overlay_legend.offset_right = -right_inset
	_map_overlay_legend.offset_left = -right_inset - OVERLAY_LEGEND_WIDTH
	_map_overlay_legend.offset_bottom = -CountryActionBar.BAR_HEIGHT - UITokens.SPACE_LG
	# A zero-height anchored rect plus BEGIN growth keeps variable legend
	# content attached to the bottom edge instead of growing off-screen.
	_map_overlay_legend.offset_top = _map_overlay_legend.offset_bottom


func _layout_country_action_bar() -> void:
	if _country_action_bar == null:
		return
	_country_action_bar.visible = true
	var ui_root := _ui_root as Control
	var viewport_width := ui_root.size.x if ui_root != null and ui_root.size.x > 0.0 \
		else _viewport.get_visible_rect().size.x
	var safe := _base_map_safe_area()
	var bar_width := 412.0
	_country_action_bar.visible = not (_right_panel != null \
		and _right_panel.family_workspace_open() \
		and safe.size.x < bar_width + UITokens.ARCHIVE_EDGE_INSET * 2.0)
	var side_margin := maxf(safe.position.x + (safe.size.x - bar_width) * 0.5,
		UITokens.ARCHIVE_EDGE_INSET)
	var right_margin := maxf(viewport_width - side_margin - bar_width,
		UITokens.ARCHIVE_EDGE_INSET)
	_country_action_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_country_action_bar.offset_left = side_margin
	_country_action_bar.offset_right = -right_margin
	_country_action_bar.offset_top = -CountryActionBar.BAR_HEIGHT - UITokens.ARCHIVE_EDGE_INSET
	_country_action_bar.offset_bottom = -UITokens.ARCHIVE_EDGE_INSET
	var window_width := _window.size.x if _window != null else int(viewport_width)
	_country_action_bar.set_compact(window_width < 720 or TouchUI.is_short_viewport())
	_layout_research_toast()


func _layout_research_toast() -> void:
	if _research_toast == null:
		return
	_research_toast.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_research_toast.offset_left = 24.0
	_research_toast.offset_right = -24.0
	_research_toast.offset_top = PlayerTopBar.BAR_HEIGHT + UITokens.SPACE_SM
	_research_toast.offset_bottom = _research_toast.offset_top + 96.0
	_research_toast.z_index = 40


func _layout_gm_panel() -> void:
	if _gm_console == null:
		return
	var viewport_width := _viewport.get_visible_rect().size.x
	var compact_detail := _right_panel != null and _right_panel.detail_open() \
		and _base_map_safe_area().size.x < GM_PANEL_MIN_WIDTH + UITokens.SPACE_MD * 2.0
	_gm_console.modulate.a = 0.0 if compact_detail else 1.0
	_gm_console.mouse_filter = Control.MOUSE_FILTER_IGNORE \
		if compact_detail else Control.MOUSE_FILTER_PASS
	if compact_detail:
		return
	var panel_width_right := RIGHT_PANEL_WIDTH
	if _right_panel != null and _right_panel.visible:
		panel_width_right = _right_panel.size.x if _right_panel.size.x > 0.0 \
			else RIGHT_PANEL_WIDTH
	var available := viewport_width - panel_width_right - UITokens.SPACE_MD * 3.0
	var panel_width := clampf(available, GM_PANEL_MIN_WIDTH, GM_PANEL_TARGET_WIDTH)
	_gm_console.offset_left = UITokens.SPACE_SM
	_gm_console.offset_right = UITokens.SPACE_SM + panel_width
	_gm_console.offset_top = PlayerTopBar.BAR_HEIGHT + UITokens.SPACE_SM
	_gm_console.offset_bottom = -UITokens.SPACE_SM


func _layout_top_bar() -> void:
	if _top_bar == null:
		return
	_top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_top_bar.offset_left = 0.0
	_top_bar.offset_top = 0.0
	_top_bar.offset_right = 0.0
	_top_bar.offset_bottom = PlayerTopBar.BAR_HEIGHT
	UIAnimation.refresh_rest_position(_top_bar)
	# 顶栏高度一变，左侧图层工具条的安全起点也跟着变，永远不许压到日历纸框。
	_layout_map_overlay_toolbar()


func _layout_map_overlay_toolbar() -> void:
	if _map_overlay_toolbar == null:
		return
	var top_bar_height := PlayerTopBar.BAR_HEIGHT
	if _top_bar != null and _top_bar.size.y > 0.0:
		top_bar_height = maxf(_top_bar.size.y, PlayerTopBar.BAR_HEIGHT)
	_map_overlay_toolbar.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_overlay_toolbar.offset_left = UITokens.ARCHIVE_EDGE_INSET
	_map_overlay_toolbar.offset_top = top_bar_height + OVERLAY_TOOLBAR_TOP_GAP
	_map_overlay_toolbar.offset_right = -UITokens.ARCHIVE_EDGE_INSET
	_map_overlay_toolbar.offset_bottom = -UITokens.ARCHIVE_EDGE_INSET


func touch_layout_enabled() -> bool:
	var settings := _settings
	if settings == null or not settings.has_method("ui_scaling"):
		return false
	var scaling = settings.call("ui_scaling")
	return scaling != null and bool(scaling.call("is_touch_profile"))


func _dump_panel_children(node: Node, depth: int) -> void:
	if depth > 5:
		return
	for child in node.get_children():
		var control := child as Control
		if control == null:
			continue
		var right_edge := control.global_position.x + control.size.x
		print("[panel-diag/%d] %s(%s) pos=%s size=%s min=%s right_edge=%.1f%s" % [
			depth, String(control.name), control.get_class(), str(control.global_position),
			str(control.size), str(control.get_combined_minimum_size()), right_edge,
			"  <-- OVERFLOW" if right_edge > _panel_right_limit + 0.5 else ""])
		_dump_panel_children(control, depth + 1)


func _layout_right_panel() -> void:
	if _right_panel == null:
		return
	# PRESET_RIGHT_WIDE：anchor_left=anchor_right=1.0（贴右边）且 anchor_bottom=1.0
	# （随视口高度伸展），必须用这个而不是 PRESET_TOP_RIGHT，否则 offset_bottom
	# 会被解释成"相对顶部锚点"而不是"相对底部锚点"，面板会被压扁到顶部一小条。
	var viewport_width := _viewport.get_visible_rect().size.x
	var detail_open := _right_panel.detail_open()
	var family_open := _right_panel.family_workspace_open()
	var layout := inspector_layout_for_width(viewport_width, detail_open, family_open)
	# 部队指挥常驻地图旁；单页不携带地块目录，也不占用整幅地图。
	var army_open := _right_panel.military_dossier_open() and \
		String(_military_dossier_context.get("kind", "")) == "army"
	if army_open:
		layout["panel_width"] = minf(520.0, viewport_width - UITokens.ARCHIVE_EDGE_INSET * 2.0)
		layout["compact"] = true
	var compact := bool(layout.get("compact", false))
	_right_panel.set_compact_detail_mode(compact)
	var panel_width := float(layout.get("panel_width", RIGHT_PANEL_WIDTH))
	# [panel-fit 2026-11-02] 触摸档把页签抬到 44dp 之后，面板内容的最小宽度会超过
	# RIGHT_PANEL_WIDTH（真机 2670x1200@520dpi 实测：右侧详情面板的页签行被挤出屏幕，
	# 关闭按钮直接看不见）。这里让面板按"内容最小宽度"兜底，并限制在视口 55% 以内，
	# 保证永远贴右且完整可见。
	panel_width = resolve_panel_content_width(
		viewport_width, panel_width, panel_content_min_width(_right_panel))
	# [panel-width-touch 2026-11-02] 触摸档的页签/KPI 行比桌面宽（页签 44dp 起），
	# 460 装不下：真机 2670x1200@520dpi 上右侧面板的"市场"页签与"就业率"读数会被
	# 屏幕右缘切掉。这里在触摸档给面板加宽 72 设计像素（视口 2053 宽，完全放得下）。
	if touch_layout_enabled():
		panel_width = maxf(panel_width, RIGHT_PANEL_WIDTH + 72.0)
		panel_width = minf(panel_width, maxf(viewport_width * 0.55, RIGHT_PANEL_WIDTH + 72.0))
	_right_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_right_panel.offset_left = -panel_width - UITokens.ARCHIVE_EDGE_INSET
	var top_bar_height := _top_bar.size.y if _top_bar != null and _top_bar.size.y > 0.0 \
		else PlayerTopBar.BAR_HEIGHT
	_right_panel.offset_top = top_bar_height + UITokens.SPACE_MD
	_right_panel.offset_right = -UITokens.ARCHIVE_EDGE_INSET
	_right_panel.offset_bottom = -UITokens.ARCHIVE_EDGE_INSET
	_right_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_right_panel.grow_vertical = Control.GROW_DIRECTION_END
	_right_panel.custom_minimum_size.x = panel_width
	# [panel-diag 2026-11-02] 真机上右侧面板内容被屏幕右缘切掉。这一行把
	# 视口/根节点/父层/面板的坐标系一次性打出来，直接判断是"锚点算错"还是
	# "父层尺寸是物理像素而面板是逻辑像素"。
	if detail_open and not _panel_diag_printed:
		_panel_diag_printed = true
		var root := _viewport.get_tree().root
		var ui_root := _ui_root as Control
		var panel_layer := _right_panel.get_parent() as Control
		print("[panel-diag] viewport=%s root=%s ui_root=%s layer=%s panel_pos=%s panel_size=%s panel_min=%s panel_width=%.1f inset=%.1f"
			% [
				str(_viewport.get_visible_rect().size),
				str(root.size if root != null else Vector2.ZERO),
				str(ui_root.size if ui_root != null else Vector2.ZERO),
				str(panel_layer.size if panel_layer != null else Vector2.ZERO),
				str(_right_panel.global_position), str(_right_panel.size),
				str(_right_panel.get_combined_minimum_size()), panel_width,
				UITokens.ARCHIVE_EDGE_INSET])
		# 面板自身尺寸是对的（右缘 = viewport - inset），所以溢出的必然是某个子控件。
		# 把两层子节点的 rect 打出来，直接定位谁比面板宽。
		_panel_right_limit = _right_panel.global_position.x + _right_panel.size.x
		_dump_panel_children(_right_panel, 0)
	# 关键一步：UIAnimation.fade_slide_in/out 会把"第一次调用时的 control.position"
	# 永久缓存成 rest position。如果不在这里主动刷新，等玩家第一次点开地块面板时，
	# fade_slide_in 可能会缓存到一个还没被上面这套 offset 结算过的旧/零值，
	# 之后每次开合面板都会被带回那个错误坐标——这正是"详情框缩在左上角"的成因。
	UIAnimation.refresh_rest_position(_right_panel)


## 右栏"内容最小宽度"：量之前先把本函数上一轮写进 custom_minimum_size 的宽度清零。
## get_combined_minimum_size() 会把 custom_minimum_size 本身算进结果，直接读它就会
## 把上一帧为详情撑开的宽面板当成"内容最小宽度"再写回去——面板只增不减，详情关闭后
## 再也回不到 460px。清零后重新取最小值，得到的才是子节点真正需要的宽度。
static func panel_content_min_width(panel: Control) -> float:
	if panel == null:
		return 0.0
	panel.custom_minimum_size.x = 0.0
	return panel.get_combined_minimum_size().x


## 内容比请求宽度更宽时按内容兜底，但上限压在视口 55%（至少 RIGHT_PANEL_WIDTH），
## 避免宽面板把地图挤没。请求宽度已经够宽时原样返回，保证关闭详情能回到窄档。
static func resolve_panel_content_width(viewport_width: float,
		requested_width: float, content_min_width: float) -> float:
	if content_min_width <= requested_width:
		return requested_width
	return minf(content_min_width,
		maxf(viewport_width * 0.55, RIGHT_PANEL_WIDTH))


static func inspector_layout_for_width(viewport_width: float,
		detail_open: bool, family_open: bool = false) -> Dictionary:
	var available_width := maxf(viewport_width - UITokens.ARCHIVE_EDGE_INSET * 2.0, 1.0)
	if detail_open and family_open:
		# 地块栏的 460 已含外框与分栏间距；窄窗先让地图，再压缩家族正文。
		var family_width := clampf(available_width - RIGHT_PANEL_WIDTH \
			- MAP_REMAINING_MIN_WIDTH, FAMILY_DETAIL_MIN_WIDTH, FAMILY_DETAIL_MAX_WIDTH)
		family_width = minf(family_width, maxf(available_width - RIGHT_PANEL_WIDTH, 1.0))
		var panel_width := RIGHT_PANEL_WIDTH + family_width
		return {
			"compact": false,
			"panel_width": panel_width,
			"detail_width": family_width,
			"map_width": maxf(available_width - panel_width, 0.0),
		}
	var compact := viewport_width < DETAIL_LAYOUT_BREAKPOINT or TouchUI.is_short_viewport()
	var panel_width := RIGHT_PANEL_WIDTH
	if detail_open:
		if compact:
			panel_width = available_width
		else:
			panel_width = minf(DETAIL_PANEL_MAX_WIDTH,
				maxf(DETAIL_PANEL_MIN_WIDTH, viewport_width * 0.62))
			panel_width = minf(panel_width,
				maxf(RIGHT_PANEL_WIDTH,
					available_width - MAP_REMAINING_MIN_WIDTH))
	return {
		"compact": compact,
		"panel_width": panel_width,
		"detail_width": maxf(panel_width - RIGHT_PANEL_WIDTH, 0.0) \
			if detail_open and not compact else panel_width if detail_open else 0.0,
		"map_width": 0.0 if compact and detail_open \
			else maxf(available_width - panel_width, 0.0),
	}


func _log_ui_layout_diagnostics(tag: String) -> void:
	var vp_rect := _viewport.get_visible_rect()
	var win := _window
	var win_size := win.size if win != null else Vector2i.ZERO
	var scale_factor := win.content_scale_factor if win != null else -1.0
	var scale_mode := win.content_scale_mode if win != null else -1
	var top_bar_rect := _top_bar.get_rect() if _top_bar != null else Rect2()
	var right_panel_rect := _right_panel.get_rect() if _right_panel != null else Rect2()
	var country_bar_rect := _country_action_bar.get_rect() if _country_action_bar != null else Rect2()
	var device_pixel_ratio := -1.0
	if OS.has_feature("web") and Engine.has_singleton("JavaScriptBridge"):
		var js_result = JavaScriptBridge.eval("window.devicePixelRatio", true)
		if js_result != null:
			device_pixel_ratio = float(js_result)
	print(("[ui-layout-diag/%s] is_web=%s viewport_visible_rect=%s window_size=%s " +
		"content_scale_factor=%.3f content_scale_mode=%d device_pixel_ratio=%.3f " +
		"top_bar_rect=%s right_panel_rect=%s country_action_bar_rect=%s") % [
		tag, OS.has_feature("web"), vp_rect, win_size, scale_factor, scale_mode,
		device_pixel_ratio, top_bar_rect, right_panel_rect, country_bar_rect,
	])
