extends RefCounted

## Display helpers borrow the host per call; state and signal receivers stay there.


static func _layout_left_panel(host) -> void:
	if not host.is_inside_tree():
		return
	var viewport_size = host.get_viewport().get_visible_rect().size
	host.set_anchors_preset(Control.PRESET_TOP_LEFT)
	host.position = Vector2(UITokens.ARCHIVE_EDGE_INSET, PlayerTopBar.BAR_HEIGHT + 4.0)
	var ratio = 0.56 if host.TouchUI.is_touch() else 0.45
	var target_w = roundf(viewport_size.x * ratio)
	var compact_viewport = viewport_size.x < UITokens.ARCHIVE_BREAKPOINT_COMPACT
	if compact_viewport:
		target_w = minf(maxf(target_w, 560.0), viewport_size.x - UITokens.ARCHIVE_EDGE_INSET * 2.0)
	if host.TouchUI.is_touch():
		target_w = clampf(target_w, 560.0, maxf(320.0, viewport_size.x - UITokens.ARCHIVE_EDGE_INSET * 2.0))
	host.size = Vector2(target_w, maxf(0.0,
		viewport_size.y - host.position.y - CountryActionBar.BAR_HEIGHT - UITokens.ARCHIVE_EDGE_INSET))
	var body = host.get_node("%Body") as BoxContainer
	var narrow = host.size.x < 560.0
	body.vertical = narrow
	# The footer already carries a population pictogram; the label only repeats it.
	host._population_label.visible = false
	host._population_row.add_theme_constant_override("separation", 4 if narrow else 6)
	host._apply_narrow_density(compact_viewport)
	var list_pane = host.get_node("%ListPane") as Control
	var preview_scroll = host.get_node("%PreviewScroll") as Control
	# At 125% the stacked layout has little vertical room. Let the dossier keep
	# enough height to expose its identity and quick-read band before scrolling.
	# In the stacked view the dossier is the decision surface; keep a compact
	# directory scroll above it rather than letting three rows crowd out the readout.
	list_pane.size_flags_stretch_ratio = 0.36 if narrow else 0.44
	preview_scroll.size_flags_stretch_ratio = 0.64 if narrow else 0.56


static func _apply_narrow_density(host, narrow: bool) -> void:
	var root = host.get_node_or_null("Margin/Root") as VBoxContainer
	if root != null:
		root.add_theme_constant_override("separation", 2 if narrow else 4)
	var tools = host.get_node_or_null("%Tools") as Control
	if tools != null:
		tools.visible = not narrow
	var route = host.get_node_or_null("%RouteStepper") as Control
	if route != null:
		route.add_theme_constant_override("margin_top", 0)
		route.add_theme_constant_override("margin_bottom", 0)
	var body = host.get_node_or_null("%Body") as BoxContainer
	if body != null:
		body.add_theme_constant_override("separation", 6 if narrow else 10)
	var identity_margin = host.get_node_or_null(
		"%PreviewIdentityCard/Margin") as MarginContainer
	if identity_margin != null:
		identity_margin.add_theme_constant_override("margin_top", 0)
		identity_margin.add_theme_constant_override("margin_bottom", 0)
	var quick_margin = host.get_node_or_null(
		"%PreviewQuickRead/Margin") as MarginContainer
	if quick_margin != null:
		quick_margin.add_theme_constant_override("margin_top", 3 if narrow else 5)
		quick_margin.add_theme_constant_override("margin_bottom", 3 if narrow else 5)


static func _sync_quote_rows(host, quotes: Array, keep_population: int) -> bool:
	host._remove_note_children()
	var keep = {}
	var restored = false
	for quote_value in quotes:
		var quote: Dictionary = quote_value.duplicate(true)
		var handle = int(quote.get("family_handle", 0))
		var key = host._quote_key(quote)
		keep[key] = true
		var local: Dictionary = host._local_families.get(key, {})
		for field in ["display_name", "population", "cash_claim", "owned_buildings", "prestige_level"]:
			if local.has(field):
				quote[field] = local[field]
		if not host._local_families.has(key) and host._controller.has_method("get_family_snapshot"):
			var identity: Dictionary = host._controller.get_family_snapshot(handle)
			quote["display_name"] = identity.get("family_name", quote.get("display_name", "家族"))
		var maximum = int(quote.get("maximum_population", 0))
		var row = host._quote_row_refs.get(key) as Button
		if row == null or not is_instance_valid(row):
			row = host.FamilyRowScene.instantiate() as Button
			row.pressed.connect(host._on_reusable_quote_pressed.bind(row))
			row.mouse_entered.connect(host._on_row_preview_entered.bind(row))
			row.mouse_exited.connect(host._on_row_preview_exited.bind(row))
			row.focus_entered.connect(host._on_row_preview_entered.bind(row))
			host._list.add_child(row)
			host._quote_row_refs[key] = row
		row.set_meta("quote", quote)
		var local_people = int(quote.get("population", maximum + 1))
		var prestige_level = int(quote.get("prestige_level", 0))
		row.set_compact_summary({
			"name": String(quote.get("display_name", "家族")),
			"population": local_people,
			"population_tooltip": "",
			"prestige_level": prestige_level,
			"icon": "family.workspace.crest" if prestige_level >= 1 else "family.house",
			"accent": UITokens.DOSSIER_OXBLOOD if prestige_level >= 3 else UITokens.DOSSIER_BRASS,
			"bar_ratio": clampf(float(maximum) / float(maxi(local_people, 1)), 0.0, 1.0),
			"bar_color": UITokens.DOSSIER_VERDIGRIS if maximum > 0 else UITokens.DOSSIER_OXBLOOD,
			"effect": "可派 %s 人" % UITokens.format_compact_number_cn(float(maximum), 0),
		})
		row.disabled = maximum <= 0
		var selected = not host._selected_quote.is_empty() and host._quote_key(host._selected_quote) == key
		row.set_pressed_no_signal(selected)
		if selected:
			host._selected_quote = quote.duplicate(true)
			var source_index = host._source_city.get_item_index(int(quote.get("source_cell", -1)))
			if source_index >= 0:
				host._source_city.select(source_index)
			var editor = host._population.get_line_edit()
			if not host._population.has_focus() and not editor.has_focus():
				host._population.max_value = maxi(1, maximum)
				host._population.set_value_no_signal(clampi(keep_population, 1, maxi(1, maximum)))
			restored = maximum > 0
	for handle in host._quote_row_refs.keys():
		if not keep.has(handle):
			var row = host._quote_row_refs[handle] as Node
			host._list.remove_child(row)
			row.queue_free()
			host._quote_row_refs.erase(handle)
	host._apply_list_filter_sort()
	return restored


static func _show_expeditions(host) -> void:
	host._current_tab = "expeditions"
	host._title.text = "派遣进展"
	if host._tabs != null:
		host._tabs.select_tab("expeditions")
	host._hover_timer.stop()
	host._hover_family = ""
	host._discard_quote_rows()
	host._update_start_enabled()
	if host._controller == null:
		host._clear_list()
		host._expeditions_identity = ""
		host._set_busy_status(false)
		return
	var page = host._expedition_page()
	page = host._filter_expedition_page(page)
	host._economy_busy = bool(page.get("busy", false))
	if not bool(page.get("ok", false)):
		var code = String(page.get("code", "command_rejected"))
		if host._transient_query_failure(code, page):
			host._economy_busy = true
			host._set_busy_status(true)
			if host._has_expedition_rows():
				return
			host._clear_list()
			host._expeditions_identity = ""
			host._add_note("正在等待经济提交完成后显示在途队伍。", UITokens.ARCHIVE_INK_MUTED)
			return
		host._clear_list()
		host._expeditions_identity = ""
		host._set_busy_status(host._economy_busy)
		host._add_note(host._reason_text(code), UITokens.RISK)
		return
	var identity = host._expeditions_identity_of(page)
	if identity == host._expeditions_identity and host._has_expedition_rows():
		host._set_busy_status(host._economy_busy)
		host._refresh_expedition_detail()
		return
	host._expeditions_identity = identity
	host._set_busy_status(host._economy_busy)
	var handles: PackedInt64Array = page.get("expedition_handles", PackedInt64Array())
	if handles.is_empty():
		host._clear_list()
		host._selected_expedition = 0
		host._expedition_cancel.visible = false
		host._show_preview_cards(false, false, false, false, false)
		if host._economy_busy:
			host._add_note("经济正在结算。在途队伍将在提交后刷新。", UITokens.ARCHIVE_INK_MUTED)
		else:
			host._add_note("活动开拓队：无", UITokens.ARCHIVE_INK_MUTED)
		return
	host._sync_expedition_rows(page)
	if not host._expedition_row_refs.has(host._selected_expedition):
		host._selected_expedition = int(handles[0])
	host._refresh_expedition_detail()
	if host.is_inside_tree() and not host.get_viewport().gui_get_focus_owner():
		(host._expedition_row_refs[host._selected_expedition].get_child(0) as Button).grab_focus()


static func _sync_expedition_rows(host, page: Dictionary) -> void:
	host._remove_note_children()
	var handles: PackedInt64Array = page.get("expedition_handles", PackedInt64Array())
	var families: PackedInt64Array = page.get("family_handles", PackedInt64Array())
	var populations: PackedInt64Array = page.get("populations", PackedInt64Array())
	var dues: PackedInt64Array = page.get("due_days", PackedInt64Array())
	var states: PackedInt32Array = page.get("states", PackedInt32Array())
	var keep = {}
	for index in range(handles.size()):
		var expedition_handle = int(handles[index])
		keep[expedition_handle] = true
		var family_handle = int(families[index]) if index < families.size() else 0
		var view: Dictionary = host._family_view_for(family_handle,
			int(populations[index]) if index < populations.size() else 0)
		var state = int(states[index]) if index < states.size() else 0
		var returning = state == 3
		var row_wrap = host._expedition_row_refs.get(expedition_handle) as HBoxContainer
		var row: Button
		if row_wrap == null or not is_instance_valid(row_wrap):
			row_wrap = UIControlParts.h_box_container()
			row_wrap.add_theme_constant_override("separation", UITokens.SPACE_SM)
			row = host.FamilyRowScene.instantiate() as Button
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.toggle_mode = true
			row.pressed.connect(host._on_reusable_expedition_pressed.bind(row))
			row_wrap.add_child(row)
			host._list.add_child(row_wrap)
			host._expedition_row_refs[expedition_handle] = row_wrap
		else:
			row = row_wrap.get_child(0) as Button
		row.set_meta("expedition_handle", expedition_handle)
		row.focus_neighbor_right = row.get_path_to(host._expedition_cancel)
		var party_people = int(populations[index]) if index < populations.size() else 0
		var state_label = host._state_text(state)
		var sources: PackedInt32Array = page.get("source_cells", PackedInt32Array())
		var targets: PackedInt32Array = page.get("target_cells", PackedInt32Array())
		var route_text = "%s 至 %s" % [
			host._cell_name(int(sources[index])) if index < sources.size() else "出发地",
			host._cell_name(int(targets[index])) if index < targets.size() else "目的地"]
		row.set_compact_summary({
			"name": String(view.get("display_name", "家族")),
			"population": party_people,
			"icon": "economy.building" if state == 4 else "action.history",
			"accent": UITokens.DOSSIER_BRASS if state == 4 else UITokens.DOSSIER_VERDIGRIS,
			"tag_text": state_label,
			"tag_color": UITokens.DOSSIER_OXBLOOD if returning else (
				UITokens.DOSSIER_BRASS if state == 4 else UITokens.DOSSIER_VERDIGRIS),
			"bar_ratio": 0.0,
			"bar_color": UITokens.DOSSIER_BRASS if state == 4 else UITokens.DOSSIER_VERDIGRIS,
			"badges": [{
				"text": state_label,
				"accent": UITokens.WARN if returning else UITokens.ACCENT,
			}],
			"effect": "%s  %s" % [state_label, route_text],
			"tooltip": host._expedition_row_tooltip(expedition_handle, state,
				int(dues[index]) if index < dues.size() else -1),
		})
		row.set_meta("expedition_view", {"name": String(view.get("display_name", "家族")),
			"population": int(populations[index]) if index < populations.size() else 0,
			"state": state, "due_day": int(dues[index]) if index < dues.size() else -1})
	var stale: Array = []
	for handle_value in host._expedition_row_refs.keys():
		if not keep.has(handle_value):
			stale.append(handle_value)
	for handle_value in stale:
		var stale_wrap = host._expedition_row_refs[handle_value] as Node
		host._expedition_row_refs.erase(handle_value)
		if stale_wrap != null and is_instance_valid(stale_wrap):
			stale_wrap.queue_free()
	var focus_rows: Array[Button] = []
	for handle in handles:
		focus_rows.append(host._expedition_row_refs[int(handle)].get_child(0) as Button)
	host._wire_row_focus(focus_rows)


static func _refresh_expedition_detail(host) -> void:
	if not host._expedition_row_refs.has(host._selected_expedition):
		return
	for handle in host._expedition_row_refs:
		(host._expedition_row_refs[handle].get_child(0) as Button).set_pressed_no_signal(handle == host._selected_expedition)
	var row = host._expedition_row_refs[host._selected_expedition].get_child(0) as Button
	var view: Dictionary = row.get_meta("expedition_view", {})
	var snap: Dictionary = {}
	if host._controller.has_method("get_family_expedition_snapshot"):
		snap = host._controller.get_family_expedition_snapshot(host._selected_expedition)
	var state = int(snap.get("state", view.get("state", 0)))
	var people = int(snap.get("population", view.get("population", 0)))
	host._expedition_cancel.visible = true
	host._expedition_cancel.disabled = state == 3
	host._expedition_cancel.text = "取消筹备" if state == 4 else "召回队伍"
	host._expedition_cancel.tooltip_text = "队伍已在返程" if state == 3 else (
		"取消筹备，退回已购物资" if state == 4 else "队伍将按当前行程返程")
	host._expedition_cancel.focus_neighbor_top = host._expedition_cancel.get_path_to(row)
	host._preview_title.text = String(view.get("name", "家族"))
	host._preview_metrics.text = "派遣 %s 人" % UITokens.format_compact_number_cn(float(people), 0)
	host._preview_effects.text = host._preparing_missing_text(host._selected_expedition, state, snap, false)
	var due = int(snap.get("due_day", view.get("due_day", -1)))
	host._preview_route.text = "第 %d 日抵达" % due if state != 4 and due >= 0 else ""
	host._paint_expedition_card(host._preview_title.text, host._preview_metrics.text,
		host._preview_effects.text, host._preview_route.text)
	host._preview_state_pill.text = host._state_text(state)
	host._route_ready_pill.text = host._state_text(state)
	host._route_ready_pill.visible = false
	(host.get_node("%RouteCardTitle") as Label).text = "筹备进展" if state == 4 else "行程状态"
	var facts: Array = []
	if snap.has("source_cell"):
		facts.append({"id": "source", "title": "出发地", "value": host._cell_name(int(snap.source_cell)), "icon": "metric.territory"})
	if snap.has("target_cell"):
		facts.append({"id": "target", "title": "目的地", "value": host._cell_name(int(snap.target_cell)), "icon": "system.target"})
	if not host._preview_route.text.is_empty():
		facts.append({"id": "due", "title": "预计抵达", "value": host._preview_route.text, "icon": "family.metric.time"})
	host._route_facts.set_facts(facts)
	host._route_facts.visible = not facts.is_empty()
	var meters: Array = []
	if state == 4:
		var bridge = int(snap.get("kit_bridge_required_units", 0))
		var materials = int(snap.get("kit_material_required_units", 0))
		var missing_bridge = int(snap.get("kit_bridge_missing_units", 0))
		var missing_materials = int(snap.get("kit_material_missing_units", 0))
		for data in [["total", "总进度", bridge + materials, missing_bridge + missing_materials],
				["bridge", "旅途补给", bridge, missing_bridge], ["materials", "开工建材", materials, missing_materials]]:
			if int(data[2]) > 0:
				var percent = host._stock_percent(int(data[2]), int(data[3]))
				meters.append({"id": data[0], "label": data[1], "value": float(percent) / 100.0,
					"value_text": "%d%%" % percent, "accent": UITokens.DOSSIER_BRASS})
	host._preview_meters.visible = not meters.is_empty()
	host._preview_meters.set_meters(meters)


static func _show_family_preview(host, quote: Dictionary, hovering: bool = false) -> void:
	if host._preview_title == null:
		return
	(host.get_node("%RouteCardTitle") as Label).text = "路线与家风"
	(host.get_node("%PreviewQuickRead") as Control).visible = true
	host._route_facts.visible = true
	host._preview_facts.visible = true
	host._route_ready_pill.visible = true
	host._preview_family = int(quote.get("family_handle", 0))
	if quote.is_empty():
		host._preview_title.text = ""
		host._preview_metrics.text = ""
		host._preview_traits.text = ""
		host._preview_preferences.text = ""
		host._preview_effects.text = ""
		host._preview_route.text = ""
		var meters = host.get_node_or_null("%PreviewMeters") as Control
		if meters != null:
			meters.visible = false
		host._paint_waiting_guide()
		return
	host._preview_hovering = hovering
	host._preview_title.text = String(quote.get("display_name", "家族"))
	var meters = host.get_node_or_null("%PreviewMeters") as Control
	if meters != null:
		meters.visible = false
	var preview_source = int(quote.get("source_cell", host._source_filter))
	var key = host._quote_key(quote)
	var preview: Dictionary = host._preview_cache.get(key, {})
	if preview.is_empty():
		if host._controller != null and host._controller.has_method("get_family_dispatch_preview"):
			preview = host._controller.get_family_dispatch_preview(host._preview_family, preview_source)
		else:
			preview = {"ok": true, "traits": {}}
			if host._controller != null and host._controller.has_method("get_family_traits"):
				preview["traits"] = host._controller.get_family_traits(host._preview_family)
		if bool(preview.get("ok", false)):
			host._preview_cache[key] = preview
	if not bool(preview.get("ok", false)):
		host._preview_metrics.text = String(preview.get("message", "当地分支详情暂不可用。"))
		host._preview_traits.text = ""
		host._preview_preferences.text = ""
		host._preview_effects.text = ""
		host._preview_route.text = ""
		host._paint_waiting_guide()
		return
	var branch: Dictionary = preview.get("branch", {})
	host._preview_metrics.text = "当地族人 %s · 可派 %s
威望 %s · 产业 %s
资金归属 %s" % [
		UITokens.format_compact_number_cn(float(branch.get("populations", quote.get("population", int(quote.get("maximum_population", 0)) + 1))), 0),
		UITokens.format_compact_number_cn(float(quote.get("maximum_population", 0)), 0),
		str(branch.get("prestige_levels", quote.get("prestige_level", "—"))),
		str(branch.get("owned_buildings", quote.get("owned_buildings", "—"))),
		UITokens.format_compact_number_cn(float(branch.get("cash_claims", quote.get("cash_claim", 0))) / 10000.0, 2)]
	var traits: Dictionary = preview.get("traits", {})
	# 只替换预览副本的显示列，原始偏好仍由原生家族运行时持有。
	traits = traits.duplicate()
	var visible_preferences = PackedStringArray()
	for behavior: Dictionary in preview.get("behavior_rows", []):
		visible_preferences.append(String(behavior.get("name", "")))
	traits["behavior_selector_display_names"] = visible_preferences
	var effects: Dictionary = preview.get("effects", traits)
	var row = host._quote_row_refs.get(host._quote_key(quote)) as ColonizationFamilyRow
	if row != null:
		row.apply_preview_summary(traits, effects)
	var names: PackedStringArray = traits.get("display_names", PackedStringArray())
	var descriptions: PackedStringArray = traits.get("descriptions", PackedStringArray())
	var core: PackedByteArray = traits.get("core", PackedByteArray())
	var lines = PackedStringArray()
	for i in range(names.size()):
		lines.append("%s · %s
%s" % ["核心" if i < core.size() and core[i] != 0 else "附加",
			names[i], descriptions[i] if i < descriptions.size() else ""])
	host._preview_traits.text = "特性
" + "

".join(lines) if not lines.is_empty() else "特性：无"
	var preferences: PackedStringArray = traits.get("behavior_selector_display_names", PackedStringArray())
	host._preview_preferences.text = "行为偏好
" + "、".join(preferences) if not preferences.is_empty() else ""
	var effect_names: PackedStringArray = effects.get("effect_display_names", PackedStringArray())
	var effect_copy: PackedStringArray = effects.get("effect_current_descriptions", effects.get("effect_descriptions", PackedStringArray()))
	lines.clear()
	for i in range(effect_names.size()):
		lines.append(String(effect_names[i]) + ("
" + String(effect_copy[i]) if i < effect_copy.size() else ""))
	host._preview_effects.text = "当地效果
" + "

".join(lines) if not lines.is_empty() else ""
	host._paint_identity_card(quote, branch, hovering, traits, effects)
	host._paint_trait_card(traits)
	host._paint_effect_card(effects if not effects.is_empty() else traits)
	var route_quote = quote.duplicate(true)
	if hovering and host._target_cell >= 0 and int(quote.get("quote_token", 0)) > 0:
		var people = maxi(1, int(quote.get("maximum_population", 1)))
		var route_key = "%d:%d" % [int(quote.quote_token), people]
		var detail: Dictionary = host._quote_preview_cache.get(route_key, {})
		if detail.is_empty() and host._controller != null:
			detail = host._controller.get_family_colonization_quote_detail(int(quote.quote_token), people)
			if bool(detail.get("ok", false)):
				host._quote_preview_cache[route_key] = detail
		if bool(detail.get("ok", false)):
			route_quote.merge(detail, true)
	host._update_preview_route(route_quote)


static func _update_preview_route(host, quote: Dictionary) -> void:
	if host._target_cell < 0:
		host._preview_route.text = "选定目的地后计算路线和开工物资。"
		host._paint_route_card(quote)
		return
	host._preview_route.text = "目的地 · %s
预计 %d 日抵达
%s" % [host._cell_name(host._target_cell),
		int(quote.get("travel_days", 1)), host._kit_summary_text(quote)]
	if bool(quote.get("kit_partial", false)):
		host._preview_route.text += "
" + ("物资不足，将先在源地筹备。" if bool(quote.get("kit_place_buildings", false)) else "仅携带当前可用的基础物资。")
	host._paint_route_card(quote)


static func _bind_atlas_shell(host) -> void:
	host._header_icon = host.get_node_or_null("%HeaderIcon") as IconBadge
	host._route_stepper = host.get_node_or_null("%RouteStepper") as Control
	host._source_pick_button = host.get_node_or_null("%SourcePickButton") as Button
	host._family_step_label = host.get_node_or_null("%FamilyStepLabel") as Label
	host._source_step_icon = host.get_node_or_null("%SourceStepIcon") as IconBadge
	host._family_step_icon = host.get_node_or_null("%FamilyStepIcon") as IconBadge
	host._target_step_icon = host.get_node_or_null("%TargetStepIcon") as IconBadge
	host._city_picker = host.get_node_or_null("%CityPickerPane") as Control
	host._city_cards_box = host.get_node_or_null("%CityCardsBox") as VBoxContainer
	host._population_slider = host.get_node_or_null("%PopulationSlider") as HSlider
	host._max_population_button = host.get_node_or_null("%MaxPopButton") as Button
	host._guide_card = host.get_node_or_null("%PreviewGuideCard") as Control
	host._guide_icon = host.get_node_or_null("%GuideIcon") as IconBadge
	host._guide_title = host.get_node_or_null("%GuideTitle") as Label
	host._guide_facts = host.get_node_or_null("%GuideFacts") as InspectorFactGrid
	host._guide_notes = host.get_node_or_null("%GuideNotes") as InspectorNoteList
	host._identity_card = host.get_node_or_null("%PreviewIdentityCard") as Control
	if host._identity_card != null:
		var frame = host.get_theme_stylebox("panel", &"MenuChapterNormal")
		if frame is StyleBoxTexture:
			var textured = (frame as StyleBoxTexture).duplicate() as StyleBoxTexture
			textured.modulate_color = Color(1.0, 0.985, 0.93, 0.98)
			host._identity_card.add_theme_stylebox_override("panel", textured)
	host._preview_crest = host.get_node_or_null("%PreviewCrest") as IconBadge
	host._preview_origin = host.get_node_or_null("%PreviewOriginSub") as Label
	host._preview_state_pill = host.get_node_or_null("%PreviewStatePill") as Label
	host._preview_trait_summary = host.get_node_or_null("%PreviewTraitSummary") as RichTextLabel
	host._preview_effect_summary = host.get_node_or_null("%PreviewEffectSummary") as RichTextLabel
	host._preview_facts = host.get_node_or_null("%PreviewFactGrid") as InspectorFactGrid
	host._preview_meters = host.get_node_or_null("%PreviewMeters") as InspectorMeterList
	host._detail_section = host.get_node_or_null("%PreviewDetailSection") as Control
	host._route_block = host.get_node_or_null("%RouteBlock") as Control
	host._route_card_icon = host.get_node_or_null("%RouteCardIcon") as IconBadge
	host._route_ready_pill = host.get_node_or_null("%RouteReadyPill") as Label
	host._route_facts = host.get_node_or_null("%RouteFactGrid") as InspectorFactGrid
	host._kit_badges = host.get_node_or_null("%KitBadges") as BadgeRow
	host._route_notes = host.get_node_or_null("%RouteNotes") as InspectorNoteList
	host._traits_block = host.get_node_or_null("%TraitsBlock") as Control
	host._traits_box = host.get_node_or_null("%TraitsVisualBox") as VBoxContainer
	host._pref_badges = host.get_node_or_null("%PrefBadges") as BadgeRow
	host._effects_block = host.get_node_or_null("%EffectsBlock") as Control
	host._effects_box = host.get_node_or_null("%EffectsVisualBox") as VBoxContainer
	host._set_shell_icon(host._header_icon, &"family.house", UITokens.DOSSIER_OXBLOOD)
	host._set_shell_icon(host.get_node_or_null("%SearchIcon") as IconBadge, &"summary.overview", UITokens.DOSSIER_UMBER)
	host._set_shell_icon(host.get_node_or_null("%SortIcon") as IconBadge, &"trend.flat", UITokens.DOSSIER_UMBER)
	host._set_shell_icon(host._source_step_icon, &"metric.territory", UITokens.DOSSIER_VERDIGRIS)
	host._set_shell_icon(host._family_step_icon, &"family.house", UITokens.DOSSIER_BRASS)
	host._set_shell_icon(host._target_step_icon, &"system.target", UITokens.DOSSIER_BRASS)
	host._set_shell_icon(host.get_node_or_null("%CityPinIcon") as IconBadge, &"metric.territory", UITokens.DOSSIER_VERDIGRIS)
	host._set_shell_icon(host.get_node_or_null("%PopIcon") as IconBadge, &"family.metric.population", UITokens.DOSSIER_OXBLOOD)
	host._set_shell_icon(host._guide_icon, &"metric.territory", UITokens.DOSSIER_OXBLOOD)
	host._set_shell_icon(host.get_node_or_null("%TraitIcon") as IconBadge, &"family.workspace.preferences", UITokens.DOSSIER_OXBLOOD)
	host._set_shell_icon(host.get_node_or_null("%EffectIcon") as IconBadge, &"family.workspace.effects", UITokens.DOSSIER_VERDIGRIS)
	host._set_shell_icon(host.get_node_or_null("%TraitsCardIcon") as IconBadge, &"technology.milestone", UITokens.DOSSIER_OXBLOOD)
	host._set_shell_icon(host.get_node_or_null("%EffectsCardIcon") as IconBadge, &"ecology.growth", UITokens.DOSSIER_VERDIGRIS)
	host._set_shell_icon(host._route_card_icon, &"system.target", UITokens.DOSSIER_BRASS)
	if host._source_pick_button != null and not host._source_pick_button.pressed.is_connected(host._on_source_pick_pressed):
		host._source_pick_button.pressed.connect(host._on_source_pick_pressed)
	if host._population_slider != null and not host._population_slider.value_changed.is_connected(host._on_population_slider_changed):
		host._population_slider.value_changed.connect(host._on_population_slider_changed)
	if host._max_population_button != null and not host._max_population_button.pressed.is_connected(host._on_max_population_pressed):
		host._max_population_button.pressed.connect(host._on_max_population_pressed)
	if host._traits_box != null and host._trait_meters == null:
		host._trait_meters = host.TraitMeterScene.instantiate() as InspectorMeterList
		host._traits_box.add_child(host._trait_meters)
	if host._effects_box != null and host._effect_notes == null:
		host._effect_notes = host.EffectNoteScene.instantiate() as InspectorNoteList
		host._effects_box.add_child(host._effect_notes)
	host._paint_waiting_guide()


static func _set_shell_icon(host, icon: IconBadge, key: StringName, accent: Color) -> void:
	if icon != null:
		icon.set_semantic(key, accent)


static func _sync_population_slider(host) -> void:
	if host._population_slider == null or host._population == null:
		return
	host._population_slider.min_value = host._population.min_value
	host._population_slider.max_value = maxf(host._population.min_value, host._population.max_value)
	host._population_slider.set_value_no_signal(host._population.value)


static func _refresh_route_stepper(host, source_name: String, family_name: String) -> void:
	if host._source_pick_button == null:
		return
	var stage = host.map_stage()
	host._source_pick_button.disabled = host._source_first
	if host._source_first or host._source_filter >= 0:
		host._source_pick_button.text = source_name
	elif host._source_picking:
		host._source_pick_button.text = "正在选出发城"
	else:
		host._source_pick_button.text = "从左侧选择出发地" if host._directory_mode else "点地图选出发城"
	host._source_pick_button.tooltip_text = "出发城已锁定" if host._source_first \
		else "也可直接点地图上的青绿环"
	if host._family_step_label != null:
		var waiting_family = host._selected_quote.is_empty()
		host._family_step_label.text = "待选世家" if waiting_family else family_name
		host._family_step_label.add_theme_color_override("font_color",
			UITokens.ARCHIVE_INK_MUTED if waiting_family else UITokens.DOSSIER_OXBLOOD)
	# 高亮当前这一步：地图点击就落在这里，玩家一眼能看出“现在点地图会发生什么”。
	host._tint_step(host._source_pick_button, stage == &"source", host._source_filter >= 0)
	host._tint_step(host._target_button, stage == &"target", host._target_cell >= 0)
	host._set_shell_icon(host._source_step_icon, &"metric.territory",
		UITokens.DOSSIER_BRASS if host._source_filter >= 0 else UITokens.DOSSIER_VERDIGRIS)
	host._set_shell_icon(host._family_step_icon, &"family.house",
		UITokens.DOSSIER_OXBLOOD if not host._selected_quote.is_empty() else UITokens.ARCHIVE_INK_MUTED)
	host._set_shell_icon(host._target_step_icon, &"system.target",
		UITokens.DOSSIER_BRASS if host._target_cell >= 0 else UITokens.ARCHIVE_INK_MUTED)


static func _tint_step(host, button: Button, active: bool, chosen: bool) -> void:
	if button == null:
		return
	var color = UITokens.DOSSIER_OXBLOOD if active else (
		UITokens.ARCHIVE_INK if chosen else UITokens.ARCHIVE_INK_MUTED)
	button.add_theme_color_override("font_color", color)
	button.add_theme_color_override("font_hover_color", color)
	button.add_theme_color_override("font_pressed_color", UITokens.DOSSIER_OXBLOOD)


static func _refresh_city_cards(host) -> void:
	if host._city_cards_box == null or host._source_city == null:
		return
	var show_picker = host._current_tab == "quotes" and not host._source_first and not host._directory_mode \
		and host._source_city.item_count > 1 and (host._source_filter < 0 or host._source_picking)
	if host._city_picker != null:
		host._city_picker.visible = show_picker
	if not show_picker:
		return
	var prompt = host.get_node_or_null("%CityPromptLabel") as Label
	if prompt != null:
		prompt.text = "正在地图上点选出发城，也可点击卡片" if host._source_picking \
			else "选择地图上的青绿环或下方城市卡片"
	if host._city_cards_identity != host._source_cities_identity:
		host._city_cards_identity = host._source_cities_identity
		for child in host._city_cards_box.get_children():
			host._city_cards_box.remove_child(child)
			child.queue_free()
		host._city_card_buttons.clear()
		for index in range(1, host._source_city.item_count):
			var card = host.FamilyRowScene.instantiate() as Button
			var city_name = host._source_city.get_item_text(index)
			card.set_compact_summary({
				"name": city_name,
				"population_text": "出发",
				"population_tooltip": "选择这座城作为出发地",
				"effect": "点击卡片，或点地图上的青绿环",
				"icon": "metric.territory",
				"accent": UITokens.DOSSIER_VERDIGRIS,
				"tag_text": "可出发",
				"tag_color": UITokens.DOSSIER_VERDIGRIS,
				"bar_ratio": 1.0,
				"bar_color": UITokens.DOSSIER_VERDIGRIS,
			})
			card.set_meta("source_index", index)
			card.pressed.connect(host._on_city_card_pressed.bind(card))
			host._city_cards_box.add_child(card)
			host._city_card_buttons.append(card)
	for card in host._city_card_buttons:
		if not is_instance_valid(card):
			continue
		var index = int(card.get_meta("source_index", -1))
		card.set_pressed_no_signal(index >= 0 and host._source_city.get_item_id(index) == host._source_filter)


static func _show_preview_cards(host, guide: bool, identity: bool, route: bool,
		traits: bool, effects: bool) -> void:
	if host._guide_card != null:
		host._guide_card.visible = guide
	if host._identity_card != null:
		host._identity_card.visible = identity
	if host._detail_section != null:
		host._detail_section.visible = route or traits or effects
	if host._route_block != null:
		host._route_block.visible = route
	if host._traits_block != null:
		host._traits_block.visible = traits
	if host._effects_block != null:
		host._effects_block.visible = effects
	if host._route_block != null:
		var body = host._route_block.get_parent()
		(body.get_node("RouteHead") as Control).visible = route
		(body.get_node("TraitsHead") as Control).visible = traits
		(body.get_node("EffectsHead") as Control).visible = effects


static func _paint_waiting_guide(host) -> void:
	host._show_preview_cards(true, false, false, false, false)
	if host._directory_mode and host._target_cell >= 0:
		host._guide_title.text = "目的地"
		host._guide_facts.set_facts([{"id": "target", "title": "前往", "value": host._cell_name(host._target_cell),
			"icon": "system.target", "accent": UITokens.DOSSIER_BRASS}])
		host._guide_notes.set_notes([])
		host._guide_notes.visible = false
		return
	if host._guide_title != null:
		host._guide_title.text = "开拓"
	if host._guide_facts != null:
		var source_name = host._source_city.text if host._source_city != null and host._source_filter >= 0 else "待选"
		host._guide_facts.set_facts([
			{"id": "source", "title": "出发", "value": source_name,
				"subtitle": "", "icon": "metric.territory",
				"accent": UITokens.DOSSIER_VERDIGRIS},
			{"id": "family", "title": "世家", "value": "待选",
				"subtitle": "", "icon": "family.house",
				"accent": UITokens.DOSSIER_BRASS},
			{"id": "target", "title": "目的地", "value": host._cell_name(host._target_cell) if host._target_cell >= 0 else "待选",
				"subtitle": "", "icon": "system.target",
				"accent": UITokens.DOSSIER_BRASS},
		])
	if host._guide_notes != null:
		host._guide_notes.set_notes([])
		host._guide_notes.visible = false


static func _paint_identity_card(host, quote: Dictionary, branch: Dictionary, hovering: bool,
		traits: Dictionary, effects: Dictionary) -> void:
	host._show_preview_cards(false, true, host._route_block.visible if host._route_block != null else false, true, true)
	host._pulse_identity_card(hovering)
	var people = float(branch.get("populations", quote.get("population",
		int(quote.get("maximum_population", 0)) + 1)))
	var maximum = float(quote.get("maximum_population", 0))
	var prestige_value: Variant = branch.get("prestige_levels", quote.get("prestige_level", 0))
	var prestige_number = float(prestige_value) if typeof(prestige_value) in [TYPE_INT, TYPE_FLOAT] else 0.0
	var buildings = str(branch.get("owned_buildings", quote.get("owned_buildings", "—")))
	var cash = float(branch.get("cash_claims", quote.get("cash_claim", 0))) / 10000.0
	var city_index = host._source_city.get_item_index(int(quote.get("source_cell", host._source_filter)))
	var city_name = host._source_city.get_item_text(city_index) if city_index >= 0 else host._cell_name(int(quote.get("source_cell", -1)))
	if host._preview_crest != null:
		host._preview_crest.set_semantic(
			&"family.workspace.crest" if prestige_number >= 1.0 else &"family.house",
			UITokens.DOSSIER_OXBLOOD if prestige_number >= 3.0 else UITokens.DOSSIER_BRASS)
	if host._preview_origin != null:
		host._preview_origin.text = city_name
	if host._preview_state_pill != null:
		host._preview_state_pill.text = ""
		host._preview_state_pill.visible = false
	host._paint_quick_read(traits, effects if not effects.is_empty() else traits)
	if host._preview_facts != null:
		host._preview_facts.set_facts([
			{"id": "people", "title": "",
				"value": UITokens.format_compact_number_cn(people, 0),
				"subtitle": "", "icon": "family.metric.population",
				"accent": UITokens.DOSSIER_OXBLOOD},
			{"id": "works", "title": "",
				"value": buildings, "subtitle": "", "icon": "economy.building",
				"accent": UITokens.DOSSIER_UMBER},
			{"id": "cash", "title": "",
				"value": UITokens.format_compact_number_cn(cash, 2),
				"subtitle": "", "icon": "metric.treasury",
				"accent": UITokens.DOSSIER_BRASS},
		])
	if host._preview_meters != null:
		host._preview_meters.set_meters([])


static func _paint_quick_read(host, traits: Dictionary, effects: Dictionary) -> void:
	if host._preview_trait_summary == null or host._preview_effect_summary == null:
		return
	var trait_names: PackedStringArray = traits.get("display_names", PackedStringArray())
	var trait_descriptions: PackedStringArray = traits.get("descriptions", PackedStringArray())
	var trait_parts = PackedStringArray()
	for index in mini(trait_names.size(), 2):
		var trait_name = String(trait_names[index]).strip_edges()
		if not trait_name.is_empty():
			trait_parts.append("[b]%s[/b]" % host._bbcode_escape(trait_name))
	if trait_names.size() > 2:
		trait_parts.append("[color=#%s]另 %d 项[/color]" % [
			UITokens.DOSSIER_INK_MUTED.to_html(false), trait_names.size() - 2])
	host._preview_trait_summary.text = "  ·  ".join(trait_parts) if not trait_parts.is_empty() \
		else "[color=#%s]家风：无[/color]" % UITokens.DOSSIER_INK_MUTED.to_html(false)
	var trait_tooltip = PackedStringArray()
	for index in trait_names.size():
		var description = String(trait_descriptions[index]).strip_edges() \
			if index < trait_descriptions.size() else ""
		trait_tooltip.append("%s：%s" % [String(trait_names[index]), description])
	host._preview_trait_summary.tooltip_text = "\n".join(trait_tooltip)

	var effect_names: PackedStringArray = effects.get("effect_display_names", PackedStringArray())
	var effect_copy: PackedStringArray = effects.get("effect_current_descriptions",
		effects.get("effect_descriptions", PackedStringArray()))
	var effect_parts = PackedStringArray()
	if not effect_names.is_empty():
		effect_parts.append("[b]%s[/b]" % host._bbcode_escape(String(effect_names[0])))
		if not effect_copy.is_empty():
			var current = host._compact_effect_text(String(effect_copy[0]))
			if not current.is_empty():
				effect_parts.append(host._highlight_effect_metrics(current))
		if effect_names.size() > 1:
			effect_parts.append("[color=#%s]另 %d 项[/color]" % [
				UITokens.DOSSIER_INK_MUTED.to_html(false), effect_names.size() - 1])
	host._preview_effect_summary.text = "  ·  ".join(effect_parts) if not effect_parts.is_empty() \
		else "[color=#%s]效果：无[/color]" % UITokens.DOSSIER_INK_MUTED.to_html(false)
	var effect_tooltip = PackedStringArray()
	for index in effect_names.size():
		var description = String(effect_copy[index]).strip_edges() \
			if index < effect_copy.size() else ""
		effect_tooltip.append("%s：%s" % [String(effect_names[index]), description])
	host._preview_effect_summary.tooltip_text = "\n".join(effect_tooltip)


static func _pulse_identity_card(host, hovering: bool) -> void:
	if host._identity_card == null or not hovering or UIAnimation.reduced_motion():
		return
	if host._identity_pulse_tween != null and host._identity_pulse_tween.is_valid():
		host._identity_pulse_tween.kill()
	host._identity_card.modulate = Color(1.035, 1.02, 0.975, 1.0)
	host._identity_pulse_tween = host.create_tween()
	host._identity_pulse_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	host._identity_pulse_tween.tween_property(host._identity_card, "modulate", Color.WHITE, 0.16)


static func _paint_trait_card(host, traits: Dictionary) -> void:
	var names: PackedStringArray = traits.get("display_names", PackedStringArray())
	var descriptions: PackedStringArray = traits.get("descriptions", PackedStringArray())
	var core: PackedByteArray = traits.get("core", PackedByteArray())
	var show = not names.is_empty()
	if host._traits_block != null:
		host._traits_block.visible = show
	if not show:
		return
	var meters: Array = []
	for index in range(names.size()):
		var description = descriptions[index] if index < descriptions.size() else ""
		var is_core = index < core.size() and core[index] != 0
		var factor = FamilyBuffCopy.trait_factor_percent(description)
		var badges: Array[Dictionary] = FamilyBuffCopy.extract_trait_badges(description)
		var readout = str(badges[0].get("text", "")) if not badges.is_empty() else ""
		meters.append({
			"id": "trait-%d" % index,
			"label": String(names[index]),
			"value": clampf(factor / 200.0, 0.0, 1.0),
			"value_text": readout,
			"status_label": "",
			"tooltip": description,
			"accent": UITokens.RISK if is_core else UITokens.WARN,
		})
	if host._trait_meters != null:
		host._trait_meters.set_meters(meters)
	var preferences: PackedStringArray = traits.get("behavior_selector_display_names", PackedStringArray())
	var pref_kicker = host.get_node_or_null("%PrefKicker") as Label
	if pref_kicker != null:
		pref_kicker.visible = not preferences.is_empty()
	if host._pref_badges != null:
		host._pref_badges.visible = not preferences.is_empty()
		var badges: Array = []
		for preference in preferences:
			badges.append({"text": String(preference), "accent": UITokens.DOSSIER_BRASS})
		host._pref_badges.set_badges(badges)


static func _paint_effect_card(host, effects: Dictionary) -> void:
	var names: PackedStringArray = effects.get("effect_display_names", PackedStringArray())
	var copy: PackedStringArray = effects.get("effect_current_descriptions",
		effects.get("effect_descriptions", PackedStringArray()))
	var show = true
	if host._effects_block != null:
		host._effects_block.visible = show
	if host._effect_notes == null:
		return
	var notes: Array = []
	if names.is_empty():
		notes.append({
			"id": "effect-none",
			"text": "独特效果：无",
			"accent": UITokens.DOSSIER_INK_MUTED,
		})
	for index in range(mini(names.size(), 4)):
		var description = String(copy[index]) if index < copy.size() else ""
		var text = String(names[index])
		if not description.is_empty():
			text += " · " + description
		notes.append({
			"id": "effect-%d" % index,
			"text": text,
			"accent": UITokens.DOSSIER_VERDIGRIS if index == 0 else UITokens.DOSSIER_UMBER,
		})
	host._effect_notes.set_notes(notes)


static func _preview_party_count(host, quote: Dictionary) -> float:
	if not host._preview_hovering and host._population != null and not host._selected_quote.is_empty():
		return float(host._population.value)
	return float(quote.get("maximum_population", 0))


static func _paint_route_card(host, quote: Dictionary) -> void:
	if host._route_block == null:
		return
	if host._preview_family <= 0 and host._selected_quote.is_empty():
		return
	host._route_block.visible = true
	var waiting = host._target_cell < 0
	if host._route_ready_pill != null:
		if waiting:
			host._route_ready_pill.text = "待定"
		elif bool(quote.get("kit_partial", false)) and bool(quote.get("kit_place_buildings", false)):
			host._route_ready_pill.text = "先筹备"
		elif bool(quote.get("kit_partial", false)):
			host._route_ready_pill.text = "基础物资"
		else:
			host._route_ready_pill.text = "可安家"
	if host._route_facts != null:
		host._route_facts.set_facts([
			{"id": "target", "title": "目的地", "value": host._cell_name(host._target_cell),
				"subtitle": "", "icon": "system.target",
				"accent": UITokens.DOSSIER_BRASS},
			{"id": "days", "title": "行程",
				"value": "待计算" if waiting else "%d 日" % int(quote.get("travel_days", 1)),
				"subtitle": "", "icon": "family.metric.time",
				"accent": UITokens.DOSSIER_UMBER},
			{"id": "party", "title": "随行",
				"value": UITokens.format_compact_number_cn(host._preview_party_count(quote), 0),
				"subtitle": "", "icon": "family.metric.population",
				"accent": UITokens.DOSSIER_OXBLOOD},
		])
	var badges = host._kit_badge_items(quote)
	if host._kit_badges != null:
		host._kit_badges.visible = not badges.is_empty()
		host._kit_badges.set_badges(badges)
	var kicker = host.get_node_or_null("%KitKicker") as Label
	if kicker != null:
		kicker.visible = not badges.is_empty()
	if host._route_notes != null:
		# 路线状态由 pill / facts / kit badges 表达，不再附修饰性引导批注。
		host._route_notes.set_notes([])
		host._route_notes.visible = false


static func _kit_badge_items(host, quote: Dictionary) -> Array:
	var badges: Array = []
	var names: PackedStringArray = quote.get("kit_building_display_names", PackedStringArray())
	var counts: PackedInt64Array = quote.get("kit_building_counts", PackedInt64Array())
	for index in range(names.size()):
		var label = String(names[index]).strip_edges()
		if label.is_empty() or label.contains("_") or label.contains("."):
			continue
		var count = int(counts[index]) if index < counts.size() else 1
		badges.append({"text": "%s ×%d" % [label, count], "accent": UITokens.DOSSIER_VERDIGRIS})
	var professions: PackedStringArray = quote.get("profession_display_names", PackedStringArray())
	var populations: PackedInt64Array = quote.get("profession_populations", PackedInt64Array())
	for index in range(professions.size()):
		var label = String(professions[index]).strip_edges()
		if label.is_empty() or label.contains("_") or label.contains("."):
			continue
		var count = int(populations[index]) if index < populations.size() else 0
		var text = label if count <= 0 else "%s %s人" % [label, UITokens.format_compact_number_cn(float(count), 0)]
		badges.append({"text": text, "accent": UITokens.DOSSIER_BRASS})
	return badges


static func _paint_expedition_card(host, title: String, metrics: String, effects: String, route: String) -> void:
	host._show_preview_cards(false, true, true, false, false)
	host._preview_title.text = title
	host._preview_route.text = route
	(host.get_node("%PreviewQuickRead") as Control).visible = false
	if host._preview_origin != null:
		host._preview_origin.text = metrics
	if host._preview_state_pill != null:
		host._preview_state_pill.text = "在途"
		host._preview_state_pill.visible = true
	if host._preview_crest != null:
		host._preview_crest.set_semantic(&"action.history", UITokens.DOSSIER_BRASS)
	if host._preview_facts != null:
		host._preview_facts.visible = false
	if host._route_ready_pill != null:
		host._route_ready_pill.text = "在途"
	if host._route_notes != null:
		if effects.is_empty():
			host._route_notes.set_notes([])
			host._route_notes.visible = false
		else:
			host._route_notes.visible = true
			host._route_notes.set_notes([{
				"id": "block", "text": effects, "accent": UITokens.DOSSIER_BRASS,
			}])
	if host._kit_badges != null:
		host._kit_badges.visible = false
	var kicker = host.get_node_or_null("%KitKicker") as Label
	if kicker != null:
		kicker.visible = false
