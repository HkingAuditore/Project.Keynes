extends PanelContainer
class_name InspectorPanel

const CohortListScript = preload("res://scripts/ui/components/cohort_list.gd")

signal close_requested()

var _model: Dictionary = {}
var _current_tab := "geography"
var _tabs_ready := false

var _title_label: Label
var _subtitle_label: Label
var _score_gauge: RadialGauge
var _summary_grid: GridContainer
var _summary_cards: Dictionary = {}
var _tabs: CategoryTabs
var _scroll: ScrollContainer
var _content_box: VBoxContainer

var _insight_list: InsightList
var _resource_list: ResourceList
var _cohort_list
var _metric_controls: Dictionary = {}
var _gauge_controls: Dictionary = {}
var _chart_controls: Dictionary = {}
var _summary_trends: Dictionary = {}
var _last_score_band := -1


func _ready() -> void:
	if _content_box != null:
		return
	var shell_style := UITokens.panel_style(
		Color(0.038, 0.035, 0.030, 0.975),
		UITokens.RADIUS_MD,
		Color(0.43, 0.32, 0.18, 0.76)
	)
	shell_style.content_margin_left = 0
	shell_style.content_margin_top = 0
	shell_style.content_margin_right = 0
	shell_style.content_margin_bottom = 0
	add_theme_stylebox_override("panel", shell_style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_LG)
	margin.add_theme_constant_override("margin_top", UITokens.SPACE_MD)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_LG)
	margin.add_theme_constant_override("margin_bottom", UITokens.SPACE_LG)
	add_child(margin)

	var root := VBoxContainer.new()
	root.name = "InspectorRoot"
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	var cap := ColorRect.new()
	cap.custom_minimum_size = Vector2(0.0, 2.0)
	cap.color = Color(UITokens.BRASS_HIGHLIGHT.r, UITokens.BRASS_HIGHLIGHT.g, UITokens.BRASS_HIGHLIGHT.b, 0.72)
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(cap)

	root.add_child(_build_header())
	root.add_child(_build_summary())

	var rule := HSeparator.new()
	rule.add_theme_color_override("separator", UITokens.PANEL_BORDER_SOFT)
	root.add_child(rule)

	_tabs = CategoryTabs.new()
	_tabs.tab_selected.connect(_on_tab_selected)
	root.add_child(_tabs)

	var content_shell := PanelContainer.new()
	content_shell.name = "ContentShell"
	content_shell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_shell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_shell.add_theme_stylebox_override(
		"panel",
		UITokens.inset_panel_style(Color(0.026, 0.025, 0.023, 0.86), UITokens.PANEL_BORDER_SOFT)
	)
	root.add_child(content_shell)

	var content_margin := MarginContainer.new()
	content_margin.add_theme_constant_override("margin_left", UITokens.SPACE_SM)
	content_margin.add_theme_constant_override("margin_top", UITokens.SPACE_SM)
	content_margin.add_theme_constant_override("margin_right", UITokens.SPACE_XS)
	content_margin.add_theme_constant_override("margin_bottom", UITokens.SPACE_SM)
	content_shell.add_child(content_margin)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_margin.add_child(_scroll)

	_content_box = VBoxContainer.new()
	_content_box.add_theme_constant_override("separation", UITokens.SPACE_SM)
	_content_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_content_box)


func set_model(model: Dictionary, _rebuild_visible: bool = true) -> void:
	set_model_for_selection(model)


func set_model_for_selection(model: Dictionary) -> void:
	_model = model
	if _content_box == null:
		_ready()
	if _model.is_empty():
		return
	_apply_header(_model.get("header", {}), false)
	_render_summary(_model.get("score", {}), _model.get("summary_cards", []))
	var tabs: Array = _model.get("tabs", [])
	if not _has_tab(tabs, _current_tab):
		_current_tab = "geography"
	if not _tabs_ready:
		_tabs.set_tabs(tabs, _current_tab)
		_tabs_ready = true
	else:
		_tabs.select_tab(_current_tab)
	_render_content()


func apply_live_patch(patch: Dictionary) -> void:
	if patch.is_empty() or _content_box == null:
		return
	_apply_header(patch.get("header", {}), true)
	_apply_score(patch.get("score", {}), true)
	for raw in patch.get("summary_cards", []):
		var data: Dictionary = raw
		var card_id := String(data.get("id", ""))
		var card := _summary_cards.get(card_id) as MetricCard
		if card != null:
			_apply_metric_card(card, data)
			var trend := String(data.get("trend", ""))
			var previous_trend := String(_summary_trends.get(card_id, ""))
			if previous_trend != "" and trend != "" and trend != previous_trend:
				UIAnimation.pulse(card, UITokens.ANIM_MED)
			_summary_trends[card_id] = trend
	if String(patch.get("tab_id", "")) != _current_tab:
		return
	_apply_category_patch(patch.get("category", {}))


func current_tab() -> String:
	return _current_tab


func select_tab(tab_id: String) -> void:
	if tab_id == _current_tab or not _has_tab(_model.get("tabs", []), tab_id):
		return
	_tabs.select_tab(tab_id)
	_on_tab_selected(tab_id)


func reset_for_world() -> void:
	_model.clear()
	_current_tab = "geography"
	_tabs_ready = false
	_last_score_band = -1
	_summary_cards.clear()
	_summary_trends.clear()
	_metric_controls.clear()
	_gauge_controls.clear()
	_chart_controls.clear()
	if _tabs != null:
		_tabs.clear_tabs()
	if _scroll != null:
		_scroll.scroll_vertical = 0


func visible_node_count() -> int:
	return _count_nodes(self)


func _build_header() -> Control:
	var shell := PanelContainer.new()
	var shell_style := UITokens.inset_panel_style(
		Color(0.072, 0.058, 0.043, 0.96),
		Color(0.48, 0.35, 0.18, 0.70),
		UITokens.RADIUS_SM
	)
	shell_style.content_margin_left = UITokens.SPACE_SM
	shell_style.content_margin_top = 6
	shell_style.content_margin_right = UITokens.SPACE_SM
	shell_style.content_margin_bottom = 6
	shell.add_theme_stylebox_override("panel", shell_style)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UITokens.SPACE_SM)
	shell.add_child(header)

	var accent_bar := ColorRect.new()
	accent_bar.custom_minimum_size = Vector2(3.0, 0.0)
	accent_bar.color = UITokens.ACCENT
	accent_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(accent_bar)

	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.add_theme_constant_override("separation", 1)
	header.add_child(title_box)

	_title_label = Label.new()
	_title_label.text = "地块档案"
	_title_label.add_theme_font_override("font", UITokens.font_with_weight(700))
	_title_label.add_theme_font_size_override("font_size", UITokens.FONT_TITLE)
	_title_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	title_box.add_child(_title_label)

	_subtitle_label = Label.new()
	_subtitle_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_subtitle_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	title_box.add_child(_subtitle_label)

	var close_button := Button.new()
	close_button.tooltip_text = "关闭地块档案"
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.custom_minimum_size = Vector2(34.0, 32.0)
	IconBadge.apply_to_button(close_button, "close", 14)
	close_button.pressed.connect(func() -> void: close_requested.emit())
	header.add_child(close_button)
	return shell


func _build_summary() -> Control:
	var shell := PanelContainer.new()
	var shell_style := UITokens.inset_panel_style(
		Color(0.030, 0.029, 0.026, 0.94),
		Color(0.36, 0.28, 0.17, 0.72),
		UITokens.RADIUS_MD
	)
	shell_style.content_margin_left = UITokens.SPACE_SM
	shell_style.content_margin_top = UITokens.SPACE_SM
	shell_style.content_margin_right = UITokens.SPACE_SM
	shell_style.content_margin_bottom = UITokens.SPACE_SM
	shell.add_theme_stylebox_override("panel", shell_style)

	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", 10)
	shell.add_child(summary)

	_score_gauge = RadialGauge.new()
	_score_gauge.custom_minimum_size = Vector2(104.0, 112.0)
	_score_gauge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	summary.add_child(_score_gauge)

	_summary_grid = GridContainer.new()
	_summary_grid.columns = 1
	_summary_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary_grid.add_theme_constant_override("h_separation", UITokens.SPACE_SM)
	_summary_grid.add_theme_constant_override("v_separation", UITokens.SPACE_XS)
	summary.add_child(_summary_grid)
	return shell


func _apply_header(header: Dictionary, _live_patch: bool) -> void:
	_title_label.text = String(header.get("title", "地块档案"))
	_subtitle_label.text = String(header.get("subtitle", ""))


func _render_summary(score: Dictionary, cards: Array) -> void:
	_apply_score(score, false)
	for child in _summary_grid.get_children():
		child.queue_free()
	_summary_cards.clear()
	for raw in cards:
		var data: Dictionary = raw
		var card := MetricCard.new()
		card.custom_minimum_size = Vector2(0.0, 42.0)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_summary_grid.add_child(card)
		_apply_metric_card(card, data)
		var card_id := String(data.get("id", "summary_%d" % _summary_cards.size()))
		_summary_cards[card_id] = card
		_summary_trends[card_id] = String(data.get("trend", ""))


func _apply_score(score: Dictionary, live_patch: bool) -> void:
	if score.is_empty():
		return
	var score_value := float(score.get("value", 0.0))
	var score_band := _score_band(score_value)
	if live_patch and _last_score_band >= 0 and score_band != _last_score_band:
		UIAnimation.pulse(_score_gauge, UITokens.ANIM_MED)
	_last_score_band = score_band
	_score_gauge.set_data(
		String(score.get("title", "适宜度")),
		score_value,
		String(score.get("caption", "")),
		score.get("accent", UITokens.ACCENT)
	)


func _render_content() -> void:
	for child in _content_box.get_children():
		child.queue_free()
	_insight_list = null
	_resource_list = null
	_cohort_list = null
	_metric_controls.clear()
	_gauge_controls.clear()
	_chart_controls.clear()
	var categories: Dictionary = _model.get("categories", {})
	var data: Dictionary = categories.get(_current_tab, categories.get("geography", {}))
	_build_category_content(data)
	if _scroll != null:
		_scroll.scroll_vertical = 0


func _build_category_content(data: Dictionary) -> void:
	var root_data := data.duplicate(false)
	root_data.erase("sections")
	_build_category_block(root_data)
	for raw_section in data.get("sections", []):
		var section: Dictionary = raw_section
		_add_section_header(section)
		_build_category_block(section)


func _build_category_block(data: Dictionary) -> void:
	var insights: Array = data.get("insights", [])
	if not insights.is_empty():
		var insight_shell := PanelContainer.new()
		var insight_style := UITokens.inset_panel_style(
			Color(0.060, 0.050, 0.038, 0.74),
			Color(0.38, 0.29, 0.18, 0.62),
			UITokens.RADIUS_SM
		)
		insight_style.content_margin_left = UITokens.SPACE_SM
		insight_style.content_margin_top = 6
		insight_style.content_margin_right = UITokens.SPACE_SM
		insight_style.content_margin_bottom = 6
		insight_shell.add_theme_stylebox_override("panel", insight_style)
		_content_box.add_child(insight_shell)
		_insight_list = InsightList.new()
		_insight_list.set_items(insights)
		insight_shell.add_child(_insight_list)

	var cohort_rows: Array = data.get("cohort_rows", [])
	if data.has("cohort_rows"):
		_add_group_separator()
		_cohort_list = CohortListScript.new()
		_cohort_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_cohort_list.set_rows(cohort_rows)
		_content_box.add_child(_cohort_list)

	var resource_rows: Array = data.get("resource_rows", [])
	if data.has("resource_rows"):
		_add_group_separator()
		_resource_list = ResourceList.new()
		_resource_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_resource_list.set_rows(resource_rows)
		_content_box.add_child(_resource_list)

	var metrics: Array = data.get("metrics", [])
	if not metrics.is_empty():
		_add_group_separator()
		var grid := GridContainer.new()
		grid.columns = 2
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_theme_constant_override("h_separation", UITokens.SPACE_SM)
		grid.add_theme_constant_override("v_separation", UITokens.SPACE_SM)
		_content_box.add_child(grid)
		for raw in metrics:
			var metric: Dictionary = raw
			var card := MetricCard.new()
			card.custom_minimum_size = Vector2(184.0, 56.0)
			card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			grid.add_child(card)
			_apply_metric_card(card, metric)
			_metric_controls[String(metric.get("id", "metric_%d" % _metric_controls.size()))] = card

	var gauges: Array = data.get("gauges", [])
	if not gauges.is_empty():
		_add_group_separator()
		for raw in gauges:
			var gauge: Dictionary = raw
			var bar := GaugeBar.new()
			bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_content_box.add_child(bar)
			_apply_gauge(bar, gauge)
			_gauge_controls[String(gauge.get("id", "gauge_%d" % _gauge_controls.size()))] = bar

	var charts: Array = data.get("charts", [])
	if not charts.is_empty():
		_add_group_separator()
		for raw in charts:
			var chart: Dictionary = raw
			var spark := ChartAdapter.make_sparkline(
				String(chart.get("title", "")),
				chart.get("values", []),
				chart.get("accent", UITokens.ACCENT),
				float(chart.get("min_value", NAN)),
				float(chart.get("max_value", NAN)),
				int(chart.get("window_size", 0)),
				String(chart.get("value_text", ""))
			)
			spark.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_content_box.add_child(spark)
			_chart_controls[String(chart.get("id", "chart_%d" % _chart_controls.size()))] = spark

	var badges: Array = data.get("badges", [])
	if not badges.is_empty():
		_add_group_separator()
		var row := BadgeRow.new()
		row.set_badges(badges)
		_content_box.add_child(row)


func _apply_category_patch(data: Dictionary) -> void:
	_apply_category_block_patch(data)
	for raw_section in data.get("sections", []):
		_apply_category_block_patch(raw_section as Dictionary)


func _apply_category_block_patch(data: Dictionary) -> void:
	if _insight_list != null:
		_insight_list.update_items(data.get("insights", []))
	if _cohort_list != null and data.has("cohort_rows"):
		_cohort_list.update_rows(data.get("cohort_rows", []))
	if _resource_list != null:
		_resource_list.update_rows(data.get("resource_rows", []))
	for raw in data.get("metrics", []):
		var metric: Dictionary = raw
		var card := _metric_controls.get(String(metric.get("id", ""))) as MetricCard
		if card != null:
			_apply_metric_card(card, metric)
	for raw in data.get("gauges", []):
		var gauge: Dictionary = raw
		var bar := _gauge_controls.get(String(gauge.get("id", ""))) as GaugeBar
		if bar != null:
			_apply_gauge(bar, gauge)
	for raw in data.get("charts", []):
		var chart: Dictionary = raw
		var spark := _chart_controls.get(String(chart.get("id", ""))) as SparklineChart
		if spark != null:
			spark.set_data(
				String(chart.get("title", "")),
				chart.get("values", []),
				chart.get("accent", UITokens.ACCENT),
				float(chart.get("min_value", NAN)),
				float(chart.get("max_value", NAN)),
				int(chart.get("window_size", 0)),
				String(chart.get("value_text", ""))
			)


func _add_section_header(section: Dictionary) -> void:
	if _content_box.get_child_count() > 0:
		_add_group_separator()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITokens.SPACE_SM)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(20.0, 20.0)
	icon.set_icon(String(section.get("icon", "overview")), section.get("accent", UITokens.ACCENT))
	row.add_child(icon)
	var label := Label.new()
	label.text = String(section.get("title", "资料"))
	label.add_theme_font_override("font", UITokens.font_with_weight(650))
	label.add_theme_font_size_override("font_size", UITokens.FONT_SECTION)
	label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	row.add_child(label)
	_content_box.add_child(row)


func _apply_metric_card(card: MetricCard, data: Dictionary) -> void:
	card.set_data(
		String(data.get("title", "")),
		String(data.get("value", "")),
		String(data.get("subtitle", "")),
		data.get("accent", UITokens.ACCENT),
		String(data.get("trend", "")),
		String(data.get("icon", ""))
	)


func _apply_gauge(bar: GaugeBar, gauge: Dictionary) -> void:
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


func _add_group_separator() -> void:
	if _content_box.get_child_count() == 0:
		return
	var line := HSeparator.new()
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_theme_color_override("separator", UITokens.PANEL_BORDER_SOFT)
	_content_box.add_child(line)


func _on_tab_selected(tab_id: String) -> void:
	_current_tab = tab_id
	_render_content()
	UIAnimation.crossfade(_content_box, UITokens.ANIM_FAST)


func _has_tab(tabs: Array, tab_id: String) -> bool:
	for raw in tabs:
		var tab: Dictionary = raw
		if String(tab.get("id", "")) == tab_id:
			return true
	return false


func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count


func _score_band(value: float) -> int:
	if value >= 0.80: return 4
	if value >= 0.62: return 3
	if value >= 0.42: return 2
	if value >= 0.24: return 1
	return 0
