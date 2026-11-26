extends RefCounted

## Binds the authored ideology workspace controls and modal presentation.


static func _bind_nodes(owner: IdeologyWorkspace) -> void:
	if owner._offer_button != null:
		return
	owner._root = owner.get_node_or_null("Root") as VBoxContainer
	owner._top_bar = owner.get_node_or_null("Root/TopBar") as PanelContainer
	owner._body = owner.get_node_or_null("Root/Body") as HBoxContainer
	owner._slot_column = owner.get_node_or_null("Root/Body/SlotColumn") as VBoxContainer
	owner._collection_column = owner.get_node_or_null("Root/Body/CollectionColumn") as VBoxContainer
	owner._deck_table = owner.get_node_or_null("Root/Body/SlotColumn/DeckTable") as PanelContainer
	owner._deck_scroll = owner._deck_table.get_node_or_null("DeckBody/DeckScroll") as ScrollContainer \
		if owner._deck_table != null else null
	owner._deck_column = owner._deck_scroll.get_node_or_null("DeckColumn") as VBoxContainer \
		if owner._deck_scroll != null else null
	owner._resonance_panel = owner.get_node_or_null(
		"Root/Body/SlotColumn/ResonancePanel") as PanelContainer
	owner._collection_heading = owner.get_node_or_null("Root/Body/CollectionColumn/CollectionHeading") as VBoxContainer
	owner._point_scroll = owner.get_node("%PointScroll")
	owner._hint = owner.get_node("%Hint")
	owner._offer_button = owner.get_node("%OpenOffer")
	owner._offer_layer = owner.get_node("%OfferLayer")
	# Candidates use viewport space even when the country page is short.
	var modal_canvas := CanvasLayer.new()
	modal_canvas.name = "CandidateModal"
	modal_canvas.layer = 30
	owner._modal_canvas = modal_canvas
	owner.add_child(modal_canvas)
	owner.visibility_changed.connect(func() -> void:
		modal_canvas.visible = owner.is_visible_in_tree()
		if not owner.is_visible_in_tree():
			owner._close_detail_modal()
		else:
			owner.call_deferred("_focus_initial_action"))
	owner._offer_layer.reparent(modal_canvas)
	owner._offer_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	owner._apply_offer_layer_insets()
	owner._offer = owner.get_node("%Offer")
	owner._offer_title = owner.get_node("%OfferTitle")
	owner._choice_0 = owner.get_node("%Choice0")
	owner._choice_1 = owner.get_node("%Choice1")
	owner._choice_2 = owner.get_node("%Choice2")
	owner._reroll_button = owner.get_node("%Reroll")
	owner._dismiss_button = owner.get_node("%Dismiss")
	owner._slot_counts = owner.get_node("%SlotCounts")
	owner._ideology_slots = owner.get_node("%IdeologySlots")
	owner._spirit_slots = owner.get_node("%SpiritSlots")
	owner._resonance_bar = owner.get_node("%ResonanceBar")
	owner._tabs = owner.get_node("%SchoolTabs")
	owner._sort = owner.get_node("%SortMode")
	owner._collection_drop = owner.get_node("%CollectionDrop")
	owner._collection_margin = owner._collection_drop.get_node_or_null(
		"CollectionMargin") as MarginContainer
	owner._collection = owner.get_node("%Collection")
	owner._scroll = owner.get_node("%CollectionScroll")
	owner._empty = owner.get_node("%EmptyState")
	owner._empty_icon = owner.get_node("%EmptyIcon")
	owner._empty_title = owner.get_node("%EmptyTitle")
	owner._empty_detail = owner.get_node("%EmptyDetail")
	owner._empty_insights = owner.get_node("%EmptyInsights")
	owner._fx = owner.get_node("%Fx")
	owner._promotion_dialog = owner.get_node("%PromotionDialog")
	owner._ledger_popup = owner.get_node("%LedgerPopup")
	owner._build_promotion_overlay()
	owner._build_detail_overlay()
	owner._build_dynamic_parts()


## The stock ConfirmationDialog belongs to the debug theme and flashes a
## rectangular grey window over the paper workspace. Build the promotion
## confirmation once from the same paper material as the cards, then only
## replace its text when a different ideology is requested. This keeps the
## modal cheap to open and preserves the native command/ACK path underneath.
static func _build_detail_overlay(owner: IdeologyWorkspace) -> void:
	if owner._detail_layer != null:
		return
	owner._detail_layer = Control.new()
	owner._detail_layer.name = "DetailOverlay"
	owner._detail_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	owner._detail_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	owner._detail_layer.visible = false
	owner._detail_layer.theme = preload("res://assets/themes/player_session_theme.tres")
	var host: Node = owner._modal_canvas if owner._modal_canvas != null else owner
	host.add_child(owner._detail_layer)
	var veil := ColorRect.new()
	veil.name = "DetailVeil"
	veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	veil.color = Color(0.07, 0.045, 0.025, 0.46)
	veil.mouse_filter = Control.MOUSE_FILTER_STOP
	veil.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mouse := event as InputEventMouseButton
			if mouse.button_index == MOUSE_BUTTON_LEFT and mouse.pressed:
				owner._close_detail_modal()
				veil.accept_event())
	owner._detail_layer.add_child(veil)
	var center := CenterContainer.new()
	center.name = "DetailCenter"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	owner._detail_layer.add_child(center)
	owner._detail_sheet = VBoxContainer.new()
	owner._detail_sheet.name = "DetailSheet"
	owner._detail_sheet.alignment = BoxContainer.ALIGNMENT_CENTER
	owner._detail_sheet.add_theme_constant_override("separation", 8)
	owner._detail_sheet.mouse_filter = Control.MOUSE_FILTER_STOP
	center.add_child(owner._detail_sheet)
	owner._detail_body_host = VBoxContainer.new()
	owner._detail_body_host.name = "DetailBodyHost"
	owner._detail_body_host.mouse_filter = Control.MOUSE_FILTER_STOP
	owner._detail_sheet.add_child(owner._detail_body_host)
	var actions := HBoxContainer.new()
	actions.name = "DetailActions"
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.mouse_filter = Control.MOUSE_FILTER_STOP
	owner._detail_sheet.add_child(actions)
	owner._detail_close = Button.new()
	owner._detail_close.name = "DetailCloseButton"
	owner._detail_close.text = "关闭"
	owner._detail_close.custom_minimum_size = Vector2(132, maxf(38.0, IdeologyWorkspace.TouchUI.min_units()))
	owner._detail_close.theme_type_variation = &"PKSealPrimaryButton"
	owner._detail_close.focus_mode = Control.FOCUS_ALL
	owner._detail_close.pressed.connect(owner._close_detail_modal)
	actions.add_child(owner._detail_close)
	owner._apply_offer_layer_insets()
