extends Control
class_name IdeologyWorkspace

# Papercut deck-building view over the native ideology authority. Facade-only:
# every mutation is a PlayerController command, and rows are rebuilt only when
# the compact native snapshot signature changes. Animation state never feeds
# back into gameplay state.

## "This card acts on these cells — show them on the map." Emitted only with a
## non-empty list, so a listener never has to distinguish "no cells" from
## "please clear". The workspace cannot paint anything itself: the map lives
## outside this panel, and the panel is full-bleed, so the receiver is expected
## to close it first.
signal target_cells_requested(cells: PackedInt32Array)

const Q16_ONE := 65536.0
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")
const ArtScript = preload("res://scripts/ui/components/ideology_art.gd")
const CardScript = preload("res://scripts/ui/components/ideology_card.gd")
const NicheScript = preload("res://scripts/ui/components/ideology_slot_niche.gd")
const LevelProgressScript = preload(
	"res://scripts/ui/components/ideology_level_progress.gd")
const LevelMeterScript = preload(
	"res://scripts/ui/components/ideology_level_meter.gd")
const PointScrollScript = preload("res://scripts/ui/components/ideology_point_scroll.gd")
const IdeologyEffectReportScript = preload("res://scripts/ideology/ideology_effect_report.gd")
const HINT_HOLD_MSEC := 4500
## Height of the offer tray chrome (title, actions, margins) around the cards.
const STAGE_CHROME_HEIGHT := 196.0
const STAGE_CHROME_HEIGHT_COMPACT := 148.0
const STAGE_CARD_MIN_HEIGHT := 140.0
const STAGE_CARD_MAX_HEIGHT := 410.0
const STAGE_OUTER_INSET := 12.0
const COMPACT_TITLE_STYLE := &"PKIdeologyStageTitle"
const COLLECTION_COLUMN_MIN_WIDTH := 560.0
const COLLECTION_COLUMN_MIN_WIDTH_COMPACT := 390.0
const SLOT_COLUMN_MIN_WIDTH := 360.0
const SLOT_COLUMN_MIN_WIDTH_COMPACT := 300.0
const SORT_LABELS := ["收录顺序", "稀有度", "流派", "境界"]
## Motion follows the shared game setting (main menu / pause menu) so this
## panel never grows a second switch. Read it on demand; it is a dict lookup.
static func motion_reduced() -> bool:
	return UIAnimation.reduced_motion()

var _facade = null
var _player_controller = null
var _country_handle := 0
var _current_day := 0
var _catalog: Dictionary = {}
var _snapshot: Dictionary = {}
var _presentation: Dictionary = {}
var _live_explain: Dictionary = {}
var _live_by_id := {}
# Per-card effect-instance totals, see IdeologyEffectReport.
var _effect_summary: Dictionary = {}
var _metadata := {}
var _states := {}
var _signature := ""
var _explain_signature := ""
var _points_signature := ""
var _pending_promotion_id := -1
var _compact := false
var _tab_school := ""
var _sort_mode := 0
var _draw_phase := ""
var _revealed_generation := 0
var _chosen_generation := -1
var _dismissed_generation := -1
var _offer_anim_busy := false
var _hint_hold_until := 0
var _active_resonances := {}
var _hover_niche: Control = null
var _hover_id := -1
var _progress_by_id := {}
var _collection_entries := {}
var _entry_intro_played := false

var _root: VBoxContainer
var _draw_stack: DrawStack
var _stage_card_applied := Vector2.ZERO
var _stage_available_height := 0.0
var _point_scroll: Control
var _hint: Label
var _offer_button: Button
var _offer_layer: Control
var _offer: PanelContainer
var _offer_title: Label
var _offer_hint: Label
var _choice_0: Control
var _choice_1: Control
var _choice_2: Control
var _reroll_button: Button
var _dismiss_button: Button
var _offer_column: VBoxContainer
var _offer_body: MarginContainer
var _offer_cards: HBoxContainer
var _offer_actions: HBoxContainer
var _offer_header: VBoxContainer
var _offer_footer: VBoxContainer
var _slot_counts: Label
var _ideology_slots: VBoxContainer
var _spirit_slots: VBoxContainer
var _ideology_section_header: PanelContainer
var _spirit_section_header: PanelContainer
var _spirit_alcove: PanelContainer
var _spirit_inset: MarginContainer
var _resonance_bar: HFlowContainer
var _resonance_views := {}
var _tabs: TabBar
var _sort: OptionButton
var _body: HBoxContainer
var _slot_column: VBoxContainer
var _collection_column: VBoxContainer
var _deck_table: PanelContainer
var _deck_heading: HBoxContainer
var _deck_scroll: ScrollContainer
var _deck_column: VBoxContainer
var _resonance_panel: PanelContainer
var _collection_margin: MarginContainer
var _collection_heading: VBoxContainer
var _collection_heading_surface: PanelContainer
var _collection_heading_top: HBoxContainer
var _collection_title: Label
var _collection_tabs_scroll: ScrollContainer
var _top_bar: PanelContainer
var _top_title: Label
var _collection_drop: PanelContainer
var _collection: HFlowContainer
var _scroll: ScrollContainer
var _empty: PanelContainer
var _empty_icon: IconBadge
var _empty_title: Label
var _empty_detail: Label
var _empty_insights: InsightList
var _fx: Control
var _promotion_dialog: ConfirmationDialog
var _ledger_popup: PopupPanel


func _ready() -> void:
	_bind_nodes()
	if _empty_icon != null:
		_empty_icon.set_semantic(&"country.politics", UITokens.ACCENT)
	call_deferred("_play_workspace_intro")
	call_deferred("_focus_initial_action")


func _bind_nodes() -> void:
	if _offer_button != null:
		return
	_root = get_node_or_null("Root") as VBoxContainer
	_top_bar = get_node_or_null("Root/TopBar") as PanelContainer
	_body = get_node_or_null("Root/Body") as HBoxContainer
	_slot_column = get_node_or_null("Root/Body/SlotColumn") as VBoxContainer
	_collection_column = get_node_or_null("Root/Body/CollectionColumn") as VBoxContainer
	_deck_table = get_node_or_null("Root/Body/SlotColumn/DeckTable") as PanelContainer
	_deck_scroll = _deck_table.get_node_or_null("DeckBody/DeckScroll") as ScrollContainer \
		if _deck_table != null else null
	_deck_column = _deck_scroll.get_node_or_null("DeckColumn") as VBoxContainer \
		if _deck_scroll != null else null
	_resonance_panel = get_node_or_null(
		"Root/Body/SlotColumn/ResonancePanel") as PanelContainer
	_collection_heading = get_node_or_null("Root/Body/CollectionColumn/CollectionHeading") as VBoxContainer
	_point_scroll = %PointScroll
	_hint = %Hint
	_offer_button = %OpenOffer
	_offer_layer = %OfferLayer
	# Candidates use viewport space even when the country page is short.
	var modal_canvas := CanvasLayer.new()
	modal_canvas.name = "CandidateModal"
	modal_canvas.layer = 30
	add_child(modal_canvas)
	visibility_changed.connect(func() -> void:
		modal_canvas.visible = is_visible_in_tree()
		if is_visible_in_tree():
			call_deferred("_focus_initial_action"))
	_offer_layer.reparent(modal_canvas)
	_offer_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_offer_layer.offset_left = 24
	_offer_layer.offset_top = 48
	_offer_layer.offset_right = -24
	_offer_layer.offset_bottom = -48
	_offer = %Offer
	_offer_title = %OfferTitle
	_choice_0 = %Choice0
	_choice_1 = %Choice1
	_choice_2 = %Choice2
	_reroll_button = %Reroll
	_dismiss_button = %Dismiss
	_slot_counts = %SlotCounts
	_ideology_slots = %IdeologySlots
	_spirit_slots = %SpiritSlots
	_resonance_bar = %ResonanceBar
	_tabs = %SchoolTabs
	_sort = %SortMode
	_collection_drop = %CollectionDrop
	_collection_margin = _collection_drop.get_node_or_null(
		"CollectionMargin") as MarginContainer
	_collection = %Collection
	_scroll = %CollectionScroll
	_empty = %EmptyState
	_empty_icon = %EmptyIcon
	_empty_title = %EmptyTitle
	_empty_detail = %EmptyDetail
	_empty_insights = %EmptyInsights
	_fx = %Fx
	_promotion_dialog = %PromotionDialog
	_ledger_popup = %LedgerPopup
	_build_dynamic_parts()


func _focus_initial_action() -> void:
	if not is_visible_in_tree() or _offer_layer.visible:
		return
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null and is_ancestor_of(focused):
		return
	if not _offer_button.disabled:
		_offer_button.grab_focus()
	else:
		_sort.grab_focus()


func _build_dynamic_parts() -> void:
	_build_stage_scenery()
	_build_archive_chrome()
	_style_school_tabs()
	for index in 3:
		var card := _choice(index)
		card.set("draggable", false)
		# One click on an offer card selects the road; the collection keeps the
		# deliberate double click because browsing must never equip by accident.
		card.set("activate_on_single_click", true)
		card.call("set_stage", true)
		card.connect("activated", _on_choice_activated.bind(index))
		card.gui_input.connect(_on_choice_input.bind(index))
	_build_stage_header()
	# The waiting stage shows a shuffled deck instead of three blank card backs,
	# so no placeholder frame is ever visible before the reveal plays.
	_draw_stack = DrawStack.new()
	var offer_cards := _choice_0.get_parent() as Control
	_offer_cards = offer_cards as HBoxContainer
	if offer_cards != null and offer_cards.get_parent() != null:
		_offer_column = offer_cards.get_parent() as VBoxContainer
		_offer_column.add_child(_draw_stack)
		_offer_column.move_child(_draw_stack, offer_cards.get_index())
	_draw_stack.visible = false
	_offer_actions = _reroll_button.get_parent() as HBoxContainer
	_offer_body = _offer.get_node("OfferBody") as MarginContainer
	_build_stage_footer()
	_apply_stage_metrics()
	resized.connect(_on_workspace_resized)
	if _point_scroll != null and _point_scroll.has_signal("ledger_requested"):
		_point_scroll.connect("ledger_requested", _open_ledger)
	# Everything below is optional chrome: a missing node must never abort the
	# builder and leave the tabs, sort menu or resonance row unbuilt.
	if _tabs != null:
		_tabs.add_tab("全部")
		for school_id in ArtScript.SCHOOL_ORDER:
			_tabs.add_tab(ArtScript.school_name(String(school_id)))
		_tabs.tab_changed.connect(_on_tab_changed)
	if _sort != null:
		for label in SORT_LABELS:
			_sort.add_item(String(label))
		_sort.item_selected.connect(_on_sort_selected)
	if _collection_drop != null:
		_collection_drop.set_drag_forwarding(Callable(), _can_drop_collection,
			_drop_collection)
	if _resonance_bar != null:
		for school_id in ArtScript.SCHOOL_ORDER:
			var view := ResonanceEmblem.new()
			view.configure(String(school_id))
			_resonance_bar.add_child(view)
			_resonance_views[String(school_id)] = view


## Lift the board from a pair of bare containers into a physical archive:
## a titled national-idea banner, a bound cabinet for the equipped roads and
## an indexed folio for everything the country has collected.
func _build_archive_chrome() -> void:
	if _top_bar != null:
		_top_bar.add_theme_stylebox_override("panel", ArtScript.paper_style(10.0))
		var top_row := _point_scroll.get_parent() as Control
		var identity := VBoxContainer.new()
		identity.custom_minimum_size.x = 112
		identity.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		identity.mouse_filter = Control.MOUSE_FILTER_IGNORE
		top_row.add_child(identity)
		top_row.move_child(identity, 0)
		_top_title = ArtScript.label("国家理念", 24, ArtScript.INK,
			HORIZONTAL_ALIGNMENT_LEFT)
		_top_title.add_theme_font_override("font",
			preload("res://assets/fonts/annual_pencil/Muyao-Softbrush-2.ttf"))
		identity.add_child(_top_title)
	if _deck_table != null:
		_deck_table.add_theme_stylebox_override("panel", ArtScript.paper_style(8.0,
			Color(0.94, 0.95, 0.90)))
		_build_deck_heading()
	if _collection_drop != null:
		_collection_drop.add_theme_stylebox_override("panel", ArtScript.paper_style(8.0))
		_build_collection_heading()
	if _scroll != null and not _scroll.resized.is_connected(_on_collection_resized):
		_scroll.resized.connect(_on_collection_resized)
	if _empty != null:
		_empty.add_theme_stylebox_override("panel", ArtScript.paper_style(16.0))
	if _resonance_bar != null:
		var row := _resonance_bar.get_parent() as Control
		var tag := row.get_node_or_null("ResonanceTag") as Label
		if tag != null:
			tag.theme_type_variation = &"Label"
			tag.add_theme_color_override("font_color", ArtScript.INK)
			tag.add_theme_font_size_override("font_size", 14)
		var panel := row.get_parent().get_parent() as PanelContainer
		panel.add_theme_stylebox_override("panel", ArtScript.paper_style(4.0))
	_apply_archive_metrics()


func _build_deck_heading() -> void:
	var deck_scroll := _deck_table.get_node_or_null(
		"DeckBody/DeckScroll") as ScrollContainer
	if deck_scroll == null:
		return
	var deck_column := deck_scroll.get_node_or_null("DeckColumn") as VBoxContainer
	if deck_column == null:
		return
	_deck_heading = HBoxContainer.new()
	_deck_heading.name = "DeckHeading"
	_deck_heading.add_theme_constant_override("separation", 10)
	_deck_heading.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var deck_emblem := TextureRect.new()
	deck_emblem.texture = IconCatalog.texture_for_key(&"hud.country.ideology")
	deck_emblem.custom_minimum_size = Vector2(24, 24)
	deck_emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	deck_emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	deck_emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
	deck_emblem.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	deck_emblem.modulate = Color(1.0, 0.96, 0.82, 0.96)
	_deck_heading.add_child(deck_emblem)
	var identity := VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.add_theme_constant_override("separation", 0)
	identity.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_deck_heading.add_child(identity)
	var title := ArtScript.label("已推行国策", 21, ArtScript.INK,
		HORIZONTAL_ALIGNMENT_LEFT)
	title.add_theme_font_override("font",
		preload("res://assets/fonts/annual_pencil/Muyao-Softbrush-2.ttf"))
	identity.add_child(title)
	_build_slot_sections(deck_column)


## 国策与民族精神各占完整栏宽，标题紧邻对应槽位。
func _build_slot_sections(deck_column: VBoxContainer) -> void:
	if _ideology_slots == null or _spirit_slots == null:
		return
	# The deck title has already claimed the top band. These section markers
	# remain compact so both slot shapes stay visible at 720p.
	_ideology_section_header = _make_slot_section_header(1)
	_ideology_section_header.name = "IdeologySectionHeader"

	_spirit_alcove = PanelContainer.new()
	_spirit_alcove.name = "SpiritCeremonialAlcove"
	_spirit_alcove.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_spirit_alcove.add_theme_stylebox_override("panel",
		_spirit_alcove_rule_style())
	ArtScript.attach_panel_shadow(_spirit_alcove, 0.19)
	_spirit_inset = MarginContainer.new()
	_spirit_inset.name = "SpiritInset"
	_spirit_inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right"]:
		_spirit_inset.add_theme_constant_override("margin_%s" % side, 4)
	for side in ["top", "bottom"]:
		_spirit_inset.add_theme_constant_override("margin_%s" % side, 4)
	_spirit_alcove.add_child(_spirit_inset)
	_spirit_slots.reparent(_spirit_inset)
	_spirit_section_header = _make_slot_section_header(2)
	_spirit_section_header.name = "SpiritSectionHeader"
	var ordinary_well := PanelContainer.new()
	ordinary_well.name = "IdeologySlotWell"
	ordinary_well.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ordinary_well.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ordinary_well.add_theme_stylebox_override("panel",
		_spirit_alcove_rule_style())
	var ordinary_inset := MarginContainer.new()
	ordinary_inset.name = "IdeologyInset"
	ordinary_inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ordinary_inset.add_theme_constant_override("margin_left", 2)
	ordinary_inset.add_theme_constant_override("margin_top", 2)
	ordinary_inset.add_theme_constant_override("margin_right", 2)
	ordinary_inset.add_theme_constant_override("margin_bottom", 2)
	ordinary_well.add_child(ordinary_inset)
	_ideology_slots.reparent(ordinary_inset)
	_spirit_alcove.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 各组标题与内容相邻，窄栏也能完整阅读卡面，不再挤成两个半宽槽。
	var groups := VBoxContainer.new()
	groups.name = "SlotGroups"
	groups.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	groups.add_theme_constant_override("separation", 10)
	groups.add_child(_ideology_section_header)
	groups.add_child(ordinary_well)
	groups.add_child(_spirit_section_header)
	groups.add_child(_spirit_alcove)
	deck_column.add_child(groups)
	# 总标题固定；每组标题跟随自己的内容滚动。
	var old_deck_body := _deck_scroll.get_parent() as MarginContainer
	var deck_stack := VBoxContainer.new()
	deck_stack.name = "DeckBody"
	deck_stack.add_theme_constant_override("separation", 3)
	deck_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	old_deck_body.add_child(deck_stack)
	old_deck_body.move_child(deck_stack, 0)
	old_deck_body.remove_child(_deck_scroll)
	deck_stack.add_child(_deck_heading)
	deck_stack.add_child(_deck_scroll)
	_deck_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL


func _make_slot_section_header(kind: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.custom_minimum_size.y = 26 if kind == 1 else 32
	panel.add_theme_stylebox_override("panel",
		ArtScript.paper_style(0.0, Color(0.94, 0.92, 0.84)
			if kind == 1 else Color(0.29, 0.40, 0.27)))
	var layer := Control.new()
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(layer)
	var chrome := SlotSectionChrome.new()
	chrome.kind = kind
	chrome.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chrome.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(chrome)
	var row := HBoxContainer.new()
	row.name = "SectionRow"
	row.add_theme_constant_override("separation", 5)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(row)
	var tab := PanelContainer.new()
	tab.name = "SectionTab"
	tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tab_tint := Color(0.78, 0.89, 0.79) if kind == 1 \
		else Color(0.29, 0.40, 0.27)
	tab.add_theme_stylebox_override("panel", ArtScript.paper_style(0.0, tab_tint))
	row.add_child(tab)
	var title := ArtScript.label("国家理念" if kind == 1 else "民族精神",
		18,
		ArtScript.INK if kind == 1 else ArtScript.GOLD_LEAF,
		HORIZONTAL_ALIGNMENT_LEFT)
	title.name = "SectionTitle"
	title.add_theme_font_override("font",
		preload("res://assets/fonts/annual_pencil/Muyao-Softbrush-2.ttf"))
	title.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var tab_margin := MarginContainer.new()
	tab_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tab_margin.add_theme_constant_override("margin_left", 10)
	tab_margin.add_theme_constant_override("margin_right", 10)
	tab.add_child(tab_margin)
	tab_margin.add_child(title)
	var rule := Control.new()
	rule.name = "SectionRule"
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rule.custom_minimum_size.y = 1
	row.add_child(rule)
	return panel


func _spirit_alcove_rule_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
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


func _build_collection_heading() -> void:
	if _collection_heading == null:
		return
	var parent := _collection_heading.get_parent()
	var index := _collection_heading.get_index()
	_collection_heading_surface = PanelContainer.new()
	_collection_heading_surface.name = "CollectionHeadingSurface"
	_collection_heading_surface.add_theme_stylebox_override("panel", ArtScript.paper_style(12.0))
	parent.add_child(_collection_heading_surface)
	parent.move_child(_collection_heading_surface, index)
	_collection_heading.reparent(_collection_heading_surface)
	_collection_heading_top = _collection_heading.get_node("HeadingTop")
	_collection_title = _collection_heading_top.get_node("CollectionTitle")
	_collection_title.text = "理念收藏"
	_collection_title.theme_type_variation = &"Label"
	_collection_title.add_theme_color_override("font_color", ArtScript.INK)
	_collection_title.add_theme_font_override("font",
		preload("res://assets/fonts/annual_pencil/Muyao-Softbrush-2.ttf"))
	_collection_tabs_scroll = _collection_heading.get_node("TabsScroll")
	_collection_heading.add_theme_constant_override("separation", 6)


func _style_school_tabs() -> void:
	if _tabs == null:
		return
	_tabs.add_theme_font_override("font", UITokens.dossier_font("sans"))
	_tabs.add_theme_font_size_override("font_size", 15)
	_tabs.add_theme_stylebox_override("tab_unselected", _tab_style("normal"))
	_tabs.add_theme_stylebox_override("tab_focus", StyleBoxEmpty.new())
	for state in ["normal", "hover", "pressed", "selected", "disabled"]:
		var style := _tab_style(state)
		if state == "selected":
			_tabs.add_theme_stylebox_override("tab_selected", style)
		else:
			_tabs.add_theme_stylebox_override("tab_%s" % state, style)
	_tabs.add_theme_color_override("font_selected_color", Color(0.97, 0.90, 0.72))
	_tabs.add_theme_color_override("font_unselected_color", ArtScript.INK_MUTED)
	_tabs.add_theme_color_override("font_hovered_color", ArtScript.VERMILION)
	_tabs.add_theme_color_override("font_disabled_color", Color(0.35, 0.28, 0.21, 0.48))
	_tabs.add_theme_constant_override("h_separation", 5)
	_tabs.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_NEVER


func _tab_style(state: String) -> StyleBox:
	var tint := Color(0.94, 0.90, 0.80)
	if state == "selected" or state == "pressed":
		tint = Color(0.76, 0.32, 0.23)
	elif state == "hover":
		tint = Color.WHITE
	return ArtScript.paper_style(8.0, tint)


func _apply_archive_metrics() -> void:
	if _slot_column != null:
		_slot_column.custom_minimum_size.x = SLOT_COLUMN_MIN_WIDTH_COMPACT \
			if _compact else SLOT_COLUMN_MIN_WIDTH
		_slot_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_slot_column.size_flags_stretch_ratio = 0.72
	if _collection_column != null:
		_collection_column.custom_minimum_size.x = COLLECTION_COLUMN_MIN_WIDTH_COMPACT \
			if _compact else COLLECTION_COLUMN_MIN_WIDTH
		_collection_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_collection_column.size_flags_stretch_ratio = 1.4
	if _top_bar != null:
		_top_bar.custom_minimum_size.y = 58 if _compact else 80
	if _top_title != null:
		_top_title.add_theme_font_size_override("font_size", 20 if _compact else 24)
	if _point_scroll != null:
		_point_scroll.custom_minimum_size = Vector2(270, 48) \
			if _compact else Vector2(360, 56)
	if _offer_button != null:
		_offer_button.custom_minimum_size = Vector2(154, 34) \
			if _compact else Vector2(210, 42)
		_offer_button.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
		_offer_button.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	if _deck_heading != null:
		_deck_heading.custom_minimum_size.y = 30 if _compact else 42
	if _ideology_section_header != null:
		_ideology_section_header.custom_minimum_size.y = 24 if _compact else 30
	if _spirit_section_header != null:
		_spirit_section_header.custom_minimum_size.y = 24 if _compact else 42
	if _spirit_inset != null:
		var horizontal_inset := 4 if _compact else 7
		_spirit_inset.add_theme_constant_override(
			"margin_left", horizontal_inset)
		_spirit_inset.add_theme_constant_override(
			"margin_right", horizontal_inset)
		_spirit_inset.add_theme_constant_override(
			"margin_top", 3 if _compact else 7)
		_spirit_inset.add_theme_constant_override(
			"margin_bottom", 3 if _compact else 7)
	if _resonance_panel != null:
		_resonance_panel.custom_minimum_size.y = 38 if _compact else 54
	if _deck_scroll != null:
		# 短窗允许滚动阅读，不用整组内容的最小高度撑开工作区。
		_deck_scroll.custom_minimum_size.y = 80 if _compact else 260
	if _resonance_panel != null:
		_resonance_panel.visible = not _compact
	if _collection_heading != null:
		_collection_heading.custom_minimum_size.y = 0
	if _collection_heading_surface != null:
		_collection_heading_surface.custom_minimum_size.y = 44 if _compact else 80
		_collection_heading_surface.add_theme_stylebox_override("panel",
			ArtScript.paper_style(6.0 if _compact else 12.0))
	if _collection_title != null:
		_collection_title.add_theme_font_size_override(
			"font_size", 17 if _compact else 24)
	if _collection_tabs_scroll != null:
		_collection_tabs_scroll.custom_minimum_size.y = 34
		var tab_parent: Control = _collection_heading
		if _collection_tabs_scroll.get_parent() != tab_parent:
			_collection_tabs_scroll.reparent(tab_parent)
		_collection_tabs_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _collection_heading_top != null:
		_collection_heading_top.add_theme_constant_override(
			"separation", 6 if _compact else 12)
		# The authored plate names the collection in every layout; the scene's
		# paper tag would repeat it as a second, unrelated title.
		var scene_title := _collection_heading_top.get_node_or_null(
			"CollectionTitle") as Control
		if scene_title != null:
			scene_title.visible = true
		var spacer := _collection_heading_top.get_node_or_null("HeadingSpacer") as Control
		if spacer != null:
			spacer.visible = true
	if _collection_margin != null:
		var inset := 6 if _compact else 10
		for side in ["left", "top", "right", "bottom"]:
			_collection_margin.add_theme_constant_override("margin_%s" % side, inset)
	if _body != null:
		_body.add_theme_constant_override("separation", 12 if _compact else 18)
	if _sort != null:
		_sort.add_theme_font_override("font", UITokens.dossier_font("sans"))
		_sort.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)


## One-shot, session-scoped entrance. Daily refresh and tab changes never replay
## it; reduced motion skips it entirely.
func _play_workspace_intro() -> void:
	if _entry_intro_played or not is_inside_tree():
		return
	_entry_intro_played = true
	if motion_reduced():
		return
	for node in [_deck_table, _collection_heading, _collection_drop]:
		if node is Control:
			(node as Control).modulate.a = 0.0
	var tween := create_tween().set_parallel(true)
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if _deck_table != null:
		tween.tween_property(_deck_table, "modulate:a", 1.0, 0.26)
	if _collection_heading != null:
		tween.tween_property(_collection_heading, "modulate:a", 1.0, 0.22).set_delay(0.06)
	if _collection_drop != null:
		tween.tween_property(_collection_drop, "modulate:a", 1.0, 0.30).set_delay(0.12)


## Keep the modal paper quiet so the candidate cards carry the hierarchy.
func _build_stage_scenery() -> void:
	_offer.add_theme_stylebox_override("panel", ArtScript.paper_style(16.0))
	ArtScript.attach_panel_shadow(_offer, 0.30, 16)
	_offer_layer.theme = preload("res://assets/themes/player_session_theme.tres")
	_offer_title.add_theme_color_override("font_color", ArtScript.INK)


func _build_stage_header() -> void:
	var column := _offer_column if _offer_column != null \
		else _offer_title.get_parent() as VBoxContainer
	_offer_column = column
	var header := VBoxContainer.new()
	header.name = "StageHeader"
	header.alignment = BoxContainer.ALIGNMENT_CENTER
	header.add_theme_constant_override("separation", 0)
	_offer_header = header
	var title_parent := _offer_title.get_parent()
	var title_index := _offer_title.get_index()
	title_parent.remove_child(_offer_title)
	_offer_title.owner = null
	column.add_child(header)
	column.move_child(header, title_index)
	header.add_child(_offer_title)



func _build_stage_footer() -> void:
	if _offer_column != null and _offer_actions != null:
		var target_index := _offer_column.get_children().find(_offer_actions)
		if target_index >= 0:
			var footer := VBoxContainer.new()
			footer.name = "StageFooter"
			footer.alignment = BoxContainer.ALIGNMENT_CENTER
			footer.add_theme_constant_override("separation", 2)
			_offer_footer = footer
			_offer_column.add_child(footer)
			_offer_column.move_child(footer, target_index)
			_offer_column.remove_child(_offer_actions)
			_offer_actions.owner = null
			footer.add_child(_offer_actions)
			_offer_hint = ArtScript.label("悬停查看详情 · 单击选定 · Esc 收起",
				14, ArtScript.INK_MUTED)
			footer.add_child(_offer_hint)


func set_model(model: Dictionary) -> void:
	_bind_nodes()
	_apply_model(model)


func refresh_model(model: Dictionary) -> void:
	_bind_nodes()
	_apply_model(model)


func set_compact(compact: bool) -> void:
	_bind_nodes()
	var changed := compact != _compact
	_compact = compact
	# Card glyph sizes are cheap to reapply, so they never wait for a signature
	# change; only the container rebuild below is gated.
	if not changed and not _signature.is_empty():
		return
	_apply_stage_metrics()
	_empty.custom_minimum_size = Vector2(0, 150 if compact else 170)
	_apply_archive_metrics()
	_style_school_tabs()
	if _compact and Time.get_ticks_msec() >= _hint_hold_until:
		_hint.visible = false
	for view in _resonance_views.values():
		(view as ResonanceEmblem).set_compact(compact)
	_signature = ""
	if not _snapshot.is_empty() and not _presentation.is_empty():
		_rebuild_board()


func _stage_card_size() -> Vector2:
	# The tray is modal over the workspace, not the whole game viewport. Measuring
	# the workspace height here was what pushed the action row below 720p.
	var view_height := _offer_layer.size.y if _offer_layer != null \
		and _offer_layer.size.y > 0.0 else size.y if size.y > 0.0 else 576.0
	var view_width := _offer_layer.size.x if _offer_layer != null \
		and _offer_layer.size.x > 0.0 else 1024.0
	var chrome_height := STAGE_CHROME_HEIGHT_COMPACT if _compact else STAGE_CHROME_HEIGHT
	_stage_available_height = maxf(0.0,
		view_height - STAGE_OUTER_INSET * 2.0 - chrome_height)
	var height := clampf(_stage_available_height, STAGE_CARD_MIN_HEIGHT,
		STAGE_CARD_MAX_HEIGHT)
	if view_width > 0.0:
		var gutter := 62.0 if _compact else 136.0
		height = minf(height, ((view_width - gutter) / 3.0) / CardScript.CARD_ASPECT)
	height = maxf(height, 118.0)
	return Vector2(roundf(height * CardScript.CARD_ASPECT), roundf(height))


func _apply_stage_metrics() -> void:
	var cards: HBoxContainer = null
	if _choice_0 != null:
		cards = _choice_0.get_parent() as HBoxContainer
	var separation := 18 if _compact else 28
	var card_size := _stage_card_size()
	_stage_card_applied = card_size
	if _offer != null:
		var chrome_width := 54.0 if _compact else 92.0
		var desired_width := card_size.x * 3.0 + separation * 2.0 + chrome_width
		_offer.custom_minimum_size = Vector2(
			minf(_offer_layer.size.x - STAGE_OUTER_INSET * 2.0, desired_width), 0)
	if cards != null:
		# 720p keeps the three offer cards and their actions inside one viewport.
		cards.add_theme_constant_override("separation", separation)
		var column := cards.get_parent() as VBoxContainer
		if column != null:
			column.add_theme_constant_override("separation", 4 if _compact else 7)
		# Reserve the three-card row even while the deck shuffles, so the tray does
		# not jump in size when the offer lands.
		cards.custom_minimum_size.x = card_size.x * 3.0 + separation * 2.0
		cards.custom_minimum_size.y = card_size.y
	if _offer_title != null:
		_offer_title.add_theme_font_size_override("font_size", 22 if _compact else 28)
		if _compact:
			_offer_title.theme_type_variation = COMPACT_TITLE_STYLE
			_offer_title.custom_minimum_size = Vector2.ZERO
		else:
			_offer_title.theme_type_variation = &"Label"
			_offer_title.custom_minimum_size = Vector2(0, 34)
	if _offer_header != null:
		_offer_header.add_theme_constant_override("separation", 0)
	if _offer_hint != null:
		_offer_hint.add_theme_font_size_override("font_size", 14)
		_offer_hint.visible = true
	if _offer_footer != null:
		_offer_footer.add_theme_constant_override("separation", 0 if _compact else 2)
		_offer_footer.custom_minimum_size.y = 48 if _compact else 52
	if _offer_body != null:
		var inset := 10 if _compact else 16
		_offer_body.add_theme_constant_override("margin_left", inset)
		_offer_body.add_theme_constant_override("margin_right", inset)
		_offer_body.add_theme_constant_override("margin_top", 6 if _compact else 10)
		_offer_body.add_theme_constant_override("margin_bottom", 6 if _compact else 10)
	if _offer_actions != null:
		_offer_actions.add_theme_constant_override("separation", 8 if _compact else 12)
		for button in _offer_actions.get_children():
			if button is Button:
				(button as Button).custom_minimum_size.y = 30 if _compact else 32
	for index in 3:
		var card := _choice(index)
		if card == null:
			continue
		# Stage text follows the actual offer size, not the collection compact
		# style. Otherwise a 145px 720p card still uses 16px frame padding.
		card.call("set_compact", false)
		card.set("stage_rest_offset", Vector2.ZERO)
		card.set("stage_rest_rotation", 0.0)
		card.call("reset_motion")
		card.call("set_stage_size", card_size)
	if _draw_stack != null:
		_draw_stack.set_card_size(card_size)


func _on_workspace_resized() -> void:
	if _choice_0 == null:
		return
	var target := _stage_card_size()
	if absf(target.y - _stage_card_applied.y) < 4.0 \
			and absf(target.x - _stage_card_applied.x) < 4.0:
		return
	_apply_stage_metrics()


func set_player_controller(controller) -> void:
	var bindings := {
		"command_settled": "_on_player_command_settled",
		"ideology_offer_ready": "_on_ideology_offer_ready",
		"ideology_draw_state_changed": "_on_ideology_draw_state_changed",
	}
	if _player_controller != null:
		for signal_name in bindings:
			var old_callback := Callable(self, String(bindings[signal_name]))
			if _player_controller.has_signal(signal_name) \
					and _player_controller.is_connected(signal_name, old_callback):
				_player_controller.disconnect(signal_name, old_callback)
	_player_controller = controller
	if _player_controller == null:
		return
	for signal_name in bindings:
		var callback := Callable(self, String(bindings[signal_name]))
		if _player_controller.has_signal(signal_name) \
				and not _player_controller.is_connected(signal_name, callback):
			_player_controller.connect(signal_name, callback)
	if _player_controller.has_method("ideology_draw_phase"):
		_draw_phase = String(_player_controller.ideology_draw_phase())


# --- model ----------------------------------------------------------------

func _apply_model(model: Dictionary) -> void:
	var ideology: Dictionary = model.get("ideology", {})
	_facade = ideology.get("facade")
	_country_handle = int(model.get("country_handle", 0))
	_current_day = int(model.get("current_day", 0))
	if ideology.is_empty() or not bool(ideology.get("available", false)):
		var raw_reason := String(ideology.get("reason", model.get("reason", "")))
		var loading := ideology.is_empty() and not bool(model.get("available", false)) \
			and (raw_reason.is_empty() or raw_reason == "正在载入已提交数据")
		_show_shell(CountryViewModel.ideology_player_reason(raw_reason), loading)
		return
	_catalog = ideology.get("catalog", {})
	_snapshot = ideology.get("snapshot", {})
	_presentation = ideology.get("presentation", {})
	if _presentation.is_empty():
		_presentation = CountryViewModel.present_ideology(_snapshot, _catalog)
	if _player_controller != null and _player_controller.has_method("ideology_draw_phase"):
		_draw_phase = String(_player_controller.ideology_draw_phase())
	_index_catalog()
	_index_states()
	_refresh_effect_report()
	_render_top()
	var known: PackedInt32Array = _snapshot.get("known_ids", PackedInt32Array())
	var explain_signature := "%d|%d|%s|%s|%s|%s" % [
		_country_handle, int(_snapshot.get("support_revision", 0)), known,
		_snapshot.get("levels", PackedInt32Array()),
		_snapshot.get("locations", PackedInt32Array()),
		_snapshot.get("transition_pending", PackedByteArray())]
	if explain_signature != _explain_signature:
		_explain_signature = explain_signature
		_refresh_live_explain(known)
	var signature := "%s|%s|%s|%s|%d|%d|%d|%d|%s|%d|%d" % [known,
		_snapshot.get("levels", PackedInt32Array()),
		_snapshot.get("locations", PackedInt32Array()),
		_snapshot.get("active_synergy_ids", PackedInt32Array()),
		int(_presentation.get("slots_capacity", 0)),
		int(_presentation.get("spirits_capacity", 0)),
		_country_handle,
		_metadata.size(), _tab_school, _sort_mode, int(_compact)]
	if signature != _signature:
		_signature = signature
		_rebuild_board()
	else:
		_refresh_board_values()
	_rebuild_offer()
	_show_empty_state(bool(_presentation.get("empty", known.is_empty())), _presentation)


func _index_catalog() -> void:
	var rows: Array = _catalog.get("ideologies", [])
	if rows.size() == _metadata.size() and not _metadata.is_empty():
		return
	_metadata.clear()
	for row_value in rows:
		var row := row_value as Dictionary
		_metadata[int(row.get("dense_id", -1))] = row


func _index_states() -> void:
	_states.clear()
	var ids: PackedInt32Array = _snapshot.get("idea_ids", PackedInt32Array())
	var understanding: PackedInt64Array = _snapshot.get("understanding_q16", PackedInt64Array())
	var levels: PackedInt32Array = _snapshot.get("levels", PackedInt32Array())
	var locations: PackedInt32Array = _snapshot.get("locations", PackedInt32Array())
	var pending: PackedByteArray = _snapshot.get("transition_pending", PackedByteArray())
	for index in ids.size():
		_states[int(ids[index])] = {
			"understanding": int(understanding[index]) if index < understanding.size() else 0,
			"level": int(levels[index]) if index < levels.size() else 0,
			"location": int(locations[index]) if index < locations.size() else 0,
			"pending": index < pending.size() and pending[index] != 0,
		}


func _render_top() -> void:
	var points := int(_presentation.get("points", 0))
	var cost := int(_presentation.get("offer_cost_q16", 65536))
	var gain := int(_presentation.get("last_gain_q16", 0))
	var ready := bool(_presentation.get("baseline_ready", false))
	var points_signature := "%d|%d|%d|%s" % [points, cost, gain, ready]
	if points_signature != _points_signature:
		_points_signature = points_signature
		_point_scroll.call("set_points", points, cost, gain, ready, motion_reduced())
	_point_scroll.tooltip_text = "理念点 %s / 抽取 %s\n累计 %s" % [
		_q16(points), _q16(cost), _q16(int(_presentation.get("lifetime_points_q16", 0)))]
	var offer_active := bool(_presentation.get("offer_active", false))
	var waiting := _draw_waiting()
	var generation := int(_snapshot.get("offer_generation", 0))
	var collapsed := offer_active and generation == _dismissed_generation
	_offer_button.disabled = waiting or not (bool(_presentation.get("can_open_offer", false))
		or collapsed)
	if waiting:
		_offer_button.text = "抽取中…"
	elif collapsed:
		_offer_button.text = "查看候选"
	elif offer_active:
		_offer_button.text = "候选待选"
	else:
		_offer_button.text = "抽取 · %s" % String(
			_presentation.get("offer_cost_text", ""))
	_offer_button.tooltip_text = "每次抽取消耗 %s 理念点，下次费用 +20%%" \
		% String(_presentation.get("offer_cost_text", ""))
	if Time.get_ticks_msec() >= _hint_hold_until:
		_hint.text = "" if waiting \
			else String(_presentation.get("offer_hint", ""))
		_hint.visible = not _compact and not _hint.text.is_empty()
	# Capacity is carried by the slot rows themselves; do not repeat it as a
	# second counter above the board.
	_slot_counts.text = ""
	_slot_counts.visible = false


func _draw_waiting() -> bool:
	return _draw_phase == "offer" or _draw_phase == "reroll"


## Per-card effect-instance totals for the card face.
##
## Refreshed on every model application, not on the explain signature: the
## instance set also moves when a selector's targets change (a cell changes
## hands) without any level or location changing, and the call is one native
## pass over at most a few hundred rows.
func _refresh_effect_report() -> void:
	if _facade == null or _country_handle == 0:
		_effect_summary = {}
		return
	_effect_summary = IdeologyEffectReportScript.summarize(
		_facade.effect_instances(_country_handle))


func _refresh_live_explain(known: PackedInt32Array) -> void:
	_live_explain = _facade.explain_ideologies(_country_handle, known) \
		if _facade != null and _facade.has_method("explain_ideologies") else {}
	_live_by_id.clear()
	if not bool(_live_explain.get("ok", false)):
		return
	var ids: PackedInt32Array = _live_explain.get("ideology_ids", PackedInt32Array())
	var support: PackedInt32Array = _live_explain.get("support_q16", PackedInt32Array())
	var thresholds: PackedInt32Array = _live_explain.get("support_thresholds_q16", PackedInt32Array())
	var blockers: PackedInt32Array = _live_explain.get("support_blocking_classes", PackedInt32Array())
	var available: PackedByteArray = _live_explain.get("support_available", PackedByteArray())
	var allowed: PackedByteArray = _live_explain.get("support_allowed", PackedByteArray())
	var equip_allowed: PackedByteArray = _live_explain.get("equip_allowed", PackedByteArray())
	var unequip_allowed: PackedByteArray = _live_explain.get("unequip_allowed", PackedByteArray())
	var promote_allowed: PackedByteArray = _live_explain.get("promote_allowed", PackedByteArray())
	var stance_offsets: PackedInt32Array = _live_explain.get("stance_offsets", PackedInt32Array())
	var stance_classes: PackedInt32Array = _live_explain.get("stance_class_indices", PackedInt32Array())
	var influence: PackedInt64Array = _live_explain.get("class_influence", PackedInt64Array())
	var adopt_contributions: PackedInt64Array = _live_explain.get("adopt_contributions", PackedInt64Array())
	var repeal_contributions: PackedInt64Array = _live_explain.get("repeal_contributions", PackedInt64Array())
	var promote_contributions: PackedInt64Array = _live_explain.get("promote_contributions", PackedInt64Array())
	for index in ids.size():
		var support_rows: Array[Dictionary] = []
		for direction in 3:
			var row := index * 3 + direction
			support_rows.append({
				"support_q16": int(support[row]) if row < support.size() else 0,
				"threshold_q16": int(thresholds[row]) if row < thresholds.size() else 0,
				"blocking_class": int(blockers[row]) if row < blockers.size() else -1,
				"available": row < available.size() and available[row] != 0,
				"allowed": row < allowed.size() and allowed[row] != 0,
			})
		var class_rows: Array[Dictionary] = []
		var stance_begin := int(stance_offsets[index]) if index < stance_offsets.size() else 0
		var stance_end := int(stance_offsets[index + 1]) \
			if index + 1 < stance_offsets.size() else stance_begin
		for row in range(stance_begin, stance_end):
			class_rows.append({
				"class_index": int(stance_classes[row]),
				"influence": int(influence[row]),
				"contributions": [int(adopt_contributions[row]),
					int(repeal_contributions[row]), int(promote_contributions[row])],
			})
		_live_by_id[int(ids[index])] = {
			"support": support_rows,
			"classes": class_rows,
			"equip_allowed": index < equip_allowed.size() and equip_allowed[index] != 0,
			"unequip_allowed": index < unequip_allowed.size() and unequip_allowed[index] != 0,
			"promote_allowed": index < promote_allowed.size() and promote_allowed[index] != 0,
		}


# --- deck table and collection --------------------------------------------

func _rebuild_board() -> void:
	var saved_scroll := _scroll.scroll_vertical if _scroll != null else 0
	var known: PackedInt32Array = _snapshot.get("known_ids", PackedInt32Array())
	var equipped: Array[int] = []
	var spirits: Array[int] = []
	for value in known:
		var location := int((_states.get(int(value), {}) as Dictionary).get("location", 0))
		if location == 1:
			equipped.append(int(value))
		elif location == 2:
			spirits.append(int(value))
	_fill_slots(_ideology_slots, 1, equipped, int(_presentation.get("slots_capacity", 0)))
	_fill_slots(_spirit_slots, 2, spirits, int(_presentation.get("spirits_capacity", 0)))
	_update_resonance(null, -1)
	_rebuild_collection(known)
	if _scroll != null:
		_scroll.set_deferred("scroll_vertical", saved_scroll)


## One compact row per equipped idea, plus a single collapsed row for whatever
## empty slots remain. Future technology milestones are a caption, not alcoves.
func _fill_slots(host: VBoxContainer, kind: int, hosted: Array[int], capacity: int) -> void:
	if host == null:
		return
	if kind == 2:
		if _spirit_alcove != null:
			_spirit_alcove.visible = capacity > 0
		if _spirit_section_header != null:
			_spirit_section_header.visible = capacity > 0
	for child in host.get_children():
		host.remove_child(child)
		child.queue_free()
	for ideology_id in hosted:
		var row := NicheScript.new()
		row.configure(kind, false, _compact)
		row.set_row(_slot_row_data(ideology_id, kind))
		row.command_requested.connect(_on_slot_command)
		row.promote_requested.connect(_request_promotion)
		# Same handler as the card grid: "where does this act" does not depend on
		# whether the caller was a 196x260 card or a 60px row.
		row.locate_requested.connect(_on_card_locate_requested)
		host.add_child(row)
	var empty_count := maxi(0, capacity - hosted.size())
	if empty_count > 0:
		var empty_row := NicheScript.new()
		empty_row.configure(kind, true, _compact)
		# The next technology milestone belongs on the empty slot itself: the
		# hint only exists while a slot is still missing, so it never costs
		# vertical space in a full board.
		empty_row.set_empty_count(empty_count, _next_milestone(kind))
		empty_row.card_dropped.connect(_on_niche_drop)
		empty_row.drag_hovered.connect(_on_niche_hover.bind(empty_row))
		host.add_child(empty_row)


func _slot_row_data(ideology_id: int, kind: int) -> Dictionary:
	var meta: Dictionary = _metadata.get(ideology_id, {})
	var state: Dictionary = _states.get(ideology_id, {})
	var live: Dictionary = _live_by_id.get(ideology_id, {})
	var level := maxi(0, int(state.get("level", 0)))
	var location := int(state.get("location", 0))
	var pending := bool(state.get("pending", false))
	var view := CountryViewModel.present_ideology_card(meta, level,
		IdeologyEffectReportScript.card_row(_effect_summary, ideology_id))
	var level_progress: Dictionary = LevelProgressScript.build(meta, state,
		String(view.get("level_label", "")))
	var tooltip := PackedStringArray([_display_name(meta, ideology_id),
		String(view.get("tooltip", ""))])
	if bool(level_progress.get("maxed", false)):
		tooltip.append("已至最高境界")
	else:
		tooltip.append("理解度 %s / %s" % [
			_q16(int(level_progress.get("understanding_q16", 0))),
			_q16(int(level_progress.get("threshold_q16", 0)))])
	tooltip.append(_support_tooltip(live, 1))
	if location == 1:
		tooltip.append(_support_tooltip(live, 2))
	var min_spirit_level := int(meta.get("min_spirit_level", 99))
	var can_promote := location == 1 and level >= min_spirit_level \
		and bool(live.get("promote_allowed", true)) and not pending
	var promote_tooltip := "晋升为民族精神（不可逆）"
	if location == 1 and level < min_spirit_level:
		promote_tooltip = "需达到境界 %d 才能晋升" % (min_spirit_level + 1)
	return {
		"ideology_id": ideology_id,
		"display_name": _display_name(meta, ideology_id),
		"school_id": String(meta.get("school_id", "")),
		"rarity": int(meta.get("rarity", 1)),
		"level": level,
		"level_count": int(view.get("level_count", 3)),
		"level_label": String(view.get("level_label", "")),
		"level_progress": level_progress,
		"effects": view.get("effect_lines", PackedStringArray()),
		"pending": pending,
		"can_unequip": bool(live.get("unequip_allowed", true)),
		"can_promote": can_promote,
		"unequip_tooltip": "%s\n%s" % ["撤回这条道路", _support_summary(live, 1)],
		"promote_tooltip": "%s\n%s" % [promote_tooltip, _support_summary(live, 2)],
		"tooltip": "\n".join(tooltip).strip_edges(),
		"detail_model": _detail_data(ideology_id),
		"kind": kind,
	}


## The next technology milestone gating another slot of this kind, or "".
func _next_milestone(kind: int) -> String:
	var capacity := int(_presentation.get(
		"slots_capacity" if kind == 1 else "spirits_capacity", 0))
	var capacity_max := int(_presentation.get(
		"slots_max" if kind == 1 else "spirits_max", capacity))
	if capacity >= capacity_max:
		return ""
	var captions := _locked_captions(kind)
	if captions.is_empty():
		return ""
	return "下一格 %s" % String(captions[0])


func _locked_captions(kind: int) -> PackedStringArray:
	var captions := PackedStringArray()
	for unlock_value in _presentation.get("capacity_unlocks", []) as Array:
		var unlock := unlock_value as Dictionary
		if bool(unlock.get("owned", false)):
			continue
		var delta := int(unlock.get("ideology_delta" if kind == 1 else "spirit_delta", 0))
		for _i in delta:
			captions.append(String(unlock.get("technology_name", "")))
	return captions


func _rebuild_collection(known: PackedInt32Array) -> void:
	for child in _collection.get_children():
		_collection.remove_child(child)
		child.queue_free()
	_progress_by_id.clear()
	_collection_entries.clear()
	var ids: Array[int] = []
	for value in known:
		var meta: Dictionary = _metadata.get(int(value), {})
		if _tab_school.is_empty() or String(meta.get("school_id", "")) == _tab_school:
			ids.append(int(value))
	if _sort_mode != 0:
		ids.sort_custom(_sort_less)
	for ideology_id in ids:
		_collection.add_child(_make_collection_entry(ideology_id))
	_apply_collection_columns()
	_update_progress()
	_update_collection_metrics(ids.size())


func _on_collection_resized() -> void:
	if _collection == null or _collection.get_child_count() == 0:
		return
	_apply_collection_columns()


## Card width follows the viewport; text flow determines height at every size.
func _apply_collection_columns() -> void:
	if _collection == null or _scroll == null:
		return
	var available := maxf(1.0, _scroll.size.x - 16.0)
	var columns := maxi(1, int(floorf((available + 12.0) / 372.0)))
	var width := floorf((available - (columns - 1) * 12.0) / columns)
	for child in _collection.get_children():
		var entry := child as Control
		entry.custom_minimum_size.x = width
		entry.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		entry.call_deferred("refresh_layout")


func _collection_max_card_width() -> float:
	# At 1080p one card should not grow into a banner: the generated frame reads
	# as an object at roughly 420px, while larger copies make its line weight and
	# parchment grain look thin beside the cabinet.
	return 420.0 if _compact else 460.0


func _update_collection_metrics(_visible_count: int) -> void:
	# Value refresh and filter changes preserve stable opacity and hit targets.
	pass


func _sort_less(a: int, b: int) -> bool:
	var meta_a: Dictionary = _metadata.get(a, {})
	var meta_b: Dictionary = _metadata.get(b, {})
	match _sort_mode:
		1:
			if int(meta_a.get("rarity", 1)) != int(meta_b.get("rarity", 1)):
				return int(meta_a.get("rarity", 1)) > int(meta_b.get("rarity", 1))
		2:
			var school_a := ArtScript.SCHOOL_ORDER.find(String(meta_a.get("school_id", "")))
			var school_b := ArtScript.SCHOOL_ORDER.find(String(meta_b.get("school_id", "")))
			if school_a != school_b:
				return school_a < school_b
		3:
			var level_a := int((_states.get(a, {}) as Dictionary).get("level", 0))
			var level_b := int((_states.get(b, {}) as Dictionary).get("level", 0))
			if level_a != level_b:
				return level_a > level_b
	return a < b


func _make_collection_entry(ideology_id: int) -> Control:
	var state: Dictionary = _states.get(ideology_id, {})
	var live: Dictionary = _live_by_id.get(ideology_id, {})
	var meta: Dictionary = _metadata.get(ideology_id, {})
	var location := int(state.get("location", 0))
	var pending := bool(state.get("pending", false))
	var view := CountryViewModel.present_ideology_card(meta,
		maxi(0, int(state.get("level", 0))),
		IdeologyEffectReportScript.card_row(_effect_summary, ideology_id))
	var level_progress: Dictionary = LevelProgressScript.build(meta, state,
		String(view.get("level_label", "")))
	var entry := CollectionEntry.new()
	entry.name = "IdeologyCollectionCard"
	_collection_entries[ideology_id] = entry
	entry.setup({
		"name": _display_name(meta, ideology_id),
		"school_id": String(meta.get("school_id", "")),
		"rarity": int(meta.get("rarity", 1)),
		"level_label": String(view.get("level_label", "")),
		"level_progress": level_progress,
		"effects": view.get("effect_lines", PackedStringArray()),
		"next_effects": view.get("next_level_lines", PackedStringArray()),
		"detail": String(view.get("detail", "")),
		"tooltip": String(_card_data(ideology_id, true).get("tooltip", "")),
		"detail_model": _detail_data(ideology_id),
		"location": location,
		"pending": pending,
		"draggable": location != 2,
		"payload": {"ideology_card": ideology_id, "location": location},
		"activated": Callable(self, "_on_card_activated").bind(ideology_id),
		"compact": _compact,
	})
	entry.custom_minimum_size = Vector2(0, 180.0 if _compact else 220.0)
	entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var progress: Control = entry.call("level_meter")
	_progress_by_id[ideology_id] = progress
	progress.set_meta("accent_source", int(meta.get("rarity", 1)))
	var actions: HBoxContainer = entry.call("footer")
	actions.alignment = BoxContainer.ALIGNMENT_END
	# The ink line and the action are separate targets: a card-wide row can be
	# dragged while the button remains a normal click target.
	entry.mouse_filter = Control.MOUSE_FILTER_PASS
	actions.mouse_filter = Control.MOUSE_FILTER_STOP
	actions.visible = true
	match location:
		0:
			actions.add_child(_action_button("推行", pending
				or not bool(live.get("equip_allowed", false)),
				_command.bind("equip", ideology_id), _support_summary(live, 0),
				_compact))
		1:
			actions.add_child(_action_button("撤回", pending
				or not bool(live.get("unequip_allowed", false)),
				_command.bind("unequip", ideology_id), _support_summary(live, 1),
				_compact))
			actions.add_child(_action_button("晋升", pending
				or int(state.get("level", 0)) < int(meta.get("min_spirit_level", 99))
				or not bool(live.get("promote_allowed", false)),
				_request_promotion.bind(ideology_id), _support_summary(live, 2),
				_compact))
		_:
			actions.add_child(ArtScript.label("民族精神", 11, ArtScript.VERMILION))
	return entry


func _action_button(text: String, disabled: bool, callback: Callable,
		tooltip: String, _compact_value := false) -> Button:
	var button := Button.new()
	button.text = text
	button.disabled = disabled
	button.custom_minimum_size = Vector2(80, 36)
	button.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
	button.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	button.theme_type_variation = &"PKSealPrimaryButton"
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
func _on_card_locate_requested(ideology_id: int) -> void:
	var row: Dictionary = IdeologyEffectReportScript.card_row(_effect_summary, ideology_id)
	if row.is_empty():
		return
	var cells: PackedInt32Array = row.get("cells", PackedInt32Array())
	if cells.is_empty():
		return
	target_cells_requested.emit(cells)


func _card_data(ideology_id: int, in_collection: bool) -> Dictionary:
	var meta: Dictionary = _metadata.get(ideology_id, {})
	var state: Dictionary = _states.get(ideology_id, {})
	var live: Dictionary = _live_by_id.get(ideology_id, {})
	var level := maxi(0, int(state.get("level", 0)))
	var location := int(state.get("location", 0))
	var pending := bool(state.get("pending", false))
	var view := CountryViewModel.present_ideology_card(meta, level,
		IdeologyEffectReportScript.card_row(_effect_summary, ideology_id))
	var stamp := ""
	if pending:
		stamp = "待生效"
	elif in_collection and location == 1:
		stamp = "推行中"
	elif in_collection and location == 2:
		stamp = "精神"
	var level_progress: Dictionary = LevelProgressScript.build(meta, state,
		String(view.get("level_label", "")))
	var tooltip := PackedStringArray([_display_name(meta, ideology_id), String(view.get("tooltip", ""))])
	if bool(level_progress.get("maxed", false)):
		tooltip.append("已至最高境界")
	else:
		tooltip.append("理解度 %s / %s" % [
			_q16(int(level_progress.get("understanding_q16", 0))),
			_q16(int(level_progress.get("threshold_q16", 0)))])
	tooltip.append(_support_tooltip(live, 0 if location == 0 else 1))
	return {
		"ideology_id": ideology_id,
		"display_name": _display_name(meta, ideology_id),
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
		"detail_model": _detail_data(ideology_id),
		"dimmed": in_collection and location != 0,
	}


func _detail_data(ideology_id: int, offer := false) -> Dictionary:
	var meta: Dictionary = _metadata.get(ideology_id, {})
	var state: Dictionary = {} if offer else _states.get(ideology_id, {})
	var level := int(state.get("level", 0))
	var view := CountryViewModel.present_ideology_card(meta, level,
		IdeologyEffectReportScript.card_row(_effect_summary, ideology_id))
	var location := int(state.get("location", 0))
	var live: Dictionary = _live_by_id.get(ideology_id, {})
	var supports: Array[Dictionary] = []
	var notes := PackedStringArray()
	if not offer and location != 2:
		var direction := 0 if location == 0 else 1
		var rows: Array = live.get("support", [])
		if direction < rows.size():
			var row: Dictionary = rows[direction].duplicate()
			row["action"] = "推行" if direction == 0 else "撤回"
			row["reason"] = "关键阶层未达到最低支持要求" if int(row.get("blocking_class", -1)) >= 0 else ""
			supports.append(row)
		if location == 1:
			notes.append("晋升民族精神需达到第 %d 境，晋升不可逆。" % (int(meta.get("min_spirit_level", 2)) + 1))
	var requirements: PackedStringArray = meta.get("required_technology_names", PackedStringArray())
	if not requirements.is_empty():
		notes.append("需要科技：%s" % "、".join(requirements))
	var rivals: PackedStringArray = meta.get("exclusion_rivals", PackedStringArray())
	if not rivals.is_empty():
		notes.append("互斥理念：%s" % "、".join(rivals))
	var synergy := String(meta.get("synergy_tooltip", ""))
	if not synergy.is_empty():
		notes.append(synergy)
	var labels: PackedStringArray = meta.get("level_labels", PackedStringArray())
	return {"name": _display_name(meta, ideology_id),
		"school_id": String(meta.get("school_id", "")), "rarity": int(meta.get("rarity", 1)),
		"status": "候选理念" if offer else "待生效" if bool(state.get("pending", false)) else "推行中" if location == 1 else "民族精神" if location == 2 else "尚未推行",
		"progress": {} if offer else LevelProgressScript.build(meta, state, String(view.get("level_label", ""))),
		"effects": view.get("effect_lines", PackedStringArray()),
		"next_effects": view.get("next_level_lines", PackedStringArray()),
		"next_level_label": String(labels[level + 1]) if level + 1 < labels.size() else "",
		"notes": notes, "supports": supports}


func _update_progress() -> void:
	for ideology_id in _progress_by_id:
		var meter := _progress_by_id[ideology_id] as Control
		if meter == null or not is_instance_valid(meter):
			continue
		var state: Dictionary = _states.get(int(ideology_id), {})
		var meta: Dictionary = _metadata.get(int(ideology_id), {})
		var view := CountryViewModel.present_ideology_card(meta,
			maxi(0, int(state.get("level", 0))),
			IdeologyEffectReportScript.card_row(_effect_summary, int(ideology_id)))
		var progress := LevelProgressScript.build(meta, state,
			String(view.get("level_label", "")))
		progress["accent"] = ArtScript.rarity_accent(int(meta.get("rarity", 1)))
		meter.configure(progress, _compact)


# --- resonance and synergy threads ----------------------------------------

func _refresh_board_values() -> void:
	for host in [_ideology_slots, _spirit_slots]:
		for row in host.get_children():
			var id := int(row.get("occupied_id"))
			if id >= 0:
				row.set_row(_slot_row_data(id, int(row.get("kind"))))
	for id in _collection_entries:
		var entry: Control = _collection_entries[id]
		var data := _card_data(id, true)
		entry.tooltip_text = String(data.get("tooltip", ""))
		entry.set_detail_model(data.get("detail_model", {}))
		var live: Dictionary = _live_by_id.get(id, {})
		var state: Dictionary = _states.get(id, {})
		entry.refresh_status(bool(state.get("pending", false)), int(state.get("location", 0)))
		for button in entry.footer().get_children():
			if not button is Button:
				continue
			var action := String(button.get_meta("ideology_action", ""))
			var direction := 0 if action == "推行" else 1 if action == "撤回" else 2
			var key: String = ["equip_allowed", "unequip_allowed", "promote_allowed"][direction]
			button.disabled = bool(state.get("pending", false)) or not bool(live.get(key, false))
			if direction == 2:
				button.disabled = button.disabled or int(state.get("level", 0)) < int(
					(_metadata.get(id, {}) as Dictionary).get("min_spirit_level", 99))
			button.tooltip_text = _support_tooltip(live, direction)
	_update_progress()


func _school_counts(extra_id: int) -> Dictionary:
	var counts := {}
	for ideology_id in _states:
		var state: Dictionary = _states[ideology_id]
		if int(state.get("location", 0)) <= 0 and int(ideology_id) != extra_id:
			continue
		var school := String((_metadata.get(int(ideology_id), {}) as Dictionary).get("school_id", ""))
		counts[school] = int(counts.get(school, 0)) + 1
	return counts


func _update_resonance(_niche: Control, preview_id: int) -> void:
	var active_ids: PackedInt32Array = _snapshot.get("active_synergy_ids", PackedInt32Array())
	var active := {}
	for value in active_ids:
		active[int(value)] = true
	var counts := _school_counts(-1)
	var preview_counts := _school_counts(preview_id) if preview_id >= 0 else counts
	var newly_active: Array[String] = []
	for school_id in _resonance_views:
		var tiers: Array[Dictionary] = []
		for row_value in _catalog.get("synergies", []) as Array:
			var row := row_value as Dictionary
			if String(row.get("school_id", "")) != school_id:
				continue
			var dense_id := int(row.get("dense_id", -1))
			var on := active.has(dense_id)
			tiers.append({"min_count": int(row.get("min_count", 0)), "active": on,
				"tooltip": String(row.get("tooltip", ""))})
			if on and not _active_resonances.has(dense_id) and not _active_resonances.is_empty():
				newly_active.append(String(school_id))
		tiers.sort_custom(_tier_less)
		(_resonance_views[school_id] as ResonanceEmblem).set_state(
			int(counts.get(school_id, 0)), int(preview_counts.get(school_id, 0)), tiers)
	var had_any := not _active_resonances.is_empty()
	_active_resonances = active.duplicate()
	_active_resonances[-999] = true  # sentinel: first sync never celebrates
	if had_any and not motion_reduced():
		for school_id in newly_active:
			var view := _resonance_views[school_id] as ResonanceEmblem
			view.celebrate()


static func _tier_less(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("min_count", 0)) < int(b.get("min_count", 0))


# --- drag and drop --------------------------------------------------------

func _on_niche_drop(ideology_id: int, from_location: int, kind: int) -> void:
	_hover_niche = null
	_hover_id = -1
	_update_resonance(null, -1)
	if kind == 1:
		if from_location == 0:
			_command("equip", ideology_id)
		return
	if from_location != 1:
		_flash_hint("需先推行")
		return
	_request_promotion(ideology_id)


func _on_niche_hover(ideology_id: int, kind: int, entered: bool, niche: Control) -> void:
	var location := int((_states.get(ideology_id, {}) as Dictionary).get("location", 0))
	if entered and kind == 1 and location == 0:
		_hover_niche = niche
		_hover_id = ideology_id
		_update_resonance(niche, ideology_id)
	elif _hover_niche == niche or not entered:
		_hover_niche = null
		_hover_id = -1
		_update_resonance(null, -1)


func _can_drop_collection(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and (data as Dictionary).has("ideology_card") \
		and int((data as Dictionary).get("location", 0)) == 1


func _drop_collection(_at_position: Vector2, data: Variant) -> void:
	_command("unequip", int((data as Dictionary).get("ideology_card", -1)))


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _hover_niche != null:
		_hover_niche = null
		_hover_id = -1
		_update_resonance(null, -1)


func _unhandled_key_input(event: InputEvent) -> void:
	if _offer_layer != null and _offer_layer.is_visible_in_tree() \
			and event.is_action_pressed(&"ui_cancel"):
		if not _draw_waiting() and not _offer_anim_busy:
			_dismiss_offer()
		get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if _offer_layer == null or not _offer_layer.is_visible_in_tree():
		return
	var backwards := event.is_action_pressed(&"ui_focus_prev")
	if not backwards and not event.is_action_pressed(&"ui_focus_next"):
		return
	var targets: Array[Control] = []
	for control in [_choice_0, _choice_1, _choice_2, _reroll_button, _dismiss_button]:
		if control.is_visible_in_tree() and not (control is Button and control.disabled):
			targets.append(control)
	if not targets.is_empty():
		var index := targets.find(get_viewport().gui_get_focus_owner())
		targets[posmod(index + (-1 if backwards else 1), targets.size())].grab_focus()
	get_viewport().set_input_as_handled()


func _on_slot_command(op: String, ideology_id: int) -> void:
	_command(op, ideology_id)


func _on_card_activated(ideology_id: int) -> void:
	# Keyboard / gamepad accept: same intent as the primary action button.
	var location := int((_states.get(ideology_id, {}) as Dictionary).get("location", 0))
	if location == 0:
		_command("equip", ideology_id)
	elif location == 1:
		_command("unequip", ideology_id)


func _on_tab_changed(tab: int) -> void:
	_tab_school = "" if tab <= 0 else String(ArtScript.SCHOOL_ORDER[tab - 1])
	if _snapshot.is_empty():
		return
	_signature = ""
	_rebuild_board()


func _on_sort_selected(index: int) -> void:
	_sort_mode = index
	if _snapshot.is_empty():
		return
	_signature = ""
	_rebuild_board()


# --- commands -------------------------------------------------------------

func _open_offer() -> void:
	var generation := int(_snapshot.get("offer_generation", 0))
	if bool(_snapshot.get("offer_active", false)) and generation == _dismissed_generation:
		_dismissed_generation = -1
		_render_top()
		_rebuild_offer()
		return
	if _player_controller == null:
		return
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_IDEOLOGY_OFFER)
	if not bool(result.get("ok", false)):
		_show_result(result)


func _reroll_offer() -> void:
	if _player_controller == null:
		return
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_IDEOLOGY_REROLL, {
			"offer_generation": int(_snapshot.get("offer_generation", 0)),
		})
	if bool(result.get("ok", false)):
		_render_draw_waiting()
	else:
		_show_result(result)


func _dismiss_offer() -> void:
	_dismissed_generation = int(_snapshot.get("offer_generation", 0))
	if _player_controller != null and _player_controller.has_method("dismiss_ideology_offer"):
		_player_controller.dismiss_ideology_offer()
	_render_top()
	_rebuild_offer()
	_offer_button.grab_focus()


func _command(kind: String, ideology_id: int) -> void:
	if _player_controller == null or ideology_id < 0:
		return
	var command_id := {
		"equip": PlayerControllerScript.COMMAND_IDEOLOGY_EQUIP,
		"unequip": PlayerControllerScript.COMMAND_IDEOLOGY_UNEQUIP,
		"promote": PlayerControllerScript.COMMAND_IDEOLOGY_PROMOTE,
	}.get(kind, &"") as StringName
	var result: Dictionary = _player_controller.request_command(
		command_id, {"ideology_id": ideology_id})
	_show_result(result)


func _request_promotion(ideology_id: int) -> void:
	if _promotion_dialog == null:
		return
	_pending_promotion_id = ideology_id
	_promotion_dialog.dialog_text = "将「%s」晋升为民族精神？晋升不可逆。" \
		% _display_name(_metadata.get(ideology_id, {}), ideology_id)
	_promotion_dialog.popup_centered()


func _confirm_promotion() -> void:
	if _pending_promotion_id < 0:
		return
	var ideology_id := _pending_promotion_id
	_pending_promotion_id = -1
	_command("promote", ideology_id)


func _on_player_command_settled(id: StringName, result: Dictionary) -> void:
	if id not in [
		PlayerControllerScript.COMMAND_IDEOLOGY_OFFER,
		PlayerControllerScript.COMMAND_IDEOLOGY_CHOOSE,
		PlayerControllerScript.COMMAND_IDEOLOGY_REROLL,
		PlayerControllerScript.COMMAND_IDEOLOGY_EQUIP,
		PlayerControllerScript.COMMAND_IDEOLOGY_UNEQUIP,
		PlayerControllerScript.COMMAND_IDEOLOGY_PROMOTE,
	]:
		return
	if bool(result.get("ok", false)):
		_flash_hint("")
	else:
		var message := CountryViewModel.ideology_player_reason(String(
			result.get("reason", result.get("message", "理念命令被拒绝。"))))
		_flash_hint(message)
		_toast(message)


func _on_ideology_offer_ready(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	_draw_phase = "presenting"
	_snapshot = snapshot
	_presentation = CountryViewModel.present_ideology(_snapshot, _catalog)
	_index_states()
	_dismissed_generation = -1
	_hint_hold_until = 0
	_render_top()
	_rebuild_offer()


func _on_ideology_draw_state_changed(phase: String, detail: Dictionary) -> void:
	_draw_phase = phase
	var message := String(detail.get("message", ""))
	if not message.is_empty():
		_flash_hint(message)
		_toast(message)
	_render_top()
	_rebuild_offer()


func _show_result(result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		_flash_hint("明日生效")
	else:
		_flash_hint(CountryViewModel.ideology_player_reason(String(
			result.get("reason", result.get("message", "理念命令被拒绝。")))))
		if _compact:
			_toast(_hint.text)


func _flash_hint(text: String) -> void:
	if _hint == null:
		return
	_hint.text = text
	_hint.visible = not _compact and not text.is_empty()
	_hint_hold_until = Time.get_ticks_msec() + HINT_HOLD_MSEC


# --- offer stage ----------------------------------------------------------

func _choice(index: int) -> Control:
	return [_choice_0, _choice_1, _choice_2][index]


func _rebuild_offer() -> void:
	if _offer_anim_busy:
		return
	var active := bool(_snapshot.get("offer_active", false))
	var generation := int(_snapshot.get("offer_generation", 0))
	var waiting := _draw_waiting()
	var chosen := active and generation == _chosen_generation
	var dismissed := active and generation == _dismissed_generation and not waiting
	if (not active and not waiting) or chosen or dismissed:
		_set_stage_visible(false)
		_set_draw_stack(false)
		for index in 3:
			_choice(index).visible = false
		if not active:
			_chosen_generation = -1
		# The stage is closed: never leave the paper cover or a face-down card
		# armed for the next reveal.
		return
	_set_stage_visible(true)
	var ids: PackedInt32Array = _snapshot.get("offer_ids", PackedInt32Array())
	var fresh := active and generation > _revealed_generation and not waiting
	if waiting and not fresh:
		# Draw submitted; the one-day settlement has not published yet. Showing
		# three face-down frames here is what read as a placeholder image before
		# the reveal, so only the shuffled deck is on stage.
		_render_draw_waiting()
		return
	_set_draw_stack(false)
	_offer_title.text = "选择国策"
	for index in 3:
		var card := _choice(index)
		var show := index < ids.size()
		card.visible = show
		if show:
			var ideology_id := int(ids[index])
			var meta: Dictionary = _metadata.get(ideology_id, {})
			var view := CountryViewModel.present_ideology_card(meta, 0)
			card.call("set_card", {
				"ideology_id": ideology_id,
				"display_name": _display_name(meta, ideology_id),
				"school_id": String(meta.get("school_id", "")),
				"rarity": int(meta.get("rarity", 1)),
				"rarity_label": String(meta.get("rarity_label", "")),
				"effects": view.get("effect_lines", PackedStringArray()),
				"level": 0,
				"level_count": int(view.get("level_count", 3)),
				"level_label": String(view.get("level_label", "")),
				"tooltip": String(view.get("tooltip", "")),
				"detail_model": _detail_data(ideology_id, true),
			})
			_apply_offer_card_tilt(card, index, int(meta.get("rarity", 1)))
	var reroll_cost := String(_presentation.get("reroll_cost_text", ""))
	_reroll_button.text = "重抽 · %s" % reroll_cost
	_reroll_button.disabled = not bool(_presentation.get("can_reroll", false))
	_reroll_button.tooltip_text = "花费 %s 理念点重抽" % reroll_cost
	_dismiss_button.disabled = false
	if fresh:
		_revealed_generation = generation
		_play_reveal(ids.size())
	else:
		for index in 3:
			_choice(index).call("set_face_up", true)


func _render_draw_waiting() -> void:
	_offer_title.text = "正在抽取"
	_offer_hint.text = "正在整理候选国策…"
	for index in 3:
		var card := _choice(index)
		card.visible = false
		card.call("reset_motion")
	_reroll_button.disabled = true
	_dismiss_button.disabled = true
	_set_draw_stack(true)


func _apply_offer_card_tilt(card: Control, _index: int, _rarity: int) -> void:
	card.set("stage_rest_offset", Vector2.ZERO)
	card.set("stage_rest_rotation", 0.0)


func _set_draw_stack(show: bool) -> void:
	if _draw_stack == null:
		return
	# These are alternative views of one card-height area, never two VBox rows.
	_offer_cards.visible = not show
	_offer_actions.visible = not show
	if not show and _offer_hint != null:
		_offer_hint.text = "悬停查看详情 · 单击选定 · Esc 收起"
	if show:
		_draw_stack.set_card_size(_stage_card_size())
		if not _draw_stack.visible:
			_draw_stack.visible = true
			_draw_stack.play(not motion_reduced())
	else:
		_draw_stack.stop()
		_draw_stack.visible = false


## The offer tray is a modal layer over the workspace: a scrim plus the centred
## paper stage. Showing it fades in; hiding is instant so the closing beat of the
## choose animation is never covered by a lingering scrim.
func _set_stage_visible(show: bool) -> void:
	if _offer != null:
		_offer.visible = show
	if _offer_layer == null:
		return
	if not show:
		if _offer_layer.visible:
			_offer_layer.visible = false
			_offer_layer.modulate.a = 1.0
		return
	if _offer_layer.visible:
		return
	_offer_layer.visible = true
	if motion_reduced():
		_offer_layer.modulate.a = 1.0
		return
	_offer_layer.modulate.a = 0.0
	var tween := _offer_layer.create_tween()
	tween.tween_property(_offer_layer, "modulate:a", 1.0, UITokens.ANIM_FAST)


## Fully open the unroll mask and lift the torn paper. Used whenever the stage
## is shown without a reveal, so a previous cover can never linger.
func _play_reveal(count: int) -> void:
	if motion_reduced() or not is_visible_in_tree():
		for index in count:
			_choice(index).call("reset_motion")
			_choice(index).call("set_face_up", true)
		return
	_offer_anim_busy = true
	for index in count:
		var card := _choice(index)
		card.call("reset_motion")
		card.call("set_face_up", true)
		card.call("play_drop", index * 0.07, 16.0)
		if int(card.get("_rarity")) > 1:
			var sheen := create_tween()
			sheen.tween_interval(0.30 + index * 0.07)
			sheen.tween_callback(card.call.bind("play_gloss", 1))
	var tween := create_tween()
	tween.tween_interval(0.45 + maxf(0, count - 1) * 0.07)
	tween.tween_callback(_finish_offer_animation)


func _finish_offer_animation() -> void:
	_offer_anim_busy = false
	for index in 3:
		if _choice(index).visible:
			_choice(index).call("set_face_up", true)
	if is_visible_in_tree():
		_choice_0.grab_focus()
	_rebuild_offer()


func _on_choice_input(event: InputEvent, index: int) -> void:
	# Press moves keyboard/gamepad focus onto the card; the selection itself
	# arrives through `activated` on release.
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_choice(index).grab_focus()


func _on_choice_activated(_ideology_id: int, index: int) -> void:
	_choose_offer(index)


func _choose_offer(choice_index: int) -> void:
	if _player_controller == null or _offer_anim_busy:
		return
	var generation := int(_snapshot.get("offer_generation", 0))
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_IDEOLOGY_CHOOSE, {
			"offer_generation": generation,
			"choice_index": choice_index,
		})
	_show_result(result)
	if not bool(result.get("ok", false)):
		return
	_flash_hint("")
	_chosen_generation = generation
	_play_choose(choice_index)


func _play_choose(choice_index: int) -> void:
	if motion_reduced() or not is_visible_in_tree():
		_rebuild_offer()
		return
	_offer_anim_busy = true
	for index in 3:
		if index != choice_index and _choice(index).visible:
			_choice(index).call("fold_away", 0.18)
	_choice(choice_index).call("stamp_punch")
	var tween := create_tween()
	tween.tween_interval(0.32)
	tween.tween_property(_offer_layer, "modulate:a", 0.0, 0.16)
	tween.tween_callback(_finish_choose_animation)


func _finish_choose_animation() -> void:
	_offer_anim_busy = false
	for index in 3:
		_choice(index).call("reset_motion")
	_rebuild_offer()
	if is_visible_in_tree():
		_offer_button.grab_focus()


func _toast(text: String) -> void:
	if _fx == null or text.is_empty():
		return
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"PKPaperToast"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := ArtScript.label(text, 14, ArtScript.INK)
	panel.add_child(label)
	_fx.add_child(panel)
	panel.reset_size()
	panel.position = Vector2((_fx.size.x - panel.size.x) * 0.5, 84.0)
	if motion_reduced():
		get_tree().create_timer(2.4).timeout.connect(panel.queue_free)
		return
	panel.modulate.a = 0.0
	var tween := panel.create_tween()
	tween.tween_property(panel, "modulate:a", 1.0, 0.18)
	tween.parallel().tween_property(panel, "position:y", 72.0, 0.18)
	tween.tween_interval(2.2)
	tween.tween_property(panel, "modulate:a", 0.0, 0.3)
	tween.tween_callback(panel.queue_free)


func _open_ledger() -> void:
	if _ledger_popup == null:
		return
	for child in _ledger_popup.get_children():
		_ledger_popup.remove_child(child)
		child.queue_free()
	_ledger_popup.add_child(PointScrollScript.build_ledger(_snapshot))
	_ledger_popup.popup_centered(Vector2i(420, 320))


# --- text helpers ---------------------------------------------------------

func _support_summary(live: Dictionary, direction: int) -> String:
	var action: String = ["推行", "撤回", "晋升"][clampi(direction, 0, 2)]
	var rows: Array = live.get("support", [])
	if direction < 0 or direction >= rows.size():
		return "%s支持条件待更新" % action
	var support: Dictionary = rows[direction]
	if not bool(support.get("available", false)):
		return "%s支持条件待结算" % action
	var result := "已满足" if bool(support.get("allowed", false)) else "未满足"
	var line := "%s支持条件%s · 评分 %s / 门槛 %s" % [action, result,
		_q16_signed(int(support.get("support_q16", 0))),
		_q16_signed(int(support.get("threshold_q16", 0)))]
	if int(support.get("blocking_class", -1)) >= 0:
		line += "（关键阶层未达到最低支持要求）"
	return line


func _support_tooltip(live: Dictionary, direction: int) -> String:
	var lines := PackedStringArray([_support_summary(live, direction),
		"支持评分由各阶层的影响力与对此操作的态度加权得出。推行、撤回、晋升分别判断。"])
	var class_ids: PackedStringArray = _catalog.get("political_class_ids", PackedStringArray())
	var names := {"general": "一般阶层", "farmer": "农民阶层",
		"worker": "工人阶层", "technology": "学者阶层"}
	for row in live.get("classes", []) as Array:
		var info := row as Dictionary
		var index := int(info.get("class_index", -1))
		var contributions: Array = info.get("contributions", [])
		var contribution := int(contributions[direction]) if direction >= 0 and direction < contributions.size() else 0
		var id := String(class_ids[index]) if index >= 0 and index < class_ids.size() else ""
		lines.append("%s · 加权贡献 %+.2f" % [String(names.get(id, "其他阶层")), float(contribution) / Q16_ONE])
	return "\n".join(lines)


func _display_name(metadata: Dictionary, ideology_id: int) -> String:
	var display := String(metadata.get("display_name", ""))
	if not display.is_empty():
		return display
	var name_key := String(metadata.get("name_key", ""))
	if not name_key.is_empty() and not name_key.contains("."):
		return name_key
	var stable_id := String(metadata.get("id", ""))
	return stable_id if not stable_id.is_empty() else "理念 %d" % ideology_id


func _q16(value: int) -> String:
	return "%.2f" % (float(value) / Q16_ONE)


func _q16_signed(value: int) -> String:
	return "%+.2f" % (float(value) / Q16_ONE)


func _show_shell(reason: String, loading: bool) -> void:
	_signature = ""
	_explain_signature = ""
	_points_signature = ""
	_presentation = {}
	_snapshot = {}
	_offer_button.disabled = true
	_offer_button.text = "抽取"
	_hint.text = "载入中…" if loading and reason.is_empty() else (
		reason if not reason.is_empty() else "暂不可用")
	_hint.visible = true
	_set_stage_visible(false)
	_set_draw_stack(false)
	_point_scroll.call("set_points", 0, 65536, 0, false, true)
	_show_empty_state(true, {
		"empty_title": "载入中…" if loading else "暂不可用",
		"empty_detail": _hint.text,
	})


func _show_empty_state(visible_state: bool, presentation: Dictionary) -> void:
	if _empty == null:
		return
	_empty.visible = visible_state
	# The cabinet card and the collection panel compete for the same column.
	if _collection_drop != null:
		_collection_drop.visible = not visible_state
	if not visible_state:
		return
	_empty_icon.set_semantic(&"country.politics", UITokens.ACCENT)
	_empty_title.text = String(presentation.get("empty_title", "尚未形成国家理念"))
	_empty_detail.text = String(presentation.get("empty_detail",
		"积累理念点后抽取。"))
	if _empty_insights != null:
		_empty_insights.visible = false


# --- test-facing API --------------------------------------------------------

func hint_text() -> String:
	return _hint.text if _hint != null else ""


func offer_button_disabled() -> bool:
	return true if _offer_button == null else _offer_button.disabled


func empty_state_visible() -> bool:
	return false if _empty == null else _empty.visible


func slots_capacity() -> int:
	return int(_presentation.get("slots_capacity", 0))


func points_text() -> String:
	return String(_presentation.get("points_text", ""))


func offer_choice_summaries() -> PackedStringArray:
	var summaries := PackedStringArray()
	for index in 3:
		var card: Control = _choice(index) if _choice_0 != null else null
		if card == null or not card.visible or int(card.get("ideology_id")) < 0:
			continue
		var data: Dictionary = card.call("card_data")
		var effects := PackedStringArray(data.get("effects", PackedStringArray()))
		summaries.append("%s：%s" % [String(data.get("display_name", "")),
			"、".join(effects)])
	return summaries


func niche_count(kind: int) -> int:
	# Logical slot count, not rendered rows: empty slots collapse into one drop
	# row, so the child count would under-report the board.
	return int(_presentation.get("slots_capacity" if kind == 1 else "spirits_capacity", 0))


func collection_count() -> int:
	return 0 if _collection == null else _collection.get_child_count()


## Test hook: simulate a card drop onto a niche kind without a real drag.
func simulate_drop(ideology_id: int, from_location: int, kind: int) -> void:
	_on_niche_drop(ideology_id, from_location, kind)


# --- inner drawing helpers --------------------------------------------------

## A physical deck shares the candidate row's footprint while the worker settles.
class DrawStack:
	extends Control
	const BACK_COUNT := 4
	var _backs: Array[Control] = []
	var _card_size := Vector2.ZERO
	var _tween: Tween
	var _shuffling := false

	func _init() -> void:
		name = "WaitingDeck"
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		for index in BACK_COUNT:
			var back := DeckBack.new()
			back.name = "DeckBack%d" % index
			back.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(back)
			IdeologyArt.attach_paper_shadow(back, 0.23 if index == BACK_COUNT - 1 else 0.12)
			_backs.append(back)
		set_card_size(Vector2(208, 276))

	func set_card_size(card_size: Vector2) -> void:
		if _card_size.is_equal_approx(card_size):
			return
		var resume := _shuffling
		stop()
		_card_size = card_size
		custom_minimum_size = card_size
		_layout()
		if resume:
			play(true)

	func play(animate: bool) -> void:
		stop()
		if not animate:
			return
		_shuffling = true
		var top := _backs.back() as Control
		var rest := top.position
		var rest_rotation := top.rotation
		_tween = create_tween().set_loops()
		_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_property(top, "position", rest + Vector2(_card_size.x * 0.12, -8), 0.65)
		_tween.parallel().tween_property(top, "rotation", rest_rotation + 0.08, 0.65)
		_tween.tween_property(top, "position", rest, 0.65)
		_tween.parallel().tween_property(top, "rotation", rest_rotation, 0.65)

	func stop() -> void:
		_shuffling = false
		if _tween != null and _tween.is_valid():
			_tween.kill()
		_tween = null
		_layout()

	func is_shuffling() -> bool:
		return _shuffling

	func _layout() -> void:
		for index in _backs.size():
			var back := _backs[index]
			back.size = _card_size * 0.84
			back.pivot_offset = back.size * 0.5
			back.position = (_card_size - back.size) * 0.5 + Vector2(index * 2 - 3, -index * 2)
			back.rotation = deg_to_rad(-5.0 + index * 2.0)
			back.queue_redraw()


## Paper, inset, stamped linework and emblem remain separate material layers.
class DeckBack:
	extends Control
	func _draw() -> void:
		if size.x < 20:
			return
		IdeologyArt.paper_style(0).draw(get_canvas_item(), Rect2(Vector2.ZERO, size))
		var inset := maxf(8, size.x * 0.065)
		var face := Rect2(Vector2.ZERO, size).grow(-inset)
		IdeologyArt.paper_style(0, Color(0.27, 0.36, 0.29)).draw(get_canvas_item(), face)
		var line := Color(0.87, 0.72, 0.42, 0.68)
		draw_rect(face.grow(-6), line, false, 1.0)
		draw_rect(face.grow(-10), Color(line, 0.20), false, 1.0)
		var center := size * 0.5
		var radius := size.x * 0.23
		for side in [-1, 1]:
			var y: float = center.y + side * size.y * 0.29
			draw_line(Vector2(center.x - radius, y), Vector2(center.x + radius, y), line, 1, true)
			draw_circle(Vector2(center.x, y), 3, line)
		draw_circle(center + Vector2(0, 2), radius + 3, Color(0.05, 0.04, 0.02, 0.15))
		draw_circle(center, radius, Color(0.91, 0.83, 0.65))
		draw_arc(center, radius - 4, 0, TAU, 64, line.darkened(0.25), 1, true)
		var emblem := IconCatalog.texture_for_key(&"hud.country.ideology")
		if emblem != null:
			var extent := Vector2.ONE * radius * 1.45
			draw_texture_rect(emblem, Rect2(center - extent * 0.5, extent), false)


## Section chrome is drawn at the section boundary so the difference is legible
## before its rows enter the scroll viewport. Ordinary ideas get a clipped
## vermilion bookmark; spirits get a forest ribbon with a centred gold crest.
class SlotSectionChrome:
	extends Control
	var kind := 1

	func _draw() -> void:
		if size.x < 24.0 or size.y < 16.0:
			return
		if kind == 1:
			var spine := Rect2(0.0, 3.0, 7.0, size.y - 6.0)
			draw_rect(spine, Color(0.53, 0.15, 0.10, 0.84))
			draw_rect(Rect2(7.0, 5.0, size.x - 7.0, 1.0),
				Color(0.46, 0.29, 0.14, 0.34))
			draw_line(Vector2(12.0, size.y - 7.0),
				Vector2(size.x - 12.0, size.y - 7.0),
				Color(0.46, 0.29, 0.14, 0.20), 1.0)
			draw_colored_polygon(PackedVector2Array([
				Vector2(0.0, 3.0), Vector2(7.0, 3.0), Vector2(7.0, 9.0),
			]), Color(0.72, 0.52, 0.24, 0.64))
			return
		var inset := Rect2(2.0, 2.0, size.x - 4.0, size.y - 4.0)
		draw_rect(inset, Color(0.10, 0.18, 0.12, 0.72))
		draw_rect(inset.grow(-3.0), Color(0.79, 0.62, 0.30, 0.68),
			false, 1.0)
		draw_line(Vector2(18.0, inset.position.y + 7.0),
			Vector2(inset.end.x - 18.0, inset.position.y + 7.0),
			Color(0.89, 0.72, 0.39, 0.42), 1.0)
		draw_line(Vector2(18.0, inset.end.y - 7.0),
			Vector2(inset.end.x - 18.0, inset.end.y - 7.0),
			Color(0.89, 0.72, 0.39, 0.26), 1.0)
		var cx := size.x * 0.5
		draw_line(Vector2(cx - 12.0, inset.position.y + 7.0),
			Vector2(cx + 12.0, inset.position.y + 7.0),
			Color(0.86, 0.68, 0.35, 0.72), 1.0)


class ResonanceEmblem:
	extends VBoxContainer
	var school_id := ""
	var _icon: TextureRect
	var _count: Label
	var _pips: HBoxContainer

	func configure(school: String) -> void:
		school_id = school
		alignment = BoxContainer.ALIGNMENT_CENTER
		add_theme_constant_override("separation", 1)
		custom_minimum_size = Vector2(52, 0)
		_icon = TextureRect.new()
		_icon.texture = IdeologyArt.emblem_for(school)
		_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon.custom_minimum_size = Vector2(22, 22)
		_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_icon)
		_count = IdeologyArt.label(IdeologyArt.school_name(school), 10,
			IdeologyArt.school_color(school))
		add_child(_count)
		_pips = HBoxContainer.new()
		_pips.visible = false
		_pips.alignment = BoxContainer.ALIGNMENT_CENTER
		_pips.add_theme_constant_override("separation", 4)
		_pips.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_pips)

	func set_compact(compact: bool) -> void:
		_icon.custom_minimum_size = Vector2(20, 20) if compact else Vector2(22, 22)
		custom_minimum_size.x = 40 if compact else 52
		_count.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		_pips.visible = false

	func set_state(count: int, preview_count: int, tiers: Array[Dictionary]) -> void:
		var school_label := IdeologyArt.school_name(school_id)
		_count.text = "%s %d" % [school_label, count] if preview_count == count \
			else "%s %d→%d" % [school_label, count, preview_count]
		_count.add_theme_color_override("font_color", IdeologyArt.VERMILION
			if preview_count != count else IdeologyArt.school_color(school_id))
		for child in _pips.get_children():
			_pips.remove_child(child)
			child.queue_free()
		var tips := PackedStringArray()
		var any_active := false
		for tier in tiers:
			var pip := ColorRect.new()
			pip.custom_minimum_size = Vector2(9, 9)
			pip.pivot_offset = Vector2(4.5, 4.5)
			# Diamonds read as inked seals; flat squares read as debug swatches.
			pip.rotation = PI * 0.25
			pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var active := bool(tier.get("active", false))
			var reach := preview_count >= int(tier.get("min_count", 99)) and not active
			any_active = any_active or active
			pip.color = IdeologyArt.VERMILION if active else (
				Color(0.86, 0.67, 0.30, 0.9) if reach else Color(0.45, 0.36, 0.26, 0.30))
			_pips.add_child(pip)
			tips.append("%s%s" % ["● " if active else "○ ", String(tier.get("tooltip", ""))])
		tooltip_text = "\n".join(tips)
		_icon.modulate = Color.WHITE if any_active or count > 0 else Color(1, 1, 1, 0.45)

	func celebrate() -> void:
		pivot_offset = size * 0.5
		var tween := create_tween()
		tween.tween_property(self, "scale", Vector2(1.05, 1.05), 0.1)
		tween.tween_property(self, "scale", Vector2.ONE, 0.3) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## A collection entry is a physical card in the archive, not a text row. The
## authored frame carries rarity; the face reserves its space for school,
## current effect, a brass level seal and a full-width understanding track.
class CollectionEntry:
	extends Control
	var _name: Label
	var _effects: Label
	var _emblem: TextureRect
	var _footer: HBoxContainer
	var _level_meter: Control
	var _payload := {}
	var _draggable := true
	var _surface: CardSurface
	var _face: MarginContainer
	var _column: VBoxContainer
	var _band: HBoxContainer
	var _rarity := 1
	var _hover_tween: Tween
	var _status: Label
	var _detail_model: Dictionary = {}
	var _action_well: MarginContainer
	var _head: HBoxContainer

	func setup(data: Dictionary) -> void:
		_detail_model = data.get("detail_model", {})
		_payload = data.get("payload", {}).duplicate()
		_payload["activated"] = data.get("activated", Callable())
		_draggable = bool(data.get("draggable", true))
		var compact := bool(data.get("compact", false))
		_rarity = clampi(int(data.get("rarity", 1)), 1, 3)
		focus_mode = Control.FOCUS_ALL
		mouse_filter = Control.MOUSE_FILTER_PASS
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		clip_contents = false
		_surface = CardSurface.new()
		_surface.rarity = _rarity
		_surface.accent = ArtScript.school_color(String(data.get("school_id", "")))
		_surface.compact = compact
		_surface.rarity_glow = ArtScript.rarity_glow(_rarity)
		_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(_surface)
		_face = MarginContainer.new()
		_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_face.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		# 纸面只保留统一内边距；文字、理解度和操作由同一列容器顺排。
		for side in ["left", "top", "right", "bottom"]:
			_face.add_theme_constant_override("margin_%s" % side, 18)
		add_child(_face)
		_column = VBoxContainer.new()
		_column.add_theme_constant_override("separation", 10)
		_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_face.add_child(_column)
		_head = HBoxContainer.new()
		_head.add_theme_constant_override("separation", 10)
		_head.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_column.add_child(_head)
		_emblem = TextureRect.new()
		_emblem.texture = ArtScript.emblem_for(String(data.get("school_id", "")))
		_emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_emblem.custom_minimum_size = Vector2(36, 36)
		_emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_head.add_child(_emblem)
		var identity := VBoxContainer.new()
		identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		identity.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_head.add_child(identity)
		_name = ArtScript.label(String(data.get("name", "")), 22,
			ArtScript.INK, HORIZONTAL_ALIGNMENT_LEFT)
		_name.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
		_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		identity.add_child(_name)
		_status = ArtScript.label("", 15, ArtScript.VERMILION, HORIZONTAL_ALIGNMENT_LEFT)
		identity.add_child(_status)
		refresh_status(bool(data.get("pending", false)), int(data.get("location", 0)))
		var edition := ArtScript.label(String(ArtScript.RARITY_NAMES[_rarity]),
			15, ArtScript.rarity_accent(_rarity), HORIZONTAL_ALIGNMENT_RIGHT)
		edition.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_head.add_child(edition)
		_effects = ArtScript.label("", 17, ArtScript.INK, HORIZONTAL_ALIGNMENT_LEFT)
		_effects.text = "\n".join(data.get("effects", PackedStringArray()))
		_effects.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_effects.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_column.add_child(_effects)
		_band = HBoxContainer.new()
		_band.name = "LevelSealBand"
		_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_band.add_theme_constant_override("separation", 8)
		_column.add_child(_band)
		var meter_data: Dictionary = data.get("level_progress", {})
		meter_data["accent"] = ArtScript.GOLD_LEAF.lerp(
			ArtScript.school_color(String(data.get("school_id", ""))), 0.12)
		_level_meter = LevelMeterScript.new()
		_level_meter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_level_meter.configure(meter_data, compact)
		_band.add_child(_level_meter)
		_action_well = MarginContainer.new()
		_action_well.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_action_well.add_theme_constant_override("margin_top", 4)
		_action_well.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_column.add_child(_action_well)
		_footer = HBoxContainer.new()
		_footer.alignment = BoxContainer.ALIGNMENT_END
		_footer.add_theme_constant_override("separation", 8)
		_footer.size_flags_vertical = Control.SIZE_SHRINK_END
		_footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_footer.visible = false
		_action_well.add_child(_footer)
		_column.minimum_size_changed.connect(_queue_layout)

		var tip_lines := PackedStringArray([String(data.get("name", ""))])
		var detail := String(data.get("detail", "")).strip_edges()
		if not detail.is_empty() and not detail.contains("."):
			tip_lines.append(detail)
		var effect_values: PackedStringArray = data.get("effects", PackedStringArray())
		for effect in effect_values:
			if not String(effect).strip_edges().is_empty():
				tip_lines.append("· %s" % String(effect))
		tooltip_text = String(data.get("tooltip", "\n".join(tip_lines)))
		gui_input.connect(_on_input)
		mouse_entered.connect(_set_hover.bind(true))
		mouse_exited.connect(_set_hover.bind(false))
		focus_entered.connect(_set_hover.bind(true))
		focus_exited.connect(_set_hover.bind(false))
		_apply_scaled_layout()

	func footer() -> HBoxContainer:
		return _footer

	func refresh_status(pending: bool, location: int) -> void:
		_status.text = "待生效" if pending else "推行中" if location == 1 else "民族精神" if location == 2 else ""
		_status.visible = not _status.text.is_empty()

	func level_meter() -> Control:
		return _level_meter

	func refresh_layout() -> void:
		_apply_scaled_layout()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			_apply_scaled_layout()

	func _queue_layout() -> void:
		call_deferred("_apply_scaled_layout")

	func _apply_scaled_layout() -> void:
		if _face == null or _column == null or size.x < 1.0:
			return
		# 正文完整换行后决定卡高；操作始终位于理解度下方。
		var required := ceilf(_column.get_combined_minimum_size().y + 36.0)
		custom_minimum_size.y = maxf(208.0, required)

	func _make_custom_tooltip(for_text: String) -> Object:
		return ArtScript.detail_tooltip(for_text, _detail_model)

	func set_detail_model(data: Dictionary) -> void:
		_detail_model = data

	func frame_path() -> String:
		return ArtScript.PAPER_SHEET

	func play_deal_in(delay := 0.0) -> void:
		if not is_inside_tree() or UIAnimation.reduced_motion():
			return
		pivot_offset = size * 0.5
		scale = Vector2(0.94, 0.94)
		modulate.a = 0.0
		var tween := create_tween().set_parallel(true)
		tween.tween_interval(delay)
		tween.tween_property(self, "modulate:a", 1.0, 0.24) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.tween_property(self, "scale", Vector2.ONE, 0.30) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	func _set_hover(on: bool) -> void:
		if _hover_tween != null and _hover_tween.is_valid():
			_hover_tween.kill()
		_hover_tween = create_tween().set_parallel(true)
		_hover_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_hover_tween.tween_property(_surface, "hover_lift", 1.0 if on else 0.0, 0.15)
		_hover_tween.tween_property(self, "self_modulate",
			Color(1.035, 1.025, 0.985) if on else Color.WHITE, 0.15)

	func _on_input(event: InputEvent) -> void:
		if ArtScript.scroll_detail(event):
			accept_event()
			return
		if event.is_action_pressed(&"ui_accept"):
			_payload.get("activated", Callable()).call()
			accept_event()
		elif event is InputEventMouseButton:
			var mouse := event as InputEventMouseButton
			if mouse.button_index == MOUSE_BUTTON_LEFT \
					and not mouse.pressed and mouse.double_click:
				_payload.get("activated", Callable()).call()
				accept_event()

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if not _draggable:
			return null
		var holder := Control.new()
		var preview := NinePatchRect.new()
		preview.texture = ArtScript.collection_frame_for(_rarity)
		preview.size = Vector2(220, 148)
		preview.position = -preview.size * 0.5
		preview.patch_margin_left = 0
		preview.patch_margin_right = 0
		preview.patch_margin_top = 0
		preview.patch_margin_bottom = 0
		preview.rotation = -0.035
		holder.add_child(preview)
		var label := ArtScript.label(_name.text, 16, ArtScript.INK)
		label.add_theme_font_override("font",
			preload("res://assets/fonts/annual_pencil/Muyao-Softbrush-2.ttf"))
		label.position = -preview.size * 0.5 + Vector2(18, 18)
		label.size = Vector2(preview.size.x - 24, 24)
		holder.add_child(label)
		set_drag_preview(holder)
		return _payload.duplicate()


## Independent paper, edition edging and diffuse shadow layers.
class CardSurface:
	extends Control
	var rarity := 1
	var accent := Color(0.3, 0.22, 0.14)
	var rarity_glow := Color(0.88, 0.79, 0.59, 0.20)
	var compact := false
	var hover_lift := 0.0:
		set(value):
			hover_lift = value
			queue_redraw()

	func _init() -> void:
		ArtScript.attach_paper_shadow(self, 0.16)

	func _draw() -> void:
		if size.x < 20.0 or size.y < 20.0:
			return
		var rect := Rect2(Vector2.ZERO, size)
		draw_style_box(ArtScript.paper_style(0.0, ArtScript.paper_tint(rarity)), rect)
		if rarity >= 2:
			draw_style_box(ArtScript.edition_style(rarity), rect)
		# A school-coloured paper tab and ink rule are independent layers.
		draw_style_box(ArtScript.paper_style(0.0, accent.lightened(0.12)),
			Rect2(0, 16, 6, 40))
		if hover_lift > 0.01:
			draw_rect(rect.grow(-3), Color(accent, 0.35 * hover_lift), false, 1.0)
