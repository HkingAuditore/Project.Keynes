extends RefCounted

## Applies live family updates and refreshes navigation and headings.


static func _refresh_page(owner: FamilyWorkspace, page_id: String) -> void:
	var rows := owner._page_rows(page_id)
	var signature := owner._shape_signature(rows)
	if String(owner._page_signatures.get(page_id, "")) != signature:
		owner._ensure_page(page_id)
		return
	var page := owner._page_cache.get(page_id) as Control
	if page == null:
		return
	if page_id == "overview":
		owner._refresh_overview_page(page)
		return
	if page_id == "people":
		var people_ledger := page.find_child("PeoplePageLedger", true, false) as DossierLedgerTable
		if people_ledger != null:
			people_ledger.set_rows(owner._people_ledger_rows(rows))
	var row_index := 0
	for card in owner._find_cards(page):
		if row_index >= rows.size():
			break
		owner._apply_card_live(page_id, card, rows[row_index])
		row_index += 1



static func _apply_card_live(owner: FamilyWorkspace, page_id: String, card: PanelContainer, row_value: Variant) -> void:
	var row: Dictionary = row_value
	var labels := owner._find_labels(card)
	if labels.is_empty():
		return
	match page_id:
		"traits":
			labels[0].text = String(row.get("name", "特性"))
			if labels.size() > 1: labels[1].text = String(row.get("kind_label", row.get("value", "附加特性")))
			if labels.size() > 2: labels[2].text = String(row.get("detail", "无"))
			if labels.size() > 3: labels[3].text = String(row.get("effect_summary", ""))
		"preferences":
			labels[0].text = String(row.get("name", "偏好"))
			if labels.size() > 1: labels[1].text = String(row.get("factor_text", row.get("value", "100%")))
			var pref_meter := card.find_child("PrefMeter", true, false) as InspectorMeterList
			if pref_meter != null:
				pref_meter.set_meters([owner._preference_meter_dict(row)])
			var bars := owner._find_progress_bars(card)
			if not bars.is_empty(): bars[0].value = clampf(float(row.get("factor_percent", 100.0)), 0.0, 200.0)
		"effects":
			labels[0].text = String(row.get("title", row.get("name", "效果")))
			if labels.size() > 1: labels[1].text = String(row.get("value", ""))
			if labels.size() > 2: labels[2].text = String(row.get("detail", ""))
			var trig_meter := card.find_child("TriggerMeter", true, false) as InspectorMeterList
			if trig_meter != null:
				trig_meter.set_meters([{
					"id": String(row.get("id", "trigger")),
					"label": "触发进度",
					"value": clampf(float(row.get("progress_ratio", 0.0)), 0.0, 1.0),
					"value_text": "%d / %d" % [int(row.get("progress", 0)), int(row.get("threshold", 1))],
					"status_label": "已触发 %d 次" % int(row.get("completed", 0)),
					"accent": UITokens.WARN,
				}])
		"people":
			labels[0].text = String(row.get("name", "未命名人物"))
			if labels.size() > 1: labels[1].text = String(row.get("role", "家族成员"))
			if labels.size() > 2: labels[2].text = String(row.get("profession", "身份未详"))
			if labels.size() > 3:
				var building := String(row.get("building", ""))
				labels[3].text = "所属产业：%s" % building if not building.is_empty() else "所属产业：无"
			var person_facts := card.find_child("PersonFacts", true, false) as InspectorFactGrid
			if person_facts != null:
				person_facts.set_facts(owner._person_fact_cells(row))
			var cashflow_bar := card.find_child("PersonCashflowBar", true, false) as DossierDivergingBar
			if cashflow_bar != null:
				owner._update_person_cashflow_bar(cashflow_bar, row)
		"branches":
			labels[0].text = "地块 %d" % int(row.get("cell", -1))
			if labels.size() > 1: labels[1].text = "威望 %s · %s" % [String(row.get("prestige_label", "0")), String(row.get("prestige_text", "0%"))]
			if labels.size() > 2: labels[2].text = "人口 %s · 现金 %s · 建筑 %s" % [String(row.get("population_share_text", "0%")), String(row.get("cash_share_text", "0%")), String(row.get("building_share_text", "0%"))]
			if labels.size() > 3: labels[3].text = "晋级目标 %s · 复核 %d/%d" % [String(row.get("target_label", "0")), int(row.get("review_streak", 0)), int(row.get("review_required", 2))]
			var branch_meters := card.find_child("BranchMeters", true, false) as InspectorMeterList
			if branch_meters != null:
				branch_meters.set_meters(owner._branch_meter_dicts(row))
			var buttons := owner._find_buttons(card)
			if not buttons.is_empty(): buttons[0].disabled = not owner._colonization_available(int(row.get("cell", -1)))



static func _refresh_overview_page(owner: FamilyWorkspace, page: Control) -> void:
	var overview: Dictionary = owner._model.get("pages", {}).get("overview", {})
	var pref_bars := page.find_child("OverviewPrefBars", true, false) as DossierBarList
	if pref_bars != null:
		pref_bars.set_rows(owner._build_preference_bar_rows(overview.get("preferences", [])))
	var ring_grid := page.find_child("OverviewRingGrid", true, false) as Control
	if ring_grid != null:
		owner._refresh_overview_rings(ring_grid, overview.get("branches", []))
	var branch_meters := page.find_child("OverviewBranchMeters", true, false) as InspectorMeterList
	if branch_meters != null:
		branch_meters.set_meters(owner._build_overview_branch_meters(overview.get("branches", [])))
	var branch_meta := page.find_child("BranchMetaLabel", true, false) as Label
	if branch_meta != null:
		branch_meta.text = owner._overview_branch_meta_text(overview.get("branches", []))
	for section_key in ["traits", "effects"]:
		var card := page.find_child("Overview%s" % section_key.capitalize(),
			true, false) as PanelContainer
		if card == null:
			continue
		var items: Array = overview.get(section_key, [])
		for item_index in range(items.size()):
			var item_root := card.find_child("Item%d" % item_index, true, false) as Control
			if item_root == null:
				continue
			var item: Dictionary = items[item_index]
			var name_label := item_root.find_child("Name", true, false) as Label
			var value_label := item_root.find_child("Value", true, false) as Label
			var detail_label := item_root.find_child("Detail", true, false) as Label
			if name_label != null:
				name_label.text = String(item.get("name", item.get("title", "记录")))
			if value_label != null:
				value_label.text = owner._overview_item_value_text(section_key, item)
			if detail_label != null:
				detail_label.text = owner._overview_item_detail_text(section_key, item)
	var people_card := page.find_child("OverviewPeople", true, false) as PanelContainer
	if people_card == null:
		return
	var people: Array = overview.get("people", [])
	var people_table := people_card.find_child("OverviewPeopleTable", true, false) as DossierLedgerTable
	if people_table != null:
		people_table.set_rows(owner._people_ledger_rows(people))
	for person_index in range(people.size()):
		var person_root := people_card.find_child("Person%d" % person_index,
			true, false) as Control
		if person_root == null:
			continue
		var person: Dictionary = people[person_index]
		var name_label := person_root.find_child("Name", true, false) as Label
		var role_label := person_root.find_child("Role", true, false) as Label
		var metrics_label := person_root.find_child("PersonMetrics", true, false) as Label
		if name_label != null:
			name_label.text = String(person.get("name", "未命名人物"))
		if role_label != null:
			role_label.text = String(person.get("value", person.get("role", "家族成员")))
		if metrics_label != null:
			metrics_label.text = owner._person_overview_metrics_text(person)


# ── 页头、DossierKpiCard 摘要条与导航状态同步 ───────────────────────────
static func _update_header(owner: FamilyWorkspace) -> void:
	var header: Dictionary = owner._model.get("header", {})
	owner._title.text = String(header.get("name", "家族"))
	owner._subtitle.text = String(header.get("subtitle", ""))
	owner._prestige_value.text = String(header.get("prestige_progress_text", "0%"))
	owner._prestige_caption.text = "威望 %s" % String(header.get("prestige_label", "0"))
	if owner._prestige_plate != null:
		owner._prestige_plate.tooltip_text = "威望 %s · 得分 %s" % [
			String(header.get("prestige_label", "0")),
			String(header.get("prestige_progress_text", "0%"))]



static func _update_summary(owner: FamilyWorkspace, live_patch: bool = false) -> void:
	var items: Array = owner._model.get("summary", [])
	var header: Dictionary = owner._model.get("header", {})
	var icon_map := {
		0: &"family.house",
		1: &"metric.treasury",
		2: &"economy.building",
		3: &"technology.milestone",
	}
	for index in range(owner._kpi_cards.size()):
		var card := owner._kpi_cards[index]
		var item: Dictionary = items[index] if index < items.size() else {}
		var title_str := String(item.get("label", ""))
		var value_str := String(item.get("value", "—"))
		var caption_str := String(item.get("caption", ""))
		var tone_str := ""
		if index == 3:
			var p_label := String(header.get("prestige_label", "0"))
			var p_prog := String(header.get("prestige_progress_text", "0%"))
			if caption_str.is_empty():
				caption_str = "威望 %s · 得分 %s" % [p_label, p_prog]
			if p_label != "0":
				tone_str = "warn"
		var sig := "%s|%s|%s|%s" % [title_str, value_str, caption_str, tone_str]
		var slot := "kpi_%d" % index
		if live_patch and String(owner._kpi_signatures.get(slot, "")) == sig:
			continue
		owner._kpi_signatures[slot] = sig
		card.set_metric({
			"id": String(item.get("id", slot)),
			"title": title_str,
			"kind": "text",
			"text": value_str,
			"value": CellInspectorViewModel._parse_leading_float(value_str, 0.0),
			"caption": caption_str,
			"tone": tone_str,
			"icon": icon_map.get(index, &"summary.overview"),
		})



static func _update_nav_state(owner: FamilyWorkspace) -> void:
	for page_id in FamilyWorkspace.PAGE_ORDER:
		var active := page_id == owner._current_page
		if owner._nav_buttons.has(page_id):
			(owner._nav_buttons[page_id] as Button).set_pressed_no_signal(active)
		if owner._nav_labels.has(page_id):
			var nav_label := owner._nav_labels[page_id] as Label
			nav_label.add_theme_color_override("font_color",
				Color("#fff0c8") if active else Color("#3a2414"))
			nav_label.add_theme_color_override("font_outline_color",
				Color(0.18, 0.06, 0.03, 0.55) if active \
				else Color(1.0, 0.93, 0.76, 0.0))
			nav_label.add_theme_constant_override("outline_size", 2 if active else 1)
		if owner._nav_icons.has(page_id):
			var nav_icon := owner._nav_icons[page_id] as TextureRect
			nav_icon.modulate = Color(1.08, 1.05, 0.98, 1.0) if active else Color.WHITE
		if owner._mobile_buttons.has(page_id):
			(owner._mobile_buttons[page_id] as Button).set_pressed_no_signal(active)
	if owner._chapter_nav != null and owner._chapter_nav.current != owner._current_page:
		owner._chapter_nav.select(owner._current_page, true)
	if FamilyWorkspace.PAGE_META.has(owner._current_page):
		owner._page_title.text = String(FamilyWorkspace.PAGE_META[owner._current_page].title)
		owner._page_icon.texture = IconCatalog.texture_for_key(StringName(FamilyWorkspace.PAGE_META[owner._current_page].icon))
