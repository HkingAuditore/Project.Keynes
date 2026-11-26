extends RefCounted

## Applies published data and selection changes to the inspector view.


static func _apply_header(panel, header: Dictionary, _live_patch: bool) -> void:
	panel._kicker_label.text = String(header.get("kicker", ""))
	panel._title_label.text = String(header.get("title", "地块"))
	panel._title_label.tooltip_text = panel._title_label.text
	panel._fit_title_font()
	panel._subtitle_label.text = String(header.get("subtitle", ""))
	panel._subtitle_label.tooltip_text = panel._subtitle_label.text
	panel._subtitle_label.visible = not panel._subtitle_label.text.is_empty()


## 长地名不截断：按可用宽度自动降字号（34 → 18），短名回到 34。
## 只在标题栏宽度变化或换地块时重算；缩字号只改高度不改宽度，不会自激。
static func _fit_title_font(panel) -> void:
	if panel._title_label == null:
		return
	var available: float = panel._title_label.size.x
	if available <= 1.0:
		return
	var font: Font = panel._title_label.get_theme_font("font")
	if font == null:
		return
	var text: String = panel._title_label.text
	if text.is_empty():
		panel._title_label.add_theme_font_size_override("font_size", panel.TITLE_FONT_BASE)
		return
	var size: int = panel.TITLE_FONT_BASE
	while size > panel.TITLE_FONT_MIN and font.get_string_size(
			text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x > available:
		size -= 2
	panel._title_label.add_theme_font_size_override("font_size", size)


## KPI 卡片固定 4 张：多余的隐藏，补丁只改值（卡片自带数值补间）。
## 数值相同的补丁不重启动画，避免每日刷新时卡片反复闪动。
static func _apply_kpis(panel, kpis: Array, live_patch: bool) -> void:
	if panel._summary_band != null:
		panel._summary_band.visible = not kpis.is_empty()
	var visible_count := mini(kpis.size(), panel._kpi_cards.size())
	for i in range(panel._kpi_cards.size()):
		var card := panel._kpi_cards[i] as DossierKpiCard
		card.visible = i < visible_count
		card.show_divider = i < visible_count - 1
		if i >= visible_count:
			continue
		var data: Dictionary = kpis[i]
		var signature := "%s|%s|%s|%s|%s|%s|%s" % [String(data.get("id", "")),
			String(data.get("title", "")), String(data.get("kind", "")),
			str(data.get("value", "")), String(data.get("text", "")),
			String(data.get("caption", "")), String(data.get("tone", ""))]
		var slot := "kpi_%d" % i
		if live_patch and String(panel._kpi_values.get(slot, "")) == signature:
			continue
		panel._kpi_values[slot] = signature
		card.set_metric(data)



static func _apply_colonization_action(panel, action: Dictionary) -> void:
	if panel._colonization_button == null:
		return
	var available := bool(action.get("available", false))
	var kind := String(action.get("kind", "colonize"))
	panel._colonization_button.visible = available
	panel._colonization_button.disabled = not available
	panel._colonization_button.text = "迁徙" if kind == "relocate" else "开拓"
	if available:
		panel._colonization_button.tooltip_text = "向此地派遣家族分支迁徙" \
			if kind == "relocate" else "派遣境内家族分支开拓这块无主地"
	else:
		panel._colonization_button.tooltip_text = String(action.get("reason", ""))



static func _sync_kpi_density(panel) -> void:
	if panel._inspector_root == null:
		return
	var dense: bool = panel._inspector_root.size.y > 1.0 \
		and panel._inspector_root.size.y < panel.DENSE_KPI_MAX_HEIGHT
	for card_value in panel._kpi_cards:
		(card_value as DossierKpiCard).dense = dense


static func set_model(panel, model: Dictionary, _rebuild_visible: bool = true) -> void:
	panel.set_model_for_selection(model)



static func set_player_controller(panel, controller) -> void:
	panel._player_controller = controller
	if panel._object_detail_dialog != null:
		panel._object_detail_dialog.set_player_controller(controller)
	if panel._family_workspace != null:
		panel._family_workspace.set_player_controller(controller)



static func set_model_for_selection(panel, model: Dictionary) -> void:
	if panel._content_box == null:
		panel._ready()
	var new_cell_index := int(model.get("cell_index", -1))
	var cell_changed: bool = new_cell_index != panel._cell_index
	if cell_changed:
		panel._scroll_by_tab.clear()
		panel._pending_tax.clear()
		panel._draft_tax.clear()
		panel._deferred_object_detail_payload.clear()
		panel._section_collapsed.clear()
		panel._kpi_values.clear()
		panel.close_detail(false)
		panel._construction_model = {}
		panel._cell_index = new_cell_index
		if panel._scroll != null:
			panel._scroll.scroll_vertical = 0
	panel._model = model
	if panel._model.is_empty():
		panel._publish_population_discontent({})
		return
	panel._apply_header(panel._model.get("header", {}), false)
	if cell_changed and panel.visible and panel.is_inside_tree():
		UIAnimation.crossfade(panel._titles_box, UITokens.ANIM_FAST)
	panel._apply_colonization_action(panel._model.get("colonization_action", {}))
	panel._apply_kpis(panel._model.get("kpis", []), not cell_changed)
	var tabs: Array = panel._model.get("tabs", [])
	if not panel._has_tab(tabs, panel._current_tab):
		panel._current_tab = "geography"
	# 页签集合会随视野状态变化（未探索 0 个 / 已探索 1 个 / 可见 5 个），
	# 所以按签名判断是否需要重设章节索引。
	var signature: String = panel._tabs_signature(tabs)
	if signature != panel._tabs_signature_cache:
		panel._tabs_signature_cache = signature
		panel._chapter_nav.set_chapters(panel._chapter_spec(tabs), panel._current_tab)
	else:
		panel._chapter_nav.select(panel._current_tab, false)
	panel._chapter_nav.visible = tabs.size() > 1
	if not tabs.is_empty():
		panel._request_tab_data_if_missing(panel._current_tab)
	panel._render_content(false)
	if cell_changed:
		panel._animate_content_in()



static func apply_live_patch(panel, patch: Dictionary) -> void:
	if patch.is_empty() or panel._content_box == null:
		return
	if patch.has("header"):
		var header: Dictionary = patch.get("header", {})
		panel._model["header"] = header
		panel._apply_header(header, true)
	if patch.has("kpis"):
		var kpis: Array = patch.get("kpis", [])
		panel._model["kpis"] = kpis.duplicate()
		panel._apply_kpis(kpis, true)
	var patch_tab := String(patch.get("tab_id", ""))
	if not patch.has("category"):
		return
	if patch_tab != "":
		panel.set_tab_category(patch_tab, patch.get("category", {}))
	if patch_tab != panel._current_tab:
		return
	var category: Dictionary = (panel._model.get("categories", {}) as Dictionary).get(patch_tab, {})
	if panel._category_structure(category) != panel._content_structure:
		panel._render_content(false)
	else:
		panel._apply_category_patch(category)
		panel._publish_population_discontent(category)



static func apply_published_gdp(panel, gdp_kpi: Dictionary) -> void:
	if gdp_kpi.is_empty() or panel._content_box == null:
		return
	var kpis: Array = (panel._model.get("kpis", []) as Array).duplicate()
	if kpis.is_empty():
		return
	var target_id := String(gdp_kpi.get("id", "kpi_gdp"))
	for i in range(kpis.size()):
		var item = kpis[i]
		if item is Dictionary and String((item as Dictionary).get("id", "")) == target_id:
			kpis[i] = gdp_kpi
			panel._model["kpis"] = kpis
			panel._apply_kpis(kpis, true)
			return



static func set_tab_category(panel, tab_id: String, category: Dictionary) -> void:
	if tab_id == "" or category.is_empty():
		return
	var categories: Dictionary = panel._model.get("categories", {})
	# 忙碌是暂态，不能用它覆盖已经显示的已提交内容。
	if bool(category.get("data_pending", false)) and categories.has(tab_id) \
			and not bool((categories[tab_id] as Dictionary).get("data_pending", false)):
		return
	categories[tab_id] = category
	panel._model["categories"] = categories


static func _publish_population_discontent(panel, category: Dictionary) -> void:
	panel._presented_population_discontent = category.get("class_discontent", {}) \
		if panel._current_tab == "population" else {}
	panel._emit_population_discontent()



static func _emit_population_discontent(panel) -> void:
	if panel._inspector_root != null and panel._inspector_root.is_visible_in_tree() \
			and not panel._presented_population_discontent.is_empty():
		panel.population_discontent_changed.emit(panel._cell_index, panel._presented_population_discontent)
	else:
		panel.population_discontent_changed.emit(-1, {})


## 切页或换格后正文逐块淡入：每块错开 28ms，总时长不超过约 0.3s。
static func _animate_content_in(panel) -> void:
	if not panel.visible or not panel.is_inside_tree():
		return
	UIAnimation.stagger_children_in(panel._content_box, 0.028, 8, UITokens.ANIM_FAST)


static func _on_tab_selected(panel, tab_id: String) -> void:
	if panel._scroll != null:
		panel._scroll_by_tab[panel._current_tab] = panel._scroll.scroll_vertical
	panel.close_detail()
	panel._current_tab = tab_id
	if panel._chapter_nav != null:
		panel._chapter_nav.select(tab_id)
	panel.tab_data_requested.emit(tab_id)
	panel._render_content(false)
	panel.call_deferred("_restore_tab_scroll", tab_id)
	panel._animate_content_in()



static func _restore_tab_scroll(panel, tab_id: String) -> void:
	if panel._scroll != null and tab_id == panel._current_tab:
		panel._scroll.scroll_vertical = int(panel._scroll_by_tab.get(tab_id, 0))



static func _request_tab_data_if_missing(panel, tab_id: String) -> void:
	var categories: Dictionary = panel._model.get("categories", {})
	if not categories.has(tab_id):
		panel.tab_data_requested.emit(tab_id)



static func _category_structure(panel, data: Dictionary) -> String:
	return panel.InspectorStructure._category_structure(data)



static func _tabs_signature(panel, tabs: Array) -> String:
	return panel.InspectorStructure._tabs_signature(tabs)



static func _has_tab(panel, tabs: Array, tab_id: String) -> bool:
	for raw in tabs:
		var tab: Dictionary = raw
		if String(tab.get("id", "")) == tab_id:
			return true
	return false
