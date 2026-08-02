extends PanelContainer
class_name InspectorPanel

const MetricCardScene := preload("res://scenes/ui/metric_card.tscn")
const InsightShellScene := preload("res://scenes/ui/insight_shell.tscn")
const ResourceListScene := preload("res://scenes/ui/resource_list.tscn")
const FamilyListScene := preload("res://scenes/ui/family_list.tscn")
const MarketListScene := preload("res://scenes/ui/market_list.tscn")
const CohortListScene := preload("res://scenes/ui/cohort_list.tscn")
const BuildingListScene := preload("res://scenes/ui/building_list.tscn")
const GaugeBarScene := preload("res://scenes/ui/gauge_bar.tscn")
const BadgeRowScene := preload("res://scenes/ui/badge_row.tscn")
const MetricGridScene := preload("res://scenes/ui/metric_grid.tscn")
const SectionHeaderScene := preload("res://scenes/ui/section_header.tscn")
const GroupSeparatorScene := preload("res://scenes/ui/group_separator.tscn")

signal close_requested()
signal tab_data_requested(tab_id: String)
signal demand_details_requested(details: Dictionary)
signal object_details_requested(request: Dictionary)

var _model: Dictionary = {}
var _current_tab := "geography"
var _tabs_signature_cache := ""

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
var _building_list
var _market_list
var _family_list
var _metric_controls: Dictionary = {}
var _gauge_controls: Dictionary = {}
var _chart_controls: Dictionary = {}
var _summary_trends: Dictionary = {}
var _last_score_band := -1


func _ready() -> void:
	if _content_box != null:
		return
	_title_label = get_node_or_null("Margin/InspectorRoot/Header/Row/Titles/TitleLabel") as Label
	_subtitle_label = get_node_or_null("Margin/InspectorRoot/Header/Row/Titles/SubtitleLabel") as Label
	_score_gauge = get_node_or_null("Margin/InspectorRoot/Summary/Row/ScoreGauge") as RadialGauge
	_summary_grid = get_node_or_null("Margin/InspectorRoot/Summary/Row/SummaryGrid") as GridContainer
	_tabs = get_node_or_null("Margin/InspectorRoot/CategoryTabs") as CategoryTabs
	_scroll = get_node_or_null("Margin/InspectorRoot/ContentShell/ContentMargin/Scroll") as ScrollContainer
	_content_box = get_node_or_null("Margin/InspectorRoot/ContentShell/ContentMargin/Scroll/ContentBox") as VBoxContainer
	var close_button := get_node_or_null("Margin/InspectorRoot/Header/Row/CloseButton") as Button
	if _title_label == null or _subtitle_label == null or _score_gauge == null \
			or _summary_grid == null or _tabs == null or _scroll == null \
			or _content_box == null or close_button == null:
		push_error("InspectorPanel 必须通过 inspector_panel.tscn 实例化。")
		return
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭地块档案")
	close_button.pressed.connect(func() -> void: close_requested.emit())
	_tabs.tab_selected.connect(_on_tab_selected)


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
	# 页签集合会随视野状态变化（未探索 0 个 / 已探索 1 个 / 可见 5 个），
	# 所以不能只在首次装配时 set_tabs，得按签名判断是否需要重建页签栏。
	var signature := _tabs_signature(tabs)
	if signature != _tabs_signature_cache:
		_tabs_signature_cache = signature
		_tabs.set_tabs(tabs, _current_tab)
	else:
		_tabs.select_tab(_current_tab)
	if not tabs.is_empty():
		_request_tab_data_if_missing(_current_tab)
	_render_content(false)


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
	var patch_tab := String(patch.get("tab_id", ""))
	if patch.has("category") and patch_tab != "":
		set_tab_category(patch_tab, patch.get("category", {}))
	if patch_tab != _current_tab:
		return
	_apply_category_patch(patch.get("category", {}))


func set_tab_category(tab_id: String, category: Dictionary) -> void:
	if tab_id == "" or category.is_empty():
		return
	var categories: Dictionary = _model.get("categories", {})
	categories[tab_id] = category
	_model["categories"] = categories


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
	_tabs_signature_cache = ""
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
		var card := MetricCardScene.instantiate() as MetricCard
		card.custom_minimum_size = Vector2(0.0, 42.0)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_summary_grid.add_child(card)
		_apply_metric_card(card, data)
		var card_id := String(data.get("id", "summary_%d" % _summary_cards.size()))
		_summary_cards[card_id] = card
		_summary_trends[card_id] = String(data.get("trend", ""))


func _apply_score(score: Dictionary, live_patch: bool) -> void:
	if score.is_empty():
		# 未探索格没有适宜度可言，留着上一格的表盘会读成这一格的数据。
		# live patch 里的空 score 只表示「这次没更新」，不能据此隐藏。
		if not live_patch and _score_gauge != null:
			_score_gauge.visible = false
			_last_score_band = -1
		return
	if _score_gauge != null:
		_score_gauge.visible = true
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


func _render_content(reset_scroll: bool) -> void:
	for child in _content_box.get_children():
		child.queue_free()
	_insight_list = null
	_resource_list = null
	_cohort_list = null
	_building_list = null
	_market_list = null
	_metric_controls.clear()
	_gauge_controls.clear()
	_chart_controls.clear()
	var categories: Dictionary = _model.get("categories", {})
	var data: Dictionary = categories.get(_current_tab, categories.get("geography", {}))
	_build_category_content(data)
	if reset_scroll and _scroll != null:
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
		var insight_shell := InsightShellScene.instantiate() as PanelContainer
		_content_box.add_child(insight_shell)
		_insight_list = insight_shell.get_node("InsightList") as InsightList
		_insight_list.set_items(insights)

	var cohort_rows: Array = data.get("cohort_rows", [])
	if data.has("family_rows"):
		_family_list = FamilyListScene.instantiate()
		_family_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_family_list.details_requested.connect(
			func(request: Dictionary) -> void: object_details_requested.emit(request))
		_family_list.set_rows(data.get("family_rows", []))
		_content_box.add_child(_family_list)
	if data.has("cohort_rows"):
		_add_group_separator()
		_cohort_list = CohortListScene.instantiate() as CohortList
		_cohort_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_cohort_list.demand_details_requested.connect(
			func(details: Dictionary) -> void: demand_details_requested.emit(details))
		_cohort_list.details_requested.connect(
			func(request: Dictionary) -> void: object_details_requested.emit(request))
		_cohort_list.set_rows(cohort_rows)
		_content_box.add_child(_cohort_list)

	var resource_rows: Array = data.get("resource_rows", [])
	if data.has("resource_rows"):
		_add_group_separator()
		_resource_list = ResourceListScene.instantiate() as ResourceList
		_resource_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_resource_list.details_requested.connect(
			func(request: Dictionary) -> void: object_details_requested.emit(request))
		_resource_list.set_rows(resource_rows)
		_content_box.add_child(_resource_list)

	var market_rows: Array = data.get("market_rows", [])
	if data.has("market_rows"):
		_add_group_separator()
		_market_list = MarketListScene.instantiate()
		_market_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_market_list.details_requested.connect(
			func(request: Dictionary) -> void: object_details_requested.emit(request))
		_market_list.set_rows(market_rows)
		_content_box.add_child(_market_list)

	var building_rows: Array = data.get("building_rows", [])
	if data.has("building_rows"):
		_add_group_separator()
		_building_list = BuildingListScene.instantiate() as BuildingList
		_building_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_building_list.details_requested.connect(
			func(request: Dictionary) -> void: object_details_requested.emit(request))
		_building_list.set_rows(building_rows)
		_content_box.add_child(_building_list)

	var metrics: Array = data.get("metrics", [])
	if not metrics.is_empty():
		_add_group_separator()
		var grid := MetricGridScene.instantiate() as GridContainer
		_content_box.add_child(grid)
		for raw in metrics:
			var metric: Dictionary = raw
			var card := MetricCardScene.instantiate() as MetricCard
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
			var bar := GaugeBarScene.instantiate() as GaugeBar
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
		var row := BadgeRowScene.instantiate() as BadgeRow
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
	if _family_list != null and data.has("family_rows"):
		_family_list.update_rows(data.get("family_rows", []))
	if _resource_list != null:
		_resource_list.update_rows(data.get("resource_rows", []))
	if _building_list != null and data.has("building_rows"):
		_building_list.update_rows(data.get("building_rows", []))
	if _market_list != null and data.has("market_rows"):
		_market_list.update_rows(data.get("market_rows", []))
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
	var row := SectionHeaderScene.instantiate() as HBoxContainer
	var icon := row.get_node("Icon") as IconBadge
	icon.set_semantic(
		StringName(section.get("icon", &"summary.overview")),
		section.get("accent", UITokens.ACCENT)
	)
	var label := row.get_node("Label") as Label
	label.text = String(section.get("title", "资料"))
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
	var line := GroupSeparatorScene.instantiate() as HSeparator
	_content_box.add_child(line)


func _on_tab_selected(tab_id: String) -> void:
	_current_tab = tab_id
	tab_data_requested.emit(tab_id)
	_render_content(true)
	UIAnimation.crossfade(_content_box, UITokens.ANIM_FAST)


func _request_tab_data_if_missing(tab_id: String) -> void:
	var categories: Dictionary = _model.get("categories", {})
	if not categories.has(tab_id):
		tab_data_requested.emit(tab_id)


func _tabs_signature(tabs: Array) -> String:
	var ids := PackedStringArray()
	for raw in tabs:
		var tab: Dictionary = raw
		ids.append(String(tab.get("id", "")))
	return "|".join(ids)


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
