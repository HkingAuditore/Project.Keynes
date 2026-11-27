extends RefCounted

## Builds the notes, metrics, and layout of each inspector category.

const InspectorListWing = preload("res://scripts/ui/components/inspector_list_wing.gd")


static func _build_category_content(panel, data: Dictionary) -> void:
	panel._tax_context = data.get("tax_context", {})
	var split := InspectorListWing.split_category(panel._current_tab, data)
	panel._has_list_wing = bool(split.get("has_left", false))
	var use_wing: bool = panel._has_list_wing and panel._list_wing_enabled \
		and panel._list_content != null
	var right_source: Dictionary = split.get("right", data) if use_wing else data
	var root_data := right_source.duplicate(false)
	root_data.erase("sections")
	root_data.erase("tax_context")
	panel._build_category_block(panel._content_box, root_data)
	for raw_section in right_source.get("sections", []):
		var section: Dictionary = raw_section
		var body: VBoxContainer = panel._add_collapsible_section(section, panel._content_box)
		panel._build_category_block(body, section)
	if use_wing:
		var left_source: Dictionary = split.get("left", {})
		var left_root := left_source.duplicate(false)
		left_root.erase("sections")
		panel._build_category_block(panel._list_content, left_root)
		for raw_section in left_source.get("sections", []):
			var section: Dictionary = raw_section
			var body: VBoxContainer = panel._add_collapsible_section(section, panel._list_content)
			panel._build_category_block(body, section)
	panel._build_page_tax_section(panel._tax_context)


## 一个块（页根或折叠节）的固定阅读顺序：
## 批注（警示）→ 事实表 → 指标条 → 趋势 → 物种徽记 → 建造入口 → 列头 + 名录 → 名录附注。
## 键存在就建控件（空则隐藏），这样补丁里内容由无到有时也只改可见性、不增删节点。
static func _build_category_block(panel, host: Control, data: Dictionary) -> void:
	var block_id := String(data.get("id", "_root"))
	if data.has("insights"):
		var notes := panel.NoteListScene.instantiate() as InspectorNoteList
		host.add_child(notes)
		var insights: Array = data.get("insights", [])
		notes.set_notes(insights)
		notes.visible = not insights.is_empty()
		panel._note_controls[block_id] = notes

	if data.has("metrics"):
		var facts := panel.FactGridScene.instantiate() as InspectorFactGrid
		host.add_child(facts)
		var metrics: Array = data.get("metrics", [])
		facts.set_facts(metrics)
		facts.visible = not metrics.is_empty()
		panel._metric_controls[block_id] = facts

	if data.has("gauges"):
		var meters := panel.MeterListScene.instantiate() as InspectorMeterList
		host.add_child(meters)
		var gauges: Array = data.get("gauges", [])
		meters.set_meters(gauges)
		meters.visible = not gauges.is_empty()
		panel._gauge_controls[block_id] = meters

	var charts: Array = data.get("charts", [])
	if not charts.is_empty():
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
			host.add_child(spark)
			panel._chart_controls[String(chart.get("id", "chart_%d" % panel._chart_controls.size()))] = spark

	var badges: Array = data.get("badges", [])
	if not badges.is_empty():
		var row := panel.BadgeRowScene.instantiate() as BadgeRow
		host.add_child(row)
		row.set_badges(badges)
		panel._badge_row = row

	if data.has("construction_entry"):
		panel._build_construction_entry(host, data.get("construction_entry", {}))

	# 军事页签：一整张撕纸台账。驻军条 / 部队 / 训练 / 三行官营建筑都由它自绘，
	# 页面上不再有并排的大按钮，也没有解释性批注。
	if data.has("military_cell"):
		panel._build_military_ledger(host, data.get("military_cell", {}))

	for row_key in panel.ROW_LIST_KEYS:
		if data.has(row_key):
			panel._build_row_list(host, data, String(row_key), block_id)



static func _set_list_caption(panel, caption: InspectorNoteList, text: String) -> void:
	caption.visible = not text.is_empty()
	caption.set_notes([] if text.is_empty() else [{"id": "list_caption", "text": text,
		"accent": UITokens.TEXT_MUTED}])


static func _apply_category_patch(panel, data: Dictionary) -> void:
	if data.has("tax_context"):
		panel._tax_context = data.get("tax_context", {})
		panel._tax_page_cell = int(panel._tax_context.get("cell", panel._tax_page_cell))
		panel._update_reset_tax_button()
		panel._apply_page_tax_patch(panel._tax_context)
		panel._resolve_tax_pending(panel._tax_context, data)
		var tax_refs: Dictionary = panel._section_refs.get("page_tax", {})
		if not tax_refs.is_empty():
			(tax_refs.summary as Label).text = panel._tax_summary(
				panel._tax_context.get("default_lanes", []))
	var root_data := data.duplicate(false)
	root_data.erase("sections")
	panel._apply_category_block_patch(root_data)
	for raw_section in data.get("sections", []):
		panel._apply_category_block_patch(raw_section as Dictionary)



static func _apply_category_block_patch(panel, data: Dictionary) -> void:
	panel.InspectorCategoryPatch._apply_category_block_patch(
		{
			"_note_controls": panel._note_controls,
			"_metric_controls": panel._metric_controls,
			"_gauge_controls": panel._gauge_controls,
			"_list_caption_controls": panel._list_caption_controls,
			"_section_refs": panel._section_refs,
			"_badge_row": panel._badge_row,
			"_military_ledger": panel._military_ledger,
			"_cohort_list": panel._cohort_list,
			"_family_list": panel._family_list,
			"_resource_list": panel._resource_list,
			"_building_list": panel._building_list,
			"_construction_workspace": panel._construction_workspace,
			"_construction_entry_hint": panel._construction_entry_hint,
			"_market_list": panel._market_list,
			"_chart_controls": panel._chart_controls
		},
		panel._set_list_caption,
		panel._apply_section_texts,
		data)
