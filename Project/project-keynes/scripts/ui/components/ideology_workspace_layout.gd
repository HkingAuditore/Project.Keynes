extends RefCounted

## Builds the archive layout, offer stage, and detail overlays.




static func _build_promotion_overlay(host) -> void:
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



static func _wire_promotion_focus(host) -> void:
	if host._promotion_cancel == null or host._promotion_confirm == null \
			or not host._promotion_cancel.is_inside_tree():
		return
	host._promotion_cancel.focus_neighbor_right = host._promotion_confirm.get_path()
	host._promotion_confirm.focus_neighbor_left = host._promotion_cancel.get_path()



static func _close_promotion_overlay(host) -> void:
	host._pending_promotion_id = -1
	if host._promotion_layer != null:
		host._promotion_layer.visible = false
	if host.is_visible_in_tree():
		host._focus_initial_action()


## Touch and click-accessible detail overlay using IdeologyDetailTooltip so
## players on Android/touchscreens can inspect next-level effects, understanding
## progress, class support gauges, and restrictions without hover tooltips.

static func _open_detail_modal(host, ideology_id: int, is_offer: bool = false) -> void:
	if ideology_id < 0 or host._detail_layer == null:
		return
	host._detail_ideology_id = ideology_id
	host._detail_is_offer = is_offer
	host._present_detail_dictionary(host._detail_data(ideology_id, is_offer))



static func _open_resonance_detail(host, school_id: String) -> void:
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



static func _present_detail_dictionary(host, data: Dictionary) -> void:
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



static func _close_detail_modal(host) -> void:
	host._detail_ideology_id = -1
	host._detail_is_offer = false
	if host._detail_layer != null:
		host._detail_layer.visible = false
	if host.is_visible_in_tree() and not (host._offer_layer != null and host._offer_layer.visible):
		host._focus_initial_action()



static func is_detail_modal_open(host) -> bool:
	return host._detail_layer != null and host._detail_layer.visible



static func _focus_initial_action(host) -> void:
	if not host.is_visible_in_tree() or host._offer_layer.visible:
		return
	var focused = host.get_viewport().gui_get_focus_owner()
	if focused != null and host.is_ancestor_of(focused):
		return
	if not host._offer_button.disabled:
		host._offer_button.grab_focus()
	else:
		host._sort.grab_focus()



static func _build_dynamic_parts(host) -> void:
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

static func _build_archive_chrome(host) -> void:
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



static func _build_deck_heading(host) -> void:
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

static func _build_slot_sections(host, deck_column: VBoxContainer) -> void:
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



static func _make_slot_section_header(host, kind: int) -> PanelContainer:
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



static func _build_collection_heading(host) -> void:
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



static func _style_school_tabs(host) -> void:
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



static func _tab_style(host, state: String) -> StyleBox:
	var tint = Color(0.94, 0.90, 0.80)
	if state == "selected" or state == "pressed":
		tint = Color(0.76, 0.32, 0.23)
	elif state == "hover":
		tint = Color.WHITE
	return host.ArtScript.paper_style(8.0, tint)



static func _apply_archive_metrics(host) -> void:
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

static func _play_workspace_intro(host) -> void:
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

static func _build_stage_scenery(host) -> void:
	host.ArtScript.attach_panel_shadow(host._offer, 0.30, 16)
	host._offer_layer.theme = preload("res://assets/themes/player_session_theme.tres")
	host._offer_title.add_theme_color_override("font_color", host.ArtScript.INK)



static func _build_stage_header(host) -> void:
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




static func _build_stage_footer(host) -> void:
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
