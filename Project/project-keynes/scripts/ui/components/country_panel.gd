extends Control
class_name CountryPanel

# Each country affair is a standalone full-bleed screen. The shell owns nothing
# but framing, so no screen inherits another domain's dossier chrome or tabs.
signal close_requested()
signal section_selected(section_id: String)
signal locate_cell_requested(cell: int)
## Same intent as `locate_cell_requested`, but for "these N cells", which is what
## a card with a per-cell selector resolves to. Kept separate because the two
## receivers differ: one selects a hex, the other paints a set.
signal target_cells_requested(cells: PackedInt32Array)

const SECTION_DEFINITIONS := [
	{"id": "technology", "label": "科技研究", "subtitle": "编排研究投入，浏览技术网络与时代前沿", "icon": &"country.technology", "hud_icon": &"hud.country.technology", "accent": UITokens.CLIMATE, "available": true},
	{"id": "ideology", "label": "国家理念", "subtitle": "形成国家道路，审视社会支持与民族精神", "icon": &"country.politics", "hud_icon": &"hud.country.ideology", "accent": UITokens.ACCENT, "available": true},
	{"id": "economy", "label": "国民经济", "subtitle": "阶层民生、产业运营、投资风向、物资贸易与财政", "icon": &"country.economy", "hud_icon": &"hud.country.economy", "accent": UITokens.RESOURCE, "available": true},
	{"id": "military", "label": "军事", "subtitle": "尚未开放", "icon": &"country.military", "hud_icon": &"hud.country.military", "accent": UITokens.RISK, "available": false},
	{"id": "diplomacy", "label": "外交", "subtitle": "尚未开放", "icon": &"country.diplomacy", "hud_icon": &"hud.country.diplomacy", "accent": UITokens.WATER, "available": false},
]
const HEADER_HEIGHT := 30.0
## Fraction of the viewport the docked shell leaves to the map. The shell is
## full-bleed by default; docking is the one state where it must not be, because
## 「定位到地块」 is only a useful answer if the player can see the hexes it
## answers with. 0.48 keeps the map readable on a 1280-wide window (~614 px)
## while the shell still fits its compact chrome.
const DOCK_MAP_SHARE := 0.48

var _dialog: Control
var _center: MarginContainer
var _section_host: MarginContainer
var _section_icon: IconBadge
var _section_title: Label
var _section_subtitle: Label
var _country_title: Label
var _country_subtitle: Label
var _country_mark: TextureRect
var _header_panel: PanelContainer
var _nav_rail: PanelContainer
var _page_surface: PanelContainer
var _nav_column: VBoxContainer
var _mobile_nav: ScrollContainer
var _nav_buttons: Dictionary = {}
var _mobile_nav_buttons: Dictionary = {}
var _technology_workspace: Control
var _economy_dossier: EconomyDossier
var _economy_workspace: Control
var _hinges: Control
var _ideology_workspace: Control
var _model: Dictionary = {}
var _section_id := ""
var _compact := false
var _docked := false
var _player_controller = null


func _ready() -> void:
	if _dialog != null:
		return
	name = "CountryPanel"
	_center = get_node_or_null("Center") as MarginContainer
	_dialog = get_node_or_null("Center/Dialog") as Control
	_nav_rail = get_node_or_null("Center/Dialog/Main/NavRail") as PanelContainer
	_nav_column = get_node_or_null("Center/Dialog/Main/NavRail/NavColumn") as VBoxContainer
	_page_surface = get_node_or_null("Center/Dialog/Main/PageSurface") as PanelContainer
	_mobile_nav = get_node_or_null("%MobileNav") as ScrollContainer
	_section_host = get_node_or_null("Center/Dialog/Main/PageSurface/PageArea/SectionHost") as MarginContainer
	_section_icon = get_node_or_null("Center/Dialog/Main/PageSurface/PageArea/Header/HeaderRow/SectionIcon") as IconBadge
	_section_title = get_node_or_null("Center/Dialog/Main/PageSurface/PageArea/Header/HeaderRow/SectionBlock/SectionTitle") as Label
	_section_subtitle = get_node_or_null("Center/Dialog/Main/PageSurface/PageArea/Header/HeaderRow/SectionBlock/SectionSubtitle") as Label
	_country_title = get_node_or_null("Center/Dialog/Main/PageSurface/PageArea/Header/HeaderRow/CountryBlock/CountryTitle") as Label
	_country_subtitle = get_node_or_null("Center/Dialog/Main/PageSurface/PageArea/Header/HeaderRow/CountryBlock/CountrySubtitle") as Label
	_country_mark = get_node_or_null("Center/Dialog/Main/PageSurface/PageArea/Header/HeaderRow/CountryMark") as TextureRect
	_header_panel = get_node_or_null("Center/Dialog/Main/PageSurface/PageArea/Header") as PanelContainer
	_technology_workspace = get_node_or_null("Center/Dialog/Main/PageSurface/PageArea/SectionHost/TechnologyWorkspace") as Control
	_economy_dossier = get_node_or_null("Center/Dialog/Main/PageSurface/PageArea/SectionHost/EconomyDossier") as EconomyDossier
	_economy_workspace = _economy_dossier.economy_workspace() if _economy_dossier != null else null
	_ideology_workspace = get_node_or_null("Center/Dialog/Main/PageSurface/PageArea/SectionHost/IdeologyWorkspace") as Control
	_hinges = get_node_or_null("Center/Dialog/Hinges") as Control
	var close_button := get_node_or_null("Center/Dialog/Main/PageSurface/PageArea/Header/HeaderRow/CloseButton") as Button
	if _center == null or _dialog == null or _section_host == null \
			or _nav_rail == null or _nav_column == null or _page_surface == null \
			or _mobile_nav == null \
			or _section_icon == null or _section_title == null \
			or _section_subtitle == null or _country_title == null \
			or _country_subtitle == null or _country_mark == null or _header_panel == null \
			or _technology_workspace == null or _economy_dossier == null or _economy_workspace == null \
			or _ideology_workspace == null or _hinges == null or close_button == null:
		push_error("CountryPanel 必须通过 country_panel.tscn 实例化。")
		return
	_country_mark.texture = IconCatalog.texture_for_key(&"family.workspace.crest")
	_country_mark.modulate = Color.WHITE
	_setup_navigation()
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭国家事务")
	close_button.pressed.connect(close_panel)
	var compact_close := get_node("%CompactClose") as Button
	IconButton.apply(compact_close, &"action.close", IconButton.SMALL, "关闭国家事务")
	compact_close.pressed.connect(close_panel)
	UIAnimation.bind_tactile_button(compact_close)
	_economy_dossier.locate_cell_requested.connect(func(cell): locate_cell_requested.emit(cell))
	if _ideology_workspace.has_signal("target_cells_requested"):
		_ideology_workspace.target_cells_requested.connect(
			func(cells: PackedInt32Array): target_cells_requested.emit(cells))
	_dialog.resized.connect(_place_hinges)
	call_deferred("_update_responsive_layout")


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _dialog != null:
		call_deferred("_update_responsive_layout")


func show_section(section_id: String, model: Dictionary) -> void:
	if _dialog == null:
		_ready()
	_model = model
	var was_open := visible and not has_meta("_ui_active_tween")
	_section_id = _normalized_section(section_id)
	_apply_section()
	visible = true
	if was_open:
		UIAnimation.crossfade(_section_host, UITokens.ANIM_FAST)
	else:
		modulate.a = 1.0
		# 窗口布局由锚点和容器负责；淡入同时取消尚未结束的关闭动画。
		UIAnimation.crossfade(self, UITokens.ANIM_MED)


func close_panel() -> void:
	if not visible:
		return
	UIAnimation.fade_slide_out(self, Vector2.ZERO, UITokens.ANIM_FAST)
	close_requested.emit()


func is_panel_open() -> bool:
	return visible


func set_player_controller(controller) -> void:
	_player_controller = controller
	if _technology_workspace != null and _technology_workspace.has_method("set_player_controller"):
		_technology_workspace.set_player_controller(controller)
	if _economy_dossier != null:
		_economy_dossier.set_player_controller(controller)
	if _ideology_workspace != null and _ideology_workspace.has_method("set_player_controller"):
		_ideology_workspace.set_player_controller(controller)


func current_section() -> String:
	return _section_id


## Dock the shell beside the map instead of over it.
##
## Only 「定位」 turns this on, and it exists for exactly one reason: a card's
## hit set is a thing you look at on the map, so closing the shell to reveal it
## threw away the card the player was reading. Docked, the map stays visible on
## the left, the highlight persists, and clicking another card repaints it
## without ever leaving the workspace.
##
## Docking also forces the compact chrome, because the shell is now narrower
## than the responsive breakpoint assumes. `_update_responsive_layout` derives
## that from the same `DOCK_MAP_SHARE`, so there is one place that decides what
## "docked is too narrow" means.
func set_docked(enabled: bool) -> void:
	if _docked == enabled:
		return
	_docked = enabled
	if is_inside_tree():
		call_deferred("_update_responsive_layout")
	else:
		_update_responsive_layout()


func is_docked() -> bool:
	return _docked


## Pure geometry, so the dock can be asserted without a live viewport: the
## shell's left edge, in viewport pixels, with `anchors_preset = 15` on the
## dialog. Split out because `_dialog.offset_left` cannot be read before
## `_ready` has run, and a layout rule that can only be checked by eye is a
## layout rule that drifts.
static func docked_offset_left(viewport_width: float) -> float:
	return maxf(16.0, viewport_width * (1.0 - DOCK_MAP_SHARE))


# Daily ticks only patch the visible workspace; long-lived controls stay alive
# so fast-forward never destroys a button or treasury row mid-read.
func refresh_summary(model: Dictionary) -> void:
	if not visible:
		return
	_model = model
	if _section_id == "technology" and _technology_workspace != null:
		_technology_workspace.refresh_research(model)
		return
	if _section_id == "economy" and _economy_dossier != null:
		_economy_dossier.refresh_model(model)
		return
	if _section_id == "ideology" and _ideology_workspace != null:
		_ideology_workspace.refresh_model(model)
		return
	_apply_section()


func layout_diagnostics() -> Dictionary:
	return {
		"visible": visible,
		"docked": _docked,
		"dialog_rect": Rect2(_dialog.global_position, _dialog.size) if _dialog != null else Rect2(),
		"viewport_rect": get_viewport().get_visible_rect() if is_inside_tree() else Rect2(),
		"window_size": get_window().size if get_window() != null else Vector2i.ZERO,
	}


func navigation_report() -> Dictionary:
	return {
		"desktop_visible": _nav_rail != null and _nav_rail.visible,
		"mobile_visible": _mobile_nav != null and _mobile_nav.visible,
		"active": _section_id,
		"desktop_count": _nav_buttons.size(),
		"mobile_count": _mobile_nav_buttons.size(),
	}


func _apply_section() -> void:
	var definition := _definition_for(_section_id)
	var accent: Color = definition.get("accent", UITokens.ACCENT)
	_section_icon.set_semantic(definition.get("icon", &"country.affairs"), accent)
	_section_title.text = String(definition.get("label", "国家"))
	_section_subtitle.text = String(definition.get("subtitle", ""))
	_section_title.add_theme_color_override("font_color", accent.lerp(UITokens.ARCHIVE_INK, 0.55))
	_country_title.text = String(_model.get("country_name", "国家事务"))
	_country_subtitle.text = _country_summary_line()
	_update_navigation_state()
	var technology_open := _section_id == "technology"
	var economy_open := _section_id == "economy"
	var ideology_open := _section_id == "ideology"
	_technology_workspace.visible = technology_open
	_economy_dossier.visible = economy_open
	_ideology_workspace.visible = ideology_open
	if technology_open:
		if _technology_workspace.has_method("set_player_controller"):
			_technology_workspace.set_player_controller(_player_controller)
		_technology_workspace.set_model(_model)
		_technology_workspace.set_compact(_compact)
		if _technology_workspace.has_method("reset_navigation"):
			_technology_workspace.reset_navigation()
		return
	if economy_open:
		_economy_dossier.set_player_controller(_player_controller)
		_economy_dossier.set_compact(_compact)
		_economy_dossier.set_model(_model)
		return
	if ideology_open:
		if _ideology_workspace.has_method("set_player_controller"):
			_ideology_workspace.set_player_controller(_player_controller)
		_ideology_workspace.set_model(_model)
		_ideology_workspace.set_compact(_compact)
		return


func _normalized_section(section_id: String) -> String:
	var definition := _definition_for(section_id)
	return section_id if bool(definition.get("available", false)) else "technology"


func _definition_for(section_id: String) -> Dictionary:
	for definition in SECTION_DEFINITIONS:
		if String(definition.id) == section_id:
			return definition
	return {}


func _setup_navigation() -> void:
	for definition in SECTION_DEFINITIONS:
		var section_id := String(definition.id)
		var node_name := section_id.capitalize()
		var desktop := _nav_column.get_node_or_null(node_name) as Button
		var mobile := _mobile_nav.get_node_or_null(
			"Buttons/%s" % node_name) as Button
		if desktop == null or mobile == null:
			continue
		var available := bool(definition.available)
		desktop.focus_mode = Control.FOCUS_NONE
		desktop.disabled = not available
		desktop.tooltip_text = String(definition.subtitle)
		var nav_icon_key: StringName = definition.get("hud_icon", definition.icon)
		var icon := desktop.get_node("Row/Icon") as TextureRect
		icon.texture = IconCatalog.texture_for_key(nav_icon_key)
		icon.modulate = Color.WHITE if available else Color(0.76, 0.72, 0.64, 0.48)
		var caption := desktop.get_node("Row/Caption") as Label
		caption.text = String(definition.label)
		mobile.focus_mode = Control.FOCUS_NONE
		mobile.disabled = not available
		mobile.tooltip_text = String(definition.subtitle)
		mobile.icon = IconCatalog.texture_for_key(nav_icon_key)
		mobile.add_theme_constant_override("icon_max_width", 22)
		if available:
			desktop.pressed.connect(_request_section.bind(section_id))
			mobile.pressed.connect(_request_section.bind(section_id))
		_nav_buttons[section_id] = desktop
		_mobile_nav_buttons[section_id] = mobile


func _request_section(section_id: String) -> void:
	if section_id == _section_id:
		return
	section_selected.emit(section_id)


func _update_navigation_state() -> void:
	for section_id in _nav_buttons:
		var desktop := _nav_buttons[section_id] as Button
		var mobile := _mobile_nav_buttons.get(section_id) as Button
		var active: bool = String(section_id) == _section_id
		if desktop != null and not desktop.disabled:
			desktop.button_pressed = active
		var caption := desktop.get_node_or_null("Row/Caption") as Label \
			if desktop != null else null
		if caption != null:
			caption.add_theme_color_override("font_color",
				Color("#fff0c8") if active else (
					Color("#3a2414") if not desktop.disabled else Color("#8a7a62")))
		var icon := desktop.get_node_or_null("Row/Icon") as TextureRect if desktop != null else null
		if icon != null and not desktop.disabled:
			icon.modulate = Color(1.08, 1.05, 0.98, 1.0) if active else Color.WHITE
		if mobile != null and not mobile.disabled:
			mobile.button_pressed = active


func _country_summary_line() -> String:
	var parts := PackedStringArray(["行政档案"])
	var territory := int(_model.get("territory_count", 0))
	var technologies := int(_model.get("technology_count", 0))
	var day := int(_model.get("current_day", -1))
	if territory > 0:
		parts.append("领土 %d" % territory)
	if technologies > 0:
		parts.append("科技 %d" % technologies)
	if day >= 0:
		parts.append("第 %d 日" % day)
	return " · ".join(parts)


func _update_responsive_layout() -> void:
	if _dialog == null or _center == null:
		return
	var viewport_size := get_viewport_rect().size
	var available_height := viewport_size.y - PlayerTopBar.BAR_HEIGHT \
		- CountryActionBar.BAR_HEIGHT - UITokens.ARCHIVE_EDGE_INSET * 2.0
	# Docking narrows the shell, so the responsive decision has to be made
	# against the width the shell actually gets — not the window's.
	var shell_width := viewport_size.x
	if _docked:
		shell_width = viewport_size.x - docked_offset_left(viewport_size.x)
		# The 16/80/-16/-90 offsets live on `Center`, not on `Dialog`: Center is
		# the full-rect margin row that positions the shell, and Dialog simply
		# fills it. Writing the offset on Dialog does nothing at all.
		_center.offset_left = docked_offset_left(viewport_size.x)
	else:
		_center.offset_left = 16.0
	# 字号缩放后的逻辑高度不足时折叠书脊，避免其最小高度把窗口顶进 HUD。
	_compact = shell_width < 900.0 or available_height < 520.0
	_dialog.custom_minimum_size = Vector2.ZERO
	_nav_rail.visible = not _compact
	_mobile_nav.visible = _compact
	(_mobile_nav.get_parent() as Control).visible = _compact
	_header_panel.visible = not _compact
	_country_title.add_theme_font_size_override("font_size", 22 if _compact else 30)
	var country_block := _country_title.get_parent() as Control
	if country_block != null:
		country_block.custom_minimum_size.x = 150.0 if _compact else 240.0
	_section_subtitle.visible = not _compact
	if _technology_workspace != null:
		_technology_workspace.set_compact(_compact)
	if _economy_dossier != null:
		_economy_dossier.set_compact(_compact)
	if _ideology_workspace != null:
		_ideology_workspace.set_compact(_compact)
	_place_hinges()


# 铜铰链压在书脊与纸页的接缝上；紧凑布局没有书脊，铰链随之隐藏。
func _place_hinges() -> void:
	if _hinges == null or _nav_rail == null:
		return
	_hinges.visible = _nav_rail.visible
	if not _hinges.visible:
		return
	var seam := _nav_rail.size.x
	var height := _dialog.size.y
	var ratios := [0.18, 0.5, 0.82]
	var children := _hinges.get_children()
	for i in range(mini(children.size(), ratios.size())):
		var hinge := children[i] as Control
		hinge.position = Vector2(seam - hinge.size.x * 0.5,
			round(height * float(ratios[i]) - hinge.size.y * 0.5))
