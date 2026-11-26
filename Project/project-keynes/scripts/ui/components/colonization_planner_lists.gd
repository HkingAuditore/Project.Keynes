extends RefCounted

## Updates the source, offer, and expedition lists.


static func _load_source_cities(owner: ColonizationPlannerPanel) -> Dictionary:
	var cities := {}
	var page := owner._get_source_quotes()
	if not bool(page.get("ok", false)):
		return page
	var sources: PackedInt32Array = page.get("source_cells", PackedInt32Array())
	var names: PackedStringArray = page.get("source_settlement_names", PackedStringArray())
	for index in range(sources.size()):
		var cell := int(sources[index])
		cities[cell] = String(names[index]) if index < names.size() else owner._cell_name(cell)
	var cells: Array = cities.keys()
	cells.sort()
	var parts := PackedStringArray()
	for cell in cells:
		parts.append("%d:%s" % [int(cell), String(cities[cell])])
	var identity := "|".join(parts)
	if identity != owner._source_cities_identity or not owner._sources_loaded:
		owner._source_cities_identity = identity
		owner._source_city.clear()
		owner._source_city.add_item("先选择出发城市", -1)
		for cell in cells:
			owner._source_city.add_item(String(cities[cell]), int(cell))
	owner._source_city.disabled = cells.is_empty()
	owner._sources_loaded = true
	if owner._directory_mode:
		if cells.size() == 1 and owner._selected_quote.is_empty():
			owner._source_filter = int(cells[0])
			owner._source_city.select(1)
		return page
	if owner._source_filter >= 0:
		var selected := owner._source_city.get_item_index(owner._source_filter)
		if selected > 0:
			owner._source_city.select(selected)
			return owner._get_source_quotes()
		owner._source_filter = -1
	# 只有一座城能派人时没有可选项，直接锁定它，别让玩家再点一次。
	if cells.size() == 1:
		owner._source_filter = int(cells[0])
		owner._source_city.select(1)
		return owner._get_source_quotes()
	owner._source_city.select(0)
	return page



static func _on_source_city_selected(owner: ColonizationPlannerPanel, index: int) -> void:
	var source := owner._source_city.get_item_id(index)
	if source >= 0:
		owner._source_picking = false
	if source == owner._source_filter:
		owner._update_start_enabled()
		return
	owner._pending_quote_reads.erase(&"target")
	owner._source_filter = source
	if owner._directory_mode:
		owner._selected_quote.clear()
		owner._detail_valid = false
		for row in owner._quote_row_refs.values():
			row.set_pressed_no_signal(false)
		owner._source_city.select(index)
		owner._show_family_preview({})
		owner._update_start_enabled()
		return
	owner._source_city.select(index)
	owner._local_families.clear()
	owner._preview_cache.clear()
	owner._display_order.clear()
	owner._show_family_preview({})
	owner._selected_quote.clear()
	owner._quotes_identity = ""
	owner._feedback.text = ""
	owner._clear_list()
	owner.route_cleared.emit()
	owner._show_quotes()



static func _show_quotes(owner: ColonizationPlannerPanel) -> void:
	owner._current_tab = "quotes"
	if owner._tabs != null:
		owner._tabs.select_tab("quotes")
	owner._discard_expedition_rows()
	if owner._controller == null:
		owner._clear_list()
		owner._quotes_identity = ""
		owner._set_busy_status(false)
		owner._add_note("游戏尚未就绪。", UITokens.RISK)
		owner._update_start_enabled()
		return
	if owner._target_cell < 0:
		owner._show_source_families()
		return
	var page: Dictionary
	if not owner._sources_loaded or owner._directory_mode or owner._source_filter < 0:
		page = owner._load_source_cities()
	else:
		page = owner._get_source_quotes()
	owner._await_quote_read(&"page", page, owner._show_quotes)
	owner._economy_busy = bool(page.get("busy", false))
	owner._await_quote_read(&"quotes", page, owner._show_quotes)
	if not bool(page.get("ok", false)):
		var code := String(page.get("code", "command_rejected"))
		if ColonizationPlannerPanel._transient_query_failure(code, page):
			owner._economy_busy = true
			owner._set_busy_status(true)
			if owner._has_quote_rows():
				owner._update_start_enabled()
				return
			owner._clear_list()
			owner._quotes_identity = ""
			owner._add_note(EconomyStatusCopy.BUSY, UITokens.ARCHIVE_INK_MUTED)
			owner._update_start_enabled()
			return
		owner._clear_list()
		owner._quotes_identity = ""
		owner._selected_quote.clear()
		owner._set_busy_status(owner._economy_busy)
		owner._add_note(ColonizationPlannerPanel._reason_text(code), UITokens.RISK)
		owner._update_start_enabled()
		return
	if owner._source_filter < 0 and not owner._directory_mode:
		owner._clear_list()
		owner._selected_quote.clear()
		owner._apply_kind(String(page.get("kind", "colonize")))
		owner._set_busy_status(owner._economy_busy)
		if owner._source_city.item_count > 1:
			owner._add_note("请选择出发城市，然后选择该城要派遣的家族。", UITokens.ARCHIVE_INK_MUTED)
		elif owner._economy_busy:
			owner._sources_loaded = false
			owner._add_note(EconomyStatusCopy.BUSY, UITokens.ARCHIVE_INK_MUTED)
		elif int(page.get("total", 0)) <= 0:
			# 城市列表为空不是「没有家族」，而是没有城市能连通这个目标：
			# 水面在拓扑里不可走，只能靠航道门户跳跃，缺科技时整片水就是墙。
			owner._add_note(ColonizationPlannerPanel.ROUTE_UNREACHABLE_NOTE, UITokens.WARN)
		else:
			owner._add_note("可派遣城市：无", UITokens.WARN)
		owner._update_start_enabled()
		return
	owner._local_families.clear()
	if owner._directory_mode:
		for index in range(1, owner._source_city.item_count):
			owner._load_local_families(owner._source_city.get_item_id(index))
	else:
		owner._load_local_families()
	var identity := ColonizationPlannerPanel._quotes_identity_of(page) + str(owner._local_families.hash())
	if identity == owner._quotes_identity and owner._has_quote_rows():
		owner._apply_kind(String(page.get("kind", "colonize")))
		owner._set_busy_status(owner._economy_busy)
		owner._refresh_selected_kit()
		return
	owner._quotes_identity = identity
	owner._apply_kind(String(page.get("kind", "colonize")))
	owner._set_busy_status(owner._economy_busy)
	var quotes := owner._quotes_for_source(page)
	var keep_population := int(owner._population.value) if not owner._selected_quote.is_empty() else 0
	var restored := owner._sync_quote_rows(quotes, keep_population)
	if not restored:
		owner._selected_quote.clear()
		owner._detail_valid = false
		owner._show_family_preview({})
		owner.route_cleared.emit()
	if quotes.is_empty():
		owner._clear_list()
		if owner._economy_busy:
			owner._add_note(EconomyStatusCopy.BUSY,
				UITokens.ARCHIVE_INK_MUTED)
		elif int(page.get("total", 0)) <= 0 and owner._source_city.item_count <= 1:
			# 全国都没城市能到达：换出发城市没有意义，直接点出航道门槛。
			owner._add_note(ColonizationPlannerPanel.ROUTE_UNREACHABLE_NOTE, UITokens.WARN)
		else:
			owner._add_note("可派遣家族：无", UITokens.WARN)
	if restored:
		owner._refresh_selected_kit()
	else:
		owner._update_start_enabled()



static func _sync_quote_rows(owner: ColonizationPlannerPanel, quotes: Array, keep_population: int) -> bool:
	return ColonizationPlannerPanel.PlannerPresentation._sync_quote_rows(owner, quotes, keep_population)



static func _on_reusable_quote_pressed(owner: ColonizationPlannerPanel, row: Button) -> void:
	var quote: Dictionary = row.get_meta("quote", {})
	if quote.is_empty():
		return
	owner._on_quote_row_pressed(quote, row)



static func _on_quote_row_pressed(owner: ColonizationPlannerPanel, quote: Dictionary, row: Button) -> void:
	for child in owner._list.get_children():
		if child is Button and child != row:
			(child as Button).set_pressed_no_signal(false)
	row.set_pressed_no_signal(true)
	owner._select_quote(quote)



static func _select_quote(owner: ColonizationPlannerPanel, quote: Dictionary) -> void:
	owner._hover_family = ""
	owner._hover_timer.stop()
	owner._clear_pending_quote_reads(&"hover")
	owner._feedback.text = ""
	owner._selected_quote = quote.duplicate(true)
	owner._source_filter = int(quote.get("source_cell", owner._source_filter))
	var source_index := owner._source_city.get_item_index(owner._source_filter)
	if source_index >= 0:
		owner._source_city.select(source_index)
	owner._detail_valid = false
	var maximum := maxi(1, int(quote.get("maximum_population", 1)))
	owner._population.max_value = maximum
	owner._population.set_value_no_signal(maximum)
	owner._show_family_preview(quote)
	owner._refresh_selected_kit()



static func _submit_selected(owner: ColonizationPlannerPanel) -> void:
	if owner._selected_quote.is_empty() or owner._start.disabled:
		return
	owner.start_requested.emit({
		"family_handle": int(owner._selected_quote.get("family_handle", 0)),
		"source_cell": int(owner._selected_quote.get("source_cell", 0)),
		"target_cell": int(owner._selected_quote.get("target_cell", 0)),
		"population": int(owner._population.value),
		"quote_token": int(owner._selected_quote.get("quote_token", 0)),
	})



static func _show_expeditions(owner: ColonizationPlannerPanel) -> void:
	ColonizationPlannerPanel.PlannerPresentation._show_expeditions(owner)



static func _filter_expedition_page(owner: ColonizationPlannerPanel, page: Dictionary) -> Dictionary:
	# The native query is country-wide. Keep the planner scoped to the target
	# currently open, and to the selected family when the panel was opened from
	# a family dossier.
	var targets: PackedInt32Array = page.get("target_cells", PackedInt32Array())
	var families: PackedInt64Array = page.get("family_handles", PackedInt64Array())
	var handles: PackedInt64Array = page.get("expedition_handles", PackedInt64Array())
	if targets.is_empty() or (owner._target_cell < 0 and owner._family_filter == 0):
		return page
	var keep := PackedInt32Array()
	for index in range(handles.size()):
		var target_ok := owner._target_cell < 0 or \
			(index < targets.size() and int(targets[index]) == owner._target_cell)
		var family_ok := owner._family_filter == 0 or \
			(index < families.size() and int(families[index]) == owner._family_filter)
		if target_ok and family_ok:
			keep.append(index)
	var filtered := page.duplicate()
	for key in [&"expedition_handles", &"family_handles", &"source_cells",
			&"target_cells", &"populations", &"departure_days", &"due_days",
			&"route_costs", &"states", &"kit_missing_stock_identities"]:
		var values: Variant = page.get(key, null)
		if values == null:
			continue
		var rebuilt = values.duplicate()
		rebuilt.clear()
		for source_index in keep:
			if source_index < values.size():
				rebuilt.append(values[source_index])
		filtered[key] = rebuilt
	filtered["total"] = keep.size()
	filtered["has_more"] = false
	return filtered



static func _sync_expedition_rows(owner: ColonizationPlannerPanel, page: Dictionary) -> void:
	ColonizationPlannerPanel.PlannerPresentation._sync_expedition_rows(owner, page)



static func _on_reusable_expedition_pressed(owner: ColonizationPlannerPanel, row: Button) -> void:
	owner._selected_expedition = int(row.get_meta("expedition_handle", 0))
	owner._refresh_expedition_detail()
	owner.expedition_selected.emit(owner._selected_expedition)



static func open_expeditions(owner: ColonizationPlannerPanel) -> void:
	owner.open_target(-1)
	owner._show_expeditions()



static func _expedition_page(owner: ColonizationPlannerPanel) -> Dictionary:
	var page: Dictionary = owner._controller.get_family_expeditions(0, 128)
	var offset := (page.get("expedition_handles", PackedInt64Array()) as PackedInt64Array).size()
	while bool(page.get("ok", false)) and bool(page.get("has_more", false)) and offset > 0:
		var next: Dictionary = owner._controller.get_family_expeditions(offset, 128)
		if not bool(next.get("ok", false)):
			return next
		var handles: PackedInt64Array = next.get("expedition_handles", PackedInt64Array())
		if handles.is_empty():
			break
		for key in ["expedition_handles", "family_handles", "source_cells", "target_cells",
				"populations", "departure_days", "due_days", "route_costs", "states", "kit_missing_stock_identities"]:
			if page.has(key) and next.has(key):
				var values: Variant = page[key]
				values.append_array(next[key])
				page[key] = values
		offset += handles.size()
		page["has_more"] = bool(next.get("has_more", false))
	return page



static func _refresh_expedition_detail(owner: ColonizationPlannerPanel) -> void:
	ColonizationPlannerPanel.PlannerPresentation._refresh_expedition_detail(owner)



static func _clear_list(owner: ColonizationPlannerPanel) -> void:
	owner._hover_family = ""
	owner._hover_timer.stop()
	owner._clear_pending_quote_reads(&"hover")
	owner._quote_row_refs.clear()
	owner._source_headers.clear()
	owner._display_order.clear()
	owner._expedition_row_refs.clear()
	for child in owner._list.get_children():
		owner._list.remove_child(child)
		child.queue_free()



static func _discard_quote_rows(owner: ColonizationPlannerPanel) -> void:
	for row_value in owner._quote_row_refs.values():
		var row := row_value as Node
		if row != null and is_instance_valid(row):
			owner._list.remove_child(row)
			row.queue_free()
	owner._quote_row_refs.clear()
	owner._display_order.clear()
	for header in owner._source_headers.values():
		header.queue_free()
	owner._source_headers.clear()



static func _discard_expedition_rows(owner: ColonizationPlannerPanel) -> void:
	for row_value in owner._expedition_row_refs.values():
		var row := row_value as Node
		if row != null and is_instance_valid(row):
			owner._list.remove_child(row)
			row.queue_free()
	owner._expedition_row_refs.clear()



static func _remove_note_children(owner: ColonizationPlannerPanel) -> void:
	if owner._list == null:
		return
	for child in owner._list.get_children():
		if child is Label and not child.has_meta("source_header"):
			owner._list.remove_child(child)
			child.queue_free()



static func _add_note(owner: ColonizationPlannerPanel, text: String, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", color)
	owner._list.add_child(label)
