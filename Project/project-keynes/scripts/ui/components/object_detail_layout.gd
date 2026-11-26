extends RefCounted

## Arranges dossier sections and controls responsive fact grids.


static func _add_fact_grid(owner: ObjectDetailDialog, facts: Array) -> Control:
	var panel := ObjectDetailDialog.FactGridScene.instantiate() as PanelContainer
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	owner._content.add_child(panel)
	var grid := panel.get_node("Grid") as GridContainer
	grid.columns = owner._fact_columns_for_width(facts.size(), owner._content_width())
	owner._fact_columns.append(grid.columns)
	owner._fact_grids.append(grid)
	for raw in facts:
		var fact: Dictionary = raw
		var cell := ObjectDetailDialog.FactCellScene.instantiate() as VBoxContainer
		grid.add_child(cell)
		var label := cell.get_node("Label") as Label
		label.text = String(fact.get("label", ""))
		label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
		var value := cell.get_node("Value") as Label
		value.text = String(fact.get("value", "—"))
		value.clip_text = true
		value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		value.autowrap_mode = TextServer.AUTOWRAP_OFF
		value.custom_minimum_size.y = 18
		value.add_theme_font_override("font", UITokens.font_with_weight(650))
		value.add_theme_color_override("font_color",
			ObjectDetailDialog._dossier_accent(fact.get("accent", UITokens.DOSSIER_INK)))
		owner._fact_value_labels.append(value)
	return panel



static func _balanced_fact_columns(fact_count: int) -> int:
	if fact_count <= 1:
		return 1
	if fact_count == 2 or fact_count == 4:
		return 2
	if fact_count % 4 == 0:
		return 4
	if fact_count % 3 == 0 or fact_count % 3 == 2:
		return 3
	return 4



static func _fact_columns_for_width(owner: ObjectDetailDialog, fact_count: int, width: float) -> int:
	var balanced := ObjectDetailDialog._balanced_fact_columns(fact_count)
	if width <= 1.0:
		return balanced
	if width < 220.0:
		return 1
	if width < 420.0:
		return mini(balanced, 2)
	return balanced



static func _content_width(owner: ObjectDetailDialog) -> float:
	if owner._scroll != null and owner._scroll.size.x > 1.0:
		return owner._scroll.size.x
	if owner.size.x > 1.0:
		return owner.size.x
	return 0.0



static func _on_dialog_resized(owner: ObjectDetailDialog) -> void:
	owner._sync_kpi_density()
	owner._sync_cohort_radar_split()
	owner._fit_fact_grids()



static func _fit_embedded_layout(owner: ObjectDetailDialog) -> void:
	owner._sync_kpi_density()
	owner._sync_cohort_radar_split()
	owner._constrain_autowrap(owner._content)
	owner._fit_fact_grids()
	if owner._embedded and owner.is_inside_tree():
		owner.call_deferred("_fit_fact_grids")



static func _constrain_autowrap(owner: ObjectDetailDialog, node: Node) -> void:
	if node == null:
		return
	if node is Label:
		var label := node as Label
		if label.autowrap_mode != TextServer.AUTOWRAP_OFF:
			label.custom_minimum_size.x = 0
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for child in node.get_children():
		owner._constrain_autowrap(child)



static func _fit_fact_grids(owner: ObjectDetailDialog) -> void:
	if owner._fact_grids.is_empty():
		return
	var width := owner._content_width()
	if width <= 1.0:
		return
	for index in range(owner._fact_grids.size()):
		var grid := owner._fact_grids[index]
		if grid == null or not is_instance_valid(grid):
			continue
		var next_columns := owner._fact_columns_for_width(grid.get_child_count(), width)
		grid.columns = next_columns
		if index < owner._fact_columns.size():
			owner._fact_columns[index] = next_columns



static func _add_rows_card(owner: ObjectDetailDialog, title_text: String, icon_key: String, accent: Color,
		rows: Array) -> Control:
	if rows.is_empty():
		return null
	var dossier_color := ObjectDetailDialog._dossier_accent(accent)
	var panel := ObjectDetailDialog.RowsCardScene.instantiate() as PanelContainer
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.clip_contents = false
	owner._content.add_child(panel)
	var icon := panel.get_node("Box/TitleRow/Icon") as IconBadge
	icon.set_semantic(StringName(icon_key), dossier_color)
	var title := panel.get_node("Box/TitleRow/Title") as Label
	title.text = title_text
	title.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	var row_box := panel.get_node("Box/Rows") as VBoxContainer
	for raw in rows:
		var data: Dictionary = raw
		if not bool(data.get("visible", true)):
			continue
		var line := ObjectDetailDialog.DetailLineScene.instantiate() as VBoxContainer
		row_box.add_child(line)
		var name_label := line.get_node("Line/Name") as Label
		name_label.text = String(data.get("name", ""))
		name_label.clip_text = true
		name_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_SOFT)
		var value_text := String(data.get("value", "")).strip_edges()
		var value_label := line.get_node("Line/Value") as Label
		value_label.text = value_text
		value_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
		var detail := String(data.get("detail", "")).strip_edges()
		var value_too_long := value_text.length() > 22
		value_label.clip_text = false
		value_label.visible = not value_text.is_empty() and not value_too_long
		if value_too_long:
			if detail.is_empty():
				detail = value_text
			elif detail != value_text:
				detail = "%s\n%s" % [value_text, detail]
		var detail_label := line.get_node("Detail") as Label
		detail_label.text = detail
		detail_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
		detail_label.visible = not detail.is_empty()
		var tooltip := String(data.get("tooltip", "")).strip_edges()
		line.tooltip_text = tooltip if not tooltip.is_empty() else detail
	return panel



static func _add_muted_note(owner: ObjectDetailDialog, text: String, color: Color = UITokens.DOSSIER_INK_MUTED) -> Control:
	var note := ObjectDetailDialog.NoteScene.instantiate() as Label
	note.text = text
	note.add_theme_color_override("font_color", ObjectDetailDialog._dossier_accent(color))
	owner._content.add_child(note)
	return note



static func _configure_section_nav(owner: ObjectDetailDialog, kind: String) -> void:
	var compat_labels := {
		"overview": "概览",
		"operations": "需求" if kind == "cohort" else \
			"人物与分支" if kind == "family" else "经营" if kind == "building" \
			else "供需",
		"effects": "效果",
	}
	var visible_count := 0
	for section_id in owner._section_buttons:
		var button := owner._section_buttons[section_id] as Button
		button.text = String(compat_labels.get(section_id, section_id))
		button.visible = owner._section_targets.has(section_id)
		visible_count += 1 if button.visible else 0
	owner._section_nav.visible = visible_count > 1

	if owner._chapter_nav == null:
		return
	var chapters: Array = []
	if kind == "good":
		chapters = [
			{"id": "overview", "label": "供需与价格", "icon": &"metric.goods", "question": ""},
			{"id": "operations", "label": "贸易与税率", "icon": &"tax.tariff", "question": ""},
		]
	elif kind == "cohort":
		chapters = [
			{"id": "overview", "label": "民生与收支", "icon": &"population.heart", "question": ""},
			{"id": "operations", "label": "消费与税率", "icon": &"metric.goods", "question": ""},
		]
	elif kind == "building":
		chapters = [
			{"id": "overview", "label": "生产与岗位", "icon": &"economy.building.factory", "question": ""},
			{"id": "operations", "label": "财务与税率", "icon": &"metric.treasury", "question": ""},
		]
	else:
		var icon_map := {
			"overview": &"summary.overview",
			"operations": &"economy.building.factory",
			"effects": &"trend.up",
		}
		for section_id in ["overview", "operations", "effects"]:
			if owner._section_targets.has(section_id):
				chapters.append({
					"id": section_id,
					"label": String(compat_labels.get(section_id, section_id)),
					"icon": icon_map.get(section_id, &"summary.overview"),
					"question": "",
				})
	owner._chapter_nav.visible = chapters.size() > 1
	if chapters.size() > 1:
		owner._chapter_nav.set_chapters(chapters, owner._current_chapter)



static func _on_chapter_selected(owner: ObjectDetailDialog, section_id: String) -> void:
	if owner._payload_kind in ["good", "cohort", "building"]:
		owner._apply_dossier_chapter(section_id, true)
		return
	if owner._chapter_nav != null and owner._chapter_nav.visible:
		owner._chapter_nav.select(section_id, true)
	owner._scroll_to_section(section_id)



static func _apply_dossier_chapter(owner: ObjectDetailDialog, section_id: String, animate: bool) -> void:
	if owner._scroll != null and owner._current_chapter != section_id:
		owner._scroll_by_chapter[owner._current_chapter] = owner._scroll.scroll_vertical
	owner._current_chapter = section_id if (section_id == "overview" or section_id == "operations") else "overview"
	if owner._chapter_nav != null and owner._chapter_nav.visible:
		owner._chapter_nav.select(owner._current_chapter, animate)
	var refs := owner._good_refs if owner._payload_kind == "good" \
		else (owner._cohort_refs if owner._payload_kind == "cohort" else owner._building_refs)
	var overview_page := refs.get("overview_page") as Control
	var operations_page := refs.get("operations_page") as Control
	if overview_page != null:
		overview_page.visible = owner._current_chapter == "overview"
	if operations_page != null:
		operations_page.visible = owner._current_chapter == "operations"
	var active_page := overview_page if owner._current_chapter == "overview" else operations_page
	if animate and active_page != null:
		owner._replay_page_charts(active_page)
	if owner._scroll != null:
		var next_scroll := int(owner._scroll_by_chapter.get(owner._current_chapter, 0))
		owner._scroll.scroll_vertical = next_scroll
		if animate:
			owner.call_deferred("_restore_scroll", next_scroll)



static func _replay_page_charts(owner: ObjectDetailDialog, node: Node) -> void:
	if node == null:
		return
	if node is DossierChart:
		(node as DossierChart).replay_growth()
		(node as DossierChart)._start_animation()
	for child in node.get_children():
		owner._replay_page_charts(child)



static func _scroll_to_section(owner: ObjectDetailDialog, section_id: String) -> void:
	if owner._scroll == null or not owner._section_targets.has(section_id):
		return
	owner.call_deferred("_ensure_section_visible", section_id)



static func _ensure_section_visible(owner: ObjectDetailDialog, section_id: String) -> void:
	var target := owner._section_targets.get(section_id) as Control
	if target != null and is_instance_valid(target):
		owner._scroll.ensure_control_visible(target)



static func _restore_scroll(owner: ObjectDetailDialog, value: int) -> void:
	if owner._scroll != null:
		owner._scroll.scroll_vertical = value
