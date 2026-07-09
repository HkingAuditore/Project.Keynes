extends PanelContainer
class_name InspectorPanel

signal close_requested()

var _model: Dictionary = {}
var _current_tab: String = "overview"
var _tabs_ready: bool = false

var _title_label: Label
var _subtitle_label: Label
var _badge_row: BadgeRow
var _score_gauge: RadialGauge
var _summary_grid: GridContainer
var _tabs: CategoryTabs
var _content_box: VBoxContainer


func _ready() -> void:
	if _content_box != null:
		return
	add_theme_stylebox_override("panel", UITokens.panel_style(UITokens.PANEL_BG, UITokens.RADIUS_LG))

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_LG)
	margin.add_theme_constant_override("margin_top", UITokens.SPACE_MD)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_LG)
	margin.add_theme_constant_override("margin_bottom", UITokens.SPACE_LG)
	add_child(margin)

	var root := VBoxContainer.new()
	root.name = "InspectorRoot"
	root.add_theme_constant_override("separation", UITokens.SPACE_SM)
	margin.add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UITokens.SPACE_SM)
	root.add_child(header)

	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title_box)
	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 20)
	_title_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	title_box.add_child(_title_label)
	_subtitle_label = Label.new()
	_subtitle_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	title_box.add_child(_subtitle_label)

	var close_btn := Button.new()
	close_btn.text = "×"
	close_btn.tooltip_text = "关闭"
	close_btn.custom_minimum_size = Vector2(36.0, 32.0)
	close_btn.pressed.connect(func() -> void: close_requested.emit())
	header.add_child(close_btn)

	_badge_row = BadgeRow.new()
	root.add_child(_badge_row)

	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", UITokens.SPACE_MD)
	root.add_child(summary)
	_score_gauge = RadialGauge.new()
	summary.add_child(_score_gauge)
	_summary_grid = GridContainer.new()
	_summary_grid.columns = 2
	_summary_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary_grid.add_theme_constant_override("h_separation", UITokens.SPACE_SM)
	_summary_grid.add_theme_constant_override("v_separation", UITokens.SPACE_XS)
	summary.add_child(_summary_grid)

	var content_shell := Control.new()
	content_shell.name = "ContentShell"
	content_shell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_shell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(content_shell)

	var tab_rail := PanelContainer.new()
	tab_rail.name = "ExternalTabRail"
	tab_rail.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	tab_rail.offset_left = -82.0
	tab_rail.offset_right = -12.0
	tab_rail.offset_top = 0.0
	tab_rail.offset_bottom = 0.0
	var tab_rail_style := UITokens.panel_style(Color(0.052, 0.040, 0.030, 0.94), UITokens.RADIUS_MD, Color(0.45, 0.33, 0.18, 0.64))
	tab_rail_style.content_margin_left = 0
	tab_rail_style.content_margin_top = 0
	tab_rail_style.content_margin_right = 0
	tab_rail_style.content_margin_bottom = 0
	tab_rail.add_theme_stylebox_override("panel", tab_rail_style)
	content_shell.add_child(tab_rail)

	var tab_margin := MarginContainer.new()
	tab_margin.add_theme_constant_override("margin_left", UITokens.SPACE_SM)
	tab_margin.add_theme_constant_override("margin_top", UITokens.SPACE_SM)
	tab_margin.add_theme_constant_override("margin_right", UITokens.SPACE_SM)
	tab_margin.add_theme_constant_override("margin_bottom", UITokens.SPACE_SM)
	tab_rail.add_child(tab_margin)

	_tabs = CategoryTabs.new()
	_tabs.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_tabs.tab_selected.connect(_on_tab_selected)
	tab_margin.add_child(_tabs)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_shell.add_child(scroll)

	_content_box = VBoxContainer.new()
	_content_box.add_theme_constant_override("separation", UITokens.SPACE_SM)
	_content_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_content_box)


func set_model(model: Dictionary, rebuild_visible: bool = true) -> void:
	_model = model
	if _content_box == null:
		_ready()
	if _model.is_empty():
		return
	if not rebuild_visible:
		return
	var header: Dictionary = _model.get("header", {})
	_title_label.text = String(header.get("title", "地块档案"))
	_subtitle_label.text = String(header.get("subtitle", ""))
	_badge_row.set_badges(header.get("badges", []))
	_render_summary()
	var tabs: Array = _model.get("tabs", [])
	if not _has_tab(tabs, _current_tab):
		_current_tab = "overview"
	if not _tabs_ready:
		_tabs.set_tabs(tabs, _current_tab)
		_tabs_ready = true
	_render_content()


func _render_summary() -> void:
	for child in _summary_grid.get_children():
		child.queue_free()
	var score: Dictionary = _model.get("score", {})
	_score_gauge.set_data(
		String(score.get("title", "适宜度")),
		float(score.get("value", 0.0)),
		String(score.get("caption", "")),
		score.get("accent", UITokens.ACCENT)
	)
	for raw in _model.get("summary_cards", []):
		var data: Dictionary = raw
		var card := MetricCard.new()
		card.custom_minimum_size = Vector2(140.0, 54.0)
		_summary_grid.add_child(card)
		card.set_data(
			String(data.get("title", "")),
			String(data.get("value", "")),
			String(data.get("subtitle", "")),
			data.get("accent", UITokens.ACCENT),
			String(data.get("trend", "")),
			String(data.get("icon", ""))
		)


func _render_content() -> void:
	for child in _content_box.get_children():
		child.queue_free()
	var categories: Dictionary = _model.get("categories", {})
	var data: Dictionary = categories.get(_current_tab, categories.get("overview", {}))
	var insights: Array = data.get("insights", [])
	if not insights.is_empty():
		_add_section_title("状态")
		var list := InsightList.new()
		list.set_items(insights)
		_content_box.add_child(list)
	var resource_rows: Array = data.get("resource_rows", [])
	if not resource_rows.is_empty():
		_add_section_title("资源清单")
		var resource_list := ResourceList.new()
		resource_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		resource_list.set_rows(resource_rows)
		_content_box.add_child(resource_list)
	var metrics: Array = data.get("metrics", [])
	if not metrics.is_empty():
		_add_section_title("档案")
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", UITokens.SPACE_SM)
		grid.add_theme_constant_override("v_separation", UITokens.SPACE_SM)
		_content_box.add_child(grid)
		for raw in metrics:
			var metric: Dictionary = raw
			var card := MetricCard.new()
			card.custom_minimum_size = Vector2(188.0, 50.0)
			grid.add_child(card)
			card.set_data(
				String(metric.get("title", "")),
				String(metric.get("value", "")),
				String(metric.get("subtitle", "")),
				metric.get("accent", UITokens.ACCENT),
				String(metric.get("trend", "")),
				String(metric.get("icon", ""))
			)
	var gauges: Array = data.get("gauges", [])
	if not gauges.is_empty():
		_add_section_title("刻度")
		for raw in gauges:
			var gauge: Dictionary = raw
			var bar := GaugeBar.new()
			bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_content_box.add_child(bar)
			bar.set_data(
				String(gauge.get("label", "")),
				float(gauge.get("value", 0.0)),
				String(gauge.get("min_label", "")),
				String(gauge.get("max_label", "")),
				gauge.get("accent", UITokens.ACCENT),
				float(gauge.get("marker", -1.0)),
				String(gauge.get("status_label", "")),
				String(gauge.get("value_text", ""))
			)
	var charts: Array = data.get("charts", [])
	if not charts.is_empty():
		_add_section_title("记录")
		for raw in charts:
			var chart: Dictionary = raw
			var spark := ChartAdapter.make_sparkline(String(chart.get("title", "")), chart.get("values", []), chart.get("accent", UITokens.ACCENT))
			spark.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_content_box.add_child(spark)
	var badges: Array = data.get("badges", [])
	if not badges.is_empty():
		_add_section_title("标签")
		var row := BadgeRow.new()
		row.set_badges(badges)
		_content_box.add_child(row)


func _add_section_title(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", UITokens.ACCENT)
	_content_box.add_child(label)


func _on_tab_selected(tab_id: String) -> void:
	_current_tab = tab_id
	_render_content()


func _has_tab(tabs: Array, tab_id: String) -> bool:
	for raw in tabs:
		var tab: Dictionary = raw
		if String(tab.get("id", "")) == tab_id:
			return true
	return false
