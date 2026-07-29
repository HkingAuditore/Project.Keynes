extends Control
class_name CountryPanel

# Each country affair is a standalone full-bleed screen. The shell owns nothing
# but framing, so no screen inherits another domain's dossier chrome or tabs.
const TechnologyWorkspaceScript = preload("res://scripts/ui/components/technology_workspace.gd")
const EconomyWorkspaceScript = preload("res://scripts/ui/components/economy_workspace.gd")
const SectionPlaceholderScreenScript = preload(
	"res://scripts/ui/components/section_placeholder_screen.gd")

signal close_requested()
signal section_selected(section_id: String)

const SECTION_DEFINITIONS := [
	{"id": "technology", "label": "科技", "icon": &"country.technology", "accent": UITokens.CLIMATE},
	{"id": "politics", "label": "政治", "icon": &"country.politics", "accent": UITokens.ACCENT},
	{"id": "economy", "label": "经济", "icon": &"country.economy", "accent": UITokens.RESOURCE},
	{"id": "military", "label": "军事", "icon": &"country.military", "accent": UITokens.RISK},
	{"id": "diplomacy", "label": "外交", "icon": &"country.diplomacy", "accent": UITokens.WATER},
]
const HEADER_HEIGHT := 30.0

var _dialog: PanelContainer
var _center: MarginContainer
var _section_host: MarginContainer
var _section_icon: IconBadge
var _section_title: Label
var _technology_workspace: Control
var _economy_workspace: Control
var _placeholder: Control
var _model: Dictionary = {}
var _section_id := ""
var _compact := false


func _ready() -> void:
	if _dialog != null:
		return
	name = "CountryPanel"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var scrim := ColorRect.new()
	scrim.color = Color(0.008, 0.007, 0.006, 0.64)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)
	_center = MarginContainer.new()
	_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_center.offset_left = UITokens.SPACE_SM
	_center.offset_top = PlayerTopBar.BAR_HEIGHT + UITokens.SPACE_SM
	_center.offset_right = -UITokens.SPACE_SM
	_center.offset_bottom = -CountryActionBar.BAR_HEIGHT - UITokens.SPACE_SM
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)
	_dialog = PanelContainer.new()
	_dialog.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dialog.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var dialog_style := UITokens.panel_style(
		Color(0.048, 0.040, 0.032, 0.99), UITokens.RADIUS_MD, UITokens.BRASS_HIGHLIGHT)
	dialog_style.content_margin_left = UITokens.SPACE_MD
	dialog_style.content_margin_top = UITokens.SPACE_SM
	dialog_style.content_margin_right = UITokens.SPACE_MD
	dialog_style.content_margin_bottom = UITokens.SPACE_MD
	_dialog.add_theme_stylebox_override("panel", dialog_style)
	_center.add_child(_dialog)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", UITokens.SPACE_SM)
	_dialog.add_child(content)
	content.add_child(_build_header())
	_section_host = MarginContainer.new()
	_section_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_section_host)
	_technology_workspace = TechnologyWorkspaceScript.new()
	_technology_workspace.visible = false
	_section_host.add_child(_technology_workspace)
	_economy_workspace = EconomyWorkspaceScript.new()
	_economy_workspace.visible = false
	_section_host.add_child(_economy_workspace)
	_placeholder = SectionPlaceholderScreenScript.new()
	_placeholder.visible = false
	_section_host.add_child(_placeholder)
	call_deferred("_update_responsive_layout")


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _dialog != null:
		call_deferred("_update_responsive_layout")


func show_section(section_id: String, model: Dictionary) -> void:
	if _dialog == null:
		_ready()
	_model = model
	_section_id = _normalized_section(section_id)
	_apply_section()
	visible = true
	UIAnimation.crossfade(_dialog, UITokens.ANIM_MED)


func close_panel() -> void:
	if not visible:
		return
	UIAnimation.fade_slide_out(self, Vector2.ZERO, UITokens.ANIM_FAST)
	close_requested.emit()


func is_panel_open() -> bool:
	return visible


func current_section() -> String:
	return _section_id


# Daily ticks only patch the visible workspace; long-lived controls stay alive
# so fast-forward never destroys a button or treasury row mid-read.
func refresh_summary(model: Dictionary) -> void:
	if not visible:
		return
	_model = model
	if _section_id == "technology" and _technology_workspace != null:
		_technology_workspace.refresh_research(model)
		return
	if _section_id == "economy" and _economy_workspace != null:
		_economy_workspace.refresh_model(model)
		return
	_apply_section()


func layout_diagnostics() -> Dictionary:
	return {
		"visible": visible,
		"dialog_rect": Rect2(_dialog.global_position, _dialog.size) if _dialog != null else Rect2(),
		"viewport_rect": get_viewport().get_visible_rect(),
		"window_size": get_window().size if get_window() != null else Vector2i.ZERO,
	}


func _build_header() -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = HEADER_HEIGHT
	row.add_theme_constant_override("separation", UITokens.SPACE_SM)
	_section_icon = IconBadge.new()
	_section_icon.custom_minimum_size = Vector2(26.0, 26.0)
	_section_icon.set_semantic(&"country.technology", UITokens.CLIMATE)
	row.add_child(_section_icon)
	_section_title = Label.new()
	_section_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_section_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_section_title.add_theme_font_override("font", UITokens.font_with_weight(700))
	_section_title.add_theme_font_size_override("font_size", UITokens.FONT_VALUE)
	row.add_child(_section_title)
	var close_button := Button.new()
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.custom_minimum_size = Vector2(30.0, 26.0)
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭国家事务")
	close_button.pressed.connect(close_panel)
	row.add_child(close_button)
	return row


func _apply_section() -> void:
	var definition := _definition_for(_section_id)
	var accent: Color = definition.get("accent", UITokens.ACCENT)
	_section_icon.set_semantic(definition.get("icon", &"country.affairs"), accent)
	_section_title.text = String(definition.get("label", "国家"))
	_section_title.add_theme_color_override("font_color", accent.lerp(UITokens.TEXT_MAIN, 0.55))
	var technology_open := _section_id == "technology"
	var economy_open := _section_id == "economy"
	_technology_workspace.visible = technology_open
	_economy_workspace.visible = economy_open
	_placeholder.visible = not technology_open and not economy_open
	if technology_open:
		_technology_workspace.set_model(_model)
		_technology_workspace.set_compact(_compact)
		return
	if economy_open:
		_economy_workspace.set_model(_model)
		return
	_placeholder.set_section(String(definition.get("label", "国家")),
		definition.get("icon", &"country.affairs"), accent)


func _normalized_section(section_id: String) -> String:
	return section_id if not _definition_for(section_id).is_empty() else "technology"


func _definition_for(section_id: String) -> Dictionary:
	for definition in SECTION_DEFINITIONS:
		if String(definition.id) == section_id:
			return definition
	return {}


func _update_responsive_layout() -> void:
	if _dialog == null or _center == null:
		return
	var window_size := get_window().size if get_window() != null else Vector2i(_center.size)
	_compact = window_size.x < 900
	_dialog.custom_minimum_size = Vector2.ZERO
	if _technology_workspace != null:
		_technology_workspace.set_compact(_compact)
