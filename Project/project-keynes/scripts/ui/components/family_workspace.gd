extends Control
class_name FamilyWorkspace

const DossierRefresh = preload("res://scripts/ui/components/family_dossier_refresh.gd")

const DossierPages = preload("res://scripts/ui/components/family_dossier_pages.gd")

const OverviewPage = preload("res://scripts/ui/components/family_overview_page.gd")

const TouchUI = preload("res://scripts/ui/touch_ui.gd")

const FamilyVBoxScene := preload("res://scenes/ui/family/family_vbox.tscn")
const FamilyHBoxScene := preload("res://scenes/ui/family/family_hbox.tscn")
const FamilyGridScene := preload("res://scenes/ui/family/family_grid.tscn")
const FamilyCardScene := preload("res://scenes/ui/family/family_card.tscn")
const FamilyLabelScene := preload("res://scenes/ui/family/family_label.tscn")
const FamilyButtonScene := preload("res://scenes/ui/family/family_button.tscn")
const FamilyTextureScene := preload("res://scenes/ui/family/family_texture_rect.tscn")
const FamilyProgressScene := preload("res://scenes/ui/family/family_progress_bar.tscn")
const FamilyControlScene := preload("res://scenes/ui/family/family_control.tscn")
const IconBadgeScene := preload("res://scenes/ui/icon_badge.tscn")
const FactGridScene := preload("res://scenes/ui/inspector_fact_grid.tscn")
const MeterListScene := preload("res://scenes/ui/inspector_meter_list.tscn")

signal closed()
signal colonization_requested(family_handle: int, source_cell: int)

const PAGE_ORDER: Array[String] = [
	"overview", "traits", "preferences", "effects", "people", "branches"]
const PAGE_META := {
	"overview": {
		"title": "概览",
		"icon": "family.workspace.overview",
		"nav_icon": &"summary.overview",
		"question": "",
	},
	"traits": {
		"title": "家族特性",
		"icon": "family.workspace.traits",
		"nav_icon": &"family.house",
		"question": "",
	},
	"preferences": {
		"title": "行为偏好",
		"icon": "family.workspace.preferences",
		"nav_icon": &"ecology.growth",
		"question": "",
	},
	"effects": {
		"title": "家族效果",
		"icon": "family.workspace.effects",
		"nav_icon": &"technology.milestone",
		"question": "",
	},
	"people": {
		"title": "主要人物",
		"icon": "family.workspace.people",
		"nav_icon": &"population.profession.owner",
		"question": "",
	},
	"branches": {
		"title": "领地与分支",
		"icon": "family.workspace.branches",
		"nav_icon": &"metric.territory",
		"question": "",
	},
}
const NAV_NAMES := {
	"overview": "NavOverview", "traits": "NavTraits",
	"preferences": "NavPreferences", "effects": "NavEffects",
	"people": "NavPeople", "branches": "NavBranches",
}
const PAGE_FADE_SECONDS := 0.12
const OPEN_SECONDS := 0.18
const CLOSE_SECONDS := 0.14
const RAIL_WIDTH := 184.0
const COMPACT_WIDTH := 720.0

var _model: Dictionary = {}
var _current_page := "overview"
var _family_handle := 0
var _page_cache: Dictionary = {}
var _page_signatures: Dictionary = {}
var _scroll_by_page: Dictionary = {}
var _nav_buttons: Dictionary = {}
var _nav_labels: Dictionary = {}
var _nav_icons: Dictionary = {}
var _mobile_buttons: Dictionary = {}
var _kpi_cards: Array[DossierKpiCard] = []
var _kpi_signatures: Dictionary = {}
var _player_controller = null
var _closing := false
var _close_generation := 0

@onready var _nav_rail_surface: PanelContainer = get_node_or_null("%NavRailSurface") as PanelContainer
@onready var _page_surface: PanelContainer = get_node_or_null("%PageSurface") as PanelContainer
@onready var _hinges: Control = get_node_or_null("%Hinges") as Control
@onready var _nav_column: VBoxContainer = %NavColumn
@onready var _safe_margin: MarginContainer = $SafeMargin
@onready var _mobile_nav: ScrollContainer = %MobileNav
@onready var _mobile_buttons_host: HBoxContainer = %Buttons
@onready var _crest: TextureRect = %Crest
@onready var _title: Label = %Title
@onready var _subtitle: Label = %Subtitle
@onready var _prestige_value: Label = %PrestigeValue
@onready var _prestige_caption: Label = %PrestigeCaption
@onready var _prestige_plate: TextureRect = %PrestigePlate
@onready var _chapter_nav: DossierChapterNav = get_node_or_null("%ChapterNav") as DossierChapterNav
@onready var _summary_band: PanelContainer = get_node_or_null("%SummaryBand") as PanelContainer
@onready var _kpi_row: HBoxContainer = get_node_or_null("%KpiRow") as HBoxContainer
@onready var _page_title: Label = %PageTitle
@onready var _page_icon: TextureRect = %PageIcon
@onready var _page_scroll: ScrollContainer = %PageScroll
@onready var _page_host: VBoxContainer = %PageHost
@onready var _close_button: Button = %CloseButton


func _ready() -> void:
	_crest.texture = IconCatalog.texture_for_key(&"family.workspace.crest")
	_prestige_plate.texture = IconCatalog.texture_for_key(&"family.workspace.prestige")
	for page_id in PAGE_ORDER:
		var button := get_node_or_null("%" + String(NAV_NAMES[page_id])) as Button
		if button == null:
			continue
		_setup_desktop_nav_button(button, page_id)
		button.pressed.connect(_select_page.bind(page_id, true))
		_nav_buttons[page_id] = button
		var mobile := FamilyButtonScene.instantiate() as Button
		mobile.name = "Mobile%s" % page_id.capitalize()
		mobile.custom_minimum_size = Vector2(96.0, 38.0)
		mobile.toggle_mode = true
		mobile.focus_mode = Control.FOCUS_ALL
		mobile.text = String(PAGE_META[page_id].title)
		mobile.icon = IconCatalog.texture_for_key(StringName(PAGE_META[page_id].icon))
		mobile.add_theme_constant_override("icon_max_width", 20)
		mobile.theme_type_variation = &"PKChapterTab"
		mobile.pressed.connect(_select_page.bind(page_id, true))
		_mobile_buttons_host.add_child(mobile)
		_mobile_buttons[page_id] = mobile
	if _chapter_nav != null:
		var chapters: Array = []
		for page_id in PAGE_ORDER:
			var meta: Dictionary = PAGE_META[page_id]
			chapters.append({
				"id": page_id,
				"label": String(meta.title),
				"icon": meta.get("nav_icon", &"summary.overview"),
				"question": String(meta.get("question", "")),
			})
		_chapter_nav.set_chapters(chapters, _current_page)
		_chapter_nav.chapter_selected.connect(func(ch_id: String) -> void:
			_select_page(ch_id, true))
	_kpi_cards.clear()
	if _kpi_row != null:
		for child in _kpi_row.get_children():
			if child is DossierKpiCard:
				(child as Control).custom_minimum_size = Vector2(72.0, DossierKpiCard.HEIGHT)
				_kpi_cards.append(child as DossierKpiCard)
		if not _kpi_cards.is_empty():
			_kpi_cards[_kpi_cards.size() - 1].show_divider = false
	IconButton.apply(_close_button, &"action.close", IconButton.SMALL, "关闭")
	_close_button.focus_mode = Control.FOCUS_ALL
	_close_button.pressed.connect(request_close)
	resized.connect(_apply_responsive_layout)
	_apply_responsive_layout()
	_update_nav_state()


func _setup_desktop_nav_button(button: Button, page_id: String) -> void:
	button.text = ""
	button.icon = null
	button.clip_contents = false
	button.focus_mode = Control.FOCUS_ALL
	button.theme_type_variation = &"PKCountryNavButton"
	button.tooltip_text = String(PAGE_META[page_id].get("question", PAGE_META[page_id].title))
	var row := FamilyHBoxScene.instantiate() as HBoxContainer
	row.name = "Visual"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(row)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 24.0
	row.offset_top = 4.0
	row.offset_right = -14.0
	row.offset_bottom = -4.0
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 8)
	var icon := FamilyTextureScene.instantiate() as TextureRect
	icon.name = "Icon"
	icon.custom_minimum_size = Vector2(22.0, 22.0)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.texture = IconCatalog.texture_for_key(StringName(PAGE_META[page_id].icon))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)
	_nav_icons[page_id] = icon
	var label := FamilyLabelScene.instantiate() as Label
	label.text = String(PAGE_META[page_id].title)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.theme_type_variation = &"PKCountryRailMuted"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label)
	_nav_labels[page_id] = label
	UIAnimation.bind_hover_glow(button, row)


func set_player_controller(controller) -> void:
	_player_controller = controller


func show_family(model: Dictionary, animate: bool = true) -> void:
	var continuing := visible and not _closing
	_close_generation += 1
	_closing = false
	if not continuing:
		_current_page = "overview"
		_scroll_by_page.clear()
		_page_scroll.scroll_vertical = 0
	set_model(model)
	if not continuing:
		_select_page(_current_page, false)
	if animate and not continuing:
		UIAnimation.fade_slide_in(self, Vector2(36.0, 0.0), OPEN_SECONDS)
	else:
		visible = true
	if not continuing:
		call_deferred("_focus_current_navigation")


func set_model(model: Dictionary) -> void:
	if model.is_empty():
		return
	var next_handle := int(model.get("actions", {}).get("family_handle", 0))
	var family_changed := _family_handle != next_handle
	if family_changed:
		_clear_page_cache()
		_scroll_by_page.clear()
		_kpi_signatures.clear()
		_page_scroll.scroll_vertical = 0
		_family_handle = next_handle
	_model = model.duplicate(true)
	_update_header()
	_update_summary(not family_changed)
	_ensure_page(_current_page)
	_refresh_page(_current_page)
	_update_nav_state()
	_apply_responsive_layout()
	if family_changed:
		call_deferred("_restore_page_scroll", _current_page)


func request_close() -> void:
	if not visible or _closing:
		return
	_closing = true
	_close_generation += 1
	var generation := _close_generation
	UIAnimation.fade_slide_out(self, Vector2(32.0, 0.0), CLOSE_SECONDS)
	get_tree().create_timer(CLOSE_SECONDS).timeout.connect(func() -> void:
		if generation != _close_generation:
			return
		_closing = false
		closed.emit())


func hide_immediately() -> void:
	_close_generation += 1
	_closing = false
	visible = false
	modulate.a = 1.0


func current_page() -> String:
	return _current_page


func select_page(page_id: String, animate: bool = true) -> void:
	_select_page(page_id, animate)


func cached_page_count() -> int:
	return _page_cache.size()


func content_node_count() -> int:
	return _count_nodes(_page_host)


func compact_navigation() -> bool:
	return _mobile_nav.visible


func _select_page(page_id: String, animate: bool = true) -> void:
	if not PAGE_META.has(page_id):
		return
	if _page_scroll != null:
		_scroll_by_page[_current_page] = _page_scroll.scroll_vertical
	_current_page = page_id
	_ensure_page(page_id)
	for cached_id in _page_cache:
		(_page_cache[cached_id] as Control).visible = String(cached_id) == page_id
	_refresh_page(page_id)
	_update_nav_state()
	_page_title.text = String(PAGE_META[page_id].title)
	_page_icon.texture = IconCatalog.texture_for_key(StringName(PAGE_META[page_id].icon))
	call_deferred("_restore_page_scroll", page_id)
	_apply_responsive_layout()
	if animate:
		var active_page := _page_cache[page_id] as Control
		_replay_page_charts(active_page)
		UIAnimation.crossfade(active_page, PAGE_FADE_SECONDS)
		UIAnimation.stagger_children_in(active_page, 0.024, 8, PAGE_FADE_SECONDS)


func _replay_page_charts(root: Node) -> void:
	if root == null:
		return
	if root is DossierChart:
		(root as DossierChart).replay_growth()
	for child in root.get_children():
		_replay_page_charts(child)


func _ensure_page(page_id: String) -> void:
	var rows := _page_rows(page_id)
	var signature := _shape_signature(rows)
	if _page_cache.has(page_id) and String(_page_signatures.get(page_id, "")) == signature:
		return
	if _page_cache.has(page_id):
		var old := _page_cache[page_id] as Control
		_page_host.remove_child(old)
		old.queue_free()
	var page := FamilyVBoxScene.instantiate() as VBoxContainer
	page.name = "Page%s" % page_id.capitalize()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.clip_contents = true
	page.add_theme_constant_override("separation", 14)
	_page_host.add_child(page)
	_page_cache[page_id] = page
	_page_signatures[page_id] = signature
	_build_page(page_id, page, rows)
	var bottom_spacer := FamilyControlScene.instantiate() as Control
	bottom_spacer.name = "BottomSafeSpacer"
	bottom_spacer.custom_minimum_size.y = 16.0
	page.add_child(bottom_spacer)
	for cached_id in _page_cache:
		(_page_cache[cached_id] as Control).visible = String(cached_id) == _current_page


func _build_page(page_id: String, page: VBoxContainer, rows: Array) -> void:
	match page_id:
		"overview":
			_build_overview_page(page)
		"traits":
			_build_trait_page(page, rows)
		"preferences":
			_build_preference_page(page, rows)
		"effects":
			_build_effect_page(page, rows)
		"people":
			_build_people_page(page, rows)
		"branches":
			_build_branch_page(page, rows)


# ── 总览页（对齐 EconomyDossier 总览与 CohortDossier 账本分栏风格） ──────────

func _build_overview_page(page: VBoxContainer) -> void:
	OverviewPage._build_overview_page(self, page)


func _add_overview_branches_card(host: Control, branches: Array) -> void:
	OverviewPage._add_overview_branches_card(self, host, branches)


func _refresh_overview_rings(ring_grid: Control, branches: Array) -> void:
	OverviewPage._refresh_overview_rings(self, ring_grid, branches)


func _build_overview_Branch_ring_specs(branches: Array) -> Array:
	return OverviewPage._build_overview_Branch_ring_specs(self, branches)


func _build_overview_branch_meters(branches: Array) -> Array:
	return OverviewPage._build_overview_branch_meters(self, branches)


func _overview_branch_meta_text(branches: Array) -> String:
	return OverviewPage._overview_branch_meta_text(self, branches)


func _add_overview_preferences_card(host: Control, items: Array) -> void:
	OverviewPage._add_overview_preferences_card(self, host, items)


func _build_preference_bar_rows(items: Array) -> Array:
	return OverviewPage._build_preference_bar_rows(self, items)


func _preference_icon_key(item: Dictionary) -> StringName:
	return OverviewPage._preference_icon_key(self, item)


func _add_overview_list_card(host: Control, page_id: String, title_text: String,
		items: Array, two_columns: bool = false) -> void:
	OverviewPage._add_overview_list_card(self, host, page_id, title_text, items, two_columns)


func _add_overview_list_item(host: Control, page_id: String,
		item: Dictionary, item_index: int) -> void:
	OverviewPage._add_overview_list_item(self, host, page_id, item, item_index)


func _overview_item_value_text(page_id: String, item: Dictionary) -> String:
	return OverviewPage._overview_item_value_text(self, page_id, item)


func _overview_item_detail_text(page_id: String, item: Dictionary) -> String:
	return OverviewPage._overview_item_detail_text(self, page_id, item)


func _append_trait_badges(host: HBoxContainer, item: Dictionary) -> void:
	OverviewPage._append_trait_badges(self, host, item)


func _add_overview_people_card(host: Control, items: Array) -> void:
	OverviewPage._add_overview_people_card(self, host, items)


func _people_ledger_columns() -> Array:
	return OverviewPage._people_ledger_columns(self)


func _people_ledger_rows(items: Array) -> Array:
	return OverviewPage._people_ledger_rows(self, items)


func _overview_people_columns(person_count: int, available_width: float) -> int:
	return OverviewPage._overview_people_columns(self, person_count, available_width)


func _person_overview_metrics_text(person: Dictionary) -> String:
	return OverviewPage._person_overview_metrics_text(self, person)


func _add_overview_heading(host: VBoxContainer, page_id: String,
		title_text: String) -> void:
	OverviewPage._add_overview_heading(self, host, page_id, title_text)


# ── 五个专项子页（对齐 Dossier 账本规范） ─────────────────────────────────

func _build_trait_page(page: VBoxContainer, rows: Array) -> void:
	DossierPages._build_trait_page(self, page, rows)


func _build_preference_page(page: VBoxContainer, rows: Array) -> void:
	DossierPages._build_preference_page(self, page, rows)


func _preference_meter_dict(row: Dictionary) -> Dictionary:
	return DossierPages._preference_meter_dict(self, row)


func _build_effect_page(page: VBoxContainer, rows: Array) -> void:
	DossierPages._build_effect_page(self, page, rows)


func _build_people_page(page: VBoxContainer, rows: Array) -> void:
	DossierPages._build_people_page(self, page, rows)


func _person_fact_cells(row: Dictionary) -> Array:
	return DossierPages._person_fact_cells(self, row)


func _update_person_cashflow_bar(bar: DossierDivergingBar, row: Dictionary) -> void:
	DossierPages._update_person_cashflow_bar(self, bar, row)


func _build_branch_page(page: VBoxContainer, rows: Array) -> void:
	DossierPages._build_branch_page(self, page, rows)


func _branch_meter_dicts(row: Dictionary) -> Array:
	return DossierPages._branch_meter_dicts(self, row)


# ── 实时刷新（保持节点树恒定与滚动位置不变） ────────────────────────────

func _refresh_page(page_id: String) -> void:
	DossierRefresh._refresh_page(self, page_id)


func _apply_card_live(page_id: String, card: PanelContainer, row_value: Variant) -> void:
	DossierRefresh._apply_card_live(self, page_id, card, row_value)


func _refresh_overview_page(page: Control) -> void:
	DossierRefresh._refresh_overview_page(self, page)


func _update_header() -> void:
	DossierRefresh._update_header(self)


func _update_summary(live_patch: bool = false) -> void:
	DossierRefresh._update_summary(self, live_patch)


func _update_nav_state() -> void:
	DossierRefresh._update_nav_state(self)


# ── 响应式布局（对齐 CountryPanel 书脊 + 合页 + 9-slice 书页结构） ─────────

func _apply_responsive_layout() -> void:
	if _nav_column == null or _safe_margin == null:
		return
	# 触摸档也走紧凑版：手机的**逻辑宽度有 1942**，纯宽度断点会把竖排书脊导航留在
	# 屏幕上——那一列按钮只有 19dp 高，而且挤压正文。手机改用横向滚动页签条。
	var compact := size.x < COMPACT_WIDTH or TouchUI.is_short_viewport()
	var focus_owner := get_viewport().gui_get_focus_owner()
	var restore_navigation := compact != _mobile_nav.visible and (
		_nav_buttons.values().has(focus_owner) or _mobile_buttons.values().has(focus_owner))
	var rail_width := RAIL_WIDTH
	var left_pad := 18.0
	var right_pad := 28.0 if not compact else 20.0
	var top_pad := 20.0 if not compact else 14.0
	var bottom_pad := 22.0 if not compact else 16.0
	var main_sep := 28.0 if not compact else 8.0
	var nav_col_width := rail_width - left_pad

	if _nav_rail_surface != null:
		_nav_rail_surface.visible = not compact
		_nav_rail_surface.position = Vector2(8.0, 8.0)
		_nav_rail_surface.size = Vector2(rail_width - 8.0, maxf(size.y - 16.0, 0.0))
	if _page_surface != null:
		var page_x := 8.0 if compact else rail_width
		_page_surface.position = Vector2(page_x, 8.0)
		_page_surface.size = Vector2(maxf(200.0, size.x - page_x - 8.0), maxf(size.y - 16.0, 0.0))
	_place_hinges(rail_width, compact)

	_safe_margin.add_theme_constant_override("margin_left", roundi(left_pad))
	_safe_margin.add_theme_constant_override("margin_top", roundi(top_pad))
	_safe_margin.add_theme_constant_override("margin_right", roundi(right_pad))
	_safe_margin.add_theme_constant_override("margin_bottom", roundi(bottom_pad))
	_nav_column.custom_minimum_size.x = nav_col_width
	_nav_column.visible = not compact
	_mobile_nav.visible = compact
	if restore_navigation:
		call_deferred("_focus_current_navigation")
	if _chapter_nav != null:
		_chapter_nav.visible = false
	var main := $SafeMargin/Main as HBoxContainer
	main.add_theme_constant_override("separation", roundi(main_sep))

	var content_width := maxf(280.0, size.x - left_pad - right_pad \
		- (0.0 if compact else nav_col_width + main_sep))
	var dense_kpi := size.y > 1.0 and size.y < 520.0
	for card in _kpi_cards:
		card.dense = dense_kpi

	var overview := _page_cache.get("overview") as Control
	if overview != null:
		var top_grid := overview.find_child("OverviewTopGrid", true, false) as GridContainer
		if top_grid != null:
			top_grid.columns = 1 if compact or content_width < 560.0 else 2
		var mid_grid := overview.find_child("OverviewMidGrid", true, false) as GridContainer
		if mid_grid != null:
			mid_grid.columns = 1 if compact or content_width < 560.0 else 2
		var ring_grid := overview.find_child("OverviewRingGrid", true, false) as GridContainer
		if ring_grid != null:
			var ring_width := content_width / float(top_grid.columns if top_grid != null else 1) - 24.0
			ring_grid.columns = 4 if ring_width >= 280.0 else 2
		var people_grid := overview.find_child("OverviewPeopleGrid", true, false) as GridContainer
		if people_grid != null:
			people_grid.columns = _overview_people_columns(
				people_grid.get_child_count(), content_width)
		var effects_grid := overview.find_child("OverviewEffectsGrid", true, false) as GridContainer
		if effects_grid != null:
			effects_grid.columns = 1 if (mid_grid != null and mid_grid.columns >= 2) \
				or content_width < 620.0 else 2
	var people_page := _page_cache.get("people") as Control
	if people_page != null:
		var people_page_grid := people_page.find_child("PeoplePageGrid", true, false) as GridContainer
		if people_page_grid != null:
			people_page_grid.columns = 1 if content_width < 620.0 else 2


func _place_hinges(seam_x: float, compact: bool) -> void:
	if _hinges == null:
		return
	_hinges.visible = not compact
	if compact:
		return
	var ratios := [0.18, 0.50, 0.82]
	var children := _hinges.get_children()
	for i in range(mini(children.size(), ratios.size())):
		var hinge := children[i] as Control
		hinge.position = Vector2(seam_x - hinge.size.x * 0.5,
			round(size.y * float(ratios[i]) - hinge.size.y * 0.5))


func _focus_current_navigation() -> void:
	if not visible:
		return
	var target: Button = (_mobile_buttons.get(_current_page) as Button) \
		if _mobile_nav.visible else (_nav_buttons.get(_current_page) as Button)
	if target != null:
		target.grab_focus()


func _page_rows(page_id: String) -> Array:
	var pages: Dictionary = _model.get("pages", {})
	if page_id == "overview":
		var overview: Dictionary = pages.get("overview", {})
		var flat: Array = []
		for key in ["traits", "preferences", "effects", "people", "branches"]:
			flat.append_array(overview.get(key, []))
		return flat
	return pages.get(page_id, [])


func _shape_signature(rows: Array) -> String:
	var parts: Array[String] = [str(rows.size())]
	for index in range(rows.size()):
		var row: Dictionary = rows[index]
		parts.append("%s:%s:%s:%s" % [str(row.get("id", index)),
			str(row.get("kind", "")), str(row.get("cell", "")),
			str(not String(row.get("effect_summary", "")).strip_edges().is_empty())])
	return "|".join(parts)


func _clear_page_cache() -> void:
	if _page_host != null:
		for child in _page_host.get_children():
			_page_host.remove_child(child)
			child.queue_free()
	_page_cache.clear()
	_page_signatures.clear()


func _restore_page_scroll(page_id: String) -> void:
	if page_id == _current_page and _page_scroll != null:
		_page_scroll.scroll_vertical = int(_scroll_by_page.get(page_id, 0))


func _colonization_available(source_cell: int) -> bool:
	if source_cell < 0:
		return false
	if _player_controller == null:
		return true
	if _player_controller.has_method("can_family_colonize_from"):
		return bool(_player_controller.can_family_colonize_from(_family_handle, source_cell))
	return true


func _new_card() -> PanelContainer:
	var card := FamilyCardScene.instantiate() as PanelContainer
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.clip_contents = true
	return card


func _card_body(card: PanelContainer) -> VBoxContainer:
	return card.get_node("Body") as VBoxContainer


func _add_title_value(host: VBoxContainer, title_text: String, value_text: String) -> void:
	_add_title_value_row(host, title_text, value_text)


func _add_title_value_row(host: VBoxContainer, title_text: String, value_text: String) -> HBoxContainer:
	var row := FamilyHBoxScene.instantiate() as HBoxContainer
	row.add_theme_constant_override("separation", 8)
	host.add_child(row)
	var title_label := FamilyLabelScene.instantiate() as Label
	title_label.text = title_text
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.theme_type_variation = &"FamilyStrongLabel"
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(title_label)
	var value_label := FamilyLabelScene.instantiate() as Label
	value_label.text = value_text
	value_label.custom_minimum_size.x = 0.0
	value_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	value_label.theme_type_variation = &"PKDossierValue"
	value_label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
	row.add_child(value_label)
	return row


func _add_wrapped_label(host: Control, text: String, muted: bool) -> void:
	var label := FamilyLabelScene.instantiate() as Label
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.theme_type_variation = &"FamilyMutedLabel" if muted else &"PKDossierBody"
	host.add_child(label)


func _family_display_key(text: String) -> String:
	return text.strip_edges().replace(" ", "").replace("\n", "").replace("\r", "")


func _add_empty_label(host: Control, text: String) -> void:
	var label := FamilyLabelScene.instantiate() as Label
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.theme_type_variation = &"FamilyMutedLabel"
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	host.add_child(label)


func _add_section_label(host: Control, text: String) -> void:
	var label := FamilyLabelScene.instantiate() as Label
	label.text = text
	label.theme_type_variation = &"PKDossierKicker"
	host.add_child(label)


func _find_cards(root: Node) -> Array[PanelContainer]:
	var result: Array[PanelContainer] = []
	for child in root.get_children():
		if child is PanelContainer and child.theme_type_variation == &"FamilyCard":
			result.append(child as PanelContainer)
		else:
			result.append_array(_find_cards(child))
	return result


func _find_labels(root: Node) -> Array[Label]:
	var result: Array[Label] = []
	for child in root.get_children():
		if child is Label:
			result.append(child as Label)
		result.append_array(_find_labels(child))
	return result


func _find_progress_bars(root: Node) -> Array[ProgressBar]:
	var result: Array[ProgressBar] = []
	for child in root.get_children():
		if child is ProgressBar:
			result.append(child as ProgressBar)
		result.append_array(_find_progress_bars(child))
	return result


func _find_buttons(root: Node) -> Array[Button]:
	var result: Array[Button] = []
	for child in root.get_children():
		if child is Button:
			result.append(child as Button)
		result.append_array(_find_buttons(child))
	return result


func _count_nodes(root: Node) -> int:
	var count := 1
	for child in root.get_children():
		count += _count_nodes(child)
	return count
