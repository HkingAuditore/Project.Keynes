extends Control
class_name CountryPanel

# Each country affair is a standalone full-bleed screen. The shell owns nothing
# but framing, so no screen inherits another domain's dossier chrome or tabs.
signal close_requested()
signal section_selected(section_id: String)

const SECTION_DEFINITIONS := [
	{"id": "technology", "label": "科技", "icon": &"country.technology", "accent": UITokens.CLIMATE, "available": true},
	{"id": "ideology", "label": "理念", "icon": &"country.politics", "accent": UITokens.ACCENT, "available": true},
	{"id": "economy", "label": "经济", "icon": &"country.economy", "accent": UITokens.RESOURCE, "available": true},
	{"id": "military", "label": "军事", "icon": &"country.military", "accent": UITokens.RISK, "available": false},
	{"id": "diplomacy", "label": "外交", "icon": &"country.diplomacy", "accent": UITokens.WATER, "available": false},
]
const HEADER_HEIGHT := 30.0

var _dialog: PanelContainer
var _center: MarginContainer
var _section_host: MarginContainer
var _section_icon: IconBadge
var _section_title: Label
var _technology_workspace: Control
var _economy_workspace: Control
var _ideology_workspace: Control
var _model: Dictionary = {}
var _section_id := ""
var _compact := false
var _player_controller = null


func _ready() -> void:
	if _dialog != null:
		return
	name = "CountryPanel"
	_center = get_node_or_null("Center") as MarginContainer
	_dialog = get_node_or_null("Center/Dialog") as PanelContainer
	_section_host = get_node_or_null("Center/Dialog/Content/SectionHost") as MarginContainer
	_section_icon = get_node_or_null("Center/Dialog/Content/Header/SectionIcon") as IconBadge
	_section_title = get_node_or_null("Center/Dialog/Content/Header/SectionTitle") as Label
	_technology_workspace = get_node_or_null("Center/Dialog/Content/SectionHost/TechnologyWorkspace") as Control
	_economy_workspace = get_node_or_null("Center/Dialog/Content/SectionHost/EconomyWorkspace") as Control
	_ideology_workspace = get_node_or_null("Center/Dialog/Content/SectionHost/IdeologyWorkspace") as Control
	var close_button := get_node_or_null("Center/Dialog/Content/Header/CloseButton") as Button
	if _center == null or _dialog == null or _section_host == null \
			or _section_icon == null or _section_title == null \
			or _technology_workspace == null or _economy_workspace == null or _ideology_workspace == null \
			or close_button == null:
		push_error("CountryPanel 必须通过 country_panel.tscn 实例化。")
		return
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭国家事务")
	close_button.pressed.connect(close_panel)
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


func set_player_controller(controller) -> void:
	_player_controller = controller
	if _technology_workspace != null and _technology_workspace.has_method("set_player_controller"):
		_technology_workspace.set_player_controller(controller)
	if _economy_workspace != null and _economy_workspace.has_method("set_player_controller"):
		_economy_workspace.set_player_controller(controller)
	if _ideology_workspace != null and _ideology_workspace.has_method("set_player_controller"):
		_ideology_workspace.set_player_controller(controller)


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
	if _section_id == "ideology" and _ideology_workspace != null:
		_ideology_workspace.refresh_model(model)
		return
	_apply_section()


func layout_diagnostics() -> Dictionary:
	return {
		"visible": visible,
		"dialog_rect": Rect2(_dialog.global_position, _dialog.size) if _dialog != null else Rect2(),
		"viewport_rect": get_viewport().get_visible_rect(),
		"window_size": get_window().size if get_window() != null else Vector2i.ZERO,
	}


func _apply_section() -> void:
	var definition := _definition_for(_section_id)
	var accent: Color = definition.get("accent", UITokens.ACCENT)
	_section_icon.set_semantic(definition.get("icon", &"country.affairs"), accent)
	_section_title.text = String(definition.get("label", "国家"))
	_section_title.add_theme_color_override("font_color", accent.lerp(UITokens.TEXT_MAIN, 0.55))
	var technology_open := _section_id == "technology"
	var economy_open := _section_id == "economy"
	var ideology_open := _section_id == "ideology"
	_technology_workspace.visible = technology_open
	_economy_workspace.visible = economy_open
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
		if _economy_workspace.has_method("set_player_controller"):
			_economy_workspace.set_player_controller(_player_controller)
		if _economy_workspace.has_method("set_compact"):
			_economy_workspace.set_compact(_compact)
		_economy_workspace.set_model(_model)
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


func _update_responsive_layout() -> void:
	if _dialog == null or _center == null:
		return
	var window_size := get_window().size if get_window() != null else Vector2i(_center.size)
	_compact = window_size.x < 900
	_dialog.custom_minimum_size = Vector2.ZERO
	if _technology_workspace != null:
		_technology_workspace.set_compact(_compact)
	if _economy_workspace != null and _economy_workspace.has_method("set_compact"):
		_economy_workspace.set_compact(_compact)
	if _ideology_workspace != null:
		_ideology_workspace.set_compact(_compact)
