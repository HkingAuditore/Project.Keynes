extends RefCounted

## Projects camp requirements, supplies, and family readiness.


static func _refresh_selected_kit(owner: ColonizationPlannerPanel) -> void:
	if owner._selected_quote.is_empty():
		owner._update_start_enabled()
		return
	if int(owner._selected_quote.get("quote_token", 0)) <= 0 or owner._target_cell < 0:
		owner._update_start_enabled()
		return
	var detail: Dictionary = {}
	if owner._controller != null:
		detail = owner._controller.get_family_colonization_quote_detail(
			int(owner._selected_quote.get("quote_token", 0)), int(owner._population.value))
	if owner._await_quote_read(&"detail", detail, owner._refresh_selected_kit):
		owner._detail_valid = false
		owner._update_start_enabled()
		owner._feedback.text = EconomyStatusCopy.BUSY
		owner._feedback.add_theme_color_override("font_color", UITokens.ARCHIVE_INK_MUTED)
		return
	owner._economy_busy = owner._economy_busy or bool(detail.get("busy", false))
	if not bool(detail.get("ok", false)):
		owner._detail_valid = ColonizationPlannerPanel._transient_query_failure(String(detail.get("code", "")), detail)
		owner._update_start_enabled()
		var detail_code := String(detail.get("code", "command_rejected"))
		if ColonizationPlannerPanel._transient_query_failure(detail_code, detail):
			owner._feedback.text = EconomyStatusCopy.BUSY
			owner._feedback.add_theme_color_override("font_color", UITokens.ARCHIVE_INK_MUTED)
			return
		owner._feedback.text = ColonizationPlannerPanel._reason_text(detail_code)
		owner._feedback.visible = true
		owner._feedback.add_theme_color_override("font_color", UITokens.RISK)
		return
	owner._detail_valid = true
	owner._selected_quote.merge(detail, true)
	owner._update_start_enabled()
	if owner._hover_family.is_empty():
		owner._update_preview_route(owner._selected_quote)
	owner.route_requested.emit(detail)



static func _update_start_enabled(owner: ColonizationPlannerPanel) -> void:
	if owner._start == null:
		return
	var on_quotes := owner._current_tab == "quotes"
	owner._expedition_cancel.visible = not on_quotes and owner._expedition_row_refs.has(owner._selected_expedition)
	owner._footer_selection.visible = false
	owner._source_city.get_parent().visible = false
	owner._search.get_parent().visible = on_quotes
	owner._target_button.visible = on_quotes
	if owner._route_stepper != null:
		owner._route_stepper.visible = on_quotes
	owner._sync_population_slider()
	owner._update_workflow()
	var has_selection := not owner._selected_quote.is_empty()
	owner._population_row.visible = on_quotes and has_selection
	owner._start.visible = on_quotes
	owner._start.disabled = not has_selection or owner._target_cell < 0 or owner._target_picking \
		or owner._pending_quote_reads.has(&"target") \
		or int(owner._selected_quote.get("quote_token", 0)) <= 0 or not owner._detail_valid \
		or int(owner._population.value) > int(owner._selected_quote.get("maximum_population", 1))
	var count := int(owner._population.value) if has_selection else 0
	var count_text := UITokens.format_compact_number_cn(float(count), 0)
	# 无家族移民队（family_handle 0）换动词：它搬的是平民，不是族人或随从。
	var caravan := has_selection and int(owner._selected_quote.get("family_handle", 0)) == 0
	var verb := "迁移" if caravan else "派遣"
	var kit_partial := bool(owner._selected_quote.get("kit_partial", false))
	var place_buildings := bool(owner._selected_quote.get("kit_place_buildings", false))
	var kit_ids: PackedInt32Array = owner._selected_quote.get(
		"kit_building_ids", PackedInt32Array())
	var complete_kit := place_buildings and not kit_partial and not kit_ids.is_empty()
	var preparing_kit := place_buildings and (kit_partial or kit_ids.is_empty())
	if owner._target_cell < 0 or owner._target_picking:
		owner._start.text = "请先选择目的地"
	elif owner._economy_busy:
		owner._start.text = ("排队%s %s 人" % [verb, count_text]) if has_selection else "排队%s" % verb
		owner._start.tooltip_text = EconomyStatusCopy.BUSY
	elif complete_kit:
		owner._start.text = ("%s %s 人并%s" % [verb, count_text, "建村" if caravan else "安家"]) if has_selection else "确认%s" % verb
		owner._start.tooltip_text = ColonizationPlannerPanel._kit_summary_text(owner._selected_quote)
	elif preparing_kit:
		owner._start.text = ("开始筹备%s %s 人" % [verb, count_text]) if has_selection else "开始筹备"
		owner._start.tooltip_text = "占用目标；人留在源地继续生产，每日把源地可用现货收进队伍库存，凑齐后自动出发。"
	else:
		owner._start.text = ("%s %s 人" % [verb, count_text]) if has_selection else "确认%s" % verb
		owner._start.tooltip_text = "基础物资不足，只携带当前可用物资" if kit_partial \
			else ColonizationPlannerPanel._kit_summary_text(owner._selected_quote)
	if has_selection and kit_partial and not preparing_kit \
			and not owner._economy_busy \
			and owner._feedback.text.find("排队") < 0 \
			and owner._feedback.text.find("已经出发") < 0:
		owner._feedback.text = "基础物资不足，只携带当前可用物资"
		owner._feedback.add_theme_color_override("font_color", UITokens.WARN)
	owner._feedback.visible = not owner._feedback.text.is_empty()
	owner._feedback.tooltip_text = owner._feedback.text



static func _transient_query_failure(code: String, page: Dictionary) -> bool:
	if bool(page.get("fatal", false)) or code == "economy_paused":
		return false
	if code == "economy_busy_retry":
		return true
	if code == "economy_not_available":
		return bool(page.get("busy", false))
	if not bool(page.get("busy", false)):
		return false
	return code == "colonization_topology_not_ready" \
		or code == "colonization_visibility_unavailable"



static func _has_quote_rows(owner: ColonizationPlannerPanel) -> bool:
	for row_value in owner._quote_row_refs.values():
		if row_value != null and is_instance_valid(row_value):
			return true
	return false



static func _has_expedition_rows(owner: ColonizationPlannerPanel) -> bool:
	for row_value in owner._expedition_row_refs.values():
		if row_value != null and is_instance_valid(row_value):
			return true
	return false



static func _quotes_identity_of(page: Dictionary) -> String:
	var tokens: PackedInt64Array = page.get("quote_tokens", PackedInt64Array())
	var parts := PackedStringArray()
	for token in tokens:
		parts.append(str(int(token)))
	return "%s|%s|%s" % [int(page.get("total", 0)),
		String(page.get("kind", "")), ",".join(parts)]



static func _expeditions_identity_of(page: Dictionary) -> String:
	var handles: PackedInt64Array = page.get("expedition_handles", PackedInt64Array())
	var states: PackedInt32Array = page.get("states", PackedInt32Array())
	var due_days: PackedInt64Array = page.get("due_days", PackedInt64Array())
	var parts := PackedStringArray()
	for index in range(handles.size()):
		var state := int(states[index]) if index < states.size() else 0
		var missing := 0
		var identities: PackedInt64Array = page.get(
			"kit_missing_stock_identities", PackedInt64Array())
		if index < identities.size():
			missing = int(identities[index])
		# A pending purchase can advance without changing stock or party state.
		# The next preparation retry must refresh its tooltip as well.
		var due := int(due_days[index]) if index < due_days.size() else -1
		parts.append("%d:%d:%d:%d" % [int(handles[index]), state, missing, due])
	return "%s|%s" % [int(page.get("total", 0)), ",".join(parts)]



static func _preparing_missing_text(owner: ColonizationPlannerPanel, handle: int, state: int, snapshot: Dictionary = {}, include_progress: bool = true) -> String:
	return ColonizationPlannerPanel.ColonizationKitStatusText._preparing_missing_text(owner._controller, handle, state, snapshot, include_progress)



static func _expedition_row_tooltip(owner: ColonizationPlannerPanel, handle: int, state: int, due_day: int) -> String:
	var missing := owner._preparing_missing_text(handle, state)
	if not missing.is_empty():
		return missing
	if due_day >= 0:
		return "第 %d 日抵达" % due_day
	return ""



static func _quotes_for_source(owner: ColonizationPlannerPanel, page: Dictionary) -> Array:
	var families: PackedInt64Array = page.get("family_handles", PackedInt64Array())
	var sources: PackedInt32Array = page.get("source_cells", PackedInt32Array())
	var maximums: PackedInt64Array = page.get("maximum_populations", PackedInt64Array())
	var caravan_populations: PackedInt64Array = page.get(
		"caravan_populations", PackedInt64Array())
	var costs: PackedInt32Array = page.get("route_costs", PackedInt32Array())
	var days: PackedInt32Array = page.get("travel_days", PackedInt32Array())
	var tokens: PackedInt64Array = page.get("quote_tokens", PackedInt64Array())
	var surnames: PackedStringArray = page.get("surnames", PackedStringArray())
	var disambiguators: PackedInt32Array = page.get(
		"surname_disambiguators", PackedInt32Array())
	var quotes: Array = []
	for index in range(families.size()):
		if index >= sources.size() or (not owner._directory_mode and int(sources[index]) != owner._source_filter):
			continue
		var handle := int(families[index])
		var surname := String(surnames[index]) if index < surnames.size() else "家族"
		var disambiguator := int(disambiguators[index]) if index < disambiguators.size() else 0
		var candidate := {
			"family_handle": handle,
			"source_cell": int(sources[index]) if index < sources.size() else 0,
			"target_cell": owner._target_cell,
			"maximum_population": int(maximums[index]) if index < maximums.size() else 0,
			"anonymous_population": int(caravan_populations[index]) if index < caravan_populations.size() else 0,
			"route_cost": int(costs[index]) if index < costs.size() else 0,
			"travel_days": int(days[index]) if index < days.size() else 1,
			"quote_token": int(tokens[index]) if index < tokens.size() else 0,
			"surname": surname,
			"display_name": "无家族移民" if handle == 0 \
				else ColonizationPlannerPanel._family_display_name(surname, disambiguator),
		}
		quotes.append(candidate)
	quotes.sort_custom(func(a, b) -> bool:
		return String(a.get("display_name", "")) < String(b.get("display_name", "")))
	return quotes



static func _family_display_name(surname: String, disambiguator: int) -> String:
	var stem := surname if not surname.is_empty() else "家族"
	if stem.ends_with("氏"):
		pass
	elif stem != "家族":
		stem = "%s氏" % stem
	if disambiguator > 0:
		return "%s（%d）" % [stem, disambiguator + 1]
	return stem



static func _kit_summary_text(quote: Dictionary) -> String:
	var names: PackedStringArray = quote.get(
		"kit_building_display_names", quote.get("kit_building_stable_ids", PackedStringArray()))
	var counts: PackedInt64Array = quote.get(
		"kit_building_counts", PackedInt64Array())
	if names.is_empty():
		return ""
	var parts := PackedStringArray()
	for index in range(names.size()):
		var label := String(names[index]).strip_edges()
		if label.is_empty():
			continue
		var count := int(counts[index]) if index < counts.size() else 1
		parts.append("%s×%d" % [label, count])
	return "开工包：%s" % "、".join(parts) if not parts.is_empty() else ""



static func _family_view_for(owner: ColonizationPlannerPanel, family_handle: int, fallback_people: int) -> Dictionary:
	if owner._family_view_cache.has(family_handle):
		return owner._family_view_cache[family_handle]
	var view := {
		"family_population": maxi(0, fallback_people),
		"trait_badges": [],
		"effect_text": "特性：无",
	}
	# 无家族移民队的 family_handle 是 0：没有族谱可读，直接给固定名。
	if family_handle == 0:
		view["display_name"] = "无家族移民"
		return view
	if owner._controller != null and owner._controller.has_method("get_family_snapshot"):
		var snapshot: Dictionary = owner._controller.get_family_snapshot(family_handle)
		if bool(snapshot.get("ok", false)):
			view["family_population"] = int(snapshot.get("population",
				view.family_population))
			var family_name := String(snapshot.get("family_name", "")).strip_edges()
			var surname := String(snapshot.get("surname", ""))
			var disambiguator := int(snapshot.get("surname_disambiguator", 0))
			if not family_name.is_empty():
				view["display_name"] = family_name
			elif not surname.is_empty():
				view["display_name"] = ColonizationPlannerPanel._family_display_name(surname, disambiguator)
	if int(view.family_population) <= 0:
		view["family_population"] = maxi(0, fallback_people)
	owner._family_view_cache[family_handle] = view
	return view
