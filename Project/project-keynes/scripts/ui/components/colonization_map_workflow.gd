extends RefCounted

## Handles choosing source and target cells and getting their offers.


static func open_source(owner: ColonizationPlannerPanel, source_cell: int, family_handle: int) -> void:
	owner.open_target(-1, 0, source_cell)
	var row := owner._quote_row_refs.get(ColonizationPlannerPanel._quote_key({"source_cell": source_cell, "family_handle": family_handle})) as Button
	if row != null and not row.disabled:
		owner._on_reusable_quote_pressed(row)
		owner._scroll_to_pinned_family()
		owner.begin_target_selection()
	else:
		owner._feedback.text = "该城分支已无法派遣，请重新选择家族。"
		owner._feedback.visible = true



static func begin_target_selection(owner: ColonizationPlannerPanel) -> void:
	owner._source_picking = false
	owner._target_picking = true
	owner._update_start_enabled()
	owner.target_selection_requested.emit()



static func cancel_target_selection(owner: ColonizationPlannerPanel) -> void:
	owner._target_picking = false
	owner._clear_pending_quote_reads(&"target")
	owner._update_start_enabled()



static func is_target_picking(owner: ColonizationPlannerPanel) -> bool:
	return owner.visible and owner._target_picking



static func begin_source_selection(owner: ColonizationPlannerPanel) -> void:
	if owner._source_first or owner._source_picking:
		return
	owner._target_picking = false
	owner._pending_quote_reads.erase(&"target")
	owner._source_picking = true
	owner._update_start_enabled()
	owner.source_selection_requested.emit()



static func cancel_source_selection(owner: ColonizationPlannerPanel) -> void:
	owner._source_picking = false
	owner._update_start_enabled()



static func is_source_picking(owner: ColonizationPlannerPanel) -> bool:
	return owner.visible and owner._source_picking


## 当前这次地图点按该落到哪一步。派发界面不再要求玩家先按“选点按钮”进入模式：
## 没定出发城就落到出发城，定了出发城就落到目的地。
static func map_stage(owner: ColonizationPlannerPanel) -> StringName:
	if owner._target_picking:
		return &"target"
	if owner._source_picking:
		return &"source"
	if owner._source_first:
		return &"target"
	return &"source" if owner._source_filter < 0 else &"target"


## 地图左键点选的唯一入口：面板可见时每一步都直接吃地图点击。
## 返回 true 表示这次点按已被派发界面消费（调用方不应再打开地块档案）。
static func handle_map_cell(owner: ColonizationPlannerPanel, cell: int) -> bool:
	if not owner.visible or cell < 0:
		return false
	if owner._current_tab != "quotes":
		owner._show_quotes()
	if owner.map_stage() == &"source":
		if owner._select_source_cell(cell):
			return true
		if owner.try_target_cell(cell, true, owner.handle_map_cell.bind(cell)):
			return true
		owner._set_feedback_line("点地图上的青绿环换出发城；点可见空地改目的地。", UITokens.RISK)
		return false
	if owner.try_target_cell(cell, false, owner.handle_map_cell.bind(cell)):
		return true
	if not owner._source_first and cell != owner._source_filter and owner._select_source_cell(cell):
		owner._set_feedback_line("已把出发城改为 %s。" % owner._cell_name(owner._source_filter),
			UITokens.ARCHIVE_INK_MUTED)
		return true
	return false



static func _select_source_cell(owner: ColonizationPlannerPanel, cell: int) -> bool:
	if owner._source_city == null or cell < 0:
		return false
	var index := owner._source_city.get_item_index(cell)
	if index <= 0:
		return false
	owner._source_picking = false
	owner._source_city.select(index)
	owner._on_source_city_selected(index)
	owner._update_start_enabled()
	return true



static func try_target_cell(owner: ColonizationPlannerPanel, cell: int, quiet: bool = false, on_read: Callable = Callable()) -> bool:
	if owner._controller == null or cell < 0:
		return false
	var family := int(owner._selected_quote.get("family_handle", 0))
	var page: Dictionary = owner._controller.get_family_colonization_quotes(cell, family, owner._source_filter, 0, 256)
	var next := on_read if on_read.is_valid() else owner.try_target_cell.bind(cell, quiet)
	if owner._await_quote_read(&"target", page, next):
		if not quiet:
			owner._set_feedback_line(EconomyStatusCopy.BUSY, UITokens.ARCHIVE_INK_MUTED)
		owner._update_start_enabled()
		return true
	if not bool(page.get("ok", false)):
		owner._update_start_enabled()
		if not quiet:
			owner._set_feedback_line(ColonizationPlannerPanel._reason_text(String(page.get("code", "colonization_target_invalid"))),
				UITokens.RISK)
		return false
	if family > 0 and int(page.get("total", 0)) <= 0:
		owner._update_start_enabled()
		if not quiet:
			# total 为 0 有两种完全不同的原因：全国无路可达（水域或不可通行
			# 地形隔断），或这条路线不收这个家族。补一条「不限城市、不限家族」
			# 的报价就能分开；只有失败路径才会多发这一次查询。
			var probe: Dictionary = owner._controller.get_family_colonization_quotes(cell, 0, -1, 0, 1)
			if owner._await_quote_read(&"target", probe, next):
				owner._update_start_enabled()
				return true
			if not bool(probe.get("ok", false)) or int(probe.get("total", 0)) > 0:
				owner._set_feedback_line("该家族当前无法从此城前往此地，请选择其他目的地。",
					UITokens.RISK)
			else:
				owner._set_feedback_line(ColonizationPlannerPanel.ROUTE_BLOCKED_SHORT, UITokens.RISK,
					ColonizationPlannerPanel._reason_text("colonization_route_unreachable"))
		return false
	owner._target_cell = cell
	owner._target_picking = false
	owner._sources_loaded = false
	owner._quotes_identity = ""
	owner._feedback.text = ""
	owner._show_quotes()
	owner._update_start_enabled()
	return true



static func _set_feedback_line(owner: ColonizationPlannerPanel, message: String, color: Color, tooltip: String = "") -> void:
	owner._feedback.text = message
	owner._feedback.visible = not message.is_empty()
	owner._feedback.tooltip_text = tooltip if not tooltip.is_empty() else message
	owner._feedback.add_theme_color_override("font_color", color)



static func _cell_name(owner: ColonizationPlannerPanel, cell: int) -> String:
	if cell < 0:
		return "待选目的地"
	if owner._controller != null and owner._controller.has_method("dispatch_cell_display_name"):
		return String(owner._controller.dispatch_cell_display_name(cell))
	return "地块 %d" % (cell + 1)



static func _update_workflow(owner: ColonizationPlannerPanel) -> void:
	if owner._workflow == null:
		return
	var source := owner._source_city.text if owner._source_filter >= 0 else "待选城市"
	var family := String(owner._selected_quote.get("display_name", "待选家族"))
	owner._workflow.text = "%s → %s → %s" % [source, family, owner._cell_name(owner._target_cell)]
	owner._footer_selection.text = "已选：%s" % family if not owner._selected_quote.is_empty() else "点击家族确定派遣对象"
	owner._subtitle.text = owner._stage_hint()
	owner._subtitle.visible = not owner._subtitle.text.is_empty()
	# 目的地这一格显示真实地名：点地图能改，但玩家首先要能确认「现在打的是哪」。
	owner._target_button.text = "正在选点" if owner._target_picking else (
		owner._cell_name(owner._target_cell) if owner._target_cell >= 0 else "点地图选目的地")
	owner._target_button.tooltip_text = "正在选点：点地图上的任意地块，Esc 退出" \
		if owner._target_picking else "点地图上的任意地块即可改目的地"
	owner._refresh_route_stepper(source, family)
	owner._refresh_city_cards()
	owner._publish_planning_context()


## 地图当前在听哪一步，就用一句话说清楚，玩家不必猜“要不要先按按钮”。
static func _stage_hint(owner: ColonizationPlannerPanel) -> String:
	if owner._current_tab != "quotes":
		return ""
	if owner._source_picking:
		return "点地图上的青绿环换出发城 · Esc 退出选点"
	if owner._target_picking:
		return "点地图上任意地块选目的地 · Esc 退出选点"
	if owner._source_first:
		return "直接点地图上任意地块选目的地"
	if owner._directory_mode and owner._selected_quote.is_empty():
		return "从左侧按出发地选择家族，再确定派遣人数"
	if owner._source_filter < 0:
		return "点地图上的青绿环选出发城"
	if owner._selected_quote.is_empty():
		return "直接点地图上任意地块改目的地，再从左侧挑选家族"
	return ""



static func _load_local_families(owner: ColonizationPlannerPanel, source_cell: int = -1) -> Dictionary:
	if source_cell < 0:
		source_cell = owner._source_filter
	if source_cell < 0 or owner._controller == null or not owner._controller.has_method("get_family_dispatch_candidates"):
		return {"ok": true}
	var rebuilt := {}
	var offset := 0
	while true:
		var page: Dictionary = owner._controller.get_family_dispatch_candidates(source_cell, offset, 256)
		if not bool(page.get("ok", false)):
			return page
		var handles: PackedInt64Array = page.get("family_handles", PackedInt64Array())
		for index in range(handles.size()):
			var data := {"family_handle": int(handles[index]), "source_cell": source_cell,
				"target_cell": owner._target_cell, "quote_token": 0}
			for pair in [["family_names", "display_name"], ["populations", "population"],
					["cash_claims", "cash_claim"], ["owned_buildings", "owned_buildings"], ["prestige_levels", "prestige_level"]]:
				var values: Variant = page.get(pair[0], [])
				if index < values.size():
					data[pair[1]] = values[index]
			data["maximum_population"] = maxi(0, int(data.get("population", 0)) - 1)
			rebuilt[ColonizationPlannerPanel._quote_key(data)] = data
		if not bool(page.get("has_more", false)) or handles.is_empty():
			break
		offset += handles.size()
	for key in owner._local_families.keys():
		if int(owner._local_families[key].get("source_cell", -1)) == source_cell:
			owner._local_families.erase(key)
	owner._local_families.merge(rebuilt, true)
	return {"ok": true}



static func _get_source_quotes(owner: ColonizationPlannerPanel) -> Dictionary:
	var source := -1 if owner._directory_mode else owner._source_filter
	var page: Dictionary = owner._controller.get_family_colonization_quotes(
		owner._target_cell, owner._family_filter, source, 0, 256)
	var offset := (page.get("family_handles", PackedInt64Array()) as PackedInt64Array).size()
	while bool(page.get("ok", false)) and bool(page.get("has_more", false)) and offset > 0:
		var next: Dictionary = owner._controller.get_family_colonization_quotes(
			owner._target_cell, owner._family_filter, source, offset, 256)
		if not bool(next.get("ok", false)):
			return next
		var handles: PackedInt64Array = next.get("family_handles", PackedInt64Array())
		if handles.is_empty():
			break
		for key in ["family_handles", "source_cells", "maximum_populations", "route_costs",
				"travel_days", "quote_tokens", "surnames", "surname_disambiguators",
				"caravan_populations", "source_settlement_names"]:
			if page.has(key) and next.has(key):
				var values: Variant = page[key]
				values.append_array(next[key])
				page[key] = values
		offset += handles.size()
		page["has_more"] = bool(next.get("has_more", false))
	return page



static func _show_source_families(owner: ColonizationPlannerPanel) -> void:
	owner._title.text = "家族派遣"
	if owner._source_city.item_count == 1:
		owner._source_city.add_item(owner._cell_name(owner._source_filter), owner._source_filter)
		owner._source_city.select(1)
	owner._source_city.disabled = true
	var page := owner._load_local_families()
	if not bool(page.get("ok", false)):
		owner._selected_quote.clear()
		owner._clear_list()
		owner._add_note(String(page.get("message", "当地家族暂不可用。")), UITokens.RISK)
	else:
		var restored := owner._sync_quote_rows(owner._local_families.values(), int(owner._population.value))
		if not restored:
			owner._selected_quote.clear()
			owner._show_family_preview({})
	owner._update_start_enabled()



static func _quote_key(quote: Dictionary) -> String:
	return "%d:%d" % [int(quote.get("source_cell", -1)), int(quote.get("family_handle", 0))]



static func _apply_list_filter_sort(owner: ColonizationPlannerPanel) -> void:
	if owner._current_tab != "quotes":
		return
	var added: Array = []
	for key in owner._quote_row_refs:
		if not owner._display_order.has(key):
			added.append(key)
	added.sort_custom(func(a, b) -> bool:
		var left: Dictionary = owner._quote_row_refs[a].get_meta("quote", {})
		var right: Dictionary = owner._quote_row_refs[b].get_meta("quote", {})
		var field := "prestige_level" if owner._sort.selected == 1 else "maximum_population"
		if owner._sort.selected < 2 and int(left.get(field, 0)) != int(right.get(field, 0)):
			return int(left.get(field, 0)) > int(right.get(field, 0))
		return String(left.get("display_name", "")) < String(right.get("display_name", "")))
	owner._display_order.append_array(added)
	var query := owner._search.text.strip_edges().to_lower()
	var sources: Array = []
	for key in owner._display_order:
		if owner._quote_row_refs.has(key):
			var quote: Dictionary = owner._quote_row_refs[key].get_meta("quote", {})
			var source := int(quote.get("source_cell", -1))
			if not sources.has(source):
				sources.append(source)
	sources.sort()
	var child_index := 0
	for header in owner._source_headers.values():
		header.visible = false
	for source in sources:
		var source_index := owner._source_city.get_item_index(source)
		var city := owner._source_city.get_item_text(source_index) if source_index >= 0 else owner._cell_name(source)
		var header := owner._source_headers.get(source) as Label
		if header == null:
			header = Label.new()
			header.set_meta("source_header", true)
			header.theme_type_variation = &"PKDossierSectionTitle"
			header.autowrap_mode = TextServer.AUTOWRAP_OFF
			header.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			owner._list.add_child(header)
			owner._source_headers[source] = header
		header.text = city
		owner._list.move_child(header, child_index)
		child_index += 1
		for key in owner._display_order:
			if not owner._quote_row_refs.has(key):
				continue
			var row := owner._quote_row_refs[key] as Button
			var quote: Dictionary = row.get_meta("quote", {})
			if int(quote.get("source_cell", -1)) != source:
				continue
			row.visible = query.is_empty() or (city + String(quote.get("display_name", ""))).to_lower().contains(query)
			header.visible = header.visible or row.visible
			owner._list.move_child(row, child_index)
			child_index += 1
	var focus_rows: Array[Button] = []
	for child in owner._list.get_children():
		if child is Button and child.visible and not child.disabled:
			focus_rows.append(child)
	owner._wire_row_focus(focus_rows)
	if not owner._hover_family.is_empty():
		var hovered := owner._quote_row_refs.get(owner._hover_family) as Control
		if hovered == null or not hovered.visible:
			owner._hover_family = ""
			owner._hover_timer.stop()
			owner._show_family_preview(owner._selected_quote)
