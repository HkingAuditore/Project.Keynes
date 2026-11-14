extends RefCounted

# G5 collaborator. The host owns all mutable state; it is passed per call.

func _build_promotion_overlay(host) -> void:
	if host._promotion_layer != null or host._promotion_dialog == null:
		return
	host._promotion_dialog.visible = false
	host._promotion_layer = Control.new()
	host._promotion_layer.name = "PromotionOverlay"
	host._promotion_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host._promotion_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	host._promotion_layer.visible = false
	host.add_child(host._promotion_layer)
	var veil = ColorRect.new()
	veil.name = "PromotionVeil"
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.color = Color(0.07, 0.045, 0.025, 0.46)
	veil.mouse_filter = Control.MOUSE_FILTER_STOP
	host._promotion_layer.add_child(veil)
	var center = CenterContainer.new()
	center.name = "PromotionCenter"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host._promotion_layer.add_child(center)
	host._promotion_sheet = PanelContainer.new()
	host._promotion_sheet.name = "PromotionSheet"
	host._promotion_sheet.custom_minimum_size = Vector2(460, 238)
	host._promotion_sheet.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	host._promotion_sheet.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	host._promotion_sheet.add_theme_stylebox_override("panel", host.ArtScript.paper_style(24.0,
		Color(0.985, 0.95, 0.84, 0.99)))
	host.ArtScript.attach_panel_shadow(host._promotion_sheet, 0.30, 4.0)
	center.add_child(host._promotion_sheet)
	var margin = MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_%s" % side, 28)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 22)
	host._promotion_sheet.add_child(margin)
	var column = VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)
	host._promotion_title = host.ArtScript.label("晋升民族精神", 25, host.ArtScript.INK,
		HORIZONTAL_ALIGNMENT_CENTER)
	host._promotion_title.add_theme_font_override("font",
		preload("res://assets/fonts/muyao/display_handwritten.tres"))
	column.add_child(host._promotion_title)
	var rule = HSeparator.new()
	rule.modulate = host.ArtScript.GOLD_LEAF
	column.add_child(rule)
	host._promotion_copy = host.ArtScript.label("", 17, host.ArtScript.INK_MUTED,
		HORIZONTAL_ALIGNMENT_CENTER)
	host._promotion_copy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	host._promotion_copy.custom_minimum_size.y = 62
	column.add_child(host._promotion_copy)
	var note = host.ArtScript.label("晋升不可逆，现有国策槽位将转为民族精神。", 14,
		host.ArtScript.VERMILION, HORIZONTAL_ALIGNMENT_CENTER)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(note)
	var actions = HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 12)
	column.add_child(actions)
	host._promotion_cancel = Button.new()
	host._promotion_cancel.text = "暂不晋升"
	host._promotion_cancel.custom_minimum_size = Vector2(132, 38)
	host._promotion_cancel.theme_type_variation = &"PKHUDButton"
	host._promotion_cancel.focus_mode = Control.FOCUS_ALL
	host._promotion_cancel.pressed.connect(host._close_promotion_overlay)
	actions.add_child(host._promotion_cancel)
	host._promotion_confirm = Button.new()
	host._promotion_confirm.text = "确认晋升"
	host._promotion_confirm.custom_minimum_size = Vector2(148, 38)
	host._promotion_confirm.theme_type_variation = &"PKSealPrimaryButton"
	host._promotion_confirm.focus_mode = Control.FOCUS_ALL
	host._promotion_confirm.pressed.connect(host._confirm_promotion)
	actions.add_child(host._promotion_confirm)
	host.call_deferred("_wire_promotion_focus")



func _wire_promotion_focus(host) -> void:
	if host._promotion_cancel == null or host._promotion_confirm == null \
			or not host._promotion_cancel.is_inside_tree():
		return
	host._promotion_cancel.focus_neighbor_right = host._promotion_confirm.get_path()
	host._promotion_confirm.focus_neighbor_left = host._promotion_cancel.get_path()



func _close_promotion_overlay(host) -> void:
	host._pending_promotion_id = -1
	if host._promotion_layer != null:
		host._promotion_layer.visible = false
	if host.is_visible_in_tree():
		host._focus_initial_action()


## Touch and click-accessible detail overlay using IdeologyDetailTooltip so
## players on Android/touchscreens can inspect next-level effects, understanding
## progress, class support gauges, and restrictions without hover tooltips.

func _open_detail_modal(host, ideology_id: int, is_offer: bool = false) -> void:
	if ideology_id < 0 or host._detail_layer == null:
		return
	host._detail_ideology_id = ideology_id
	host._detail_is_offer = is_offer
	host._present_detail_dictionary(host._detail_data(ideology_id, is_offer))



func _open_resonance_detail(host, school_id: String) -> void:
	if school_id.is_empty() or host._detail_layer == null:
		return
	host._detail_ideology_id = -1
	host._detail_is_offer = false
	var active_ids: PackedInt32Array = host._snapshot.get("active_synergy_ids", PackedInt32Array())
	var active_set = {}
	for value in active_ids:
		active_set[int(value)] = true
	var counts = host._school_counts(-1)
	var count = int(counts.get(school_id, 0))
	var active_lines = PackedStringArray()
	var next_lines = PackedStringArray()
	for row_value in host._catalog.get("synergies", []) as Array:
		var row = row_value as Dictionary
		if String(row.get("school_id", "")) != school_id:
			continue
		var dense_id = int(row.get("dense_id", -1))
		var tip = String(row.get("tooltip", "")).strip_edges()
		if tip.is_empty():
			continue
		if active_set.has(dense_id):
			active_lines.append(tip)
		else:
			next_lines.append("需推行 %d 项 · %s" % [int(row.get("min_count", 0)), tip])
	if active_lines.is_empty():
		active_lines.append("当前已推行本流派 %d 项，尚未触发共鸣" % count)
	host._present_detail_dictionary({
		"name": "%s流派共鸣" % host.ArtScript.school_name(school_id),
		"school_id": school_id,
		"rarity": 2,
		"status": "已推行 %d 项" % count,
		"progress": {},
		"effects": active_lines,
		"next_effects": next_lines,
		"next_level_label": "更高阶共鸣",
		"notes": PackedStringArray(["推行同流派国策或晋升民族精神可累积流派共鸣点数。"]),
		"supports": [],
	})



func _present_detail_dictionary(host, data: Dictionary) -> void:
	if host._detail_layer == null or host._detail_body_host == null or data.is_empty():
		return
	for child in host._detail_body_host.get_children():
		host._detail_body_host.remove_child(child)
		child.queue_free()
	host._apply_offer_layer_insets()
	var view_h = host.get_viewport_rect().size.y if host.is_inside_tree() else 720.0
	var insets = host._safe_insets()
	var safe_v = float(insets.get("top", 0.0)) + float(insets.get("bottom", 0.0))
	var close_h = maxf(38.0, host.TouchUI.min_units())
	if host._detail_close != null:
		host._detail_close.custom_minimum_size.y = close_h
	var max_scroll_h = maxf(160.0, view_h - safe_v - close_h - 110.0)
	var tooltip = host.ArtScript.interactive_detail_tooltip(data, max_scroll_h)
	host._detail_body_host.add_child(tooltip)
	host._detail_layer.visible = true
	if host._detail_close != null and host.is_visible_in_tree():
		host._detail_close.grab_focus()



func _close_detail_modal(host) -> void:
	host._detail_ideology_id = -1
	host._detail_is_offer = false
	if host._detail_layer != null:
		host._detail_layer.visible = false
	if host.is_visible_in_tree() and not (host._offer_layer != null and host._offer_layer.visible):
		host._focus_initial_action()



func is_detail_modal_open(host) -> bool:
	return host._detail_layer != null and host._detail_layer.visible



func _focus_initial_action(host) -> void:
	if not host.is_visible_in_tree() or host._offer_layer.visible:
		return
	var focused = host.get_viewport().gui_get_focus_owner()
	if focused != null and host.is_ancestor_of(focused):
		return
	if not host._offer_button.disabled:
		host._offer_button.grab_focus()
	else:
		host._sort.grab_focus()



func _build_dynamic_parts(host) -> void:
	host._build_stage_scenery()
	host._build_archive_chrome()
	host._style_school_tabs()
	for index in 3:
		var card = host._choice(index)
		card.set("draggable", false)
		# One click on an offer card selects the road; the collection keeps the
		# deliberate double click because browsing must never equip by accident.
		card.set("activate_on_single_click", true)
		card.call("set_stage", true)
		card.connect("activated", host._on_choice_activated.bind(index))
		if card.has_signal("detail_requested"):
			card.connect("detail_requested", host._on_choice_detail_requested)
		card.gui_input.connect(host._on_choice_input.bind(index))
	host._build_stage_header()
	# The waiting stage shows a shuffled deck instead of three blank card backs,
	# so no placeholder frame is ever visible before the reveal plays.
	host._draw_stack = host.DrawStack.new()
	var offer_cards = host._choice_0.get_parent() as Control
	host._offer_cards = offer_cards as HBoxContainer
	if offer_cards != null and offer_cards.get_parent() != null:
		host._offer_column = offer_cards.get_parent() as VBoxContainer
		host._offer_column.add_child(host._draw_stack)
		host._offer_column.move_child(host._draw_stack, offer_cards.get_index())
	host._draw_stack.visible = false
	host._offer_actions = host._reroll_button.get_parent() as HBoxContainer
	host._offer_body = host._offer.get_node("OfferBody") as MarginContainer
	host._build_stage_footer()
	host._apply_stage_metrics()
	host.resized.connect(host._on_workspace_resized)
	if host._point_scroll != null:
		if host._point_scroll.has_signal("ledger_requested"):
			host._point_scroll.connect("ledger_requested", host._open_ledger)
		host._point_scroll.gui_input.connect(func(event: InputEvent) -> void:
			if event is InputEventMouseButton:
				var mouse = event as InputEventMouseButton
				if mouse.button_index == MOUSE_BUTTON_LEFT and not mouse.pressed:
					host._open_ledger()
					host._point_scroll.accept_event())
	# Everything below is optional chrome: a missing node must never abort the
	# builder and leave the tabs, sort menu or resonance row unbuilt.
	if host._tabs != null:
		host._tabs.add_tab("全部")
		for school_id in host.ArtScript.SCHOOL_ORDER:
			host._tabs.add_tab(host.ArtScript.school_name(String(school_id)))
		host._tabs.tab_changed.connect(host._on_tab_changed)
	if host._sort != null:
		for label in host.SORT_LABELS:
			host._sort.add_item(String(label))
		host._sort.item_selected.connect(host._on_sort_selected)
	if host._collection_drop != null:
		host._collection_drop.set_drag_forwarding(Callable(), host._can_drop_collection,
			host._drop_collection)
	if host._resonance_bar != null:
		for school_id in host.ArtScript.SCHOOL_ORDER:
			var view = host.ResonanceEmblem.new()
			view.configure(String(school_id))
			view.activated.connect(host._open_resonance_detail)
			host._resonance_bar.add_child(view)
			host._resonance_views[String(school_id)] = view


## Lift the board from a pair of bare containers into a physical archive:
## a titled national-idea banner, a bound cabinet for the equipped roads and
## an indexed folio for everything the country has collected.

func _build_archive_chrome(host) -> void:
	if host._top_bar != null:
		var top_row = host._point_scroll.get_parent() as Control
		var identity = VBoxContainer.new()
		identity.custom_minimum_size.x = 112
		identity.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		identity.mouse_filter = Control.MOUSE_FILTER_IGNORE
		top_row.add_child(identity)
		top_row.move_child(identity, 0)
		host._top_title = host.ArtScript.label("国家理念", 24, host.ArtScript.INK,
			HORIZONTAL_ALIGNMENT_LEFT)
		host._top_title.add_theme_font_override("font",
			preload("res://assets/fonts/muyao/display_handwritten.tres"))
		identity.add_child(host._top_title)
	if host._deck_table != null:
		host._build_deck_heading()
	if host._collection_drop != null:
		host._build_collection_heading()
	if host._scroll != null and not host._scroll.resized.is_connected(host._on_collection_resized):
		host._scroll.resized.connect(host._on_collection_resized)
	if host._resonance_bar != null:
		var row = host._resonance_bar.get_parent() as Control
		var tag = row.get_node_or_null("ResonanceTag") as Label
		if tag != null:
			tag.theme_type_variation = &"Label"
			tag.add_theme_color_override("font_color", host.ArtScript.INK)
			tag.add_theme_font_size_override("font_size", 14)
	host._apply_archive_metrics()



func _build_deck_heading(host) -> void:
	var deck_scroll = host._deck_table.get_node_or_null(
		"DeckBody/DeckScroll") as ScrollContainer
	if deck_scroll == null:
		return
	var deck_column = deck_scroll.get_node_or_null("DeckColumn") as VBoxContainer
	if deck_column == null:
		return
	host._deck_heading = HBoxContainer.new()
	host._deck_heading.name = "DeckHeading"
	host._deck_heading.add_theme_constant_override("separation", 10)
	host._deck_heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var deck_emblem = TextureRect.new()
	deck_emblem.texture = IconCatalog.texture_for_key(&"hud.country.ideology")
	deck_emblem.custom_minimum_size = Vector2(24, 24)
	deck_emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	deck_emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	deck_emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
	deck_emblem.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	deck_emblem.modulate = Color(1.0, 0.96, 0.82, 0.96)
	host._deck_heading.add_child(deck_emblem)
	var identity = VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.add_theme_constant_override("separation", 0)
	identity.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host._deck_heading.add_child(identity)
	var title = host.ArtScript.label("已推行国策", 21, host.ArtScript.INK,
		HORIZONTAL_ALIGNMENT_LEFT)
	title.add_theme_font_override("font",
		preload("res://assets/fonts/muyao/display_handwritten.tres"))
	identity.add_child(title)
	host._build_slot_sections(deck_column)


## 国策与民族精神各占完整栏宽，标题紧邻对应槽位。

func _build_slot_sections(host, deck_column: VBoxContainer) -> void:
	if host._ideology_slots == null or host._spirit_slots == null:
		return
	# The deck title has already claimed the top band. These section markers
	# remain compact so both slot shapes stay visible at 720p.
	host._ideology_section_header = host._make_slot_section_header(1)
	host._ideology_section_header.name = "IdeologySectionHeader"

	host._spirit_alcove = PanelContainer.new()
	host._spirit_alcove.name = "SpiritCeremonialAlcove"
	host._spirit_alcove.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host._spirit_alcove.add_theme_stylebox_override("panel",
		host._spirit_alcove_rule_style())
	host.ArtScript.attach_panel_shadow(host._spirit_alcove, 0.19)
	host._spirit_inset = MarginContainer.new()
	host._spirit_inset.name = "SpiritInset"
	host._spirit_inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right"]:
		host._spirit_inset.add_theme_constant_override("margin_%s" % side, 4)
	for side in ["top", "bottom"]:
		host._spirit_inset.add_theme_constant_override("margin_%s" % side, 4)
	host._spirit_alcove.add_child(host._spirit_inset)
	host._spirit_slots.reparent(host._spirit_inset)
	host._spirit_section_header = host._make_slot_section_header(2)
	host._spirit_section_header.name = "SpiritSectionHeader"
	var ordinary_well = PanelContainer.new()
	ordinary_well.name = "IdeologySlotWell"
	ordinary_well.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ordinary_well.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ordinary_well.add_theme_stylebox_override("panel",
		host._spirit_alcove_rule_style())
	var ordinary_inset = MarginContainer.new()
	ordinary_inset.name = "IdeologyInset"
	ordinary_inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ordinary_inset.add_theme_constant_override("margin_left", 2)
	ordinary_inset.add_theme_constant_override("margin_top", 2)
	ordinary_inset.add_theme_constant_override("margin_right", 2)
	ordinary_inset.add_theme_constant_override("margin_bottom", 2)
	ordinary_well.add_child(ordinary_inset)
	host._ideology_slots.reparent(ordinary_inset)
	host._spirit_alcove.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 各组标题与内容相邻，窄栏也能完整阅读卡面，不再挤成两个半宽槽。
	var groups = VBoxContainer.new()
	groups.name = "SlotGroups"
	groups.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	groups.add_theme_constant_override("separation", 10)
	groups.add_child(host._ideology_section_header)
	groups.add_child(ordinary_well)
	groups.add_child(host._spirit_section_header)
	groups.add_child(host._spirit_alcove)
	deck_column.add_child(groups)
	# 总标题固定；每组标题跟随自己的内容滚动。
	var old_deck_body = host._deck_scroll.get_parent() as MarginContainer
	var deck_stack = VBoxContainer.new()
	deck_stack.name = "DeckBody"
	deck_stack.add_theme_constant_override("separation", 3)
	deck_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	old_deck_body.add_child(deck_stack)
	old_deck_body.move_child(deck_stack, 0)
	old_deck_body.remove_child(host._deck_scroll)
	deck_stack.add_child(host._deck_heading)
	deck_stack.add_child(host._deck_scroll)
	host._deck_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL



func _make_slot_section_header(host, kind: int) -> PanelContainer:
	var panel = PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.custom_minimum_size.y = 26 if kind == 1 else 32
	panel.add_theme_stylebox_override("panel",
		host.ArtScript.paper_style(0.0, Color(0.94, 0.92, 0.84)
			if kind == 1 else Color(0.29, 0.40, 0.27)))
	var layer = Control.new()
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(layer)
	var chrome = host.SlotSectionChrome.new()
	chrome.kind = kind
	chrome.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chrome.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(chrome)
	var row = HBoxContainer.new()
	row.name = "SectionRow"
	row.add_theme_constant_override("separation", 5)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(row)
	var tab = PanelContainer.new()
	tab.name = "SectionTab"
	tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tab_tint = Color(0.78, 0.89, 0.79) if kind == 1 \
		else Color(0.29, 0.40, 0.27)
	tab.add_theme_stylebox_override("panel", host.ArtScript.paper_style(0.0, tab_tint))
	row.add_child(tab)
	var title = host.ArtScript.label("国家理念" if kind == 1 else "民族精神",
		18,
		host.ArtScript.INK if kind == 1 else host.ArtScript.GOLD_LEAF,
		HORIZONTAL_ALIGNMENT_LEFT)
	title.name = "SectionTitle"
	title.add_theme_font_override("font",
		preload("res://assets/fonts/muyao/display_handwritten.tres"))
	title.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var tab_margin = MarginContainer.new()
	tab_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tab_margin.add_theme_constant_override("margin_left", 10)
	tab_margin.add_theme_constant_override("margin_right", 10)
	tab.add_child(tab_margin)
	tab_margin.add_child(title)
	var rule = Control.new()
	rule.name = "SectionRule"
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rule.custom_minimum_size.y = 1
	row.add_child(rule)
	return panel



static func _spirit_alcove_rule_style(host) -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.20, 0.13, 0.10)
	style.border_color = Color(0.79, 0.62, 0.30, 0.72)
	style.set_border_width_all(1)
	style.corner_radius_top_left = 7
	style.corner_radius_top_right = 7
	style.corner_radius_bottom_left = 7
	style.corner_radius_bottom_right = 7
	style.content_margin_left = 3
	style.content_margin_top = 3
	style.content_margin_right = 3
	style.content_margin_bottom = 3
	return style



func _build_collection_heading(host) -> void:
	if host._collection_heading == null:
		return
	var parent = host._collection_heading.get_parent()
	var index = host._collection_heading.get_index()
	host._collection_heading_surface = PanelContainer.new()
	host._collection_heading_surface.name = "CollectionHeadingSurface"
	host._collection_heading_surface.add_theme_stylebox_override("panel", host.ArtScript.paper_style(12.0))
	parent.add_child(host._collection_heading_surface)
	parent.move_child(host._collection_heading_surface, index)
	host._collection_heading.reparent(host._collection_heading_surface)
	host._collection_heading_top = host._collection_heading.get_node("HeadingTop")
	host._collection_title = host._collection_heading_top.get_node("CollectionTitle")
	host._collection_title.text = "理念收藏"
	host._collection_title.theme_type_variation = &"Label"
	host._collection_title.add_theme_color_override("font_color", host.ArtScript.INK)
	host._collection_title.add_theme_font_override("font",
		preload("res://assets/fonts/muyao/display_handwritten.tres"))
	host._collection_tabs_scroll = host._collection_heading.get_node("TabsScroll")
	host._collection_heading.add_theme_constant_override("separation", 6)



func _style_school_tabs(host) -> void:
	if host._tabs == null:
		return
	host._tabs.add_theme_font_override("font", UITokens.dossier_font("sans"))
	host._tabs.add_theme_font_size_override("font_size", 15)
	host._tabs.add_theme_stylebox_override("tab_unselected", host._tab_style("normal"))
	host._tabs.add_theme_stylebox_override("tab_focus", StyleBoxEmpty.new())
	for state in ["normal", "hover", "pressed", "selected", "disabled"]:
		var style = host._tab_style(state)
		if state == "selected":
			host._tabs.add_theme_stylebox_override("tab_selected", style)
		else:
			host._tabs.add_theme_stylebox_override("tab_%s" % state, style)
	host._tabs.add_theme_color_override("font_selected_color", Color(0.97, 0.90, 0.72))
	host._tabs.add_theme_color_override("font_unselected_color", host.ArtScript.INK_MUTED)
	host._tabs.add_theme_color_override("font_hovered_color", host.ArtScript.VERMILION)
	host._tabs.add_theme_color_override("font_disabled_color", Color(0.35, 0.28, 0.21, 0.48))
	host._tabs.add_theme_constant_override("h_separation", 5)
	host._tabs.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_NEVER



func _tab_style(host, state: String) -> StyleBox:
	var tint = Color(0.94, 0.90, 0.80)
	if state == "selected" or state == "pressed":
		tint = Color(0.76, 0.32, 0.23)
	elif state == "hover":
		tint = Color.WHITE
	return host.ArtScript.paper_style(8.0, tint)



func _apply_archive_metrics(host) -> void:
	if host._slot_column != null:
		var slot_min_w = host.SLOT_COLUMN_MIN_WIDTH_COMPACT if host._compact else host.SLOT_COLUMN_MIN_WIDTH
		if host._compact and host.size.x > 0.0 and host.size.x < 720.0:
			slot_min_w = minf(slot_min_w, maxf(230.0, floorf(host.size.x * 0.40)))
		host._slot_column.custom_minimum_size.x = slot_min_w
		host._slot_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		host._slot_column.size_flags_stretch_ratio = 0.72
	if host._collection_column != null:
		var col_min_w = host.COLLECTION_COLUMN_MIN_WIDTH_COMPACT if host._compact else host.COLLECTION_COLUMN_MIN_WIDTH
		if host._compact and host.size.x > 0.0 and host.size.x < 720.0:
			col_min_w = minf(col_min_w, maxf(280.0, floorf(host.size.x * 0.56)))
		host._collection_column.custom_minimum_size.x = col_min_w
		host._collection_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		host._collection_column.size_flags_stretch_ratio = 1.4
	if host._top_bar != null:
		host._top_bar.custom_minimum_size.y = 58 if host._compact else 80
	if host._top_title != null:
		host._top_title.add_theme_font_size_override("font_size", 20 if host._compact else 24)
	if host._point_scroll != null:
		host._point_scroll.custom_minimum_size = Vector2(270, 48) \
			if host._compact else Vector2(360, 56)
	if host._offer_button != null:
		host._offer_button.custom_minimum_size = Vector2(154, 34) \
			if host._compact else Vector2(210, 42)
		host._offer_button.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
		host._offer_button.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	if host._deck_heading != null:
		host._deck_heading.custom_minimum_size.y = 30 if host._compact else 42
	if host._ideology_section_header != null:
		host._ideology_section_header.custom_minimum_size.y = 24 if host._compact else 30
	if host._spirit_section_header != null:
		host._spirit_section_header.custom_minimum_size.y = 24 if host._compact else 42
	if host._spirit_inset != null:
		var horizontal_inset = 4 if host._compact else 7
		host._spirit_inset.add_theme_constant_override(
			"margin_left", horizontal_inset)
		host._spirit_inset.add_theme_constant_override(
			"margin_right", horizontal_inset)
		host._spirit_inset.add_theme_constant_override(
			"margin_top", 3 if host._compact else 7)
		host._spirit_inset.add_theme_constant_override(
			"margin_bottom", 3 if host._compact else 7)
	if host._resonance_panel != null:
		host._resonance_panel.custom_minimum_size.y = 34 if host._compact else 54
	if host._deck_scroll != null:
		# 短窗允许滚动阅读，不用整组内容的最小高度撑开工作区。
		host._deck_scroll.custom_minimum_size.y = 80 if host._compact else 260
		host.TouchUI.widen_scrollbars(host._deck_scroll)
	if host._scroll != null:
		host.TouchUI.widen_scrollbars(host._scroll)
	if host._resonance_panel != null:
		host._resonance_panel.visible = true
	if host._collection_heading != null:
		host._collection_heading.custom_minimum_size.y = 0
	if host._collection_heading_surface != null:
		host._collection_heading_surface.custom_minimum_size.y = 44 if host._compact else 80
		host._collection_heading_surface.add_theme_stylebox_override("panel",
			host.ArtScript.paper_style(6.0 if host._compact else 12.0))
	if host._collection_title != null:
		host._collection_title.add_theme_font_size_override(
			"font_size", 17 if host._compact else 24)
	if host._collection_tabs_scroll != null:
		host._collection_tabs_scroll.custom_minimum_size.y = 34
		var tab_parent: Control = host._collection_heading
		if host._collection_tabs_scroll.get_parent() != tab_parent:
			host._collection_tabs_scroll.reparent(tab_parent)
		host._collection_tabs_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if host._collection_heading_top != null:
		host._collection_heading_top.add_theme_constant_override(
			"separation", 6 if host._compact else 12)
		# The authored plate names the collection in every layout; the scene's
		# paper tag would repeat it as a second, unrelated title.
		var scene_title = host._collection_heading_top.get_node_or_null(
			"CollectionTitle") as Control
		if scene_title != null:
			scene_title.visible = true
		var spacer = host._collection_heading_top.get_node_or_null("HeadingSpacer") as Control
		if spacer != null:
			spacer.visible = true
	if host._collection_margin != null:
		var inset = 6 if host._compact else 10
		for side in ["left", "top", "right", "bottom"]:
			host._collection_margin.add_theme_constant_override("margin_%s" % side, inset)
	if host._body != null:
		host._body.add_theme_constant_override("separation", 12 if host._compact else 18)
	if host._sort != null:
		host._sort.add_theme_font_override("font", UITokens.dossier_font("sans"))
		host._sort.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)


## One-shot, session-scoped entrance. Daily refresh and tab changes never replay
## it; reduced motion skips it entirely.

func _play_workspace_intro(host) -> void:
	if host._entry_intro_played or not host.is_inside_tree():
		return
	host._entry_intro_played = true
	if host.motion_reduced():
		return
	for node in [host._deck_table, host._collection_heading, host._collection_drop]:
		if node is Control:
			(node as Control).modulate.a = 0.0
	var tween = host.create_tween().set_parallel(true)
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if host._deck_table != null:
		tween.tween_property(host._deck_table, "modulate:a", 1.0, 0.26)
	if host._collection_heading != null:
		tween.tween_property(host._collection_heading, "modulate:a", 1.0, 0.22).set_delay(0.06)
	if host._collection_drop != null:
		tween.tween_property(host._collection_drop, "modulate:a", 1.0, 0.30).set_delay(0.12)


## Keep the modal paper quiet so the candidate cards carry the hierarchy.

func _build_stage_scenery(host) -> void:
	host.ArtScript.attach_panel_shadow(host._offer, 0.30, 16)
	host._offer_layer.theme = preload("res://assets/themes/player_session_theme.tres")
	host._offer_title.add_theme_color_override("font_color", host.ArtScript.INK)



func _build_stage_header(host) -> void:
	var column = host._offer_column if host._offer_column != null \
		else host._offer_title.get_parent() as VBoxContainer
	host._offer_column = column
	var header = VBoxContainer.new()
	header.name = "StageHeader"
	header.alignment = BoxContainer.ALIGNMENT_CENTER
	header.add_theme_constant_override("separation", 0)
	host._offer_header = header
	var title_parent = host._offer_title.get_parent()
	var title_index = host._offer_title.get_index()
	title_parent.remove_child(host._offer_title)
	host._offer_title.owner = null
	column.add_child(header)
	column.move_child(header, title_index)
	header.add_child(host._offer_title)




func _build_stage_footer(host) -> void:
	if host._offer_column != null and host._offer_actions != null:
		var target_index = host._offer_column.get_children().find(host._offer_actions)
		if target_index >= 0:
			var footer = VBoxContainer.new()
			footer.name = "StageFooter"
			footer.alignment = BoxContainer.ALIGNMENT_CENTER
			footer.add_theme_constant_override("separation", 2)
			host._offer_footer = footer
			host._offer_column.add_child(footer)
			host._offer_column.move_child(footer, target_index)
			host._offer_column.remove_child(host._offer_actions)
			host._offer_actions.owner = null
			footer.add_child(host._offer_actions)
			host._offer_hint = host.ArtScript.label("悬停查看详情 · 单击选定 · Esc 收起",
				14, host.ArtScript.INK_MUTED)
			footer.add_child(host._offer_hint)



func set_model(host, model: Dictionary) -> void:
	host._bind_nodes()
	host._apply_model(model)



func refresh_model(host, model: Dictionary) -> void:
	host._bind_nodes()
	host._apply_model(model)



func set_compact(host, compact: bool) -> void:
	host._bind_nodes()
	# 触摸档（手机横屏逻辑 1942×873）走紧凑版：让渡一列给卡面，页签才有 44dp 的位置。
	compact = compact or host.TouchUI.is_short_viewport()
	var changed = compact != host._compact
	host._compact = compact
	# Card glyph sizes are cheap to reapply, so they never wait for a signature
	# change; only the container rebuild below is gated.
	if not changed and not host._signature.is_empty():
		return
	host._apply_stage_metrics()
	host._empty.custom_minimum_size = Vector2(0, 150 if compact else 170)
	host._apply_archive_metrics()
	host._style_school_tabs()
	if host._compact and Time.get_ticks_msec() >= host._hint_hold_until:
		host._hint.visible = false
	for view in host._resonance_views.values():
		(view).set_compact(compact)
	host._signature = []
	if not host._snapshot.is_empty() and not host._presentation.is_empty():
		host._rebuild_board()
		host._signature = host._board_signature(
			host._snapshot.get("known_ids", PackedInt32Array()))



static func _safe_insets(host) -> Dictionary:
	var insets = {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	var tree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return insets
	var settings = tree.root.get_node_or_null("/root/GameSettings")
	if settings != null and settings.has_method("ui_scaling"):
		var scaling = settings.call("ui_scaling")
		if scaling != null and scaling.has_method("safe_insets"):
			insets = scaling.call("safe_insets")
	return insets



func _apply_offer_layer_insets(host) -> void:
	var insets = host._safe_insets()
	var safe_left = float(insets.get("left", 0.0))
	var safe_top = float(insets.get("top", 0.0))
	var safe_right = float(insets.get("right", 0.0))
	var safe_bottom = float(insets.get("bottom", 0.0))
	var v_margin = 24.0 if host._compact else 48.0
	if host._offer_layer != null:
		host._offer_layer.offset_left = 24.0 + safe_left
		host._offer_layer.offset_top = v_margin + safe_top
		host._offer_layer.offset_right = -24.0 - safe_right
		host._offer_layer.offset_bottom = -v_margin - safe_bottom
	if host._detail_layer != null:
		host._detail_layer.offset_left = safe_left
		host._detail_layer.offset_top = safe_top
		host._detail_layer.offset_right = -safe_right
		host._detail_layer.offset_bottom = -safe_bottom



func _stage_card_size(host) -> Vector2:
	# The tray is modal over the workspace, not the whole game viewport. Measuring
	# the workspace height here was what pushed the action row below 720p.
	var view_height = host._offer_layer.size.y if host._offer_layer != null \
		and host._offer_layer.size.y > 0.0 else host.size.y if host.size.y > 0.0 else 576.0
	var view_width = host._offer_layer.size.x if host._offer_layer != null \
		and host._offer_layer.size.x > 0.0 else 1024.0
	var base_chrome = host.STAGE_CHROME_HEIGHT_COMPACT if host._compact else host.STAGE_CHROME_HEIGHT
	var action_min_y = maxf(32.0, host.TouchUI.min_units())
	if host._offer_actions != null:
		action_min_y = maxf(action_min_y, host._offer_actions.get_combined_minimum_size().y)
	var extra_actions_height = maxf(0.0, action_min_y - 32.0)
	var chrome_height = base_chrome + extra_actions_height
	host._stage_available_height = maxf(0.0,
		view_height - host.STAGE_OUTER_INSET * 2.0 - chrome_height)
	var height = clampf(host._stage_available_height, host.STAGE_CARD_MIN_HEIGHT,
		host.STAGE_CARD_MAX_HEIGHT)
	if view_width > 0.0:
		var gutter = 62.0 if host._compact else 136.0
		height = minf(height, ((view_width - gutter) / 3.0) / host.CardScript.CARD_ASPECT)
	height = maxf(height, 118.0)
	return Vector2(roundf(height * host.CardScript.CARD_ASPECT), roundf(height))



func _apply_stage_metrics(host) -> void:
	host._apply_offer_layer_insets()
	var cards: HBoxContainer = null
	if host._choice_0 != null:
		cards = host._choice_0.get_parent() as HBoxContainer
	var separation = 18 if host._compact else 28
	var card_size = host._stage_card_size()
	host._stage_card_applied = card_size
	if host._offer != null:
		var chrome_width = 54.0 if host._compact else 92.0
		var desired_width = card_size.x * 3.0 + separation * 2.0 + chrome_width
		host._offer.custom_minimum_size = Vector2(
			minf(host._offer_layer.size.x - host.STAGE_OUTER_INSET * 2.0, desired_width), 0)
	if cards != null:
		# 720p keeps the three offer cards and their actions inside one viewport.
		cards.add_theme_constant_override("separation", separation)
		var column = cards.get_parent() as VBoxContainer
		if column != null:
			column.add_theme_constant_override("separation", 4 if host._compact else 7)
		# Reserve the three-card row even while the deck shuffles, so the tray does
		# not jump in size when the offer lands.
		cards.custom_minimum_size.x = card_size.x * 3.0 + separation * 2.0
		cards.custom_minimum_size.y = card_size.y
	if host._offer_title != null:
		host._offer_title.add_theme_font_size_override("font_size", 22 if host._compact else 28)
		if host._compact:
			host._offer_title.theme_type_variation = host.COMPACT_TITLE_STYLE
			host._offer_title.custom_minimum_size = Vector2.ZERO
		else:
			host._offer_title.theme_type_variation = &"Label"
			host._offer_title.custom_minimum_size = Vector2(0, 34)
	if host._offer_header != null:
		host._offer_header.add_theme_constant_override("separation", 0)
	if host._offer_hint != null:
		host._offer_hint.add_theme_font_size_override("font_size", 14)
		host._offer_hint.visible = true
	var button_min_y = maxf(30.0 if host._compact else 32.0, host.TouchUI.min_units())
	if host._offer_actions != null:
		host._offer_actions.add_theme_constant_override("separation", 8 if host._compact else 12)
		for button in host._offer_actions.get_children():
			if button is Button:
				(button as Button).custom_minimum_size.y = maxf(
					(button as Button).custom_minimum_size.y, button_min_y)
		button_min_y = maxf(button_min_y, host._offer_actions.get_combined_minimum_size().y)
	if host._offer_footer != null:
		host._offer_footer.add_theme_constant_override("separation", 0 if host._compact else 2)
		host._offer_footer.custom_minimum_size.y = maxf(48.0 if host._compact else 52.0, button_min_y + 20.0)
	if host._offer_body != null:
		var inset = 10 if host._compact else 16
		host._offer_body.add_theme_constant_override("margin_left", inset)
		host._offer_body.add_theme_constant_override("margin_right", inset)
		host._offer_body.add_theme_constant_override("margin_top", 6 if host._compact else 10)
		host._offer_body.add_theme_constant_override("margin_bottom", 6 if host._compact else 10)
	for index in 3:
		var card = host._choice(index)
		if card == null:
			continue
		# Stage text follows the actual offer size, not the collection compact
		# style. Otherwise a 145px 720p card still uses 16px frame padding.
		card.call("set_compact", false)
		card.set("stage_rest_offset", Vector2.ZERO)
		card.set("stage_rest_rotation", 0.0)
		card.call("reset_motion")
		card.call("set_stage_size", card_size)
	if host._draw_stack != null:
		host._draw_stack.set_card_size(card_size)



func _on_workspace_resized(host) -> void:
	if host._choice_0 == null:
		return
	host._apply_offer_layer_insets()
	if host._compact:
		host._apply_archive_metrics()
	var target = host._stage_card_size()
	if absf(target.y - host._stage_card_applied.y) < 4.0 \
			and absf(target.x - host._stage_card_applied.x) < 4.0:
		return
	host._apply_stage_metrics()



func set_player_controller(host, controller) -> void:
	var bindings = {
		"command_settled": "_on_player_command_settled",
		"ideology_offer_ready": "_on_ideology_offer_ready",
		"ideology_draw_state_changed": "_on_ideology_draw_state_changed",
	}
	if host._player_controller != null:
		for signal_name in bindings:
			var old_callback = Callable(host, String(bindings[signal_name]))
			if host._player_controller.has_signal(signal_name) \
					and host._player_controller.is_connected(signal_name, old_callback):
				host._player_controller.disconnect(signal_name, old_callback)
	host._player_controller = controller
	if host._player_controller == null:
		return
	for signal_name in bindings:
		var callback = Callable(host, String(bindings[signal_name]))
		if host._player_controller.has_signal(signal_name) \
				and not host._player_controller.is_connected(signal_name, callback):
			host._player_controller.connect(signal_name, callback)
	if host._player_controller.has_method("ideology_draw_phase"):
		host._draw_phase = String(host._player_controller.ideology_draw_phase())


# --- model ----------------------------------------------------------------


func _apply_model(host, model: Dictionary) -> void:
	var ideology: Dictionary = model.get("ideology", {})
	host._facade = ideology.get("facade")
	host._country_handle = int(model.get("country_handle", 0))
	host._current_day = int(model.get("current_day", 0))
	if ideology.is_empty() or not bool(ideology.get("available", false)):
		var raw_reason = String(ideology.get("reason", model.get("reason", "")))
		var loading = ideology.is_empty() and not bool(model.get("available", false)) \
			and (raw_reason.is_empty() or raw_reason == "正在载入已提交数据")
		host._show_shell(CountryViewModel.ideology_player_reason(raw_reason), loading)
		return
	host._catalog = ideology.get("catalog", {})
	host._snapshot = ideology.get("snapshot", {})
	host._presentation = ideology.get("presentation", {})
	if host._presentation.is_empty():
		host._presentation = CountryViewModel.present_ideology(host._snapshot, host._catalog)
	if host._player_controller != null and host._player_controller.has_method("ideology_draw_phase"):
		host._draw_phase = String(host._player_controller.ideology_draw_phase())
	host._index_catalog()
	var state_changes = host._index_states()
	host._render_top()
	var known: PackedInt32Array = host._snapshot.get("known_ids", PackedInt32Array())
	var explain_signature: Array = [
		host._country_handle, int(host._snapshot.get("support_revision", 0)), known,
		host._snapshot.get("levels", PackedInt32Array()),
		host._snapshot.get("locations", PackedInt32Array())]
	var support_changed = explain_signature != host._explain_signature
	if support_changed:
		host._explain_signature = explain_signature
		host._refresh_live_explain(known)
	var effect_changed_ids = PackedInt32Array()
	var effect_context: Array = [
		host._country_handle, known,
		host._snapshot.get("levels", PackedInt32Array()),
		host._snapshot.get("locations", PackedInt32Array()),
		host._snapshot.get("active_synergy_ids", PackedInt32Array())]
	if host._effect_report_context != effect_context:
		host._effect_report_context = effect_context
		host._effect_report_day = -1
	if host._effect_report_day != host._current_day or host._effect_summary.is_empty():
		host._effect_report_day = host._current_day
		effect_changed_ids = host._refresh_effect_report()
	var signature = host._board_signature(known)
	var active_synergy_ids: PackedInt32Array = host._snapshot.get(
		"active_synergy_ids", PackedInt32Array())
	if signature != host._signature:
		host._signature = signature
		host._rebuild_board()
		host._resonance_signature = active_synergy_ids
	else:
		if active_synergy_ids != host._resonance_signature:
			host._resonance_signature = active_synergy_ids
			host._update_resonance(null, -1)
		host._refresh_board_values(support_changed,
			state_changes.get("progress_ids", PackedInt32Array()),
			state_changes.get("pending_ids", PackedInt32Array()),
			state_changes.get("level_ids", PackedInt32Array()), effect_changed_ids)
	host._rebuild_offer()
	host._show_empty_state(bool(host._presentation.get("empty", known.is_empty())), host._presentation)



func _index_catalog(host) -> void:
	var rows: Array = host._catalog.get("ideologies", [])
	if rows.size() == host._metadata.size() and not host._metadata.is_empty():
		return
	host._metadata.clear()
	for row_value in rows:
		var row = row_value as Dictionary
		host._metadata[int(row.get("dense_id", -1))] = row



func _index_states(host) -> Dictionary:
	var ids: PackedInt32Array = host._snapshot.get("idea_ids", PackedInt32Array())
	var understanding: PackedInt64Array = host._snapshot.get("understanding_q16", PackedInt64Array())
	var levels: PackedInt32Array = host._snapshot.get("levels", PackedInt32Array())
	var locations: PackedInt32Array = host._snapshot.get("locations", PackedInt32Array())
	var pending: PackedByteArray = host._snapshot.get("transition_pending", PackedByteArray())
	var same_ids = host._indexed_snapshot_valid and ids == host._indexed_idea_ids
	var changed = not same_ids or understanding != host._indexed_understanding \
		or levels != host._indexed_levels or locations != host._indexed_locations \
		or pending != host._indexed_pending
	if not changed:
		return {"progress_ids": PackedInt32Array(),
			"pending_ids": PackedInt32Array(), "level_ids": PackedInt32Array()}
	if not same_ids:
		host._states.clear()
	var progress_ids = PackedInt32Array()
	var pending_ids = PackedInt32Array()
	var level_ids = PackedInt32Array()
	for index in ids.size():
		var idea_id = int(ids[index])
		var state: Dictionary = host._states.get(idea_id, {})
		var next_understanding = int(understanding[index]) if index < understanding.size() else 0
		var next_level = int(levels[index]) if index < levels.size() else 0
		var next_location = int(locations[index]) if index < locations.size() else 0
		var next_pending = index < pending.size() and pending[index] != 0
		if not same_ids or int(state.get("understanding", -1)) != next_understanding \
				or int(state.get("level", -1)) != next_level:
			progress_ids.append(idea_id)
		if not same_ids or int(state.get("level", -1)) != next_level:
			level_ids.append(idea_id)
		if not same_ids or bool(state.get("pending", false)) != next_pending:
			pending_ids.append(idea_id)
		state["understanding"] = next_understanding
		state["level"] = next_level
		state["location"] = next_location
		state["pending"] = next_pending
		host._states[idea_id] = state
	host._indexed_snapshot_valid = true
	host._indexed_idea_ids = ids
	host._indexed_understanding = understanding
	host._indexed_levels = levels
	host._indexed_locations = locations
	host._indexed_pending = pending
	return {"progress_ids": progress_ids, "pending_ids": pending_ids,
		"level_ids": level_ids}



func _render_top(host) -> void:
	var points = int(host._presentation.get("points", 0))
	var cost = int(host._presentation.get("offer_cost_q16", 65536))
	var gain = int(host._presentation.get("last_gain_q16", 0))
	var ready = bool(host._presentation.get("baseline_ready", false))
	var points_signature = "%d|%d|%d|%s" % [points, cost, gain, ready]
	if points_signature != host._points_signature:
		host._points_signature = points_signature
		host._point_scroll.call("set_points", points, cost, gain, ready, host.motion_reduced())
	host._point_scroll.tooltip_text = "理念点 %s / 抽取 %s\n累计 %s" % [
		host._q16(points), host._q16(cost), host._q16(int(host._presentation.get("lifetime_points_q16", 0)))]
	var offer_active = bool(host._presentation.get("offer_active", false))
	var waiting = host._draw_waiting()
	var generation = int(host._snapshot.get("offer_generation", 0))
	var collapsed = offer_active and generation == host._dismissed_generation
	host._offer_button.disabled = waiting or not (bool(host._presentation.get("can_open_offer", false))
		or collapsed)
	if waiting:
		host._offer_button.text = "抽取中…"
	elif collapsed:
		host._offer_button.text = "查看候选"
	elif offer_active:
		host._offer_button.text = "候选待选"
	else:
		host._offer_button.text = "抽取 · %s" % String(
			host._presentation.get("offer_cost_text", ""))
	host._offer_button.tooltip_text = "每次抽取消耗 %s 理念点，下次费用 +20%%" \
		% String(host._presentation.get("offer_cost_text", ""))
	if Time.get_ticks_msec() >= host._hint_hold_until:
		host._hint.text = "" if waiting \
			else String(host._presentation.get("offer_hint", ""))
		host._hint.visible = not host._compact and not host._hint.text.is_empty()
	# Capacity is carried by the slot rows themselves; do not repeat it as a
	# second counter above the board.
	host._slot_counts.text = ""
	host._slot_counts.visible = false



func _draw_waiting(host) -> bool:
	return host._draw_phase == "offer" or host._draw_phase == "reroll"


## Per-card effect-instance totals for the card face.
##
## Effect target rows can change when a committed day changes or an equipped
## card changes. The UI only queries this native report at those boundaries.

func _refresh_effect_report(host) -> PackedInt32Array:
	if host._facade == null or host._country_handle == 0:
		return host._replace_effect_summary({})
	var report: Dictionary = host._facade.effect_instances(host._country_handle)
	if not bool(report.get("ok", false)):
		return host._replace_effect_summary({})
	var summary: Dictionary = host.IdeologyEffectReportScript.summarize(report)
	if not bool(summary.get("ok", false)):
		return host._replace_effect_summary({})
	return host._replace_effect_summary(summary)



func _replace_effect_summary(host, summary: Dictionary) -> PackedInt32Array:
	var previous_rows: Dictionary = host._effect_summary.get("by_idea", {})
	var next_rows: Dictionary = summary.get("by_idea", {})
	var changed = PackedInt32Array()
	for raw_id in previous_rows:
		var idea_id = int(raw_id)
		if not next_rows.has(raw_id) or previous_rows[raw_id] != next_rows[raw_id]:
			changed.append(idea_id)
	for raw_id in next_rows:
		if not previous_rows.has(raw_id):
			changed.append(int(raw_id))
	host._effect_summary = summary
	return changed



func _refresh_live_explain(host, known: PackedInt32Array) -> void:
	host._live_explain = host._facade.explain_ideologies(host._country_handle, known) \
		if host._facade != null and host._facade.has_method("explain_ideologies") else {}
	host._live_by_id.clear()
	if not bool(host._live_explain.get("ok", false)):
		return
	var ids: PackedInt32Array = host._live_explain.get("ideology_ids", PackedInt32Array())
	var support: PackedInt32Array = host._live_explain.get("support_q16", PackedInt32Array())
	var thresholds: PackedInt32Array = host._live_explain.get("support_thresholds_q16", PackedInt32Array())
	var blockers: PackedInt32Array = host._live_explain.get("support_blocking_classes", PackedInt32Array())
	var available: PackedByteArray = host._live_explain.get("support_available", PackedByteArray())
	var allowed: PackedByteArray = host._live_explain.get("support_allowed", PackedByteArray())
	var equip_allowed: PackedByteArray = host._live_explain.get("equip_allowed", PackedByteArray())
	var unequip_allowed: PackedByteArray = host._live_explain.get("unequip_allowed", PackedByteArray())
	var promote_allowed: PackedByteArray = host._live_explain.get("promote_allowed", PackedByteArray())
	var stance_offsets: PackedInt32Array = host._live_explain.get("stance_offsets", PackedInt32Array())
	var stance_classes: PackedInt32Array = host._live_explain.get("stance_class_indices", PackedInt32Array())
	var influence: PackedInt64Array = host._live_explain.get("class_influence", PackedInt64Array())
	var adopt_contributions: PackedInt64Array = host._live_explain.get("adopt_contributions", PackedInt64Array())
	var repeal_contributions: PackedInt64Array = host._live_explain.get("repeal_contributions", PackedInt64Array())
	var promote_contributions: PackedInt64Array = host._live_explain.get("promote_contributions", PackedInt64Array())
	for index in ids.size():
		var support_rows: Array[Dictionary] = []
		for direction in 3:
			var row = index * 3 + direction
			support_rows.append({
				"support_q16": int(support[row]) if row < support.size() else 0,
				"threshold_q16": int(thresholds[row]) if row < thresholds.size() else 0,
				"blocking_class": int(blockers[row]) if row < blockers.size() else -1,
				"available": row < available.size() and available[row] != 0,
				"allowed": row < allowed.size() and allowed[row] != 0,
			})
		var class_rows: Array[Dictionary] = []
		var stance_begin = int(stance_offsets[index]) if index < stance_offsets.size() else 0
		var stance_end = int(stance_offsets[index + 1]) \
			if index + 1 < stance_offsets.size() else stance_begin
		for row in range(stance_begin, stance_end):
			class_rows.append({
				"class_index": int(stance_classes[row]),
				"influence": int(influence[row]),
				"contributions": [int(adopt_contributions[row]),
					int(repeal_contributions[row]), int(promote_contributions[row])],
			})
		host._live_by_id[int(ids[index])] = {
			"support": support_rows,
			"classes": class_rows,
			"equip_allowed": index < equip_allowed.size() and equip_allowed[index] != 0,
			"unequip_allowed": index < unequip_allowed.size() and unequip_allowed[index] != 0,
			"promote_allowed": index < promote_allowed.size() and promote_allowed[index] != 0,
		}


# --- deck table and collection --------------------------------------------


func _rebuild_board(host) -> void:
	var saved_scroll = host._scroll.scroll_vertical if host._scroll != null else 0
	var known: PackedInt32Array = host._snapshot.get("known_ids", PackedInt32Array())
	var equipped: Array[int] = []
	var spirits: Array[int] = []
	for value in known:
		var location = int((host._states.get(int(value), {}) as Dictionary).get("location", 0))
		if location == 1:
			equipped.append(int(value))
		elif location == 2:
			spirits.append(int(value))
	host._fill_slots(host._ideology_slots, 1, equipped, int(host._presentation.get("slots_capacity", 0)))
	host._fill_slots(host._spirit_slots, 2, spirits, int(host._presentation.get("spirits_capacity", 0)))
	host._update_resonance(null, -1)
	host._rebuild_collection(known)
	if host._scroll != null:
		host._scroll.set_deferred("scroll_vertical", saved_scroll)



func _board_signature(host, known: PackedInt32Array) -> Array:
	var signature: Array = [known]
	if host._sort_mode == 3:
		signature.append(host._snapshot.get("levels", PackedInt32Array()))
	signature.append_array([host._snapshot.get("locations", PackedInt32Array()),
		int(host._presentation.get("slots_capacity", 0)),
		int(host._presentation.get("spirits_capacity", 0)), host._country_handle,
		host._metadata.size(), host._tab_school, host._sort_mode, host._compact])
	return signature


## One compact row per equipped idea, plus a single collapsed row for whatever
## empty slots remain. Future technology milestones are a caption, not alcoves.

func _slot_row_data(host, ideology_id: int, kind: int) -> Dictionary:
	var meta: Dictionary = host._metadata.get(ideology_id, {})
	var state: Dictionary = host._states.get(ideology_id, {})
	var live: Dictionary = host._live_by_id.get(ideology_id, {})
	var level = maxi(0, int(state.get("level", 0)))
	var location = int(state.get("location", 0))
	var pending = bool(state.get("pending", false))
	var effect_row = host.IdeologyEffectReportScript.card_row(host._effect_summary, ideology_id)
	var target_cells: PackedInt32Array = effect_row.get("cells", PackedInt32Array())
	var has_target_cells = not target_cells.is_empty()
	var locate_tooltip = "在地图上定位 %d 处生效地块" % target_cells.size() \
		if has_target_cells else "在地图上定位生效地块"
	var view = CountryViewModel.present_ideology_card(meta, level, effect_row)
	var level_progress: Dictionary = host.LevelProgressScript.build(meta, state,
		String(view.get("level_label", "")))
	var tooltip = PackedStringArray([host._display_name(meta, ideology_id),
		String(view.get("tooltip", ""))])
	if bool(level_progress.get("maxed", false)):
		tooltip.append("已至最高境界")
	else:
		tooltip.append("理解度 %s / %s" % [
			host._q16(int(level_progress.get("understanding_q16", 0))),
			host._q16(int(level_progress.get("threshold_q16", 0)))])
	tooltip.append(host._support_tooltip(live, 1))
	if location == 1:
		tooltip.append(host._support_tooltip(live, 2))
	var min_spirit_level = int(meta.get("min_spirit_level", 99))
	var can_promote = location == 1 and level >= min_spirit_level \
		and bool(live.get("promote_allowed", true)) and not pending
	var promote_tooltip = "晋升为民族精神（不可逆）"
	if location == 1 and level < min_spirit_level:
		promote_tooltip = "需达到境界 %d 才能晋升" % (min_spirit_level + 1)
	return {
		"ideology_id": ideology_id,
		"display_name": host._display_name(meta, ideology_id),
		"school_id": String(meta.get("school_id", "")),
		"rarity": int(meta.get("rarity", 1)),
		"level": level,
		"level_count": int(view.get("level_count", 3)),
		"level_label": String(view.get("level_label", "")),
		"level_progress": level_progress,
		"effects": view.get("effect_lines", PackedStringArray()),
		"pending": pending,
		"has_target_cells": has_target_cells,
		"locate_tooltip": locate_tooltip,
		"can_unequip": bool(live.get("unequip_allowed", true)),
		"can_promote": can_promote,
		"unequip_tooltip": "%s\n%s" % ["撤回这条道路", host._support_summary(live, 1)],
		"promote_tooltip": "%s\n%s" % [promote_tooltip, host._support_summary(live, 2)],
		"tooltip": "\n".join(tooltip).strip_edges(),
		"detail_model": host._detail_data(ideology_id),
		"kind": kind,
	}


## The next technology milestone gating another slot of this kind, or "".

func _next_milestone(host, kind: int) -> String:
	var capacity = int(host._presentation.get(
		"slots_capacity" if kind == 1 else "spirits_capacity", 0))
	var capacity_max = int(host._presentation.get(
		"slots_max" if kind == 1 else "spirits_max", capacity))
	if capacity >= capacity_max:
		return ""
	var captions = host._locked_captions(kind)
	if captions.is_empty():
		return ""
	return "下一格 %s" % String(captions[0])



func _locked_captions(host, kind: int) -> PackedStringArray:
	var captions = PackedStringArray()
	for unlock_value in host._presentation.get("capacity_unlocks", []) as Array:
		var unlock = unlock_value as Dictionary
		if bool(unlock.get("owned", false)):
			continue
		var delta = int(unlock.get("ideology_delta" if kind == 1 else "spirit_delta", 0))
		for _i in delta:
			captions.append(String(unlock.get("technology_name", "")))
	return captions



func _rebuild_collection(host, known: PackedInt32Array) -> void:
	for child in host._collection.get_children():
		host._collection.remove_child(child)
		child.queue_free()
	host._collection_entries.clear()
	var ids: Array[int] = []
	for value in known:
		var meta: Dictionary = host._metadata.get(int(value), {})
		if host._tab_school.is_empty() or String(meta.get("school_id", "")) == host._tab_school:
			ids.append(int(value))
	if host._sort_mode != 0:
		ids.sort_custom(host._sort_less)
	for ideology_id in ids:
		host._collection.add_child(host._make_collection_entry(ideology_id))
	host._apply_collection_columns()
	host._update_collection_metrics(ids.size())



func _on_collection_resized(host) -> void:
	if host._collection == null or host._collection.get_child_count() == 0:
		return
	host._apply_collection_columns()


## Card width follows the viewport; text flow determines height at every size.

func _apply_collection_columns(host) -> void:
	if host._collection == null or host._scroll == null:
		return
	var available = maxf(1.0, host._scroll.size.x - 16.0)
	var columns = maxi(1, int(floorf((available + 12.0) / 372.0)))
	var width = floorf((available - (columns - 1) * 12.0) / columns)
	for child in host._collection.get_children():
		var entry = child as Control
		entry.custom_minimum_size.x = width
		entry.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		entry.call_deferred("refresh_layout")



func _collection_max_card_width(host) -> float:
	# At 1080p one card should not grow into a banner: the generated frame reads
	# as an object at roughly 420px, while larger copies make its line weight and
	# parchment grain look thin beside the cabinet.
	return 420.0 if host._compact else 460.0



static func _update_collection_metrics(host, _visible_count: int) -> void:
	# Value refresh and filter changes preserve stable opacity and hit targets.
	pass



func _sort_less(host, a: int, b: int) -> bool:
	var meta_a: Dictionary = host._metadata.get(a, {})
	var meta_b: Dictionary = host._metadata.get(b, {})
	match host._sort_mode:
		1:
			if int(meta_a.get("rarity", 1)) != int(meta_b.get("rarity", 1)):
				return int(meta_a.get("rarity", 1)) > int(meta_b.get("rarity", 1))
		2:
			var school_a = host.ArtScript.SCHOOL_ORDER.find(String(meta_a.get("school_id", "")))
			var school_b = host.ArtScript.SCHOOL_ORDER.find(String(meta_b.get("school_id", "")))
			if school_a != school_b:
				return school_a < school_b
		3:
			var level_a = int((host._states.get(a, {}) as Dictionary).get("level", 0))
			var level_b = int((host._states.get(b, {}) as Dictionary).get("level", 0))
			if level_a != level_b:
				return level_a > level_b
	return a < b



func _make_collection_entry(host, ideology_id: int) -> Control:
	var state: Dictionary = host._states.get(ideology_id, {})
	var live: Dictionary = host._live_by_id.get(ideology_id, {})
	var meta: Dictionary = host._metadata.get(ideology_id, {})
	var location = int(state.get("location", 0))
	var pending = bool(state.get("pending", false))
	var effect_row = host.IdeologyEffectReportScript.card_row(host._effect_summary, ideology_id)
	var target_cells: PackedInt32Array = effect_row.get("cells", PackedInt32Array())
	var has_target_cells = not target_cells.is_empty()
	var view = CountryViewModel.present_ideology_card(meta,
		maxi(0, int(state.get("level", 0))),
		effect_row)
	var level_progress: Dictionary = host.LevelProgressScript.build(meta, state,
		String(view.get("level_label", "")))
	var entry = host.CollectionEntry.new()
	entry.name = "IdeologyCollectionCard"
	host._collection_entries[ideology_id] = entry
	entry.setup({
		"name": host._display_name(meta, ideology_id),
		"school_id": String(meta.get("school_id", "")),
		"rarity": int(meta.get("rarity", 1)),
		"level_label": String(view.get("level_label", "")),
		"level_progress": level_progress,
		"effects": view.get("effect_lines", PackedStringArray()),
		"next_effects": view.get("next_level_lines", PackedStringArray()),
		"detail": String(view.get("detail", "")),
		"tooltip": String(host._card_data(ideology_id, true).get("tooltip", "")),
		"detail_model": host._detail_data(ideology_id),
		"location": location,
		"pending": pending,
		"draggable": location != 2,
		"payload": {"ideology_card": ideology_id, "location": location},
		"activated": Callable(host, "_on_card_activated").bind(ideology_id),
		"detail_requested": Callable(host, "_open_detail_modal").bind(ideology_id, false),
		"locate_requested": Callable(host, "_on_card_locate_requested").bind(ideology_id),
		"compact": host._compact,
	})
	entry.custom_minimum_size = Vector2(0, 180.0 if host._compact else 220.0)
	entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var progress: Control = entry.call("level_meter")
	progress.set_meta("accent_source", int(meta.get("rarity", 1)))
	var actions: HBoxContainer = entry.call("footer")
	actions.alignment = BoxContainer.ALIGNMENT_END
	# The ink line and the action are separate targets: a card-wide row can be
	# dragged while the button remains a normal click target.
	entry.mouse_filter = Control.MOUSE_FILTER_PASS
	actions.mouse_filter = Control.MOUSE_FILTER_STOP
	actions.visible = true
	actions.add_child(host._secondary_action_button("详情",
		host._open_detail_modal.bind(ideology_id, false),
		"查看理念详情、下一境效果与阶层支持", host._compact))
	var locate_btn = host._secondary_action_button("定位",
		host._on_card_locate_requested.bind(ideology_id),
		"在地图上定位 %d 处生效地块" % target_cells.size() if has_target_cells else "在地图上定位生效地块",
		host._compact)
	locate_btn.visible = has_target_cells
	actions.add_child(locate_btn)
	match location:
		0:
			actions.add_child(host._action_button("推行", pending
				or not bool(live.get("equip_allowed", false)),
				host._command.bind("equip", ideology_id), host._support_summary(live, 0),
				host._compact))
		1:
			actions.add_child(host._action_button("撤回", pending
				or not bool(live.get("unequip_allowed", false)),
				host._command.bind("unequip", ideology_id), host._support_summary(live, 1),
				host._compact))
			actions.add_child(host._action_button("晋升", pending
				or int(state.get("level", 0)) < int(meta.get("min_spirit_level", 99))
				or not bool(live.get("promote_allowed", false)),
				host._request_promotion.bind(ideology_id), host._support_summary(live, 2),
				host._compact))
		_:
			actions.add_child(host.ArtScript.label("民族精神", 11, host.ArtScript.VERMILION))
	return entry



static func _action_button(host, text: String, disabled: bool, callback: Callable,
		tooltip: String, _compact_value := false) -> Button:
	var button = Button.new()
	button.text = text
	button.disabled = disabled
	button.custom_minimum_size = Vector2(72 if _compact_value else 80, 36)
	button.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
	button.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	button.theme_type_variation = &"PKSealPrimaryButton"
	button.focus_mode = Control.FOCUS_ALL
	button.tooltip_text = tooltip
	button.set_meta("ideology_action", text)
	button.pressed.connect(callback)
	return button



static func _secondary_action_button(host, text: String, callback: Callable,
		tooltip: String, compact_value := false) -> Button:
	var button = Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(56 if compact_value else 66, 36)
	button.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
	button.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	button.theme_type_variation = &"PKDossierRowButton"
	button.focus_mode = Control.FOCUS_ALL
	button.tooltip_text = tooltip
	button.set_meta("ideology_action", text)
	button.pressed.connect(callback)
	return button


## Right click on a card face: hand the receiver the cells this card resolved to.
##
## The list comes from the same report the badge is built from, so the number on
## the card and the hexes on the map can never disagree. A card with no cell
## targets emits nothing at all rather than an empty list — there is nothing to
## show, and silently clearing the previous card's highlight would look like a
## dropped click.

func _on_card_locate_requested(host, ideology_id: int) -> void:
	if host._effect_summary.is_empty() and host._facade != null and host._country_handle > 0:
		host._refresh_effect_report()
	var row: Dictionary = host.IdeologyEffectReportScript.card_row(host._effect_summary, ideology_id)
	if row.is_empty():
		return
	var cells: PackedInt32Array = row.get("cells", PackedInt32Array())
	if cells.is_empty():
		return
	host.target_cells_requested.emit(cells)



func _card_data(host, ideology_id: int, in_collection: bool) -> Dictionary:
	var meta: Dictionary = host._metadata.get(ideology_id, {})
	var state: Dictionary = host._states.get(ideology_id, {})
	var live: Dictionary = host._live_by_id.get(ideology_id, {})
	var level = maxi(0, int(state.get("level", 0)))
	var location = int(state.get("location", 0))
	var pending = bool(state.get("pending", false))
	var view = CountryViewModel.present_ideology_card(meta, level,
		host.IdeologyEffectReportScript.card_row(host._effect_summary, ideology_id))
	var stamp = ""
	if pending:
		stamp = "待生效"
	elif in_collection and location == 1:
		stamp = "推行中"
	elif in_collection and location == 2:
		stamp = "精神"
	var level_progress: Dictionary = host.LevelProgressScript.build(meta, state,
		String(view.get("level_label", "")))
	var tooltip = PackedStringArray([host._display_name(meta, ideology_id), String(view.get("tooltip", ""))])
	if bool(level_progress.get("maxed", false)):
		tooltip.append("已至最高境界")
	else:
		tooltip.append("理解度 %s / %s" % [
			host._q16(int(level_progress.get("understanding_q16", 0))),
			host._q16(int(level_progress.get("threshold_q16", 0)))])
	tooltip.append(host._support_tooltip(live, 0 if location == 0 else 1))
	return {
		"ideology_id": ideology_id,
		"display_name": host._display_name(meta, ideology_id),
		"school_id": String(meta.get("school_id", "")),
		"rarity": int(meta.get("rarity", 1)),
		"rarity_label": String(meta.get("rarity_label", "")),
		"effects": view.get("effect_lines", PackedStringArray()),
		"level": level,
		"level_count": int(view.get("level_count", 3)),
		"level_label": String(view.get("level_label", "")),
		"level_progress": level_progress,
		"location": location,
		"pending": pending,
		"stamp_text": stamp,
		"tooltip": "\n".join(tooltip).strip_edges(),
		"detail_model": host._detail_data(ideology_id),
		"dimmed": in_collection and location != 0,
	}



func _detail_data(host, ideology_id: int, offer := false) -> Dictionary:
	var meta: Dictionary = host._metadata.get(ideology_id, {})
	var state: Dictionary = {} if offer else host._states.get(ideology_id, {})
	var level = int(state.get("level", 0))
	var view = CountryViewModel.present_ideology_card(meta, level,
		host.IdeologyEffectReportScript.card_row(host._effect_summary, ideology_id))
	var location = int(state.get("location", 0))
	var live: Dictionary = host._live_by_id.get(ideology_id, {})
	var supports: Array[Dictionary] = []
	if not offer:
		supports = host._support_details(live, location)
	var notes = PackedStringArray()
	if not offer and location == 1:
		notes.append("晋升民族精神需达到第 %d 境，晋升不可逆。" % (int(meta.get("min_spirit_level", 2)) + 1))
	var requirements: PackedStringArray = meta.get("required_technology_names", PackedStringArray())
	if not requirements.is_empty():
		notes.append("需要科技：%s" % "、".join(requirements))
	var rivals: PackedStringArray = meta.get("exclusion_rivals", PackedStringArray())
	if not rivals.is_empty():
		notes.append("互斥理念：%s" % "、".join(rivals))
	var synergy = String(meta.get("synergy_tooltip", ""))
	if not synergy.is_empty():
		notes.append(synergy)
	var labels: PackedStringArray = meta.get("level_labels", PackedStringArray())
	return {"name": host._display_name(meta, ideology_id),
		"school_id": String(meta.get("school_id", "")), "rarity": int(meta.get("rarity", 1)),
		"status": "候选理念" if offer else "待生效" if bool(state.get("pending", false)) else "推行中" if location == 1 else "民族精神" if location == 2 else "尚未推行",
		"progress": {} if offer else host.LevelProgressScript.build(meta, state, String(view.get("level_label", ""))),
		"effects": view.get("effect_lines", PackedStringArray()),
		"next_effects": view.get("next_level_lines", PackedStringArray()),
		"next_level_label": String(labels[level + 1]) if level + 1 < labels.size() else "",
		"notes": notes, "supports": supports}


# --- resonance and synergy threads ----------------------------------------


static func _id_set(host, ids: PackedInt32Array) -> Dictionary:
	var out = {}
	for value in ids:
		out[int(value)] = true
	return out



func _progress_data(host, ideology_id: int) -> Dictionary:
	var meta: Dictionary = host._metadata.get(ideology_id, {})
	var state: Dictionary = host._states.get(ideology_id, {})
	var labels: PackedStringArray = meta.get("level_labels", PackedStringArray())
	var level = clampi(int(state.get("level", 0)), 0, 64)
	var label = String(labels[level]) if level < labels.size() else ""
	var progress = host.LevelProgressScript.build(meta, state, label)
	progress["accent"] = host.ArtScript.rarity_accent(int(meta.get("rarity", 1)))
	return progress



static func _support_details(host, live: Dictionary, location: int) -> Array[Dictionary]:
	var supports: Array[Dictionary] = []
	if location == 2:
		return supports
	var direction = 0 if location == 0 else 1
	var rows: Array = live.get("support", [])
	if direction < rows.size():
		var row: Dictionary = (rows[direction] as Dictionary).duplicate()
		row["action"] = "推行" if direction == 0 else "撤回"
		row["reason"] = "关键阶层未达到最低支持要求" \
			if int(row.get("blocking_class", -1)) >= 0 else ""
		supports.append(row)
	return supports



func _school_counts(host, extra_id: int) -> Dictionary:
	var counts = {}
	for ideology_id in host._states:
		var state: Dictionary = host._states[ideology_id]
		if int(state.get("location", 0)) <= 0 and int(ideology_id) != extra_id:
			continue
		var school = String((host._metadata.get(int(ideology_id), {}) as Dictionary).get("school_id", ""))
		counts[school] = int(counts.get(school, 0)) + 1
	return counts



func _update_resonance(host, _niche: Control, preview_id: int) -> void:
	var active_ids: PackedInt32Array = host._snapshot.get("active_synergy_ids", PackedInt32Array())
	var active = {}
	for value in active_ids:
		active[int(value)] = true
	var counts = host._school_counts(-1)
	var preview_counts = host._school_counts(preview_id) if preview_id >= 0 else counts
	var newly_active: Array[String] = []
	for school_id in host._resonance_views:
		var tiers: Array[Dictionary] = []
		for row_value in host._catalog.get("synergies", []) as Array:
			var row = row_value as Dictionary
			if String(row.get("school_id", "")) != school_id:
				continue
			var dense_id = int(row.get("dense_id", -1))
			var on = active.has(dense_id)
			tiers.append({"min_count": int(row.get("min_count", 0)), "active": on,
				"tooltip": String(row.get("tooltip", ""))})
			if on and not host._active_resonances.has(dense_id) and not host._active_resonances.is_empty():
				newly_active.append(String(school_id))
		tiers.sort_custom(host._tier_less)
		(host._resonance_views[school_id]).set_state(
			int(counts.get(school_id, 0)), int(preview_counts.get(school_id, 0)), tiers)
	var had_any = not host._active_resonances.is_empty()
	host._active_resonances = active.duplicate()
	host._active_resonances[-999] = true  # sentinel: first sync never celebrates
	if had_any and not host.motion_reduced():
		for school_id in newly_active:
			var view = host._resonance_views[school_id]
			view.celebrate()



func _on_niche_drop(host, ideology_id: int, from_location: int, kind: int) -> void:
	host._hover_niche = null
	host._hover_id = -1
	host._update_resonance(null, -1)
	if kind == 1:
		if from_location == 0:
			host._command("equip", ideology_id)
		return
	if from_location != 1:
		host._flash_hint("需先推行")
		return
	host._request_promotion(ideology_id)



func _on_niche_hover(host, ideology_id: int, kind: int, entered: bool, niche: Control) -> void:
	var location = int((host._states.get(ideology_id, {}) as Dictionary).get("location", 0))
	if entered and kind == 1 and location == 0:
		host._hover_niche = niche
		host._hover_id = ideology_id
		host._update_resonance(niche, ideology_id)
	elif host._hover_niche == niche or not entered:
		host._hover_niche = null
		host._hover_id = -1
		host._update_resonance(null, -1)



static func _can_drop_collection(host, _at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and (data as Dictionary).has("ideology_card") \
		and int((data as Dictionary).get("location", 0)) == 1



func _drop_collection(host, _at_position: Vector2, data: Variant) -> void:
	host._command("unequip", int((data as Dictionary).get("ideology_card", -1)))


static func _fill_slots(workspace, host: VBoxContainer, kind: int, hosted: Array[int], capacity: int) -> void:
	if host == null:
		return
	if kind == 2:
		if workspace._spirit_alcove != null:
			workspace._spirit_alcove.visible = capacity > 0
		if workspace._spirit_section_header != null:
			workspace._spirit_section_header.visible = capacity > 0
	for child in host.get_children():
		host.remove_child(child)
		child.queue_free()
	for ideology_id in hosted:
		var row = workspace.NicheScript.new()
		row.configure(kind, false, workspace._compact)
		row.set_row(workspace._slot_row_data(ideology_id, kind))
		row.command_requested.connect(workspace._on_slot_command)
		row.promote_requested.connect(workspace._request_promotion)
		# Same handler as the card grid: "where does this act" does not depend on
		# whether the caller was a 196x260 card or a 60px row.
		row.locate_requested.connect(workspace._on_card_locate_requested)
		if row.has_signal("detail_requested"):
			row.detail_requested.connect(workspace._open_detail_modal.bind(false))
		host.add_child(row)
	var empty_count = maxi(0, capacity - hosted.size())
	if empty_count > 0:
		var empty_row = workspace.NicheScript.new()
		empty_row.configure(kind, true, workspace._compact)
		# The next technology milestone belongs on the empty slot itself: the
		# hint only exists while a slot is still missing, so it never costs
		# vertical space in a full board.
		empty_row.set_empty_count(empty_count, workspace._next_milestone(kind))
		empty_row.card_dropped.connect(workspace._on_niche_drop)
		empty_row.drag_hovered.connect(workspace._on_niche_hover.bind(empty_row))
		host.add_child(empty_row)


static func _refresh_board_values(workspace, support_changed: bool,
		progress_ids: PackedInt32Array, pending_ids: PackedInt32Array,
		level_ids: PackedInt32Array, effect_ids: PackedInt32Array) -> void:
	if not support_changed and progress_ids.is_empty() \
			and pending_ids.is_empty() and level_ids.is_empty() \
			and effect_ids.is_empty():
		return
	var progress_set = workspace._id_set(progress_ids)
	var pending_set = workspace._id_set(pending_ids)
	var level_set = workspace._id_set(level_ids)
	var effect_set = workspace._id_set(effect_ids)
	for host in [workspace._ideology_slots, workspace._spirit_slots]:
		for row in host.get_children():
			var id = int(row.get("occupied_id"))
			if id >= 0 and (support_changed or progress_set.has(id) \
					or pending_set.has(id) or level_set.has(id) \
					or effect_set.has(id)):
				row.set_row(workspace._slot_row_data(id, int(row.get("kind"))))
	if not support_changed and progress_ids.is_empty() \
			and pending_ids.is_empty() and level_ids.is_empty() \
			and effect_ids.is_empty():
		return
	for id in workspace._collection_entries:
		var idea_id = int(id)
		if not support_changed and not progress_set.has(idea_id) \
				and not pending_set.has(idea_id) and not level_set.has(idea_id) \
				and not effect_set.has(idea_id):
			continue
		var entry: Control = workspace._collection_entries[id]
		var live: Dictionary = workspace._live_by_id.get(idea_id, {})
		var state: Dictionary = workspace._states.get(idea_id, {})
		var location = int(state.get("location", 0))
		if pending_set.has(idea_id):
			entry.call("refresh_status", bool(state.get("pending", false)), location)
		if support_changed:
			entry.call("refresh_support_details", workspace._support_details(live, location))
		if support_changed or pending_set.has(idea_id) or level_set.has(idea_id) or effect_set.has(idea_id):
			var footer = entry.call("footer") as HBoxContainer
			var effect_row = workspace.IdeologyEffectReportScript.card_row(workspace._effect_summary, idea_id)
			var target_cells: PackedInt32Array = effect_row.get("cells", PackedInt32Array())
			var has_target_cells = not target_cells.is_empty()
			for button in footer.get_children():
				if not button is Button:
					continue
				var action = String(button.get_meta("ideology_action", ""))
				if action == "详情":
					continue
				if action == "定位":
					button.visible = has_target_cells
					button.tooltip_text = "在地图上定位 %d 处生效地块" % target_cells.size() \
						if has_target_cells else "在地图上定位生效地块"
					continue
				var direction = 0 if action == "推行" else 1 if action == "撤回" else 2
				var key: String = ["equip_allowed", "unequip_allowed", "promote_allowed"][direction]
				button.disabled = bool(state.get("pending", false)) \
					or not bool(live.get(key, false))
				if direction == 2:
					button.disabled = button.disabled or int(state.get("level", 0)) < int(
						(workspace._metadata.get(idea_id, {}) as Dictionary).get("min_spirit_level", 99))
				if support_changed:
					button.tooltip_text = workspace._support_tooltip(live, direction)
		if level_set.has(idea_id) or effect_set.has(idea_id):
			entry.call("refresh_card_data", workspace._card_data(idea_id, true))
		elif progress_set.has(idea_id):
			entry.call("refresh_progress", workspace._progress_data(idea_id))
	if workspace.is_detail_modal_open() and workspace._detail_ideology_id >= 0:
		workspace._present_detail_dictionary(workspace._detail_data(workspace._detail_ideology_id, workspace._detail_is_offer))
