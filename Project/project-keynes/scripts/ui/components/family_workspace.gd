extends Control
class_name FamilyWorkspace

const FamilyVBoxScene := preload("res://scenes/ui/family/family_vbox.tscn")
const FamilyHBoxScene := preload("res://scenes/ui/family/family_hbox.tscn")
const FamilyGridScene := preload("res://scenes/ui/family/family_grid.tscn")
const FamilyCardScene := preload("res://scenes/ui/family/family_card.tscn")
const FamilyLabelScene := preload("res://scenes/ui/family/family_label.tscn")
const FamilyButtonScene := preload("res://scenes/ui/family/family_button.tscn")
const FamilyTextureScene := preload("res://scenes/ui/family/family_texture_rect.tscn")
const FamilyProgressScene := preload("res://scenes/ui/family/family_progress_bar.tscn")
const FamilyControlScene := preload("res://scenes/ui/family/family_control.tscn")
const NAV_NORMAL_TEXTURE: Texture2D = preload(
	"res://assets/ui/family_workspace/bitmap/nav_normal_bitmap.tres")
const NAV_ACTIVE_TEXTURE: Texture2D = preload(
	"res://assets/ui/family_workspace/bitmap/nav_active_bitmap.tres")

signal closed()
signal colonization_requested(family_handle: int, source_cell: int)

const PAGE_ORDER: Array[String] = [
	"overview", "traits", "preferences", "effects", "people", "branches"]
const PAGE_META := {
	"overview": {"title": "概览", "icon": "family.workspace.overview"},
	"traits": {"title": "家族特性", "icon": "family.workspace.traits"},
	"preferences": {"title": "行为偏好", "icon": "family.workspace.preferences"},
	"effects": {"title": "家族效果", "icon": "family.workspace.effects"},
	"people": {"title": "主要人物", "icon": "family.workspace.people"},
	"branches": {"title": "领地与分支", "icon": "family.workspace.branches"},
}
const NAV_NAMES := {
	"overview": "NavOverview", "traits": "NavTraits",
	"preferences": "NavPreferences", "effects": "NavEffects",
	"people": "NavPeople", "branches": "NavBranches",
}
const PAGE_FADE_SECONDS := 0.12
const OPEN_SECONDS := 0.18
const CLOSE_SECONDS := 0.14
const REFERENCE_BOOK_SIZE := Vector2(855.0, 876.0)
const PREFERENCE_COLORS: Array[Color] = [
	Color("#a54b3f"), Color("#c28a32"), Color("#398795"),
	Color("#51854f"), Color("#75578d")]
const FONT_BASE_SIZES := {
	&"FamilyTitle": 31.0,
	&"FamilySectionTitle": 20.0,
	&"FamilyStrongLabel": 17.0,
	&"FamilyMetricValue": 20.0,
	&"FamilyMutedLabel": 15.0,
	&"FamilySubtitle": 16.0,
	&"FamilyPrestigeValue": 27.0,
	&"FamilyPrestigeCaption": 13.0,
	&"FamilyNavLabel": 17.0,
	&"FamilyOverviewHeading": 18.0,
}

var _model: Dictionary = {}
var _current_page := "overview"
var _family_handle := 0
var _page_cache: Dictionary = {}
var _page_signatures: Dictionary = {}
var _scroll_by_page: Dictionary = {}
var _nav_buttons: Dictionary = {}
var _nav_labels: Dictionary = {}
var _nav_backgrounds: Dictionary = {}
var _mobile_buttons: Dictionary = {}
var _summary_cards: Array[Dictionary] = []
var _player_controller = null
var _fullscreen_mode := false
var _closing := false
var _close_generation := 0
var _visual_scale := 1.0

@onready var _nav_column: VBoxContainer = %NavColumn
@onready var _nav_top_spacer: Control = $SafeMargin/Main/NavColumn/NavTopSpacer
@onready var _safe_margin: MarginContainer = $SafeMargin
@onready var _mobile_nav: ScrollContainer = %MobileNav
@onready var _mobile_buttons_host: HBoxContainer = %Buttons
@onready var _header: HBoxContainer = $SafeMargin/Main/PageArea/Header
@onready var _header_content: VBoxContainer = $SafeMargin/Main/PageArea/Header/HeaderContent
@onready var _identity_row: HBoxContainer = $SafeMargin/Main/PageArea/Header/HeaderContent/IdentityRow
@onready var _crest: TextureRect = %Crest
@onready var _title: Label = %Title
@onready var _subtitle: Label = %Subtitle
@onready var _prestige_value: Label = %PrestigeValue
@onready var _prestige_caption: Label = %PrestigeCaption
@onready var _prestige_plate: TextureRect = %PrestigePlate
@onready var _summary_grid: GridContainer = %SummaryGrid
@onready var _page_heading: HBoxContainer = $SafeMargin/Main/PageArea/PageHeading
@onready var _page_title: Label = %PageTitle
@onready var _page_icon: TextureRect = %PageIcon
@onready var _page_scroll: ScrollContainer = %PageScroll
@onready var _page_host: VBoxContainer = %PageHost
@onready var _close_button: Button = %CloseButton


func _ready() -> void:
	# Theme 子资源会在响应式视觉缩放时调整内容边距，必须实例独享。
	theme = theme.duplicate(true)
	for page_id in PAGE_ORDER:
		var button := get_node_or_null("%" + String(NAV_NAMES[page_id])) as Button
		if button == null:
			continue
		_setup_desktop_nav_button(button, page_id)
		button.pressed.connect(_select_page.bind(page_id, true))
		_nav_buttons[page_id] = button
		var mobile := FamilyButtonScene.instantiate() as Button
		mobile.name = "Mobile%s" % page_id.capitalize()
		mobile.custom_minimum_size = Vector2(112.0, 46.0)
		mobile.toggle_mode = true
		mobile.text = String(PAGE_META[page_id].title)
		mobile.icon = IconCatalog.texture_for_key(StringName(PAGE_META[page_id].icon))
		mobile.add_theme_constant_override("icon_max_width", 24)
		mobile.theme_type_variation = &"FamilyNavButton"
		mobile.pressed.connect(_select_page.bind(page_id, true))
		_mobile_buttons_host.add_child(mobile)
		_mobile_buttons[page_id] = mobile
	_close_button.pressed.connect(request_close)
	resized.connect(_apply_responsive_layout)
	_build_summary_cards()
	_apply_responsive_layout()
	_update_nav_state()


func _setup_desktop_nav_button(button: Button, page_id: String) -> void:
	button.text = ""
	button.icon = null
	button.clip_contents = false
	button.theme_type_variation = &"FamilyNavHitBox"
	var background := FamilyTextureScene.instantiate() as TextureRect
	background.name = "Background"
	background.texture = NAV_NORMAL_TEXTURE
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background.stretch_mode = TextureRect.STRETCH_SCALE
	_nav_backgrounds[page_id] = background
	var content := FamilyVBoxScene.instantiate() as VBoxContainer
	content.name = "Visual"
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(content)
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.offset_left = 18.0
	content.offset_top = 8.0
	content.offset_right = -8.0
	content.offset_bottom = -7.0
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 0)
	var icon := FamilyTextureScene.instantiate() as TextureRect
	icon.name = "Icon"
	icon.custom_minimum_size = Vector2(34.0, 34.0)
	icon.texture = IconCatalog.texture_for_key(StringName(PAGE_META[page_id].icon))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(icon)
	var label := FamilyLabelScene.instantiate() as Label
	label.text = String(PAGE_META[page_id].title)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.theme_type_variation = &"FamilyNavLabel"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(label)
	_nav_labels[page_id] = label
	button.mouse_entered.connect(func() -> void:
		if page_id != _current_page:
			background.modulate = Color(1.07, 1.04, 0.95, 1.0))
	button.mouse_exited.connect(func() -> void:
		background.modulate = Color.WHITE)
	button.button_down.connect(func() -> void:
		background.modulate = Color(0.92, 0.90, 0.86, 1.0))
	button.button_up.connect(func() -> void:
		background.modulate = Color.WHITE)
	button.focus_entered.connect(func() -> void:
		if page_id != _current_page:
			background.modulate = Color(1.07, 1.04, 0.95, 1.0))
	button.focus_exited.connect(func() -> void:
		background.modulate = Color.WHITE)


func set_player_controller(controller) -> void:
	_player_controller = controller


func set_fullscreen_mode(fullscreen: bool) -> void:
	_fullscreen_mode = fullscreen
	_apply_responsive_layout()


func show_family(model: Dictionary, animate: bool = true) -> void:
	_close_generation += 1
	_closing = false
	set_model(model)
	if animate:
		UIAnimation.fade_slide_in(self, Vector2(36.0, 0.0), OPEN_SECONDS)
	else:
		visible = true
	call_deferred("_focus_current_navigation")


func set_model(model: Dictionary) -> void:
	if model.is_empty():
		return
	var next_handle := int(model.get("actions", {}).get("family_handle", 0))
	if _family_handle != next_handle:
		_clear_page_cache()
		_scroll_by_page.clear()
		_current_page = "overview"
		_family_handle = next_handle
	_model = model.duplicate(true)
	_update_header()
	_update_summary()
	_ensure_page(_current_page)
	_refresh_page(_current_page)
	_update_nav_state()
	_apply_responsive_layout()


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
		UIAnimation.crossfade(_page_cache[page_id] as Control, PAGE_FADE_SECONDS)


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
	page.clip_contents = true
	page.add_theme_constant_override("separation", 8)
	_page_host.add_child(page)
	_page_cache[page_id] = page
	_page_signatures[page_id] = signature
	_build_page(page_id, page, rows)
	var bottom_spacer := FamilyControlScene.instantiate() as Control
	bottom_spacer.name = "BottomSafeSpacer"
	bottom_spacer.custom_minimum_size.y = 12.0
	bottom_spacer.set_meta("family_base_height", 12.0)
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


func _build_overview_page(page: VBoxContainer) -> void:
	var overview: Dictionary = _model.get("pages", {}).get("overview", {})
	var top_grid := FamilyGridScene.instantiate() as GridContainer
	top_grid.name = "OverviewTopGrid"
	top_grid.columns = 2
	top_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_grid.add_theme_constant_override("h_separation", 8)
	top_grid.add_theme_constant_override("v_separation", 8)
	page.add_child(top_grid)
	_add_overview_list_card(top_grid, "traits", "家族特性",
		overview.get("traits", []), 180.0)
	_add_overview_list_card(top_grid, "preferences", "行为偏好",
		overview.get("preferences", []), 180.0)
	_add_overview_list_card(page, "effects", "家族效果",
		overview.get("effects", []), 124.0, true)
	_add_overview_people_card(page, overview.get("people", []))


func _add_overview_list_card(host: Control, page_id: String, title_text: String,
		items: Array, minimum_height: float, two_columns: bool = false) -> void:
	var card := _new_card()
	card.name = "Overview%s" % page_id.capitalize()
	card.custom_minimum_size.y = minimum_height
	card.set_meta("family_base_height", minimum_height)
	host.add_child(card)
	var body := _card_body(card)
	_add_overview_heading(body, page_id, title_text)
	var item_host: Control = body
	if two_columns:
		var grid := FamilyGridScene.instantiate() as GridContainer
		grid.name = "Overview%sGrid" % page_id.capitalize()
		grid.columns = 2
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_theme_constant_override("h_separation", 12)
		grid.add_theme_constant_override("v_separation", 4)
		body.add_child(grid)
		item_host = grid
	if items.is_empty():
		_add_empty_label(item_host, "暂无记录")
	for item_index in range(items.size()):
		var item_value: Variant = items[item_index]
		var item: Dictionary = item_value
		_add_overview_list_item(item_host, page_id, item, item_index)


func _add_overview_list_item(host: Control, page_id: String,
		item: Dictionary, item_index: int) -> void:
	var row := FamilyHBoxScene.instantiate() as HBoxContainer
	row.name = "Item%d" % item_index
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)
	host.add_child(row)
	var icon := FamilyTextureScene.instantiate() as TextureRect
	icon.name = "Icon"
	icon.custom_minimum_size = Vector2(30.0, 30.0)
	icon.set_meta("family_base_size", Vector2(30.0, 30.0))
	icon.texture = IconCatalog.texture_for_key(StringName(PAGE_META[page_id].icon))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(icon)
	var content := FamilyVBoxScene.instantiate() as VBoxContainer
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 1)
	row.add_child(content)
	var title_row := FamilyHBoxScene.instantiate() as HBoxContainer
	title_row.add_theme_constant_override("separation", 6)
	content.add_child(title_row)
	var name_label := FamilyLabelScene.instantiate() as Label
	name_label.name = "Name"
	name_label.text = String(item.get("name", item.get("title", "记录")))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.theme_type_variation = &"FamilyStrongLabel"
	if page_id == "effects":
		name_label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	else:
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_row.add_child(name_label)
	var value_label := FamilyLabelScene.instantiate() as Label
	value_label.name = "Value"
	value_label.text = String(item.get("value", ""))
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.theme_type_variation = &"FamilyMutedLabel"
	value_label.add_theme_color_override("font_color", UITokens.FAMILY_OXBLOOD)
	title_row.add_child(value_label)
	if page_id == "preferences":
		var progress := FamilyProgressScene.instantiate() as ProgressBar
		progress.name = "Gauge"
		progress.custom_minimum_size.y = 10.0
		progress.set_meta("family_base_height", 10.0)
		progress.min_value = 0.0
		progress.max_value = 200.0
		progress.show_percentage = false
		progress.value = clampf(float(item.get("factor_percent", 100.0)), 0.0, 200.0)
		content.add_child(progress)
		_apply_preference_color(progress, item_index)
	elif page_id == "traits":
		var detail_text := String(item.get("detail", item.get("effect_summary", "")))
		if not detail_text.is_empty():
			var detail := FamilyLabelScene.instantiate() as Label
			detail.name = "Detail"
			detail.text = detail_text
			detail.theme_type_variation = &"FamilyMutedLabel"
			detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			content.add_child(detail)


func _add_overview_people_card(host: Control, items: Array) -> void:
	var card := _new_card()
	card.name = "OverviewPeople"
	var minimum_height := 210.0 if items.size() <= 3 else 240.0
	card.custom_minimum_size.y = minimum_height
	card.set_meta("family_base_height", minimum_height)
	host.add_child(card)
	var body := _card_body(card)
	_add_overview_heading(body, "people", "主要人物")
	var people_grid := FamilyGridScene.instantiate() as GridContainer
	people_grid.name = "OverviewPeopleGrid"
	people_grid.columns = maxi(1, mini(5, items.size()))
	people_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	people_grid.add_theme_constant_override("h_separation", 6)
	people_grid.add_theme_constant_override("v_separation", 6)
	body.add_child(people_grid)
	if items.is_empty():
		_add_empty_label(people_grid, "尚无可记录的重要人物")
	for item_index in range(items.size()):
		var item_value: Variant = items[item_index]
		var item: Dictionary = item_value
		var portrait_box := FamilyVBoxScene.instantiate() as VBoxContainer
		portrait_box.name = "Person%d" % item_index
		portrait_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		portrait_box.alignment = BoxContainer.ALIGNMENT_CENTER
		portrait_box.add_theme_constant_override("separation", 1)
		people_grid.add_child(portrait_box)
		var portrait := FamilyTextureScene.instantiate() as TextureRect
		portrait.name = "Portrait"
		portrait.custom_minimum_size = Vector2(112.0, 132.0)
		portrait.set_meta("family_base_size", Vector2(112.0, 132.0))
		portrait.texture = IconCatalog.texture_for_key(&"family.workspace.person")
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		portrait_box.add_child(portrait)
		var name_label := FamilyLabelScene.instantiate() as Label
		name_label.name = "Name"
		name_label.text = String(item.get("name", "未命名人物"))
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.theme_type_variation = &"FamilyStrongLabel"
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		portrait_box.add_child(name_label)
		var role_label := FamilyLabelScene.instantiate() as Label
		role_label.name = "Role"
		role_label.text = String(item.get("value", item.get("role", "家族成员")))
		role_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		role_label.theme_type_variation = &"FamilyMutedLabel"
		role_label.add_theme_font_size_override("font_size", 14)
		role_label.set_meta("family_base_font_size", 14.0)
		role_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		portrait_box.add_child(role_label)


func _add_overview_heading(host: VBoxContainer, page_id: String,
		title_text: String) -> void:
	var heading := FamilyButtonScene.instantiate() as Button
	heading.name = "Heading"
	heading.flat = true
	heading.text = "%s  ›" % title_text
	heading.icon = IconCatalog.texture_for_key(StringName(PAGE_META[page_id].icon))
	heading.add_theme_constant_override("icon_max_width", 24)
	heading.set_meta("family_base_icon_width", 24.0)
	heading.alignment = HORIZONTAL_ALIGNMENT_LEFT
	heading.theme_type_variation = &"FamilyOverviewHeading"
	heading.pressed.connect(_select_page.bind(page_id, true))
	host.add_child(heading)


func _overview_item_text(item: Dictionary) -> String:
	var value := String(item.get("value", ""))
	return "• %s%s" % [String(item.get("name", item.get("title", "记录"))),
		("  " + value) if not value.is_empty() else ""]


func _build_trait_page(page: VBoxContainer, rows: Array) -> void:
	if rows.is_empty():
		_add_empty_label(page, "这个家族尚未形成可记录的特性。")
		return
	for raw in rows:
		var row: Dictionary = raw
		var card := _new_card()
		page.add_child(card)
		var body := _card_body(card)
		_add_title_value(body, String(row.get("name", "特性")),
			String(row.get("kind_label", row.get("value", "附加特性"))))
		var detail := String(row.get("detail", "暂无说明"))
		_add_wrapped_label(body, detail, true)
		var effect_summary := String(row.get("effect_summary", ""))
		if not effect_summary.strip_edges().is_empty() and \
				_family_display_key(effect_summary) != _family_display_key(detail):
			_add_wrapped_label(body, effect_summary, false)


func _build_preference_page(page: VBoxContainer, rows: Array) -> void:
	if rows.is_empty():
		_add_empty_label(page, "当前没有可见的家族行为偏好。")
		return
	var current_axis := ""
	for raw in rows:
		var row: Dictionary = raw
		var axis_name := String(row.get("axis_name", "行为"))
		if axis_name != current_axis:
			current_axis = axis_name
			_add_section_label(page, axis_name)
		var card := _new_card()
		page.add_child(card)
		var body := _card_body(card)
		_add_title_value(body, String(row.get("name", "偏好")),
			String(row.get("factor_text", row.get("value", "100%"))))
		var progress := FamilyProgressScene.instantiate() as ProgressBar
		progress.custom_minimum_size = Vector2(0.0, 16.0)
		progress.set_meta("family_base_height", 16.0)
		progress.min_value = 0.0
		progress.max_value = 200.0
		progress.show_percentage = false
		progress.value = clampf(float(row.get("factor_percent", 100.0)), 0.0, 200.0)
		body.add_child(progress)
		_apply_preference_color(progress, int(row.get("axis", 0)))
		_add_preference_scale(body)


func _add_preference_scale(host: VBoxContainer) -> void:
	var scale_row := FamilyHBoxScene.instantiate() as HBoxContainer
	scale_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scale_row.add_theme_constant_override("separation", 0)
	host.add_child(scale_row)
	var texts := ["0%", "基线 100%", "200%"]
	var alignments := [HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_CENTER,
		HORIZONTAL_ALIGNMENT_RIGHT]
	for index in range(texts.size()):
		var label := FamilyLabelScene.instantiate() as Label
		label.text = texts[index]
		label.horizontal_alignment = alignments[index]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.theme_type_variation = &"FamilyMutedLabel"
		label.add_theme_font_size_override("font_size", 13)
		label.set_meta("family_base_font_size", 13.0)
		scale_row.add_child(label)


func _build_effect_page(page: VBoxContainer, rows: Array) -> void:
	if rows.is_empty():
		_add_empty_label(page, "当前没有家族分支效果。")
		return
	var current_cell := -999999
	for raw in rows:
		var row: Dictionary = raw
		var cell := int(row.get("cell", -1))
		if cell != current_cell:
			current_cell = cell
			_add_section_label(page, "地块 %d" % cell if cell >= 0 else "家族整体")
		var card := _new_card()
		page.add_child(card)
		var body := _card_body(card)
		_add_title_value(body, String(row.get("title", row.get("name", "效果"))),
			String(row.get("value", "")))
		_add_wrapped_label(body, String(row.get("detail", "")), true)
		if String(row.get("kind", "")) == "trigger":
			var gauge := FamilyProgressScene.instantiate() as ProgressBar
			gauge.custom_minimum_size = Vector2(0.0, 14.0)
			gauge.set_meta("family_base_height", 14.0)
			gauge.max_value = 1.0
			gauge.show_percentage = false
			gauge.value = clampf(float(row.get("progress_ratio", 0.0)), 0.0, 1.0)
			body.add_child(gauge)


func _build_people_page(page: VBoxContainer, rows: Array) -> void:
	if rows.is_empty():
		_add_empty_label(page, "尚无可记录的重要人物。")
		return
	var grid := FamilyGridScene.instantiate() as GridContainer
	grid.columns = 2 if size.x >= 680.0 else 1
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	page.add_child(grid)
	for raw in rows:
		var row: Dictionary = raw
		var card := _new_card()
		grid.add_child(card)
		var horizontal := FamilyHBoxScene.instantiate() as HBoxContainer
		horizontal.add_theme_constant_override("separation", 10)
		_card_body(card).add_child(horizontal)
		var portrait := FamilyTextureScene.instantiate() as TextureRect
		portrait.name = "Portrait"
		portrait.custom_minimum_size = Vector2(62.0, 74.0)
		portrait.set_meta("family_base_size", Vector2(62.0, 74.0))
		portrait.texture = IconCatalog.texture_for_key(&"family.workspace.person")
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		horizontal.add_child(portrait)
		var text_box := FamilyVBoxScene.instantiate() as VBoxContainer
		text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		horizontal.add_child(text_box)
		_add_title_value(text_box, String(row.get("name", "未命名人物")),
			String(row.get("role", "家族成员")))
		_add_wrapped_label(text_box, String(row.get("profession", "身份未详")), true)
		var building := String(row.get("building", ""))
		_add_wrapped_label(text_box,
			"所属产业：%s" % building if not building.is_empty() else "所属产业：无", true)


func _build_branch_page(page: VBoxContainer, rows: Array) -> void:
	if rows.is_empty():
		_add_empty_label(page, "这个家族尚未建立分支。")
		return
	for raw in rows:
		var row: Dictionary = raw
		var card := _new_card()
		page.add_child(card)
		var body := _card_body(card)
		_add_title_value(body, "地块 %d" % int(row.get("cell", -1)),
			"威望 %s · %s" % [String(row.get("prestige_label", "0")),
			String(row.get("prestige_text", "0%"))])
		_add_wrapped_label(body, "人口 %s · 现金 %s · 建筑 %s" % [
			String(row.get("population_share_text", "0%")),
			String(row.get("cash_share_text", "0%")),
			String(row.get("building_share_text", "0%"))], true)
		_add_wrapped_label(body, "晋级目标 %s · 复核 %d/2" % [
			String(row.get("target_label", "0")), int(row.get("review_streak", 0))], true)
		var action := FamilyButtonScene.instantiate() as Button
		action.text = "进入地图选点"
		action.theme_type_variation = &"FamilyActionButton"
		action.disabled = not _colonization_available(int(row.get("cell", -1)))
		action.tooltip_text = "以此分支为来源进入地图选点"
		action.pressed.connect(func() -> void:
			colonization_requested.emit(_family_handle, int(row.get("cell", -1))))
		body.add_child(action)


func _refresh_page(page_id: String) -> void:
	var rows := _page_rows(page_id)
	var signature := _shape_signature(rows)
	if String(_page_signatures.get(page_id, "")) != signature:
		_ensure_page(page_id)
		return
	# 页面结构未变时只更新文本和仪表；为避免业务组件解析字符串，值仍来自
	# view-model 的独立字段。各页的轻量绑定按构建顺序更新。
	var page := _page_cache.get(page_id) as Control
	if page == null:
		return
	if page_id == "overview":
		_refresh_overview_page(page)
		return
	var row_index := 0
	for card in _find_cards(page):
		if row_index >= rows.size():
			break
		_apply_card_live(page_id, card, rows[row_index])
		row_index += 1


func _apply_card_live(page_id: String, card: PanelContainer, row_value: Variant) -> void:
	var row: Dictionary = row_value
	var labels := _find_labels(card)
	if labels.is_empty():
		return
	match page_id:
		"traits":
			labels[0].text = String(row.get("name", "特性"))
			if labels.size() > 1: labels[1].text = String(row.get("kind_label", row.get("value", "附加特性")))
			if labels.size() > 2: labels[2].text = String(row.get("detail", "暂无说明"))
			if labels.size() > 3: labels[3].text = String(row.get("effect_summary", ""))
		"preferences":
			labels[0].text = String(row.get("name", "偏好"))
			if labels.size() > 1: labels[1].text = String(row.get("factor_text", row.get("value", "100%")))
			var bars := _find_progress_bars(card)
			if not bars.is_empty(): bars[0].value = clampf(float(row.get("factor_percent", 100.0)), 0.0, 200.0)
		"effects":
			labels[0].text = String(row.get("title", row.get("name", "效果")))
			if labels.size() > 1: labels[1].text = String(row.get("value", ""))
			if labels.size() > 2: labels[2].text = String(row.get("detail", ""))
		"people":
			labels[0].text = String(row.get("name", "未命名人物"))
			if labels.size() > 1: labels[1].text = String(row.get("role", "家族成员"))
			if labels.size() > 2: labels[2].text = String(row.get("profession", "身份未详"))
			if labels.size() > 3:
				var building := String(row.get("building", ""))
				labels[3].text = "所属产业：%s" % building if not building.is_empty() else "所属产业：无"
		"branches":
			labels[0].text = "地块 %d" % int(row.get("cell", -1))
			if labels.size() > 1: labels[1].text = "威望 %s · %s" % [String(row.get("prestige_label", "0")), String(row.get("prestige_text", "0%"))]
			if labels.size() > 2: labels[2].text = "人口 %s · 现金 %s · 建筑 %s" % [String(row.get("population_share_text", "0%")), String(row.get("cash_share_text", "0%")), String(row.get("building_share_text", "0%"))]
			if labels.size() > 3: labels[3].text = "晋级目标 %s · 复核 %d/2" % [String(row.get("target_label", "0")), int(row.get("review_streak", 0))]
			var buttons := _find_buttons(card)
			if not buttons.is_empty(): buttons[0].disabled = not _colonization_available(int(row.get("cell", -1)))


func _refresh_overview_page(page: Control) -> void:
	var overview: Dictionary = _model.get("pages", {}).get("overview", {})
	for section_key in ["traits", "preferences", "effects"]:
		var card := page.find_child("Overview%s" % section_key.capitalize(),
			true, false) as PanelContainer
		if card == null:
			continue
		var items: Array = overview.get(section_key, [])
		for item_index in range(items.size()):
			var item_root := card.find_child("Item%d" % item_index, true, false) as Control
			if item_root == null:
				continue
			var item: Dictionary = items[item_index]
			var name_label := item_root.find_child("Name", true, false) as Label
			var value_label := item_root.find_child("Value", true, false) as Label
			var detail_label := item_root.find_child("Detail", true, false) as Label
			var gauge := item_root.find_child("Gauge", true, false) as ProgressBar
			if name_label != null:
				name_label.text = String(item.get("name", item.get("title", "记录")))
			if value_label != null:
				value_label.text = String(item.get("value", ""))
			if detail_label != null:
				detail_label.text = String(item.get("detail", item.get("effect_summary", "")))
			if gauge != null:
				gauge.value = clampf(float(item.get("factor_percent", 100.0)), 0.0, 200.0)
	var people_card := page.find_child("OverviewPeople", true, false) as PanelContainer
	if people_card == null:
		return
	var people: Array = overview.get("people", [])
	for person_index in range(people.size()):
		var person_root := people_card.find_child("Person%d" % person_index,
			true, false) as Control
		if person_root == null:
			continue
		var person: Dictionary = people[person_index]
		var name_label := person_root.find_child("Name", true, false) as Label
		var role_label := person_root.find_child("Role", true, false) as Label
		if name_label != null:
			name_label.text = String(person.get("name", "未命名人物"))
		if role_label != null:
			role_label.text = String(person.get("value", person.get("role", "家族成员")))


func _update_header() -> void:
	var header: Dictionary = _model.get("header", {})
	_title.text = String(header.get("name", "家族档案"))
	_subtitle.text = String(header.get("subtitle", ""))
	_prestige_value.text = String(header.get("prestige_progress_text", "0%"))
	_prestige_caption.text = "威望 %s" % String(header.get("prestige_label", "0"))


func _build_summary_cards() -> void:
	for child in _summary_grid.get_children():
		child.queue_free()
	_summary_cards.clear()
	for index in range(4):
		var card := _new_card()
		card.custom_minimum_size.y = 112.0
		card.set_meta("family_base_height", 112.0)
		card.theme_type_variation = &"FamilyMetricCell"
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_summary_grid.add_child(card)
		var column := FamilyVBoxScene.instantiate() as VBoxContainer
		column.alignment = BoxContainer.ALIGNMENT_CENTER
		column.add_theme_constant_override("separation", 1)
		_card_body(card).add_child(column)
		var icon := FamilyTextureScene.instantiate() as TextureRect
		icon.name = "Icon"
		icon.custom_minimum_size = Vector2(48.0, 48.0)
		icon.set_meta("family_base_size", Vector2(48.0, 48.0))
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		column.add_child(icon)
		var label := FamilyLabelScene.instantiate() as Label
		label.theme_type_variation = &"FamilyMutedLabel"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 15)
		label.set_meta("family_base_font_size", 15.0)
		column.add_child(label)
		var value := FamilyLabelScene.instantiate() as Label
		value.theme_type_variation = &"FamilyMetricValue"
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		column.add_child(value)
		_summary_cards.append({"icon": icon, "value": value, "label": label})


func _update_summary() -> void:
	var items: Array = _model.get("summary", [])
	for index in range(_summary_cards.size()):
		var controls: Dictionary = _summary_cards[index]
		var item: Dictionary = items[index] if index < items.size() else {}
		(controls.icon as TextureRect).texture = IconCatalog.texture_for_key(StringName(item.get("icon", "family.metric.population")))
		(controls.value as Label).text = String(item.get("value", "—"))
		(controls.label as Label).text = String(item.get("label", ""))


func _update_nav_state() -> void:
	for page_id in PAGE_ORDER:
		if _nav_buttons.has(page_id):
			(_nav_buttons[page_id] as Button).button_pressed = page_id == _current_page
		if _nav_backgrounds.has(page_id):
			(_nav_backgrounds[page_id] as TextureRect).texture = NAV_ACTIVE_TEXTURE \
				if page_id == _current_page else NAV_NORMAL_TEXTURE
		if _nav_labels.has(page_id):
			var nav_label := _nav_labels[page_id] as Label
			var active := page_id == _current_page
			nav_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.66, 1.0) \
				if active else Color(0.075, 0.043, 0.022, 1.0))
			nav_label.add_theme_color_override("font_outline_color",
				Color(0.08, 0.025, 0.012, 1.0) if active \
				else Color(1.0, 0.93, 0.76, 0.95))
			nav_label.add_theme_constant_override("outline_size", maxi(1,
				roundi((2.0 if active else 1.0) * _visual_scale)))
		if _mobile_buttons.has(page_id):
			(_mobile_buttons[page_id] as Button).button_pressed = page_id == _current_page
	if PAGE_META.has(_current_page):
		_page_title.text = String(PAGE_META[_current_page].title)
		_page_icon.texture = IconCatalog.texture_for_key(StringName(PAGE_META[_current_page].icon))


func _apply_responsive_layout() -> void:
	if _nav_column == null or _safe_margin == null:
		return
	_visual_scale = clampf(minf(size.x / REFERENCE_BOOK_SIZE.x,
		size.y / REFERENCE_BOOK_SIZE.y), 0.78, 1.5)
	var full_width_book := _uses_full_width_book_layout()
	var compact := full_width_book and size.x < 720.0
	# 全屏档案册使用方形原画比例，书脊约占 21%；桌面半屏仍保持
	# P2 的紧凑书签宽度。不能只依赖 Inspector 的 compact 标志：工作区
	# 可能因窗口/父容器重排而实际占满视口，仍须自动使用完整书脊缩进。
	var nav_width := clampf(size.x * (0.21 if full_width_book else 0.19),
		126.0 * _visual_scale,
		300.0 if full_width_book else 228.0 * _visual_scale)
	var right_margin := clampf(size.x * 0.06, 34.0 * _visual_scale,
		72.0 * _visual_scale)
	var left_margin := clampf(size.x * 0.19 + 12.0, 128.0, 240.0) \
		if compact else 20.0 * _visual_scale
	_safe_margin.add_theme_constant_override("margin_left", roundi(left_margin))
	_safe_margin.add_theme_constant_override("margin_top", roundi(20.0 * _visual_scale))
	_safe_margin.add_theme_constant_override("margin_right", roundi(right_margin))
	_safe_margin.add_theme_constant_override("margin_bottom", roundi(56.0 * _visual_scale))
	_nav_column.custom_minimum_size.x = nav_width
	_nav_column.visible = not compact
	_mobile_nav.visible = compact
	var main_separation := 8.0 if compact else 24.0 * _visual_scale
	var content_width := maxf(320.0, size.x - left_margin - right_margin \
		- (0.0 if compact else nav_width + main_separation))
	var logical_content_width := content_width / _visual_scale
	_summary_grid.columns = 2 if logical_content_width < 580.0 else 4
	_apply_shell_visual_scale()
	_apply_registered_visual_scale(self)
	_apply_family_theme_scale()
	_apply_typography_scale(self)
	if _prestige_plate != null:
		_prestige_plate.custom_minimum_size = (Vector2(112.0, 132.0) \
			if logical_content_width < 580.0 else Vector2(138.0, 148.0)) * _visual_scale
	if _close_button != null:
		_close_button.custom_minimum_size = (Vector2(34.0, 34.0) \
			if logical_content_width < 580.0 else Vector2(38.0, 38.0)) * _visual_scale
	var overview := _page_cache.get("overview") as Control
	if overview != null:
		var top_grid := overview.find_child("OverviewTopGrid", true, false) as GridContainer
		if top_grid != null:
			top_grid.columns = 1 if content_width < 680.0 else 2
		var people_grid := overview.find_child("OverviewPeopleGrid", true, false) as GridContainer
		if people_grid != null:
			people_grid.columns = 5 if content_width >= 680.0 else (3 \
				if content_width >= 520.0 else (2 \
				if content_width >= 360.0 else 1))
		var effects_grid := overview.find_child("OverviewEffectsGrid", true, false) as GridContainer
		if effects_grid != null:
			effects_grid.columns = 1 if content_width < 680.0 else 2
	var people_page := _page_cache.get("people") as Control
	if people_page != null and people_page.get_child_count() > 0:
		var people_page_grid := people_page.get_child(0) as GridContainer
		if people_page_grid != null:
			people_page_grid.columns = 1 if content_width < 680.0 else 2


func _apply_shell_visual_scale() -> void:
	_nav_top_spacer.custom_minimum_size.y = 12.0 * _visual_scale
	for page_id in PAGE_ORDER:
		var button := _nav_buttons.get(page_id) as Button
		if button == null:
			continue
		button.custom_minimum_size.y = 76.0 * _visual_scale
		var visual := button.get_node_or_null("Visual") as Control
		if visual != null:
			visual.offset_left = 18.0 * _visual_scale
			visual.offset_top = 8.0 * _visual_scale
			visual.offset_right = -8.0 * _visual_scale
			visual.offset_bottom = -7.0 * _visual_scale
			var icon := visual.get_node_or_null("Icon") as TextureRect
			if icon != null:
				icon.custom_minimum_size = Vector2(34.0, 34.0) * _visual_scale
	var main := $SafeMargin/Main as HBoxContainer
	var page_area := $SafeMargin/Main/PageArea as VBoxContainer
	main.add_theme_constant_override("separation", roundi(
		8.0 if _mobile_nav.visible else 24.0 * _visual_scale))
	page_area.add_theme_constant_override("separation", roundi(6.0 * _visual_scale))
	_header.custom_minimum_size.y = 158.0 * _visual_scale
	_header.add_theme_constant_override("separation", roundi(8.0 * _visual_scale))
	_header_content.add_theme_constant_override("separation", roundi(5.0 * _visual_scale))
	_identity_row.add_theme_constant_override("separation", roundi(10.0 * _visual_scale))
	_crest.custom_minimum_size = Vector2(68.0, 68.0) * _visual_scale
	_summary_grid.add_theme_constant_override("h_separation", roundi(2.0 * _visual_scale))
	_summary_grid.add_theme_constant_override("v_separation", roundi(2.0 * _visual_scale))
	_page_heading.custom_minimum_size.y = 32.0 * _visual_scale
	_page_heading.add_theme_constant_override("separation", roundi(6.0 * _visual_scale))
	_page_icon.custom_minimum_size = Vector2(30.0, 30.0) * _visual_scale
	_page_host.add_theme_constant_override("separation", roundi(8.0 * _visual_scale))
	_mobile_nav.custom_minimum_size.y = 56.0 * _visual_scale


func _apply_registered_visual_scale(root: Node) -> void:
	if root is Control:
		var control := root as Control
		if control.has_meta("family_base_size"):
			control.custom_minimum_size = (control.get_meta("family_base_size") as Vector2) \
				* _visual_scale
		elif control.has_meta("family_base_height"):
			control.custom_minimum_size.y = float(control.get_meta("family_base_height")) \
				* _visual_scale
		if control.has_meta("family_base_icon_width"):
			control.add_theme_constant_override("icon_max_width", roundi(
				float(control.get_meta("family_base_icon_width")) * _visual_scale))
	for child in root.get_children():
		_apply_registered_visual_scale(child)


func _apply_typography_scale(root: Node) -> void:
	if root is Label or root is Button:
		var control := root as Control
		var base_size := float(control.get_meta("family_base_font_size", 0.0))
		if base_size <= 0.0:
			base_size = float(FONT_BASE_SIZES.get(control.theme_type_variation, 16.0))
		var font_scale := lerpf(1.0, _visual_scale, 0.72)
		control.add_theme_font_size_override("font_size", maxi(13,
			roundi(base_size * font_scale)))
	for child in root.get_children():
		_apply_typography_scale(child)


func _apply_family_theme_scale() -> void:
	_scale_stylebox_content("panel", &"FamilyCard", Vector4(14.0, 14.0, 14.0, 14.0))
	_scale_stylebox_content("panel", &"FamilySummaryBand", Vector4(12.0, 10.0, 12.0, 10.0))
	_scale_stylebox_content("panel", &"FamilyMetricCell", Vector4(8.0, 4.0, 8.0, 4.0))


func _scale_stylebox_content(property_name: StringName, type_name: StringName,
		base: Vector4) -> void:
	var style := theme.get_stylebox(property_name, type_name)
	if style == null:
		return
	style.set_content_margin(SIDE_LEFT, base.x * _visual_scale)
	style.set_content_margin(SIDE_TOP, base.y * _visual_scale)
	style.set_content_margin(SIDE_RIGHT, base.z * _visual_scale)
	style.set_content_margin(SIDE_BOTTOM, base.w * _visual_scale)


func _apply_preference_color(progress: ProgressBar, color_index: int) -> void:
	var fill := progress.get_theme_stylebox("fill") as StyleBoxFlat
	if fill == null:
		return
	var colored := fill.duplicate(true) as StyleBoxFlat
	var semantic := PREFERENCE_COLORS[posmod(color_index, PREFERENCE_COLORS.size())]
	colored.bg_color = semantic
	colored.border_color = semantic.darkened(0.35)
	progress.add_theme_stylebox_override("fill", colored)


func _focus_current_navigation() -> void:
	if not visible:
		return
	var target: Button = (_mobile_buttons.get(_current_page) as Button) \
		if _mobile_nav.visible else (_nav_buttons.get(_current_page) as Button)
	if target != null:
		target.grab_focus()


func _uses_full_width_book_layout() -> bool:
	if _fullscreen_mode:
		return true
	var viewport_width := get_viewport_rect().size.x
	if viewport_width <= 0.0:
		return false
	# 半屏工作区约为视口的 50%；75% 阈值为面板外框和安全边距留出余量，
	# 同时避免 1279px 全屏路径误套用半屏书脊宽度。
	return size.x >= viewport_width * 0.75


func _page_rows(page_id: String) -> Array:
	var pages: Dictionary = _model.get("pages", {})
	if page_id == "overview":
		var overview: Dictionary = pages.get("overview", {})
		var flat: Array = []
		for key in ["traits", "preferences", "effects", "people"]:
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
	value_label.add_theme_color_override("font_color", UITokens.FAMILY_OXBLOOD)
	row.add_child(value_label)


func _add_wrapped_label(host: Control, text: String, muted: bool) -> void:
	var label := FamilyLabelScene.instantiate() as Label
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if muted:
		label.theme_type_variation = &"FamilyMutedLabel"
	host.add_child(label)


func _family_display_key(text: String) -> String:
	return text.strip_edges().replace(" ", "").replace("\n", "").replace("\r", "")


func _add_empty_label(host: Control, text: String) -> void:
	var label := FamilyLabelScene.instantiate() as Label
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.theme_type_variation = &"FamilyMutedLabel"
	label.custom_minimum_size = Vector2(0.0, 72.0)
	host.add_child(label)


func _add_section_label(host: Control, text: String) -> void:
	var label := FamilyLabelScene.instantiate() as Label
	label.text = text
	label.theme_type_variation = &"FamilySectionTitle"
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
