extends GridContainer

const QualitySettings := preload("res://scripts/game/graphics_quality_settings.gd")
const TouchUI := preload("res://scripts/ui/touch_ui.gd")
const PRESET_LABELS := ["自动", "低", "中", "高", "自定义"]
const OPTION_LABELS := {
	"map_render_scale": ["地图清晰度", ["100%", "90%", "85%", "75%"]],
	"water_detail": ["水面细节", ["基础", "标准", "精细"]],
	"fog_render_scale": ["迷雾清晰度", ["50%", "75%", "100%"]],
	"vegetation_detail": ["植被与点缀", ["稀疏", "标准", "茂密"]],
	"weather_detail": ["天气表现", ["简洁", "标准", "精细"]],
	"cloud_shadow": ["地面云影", ["关闭", "开启"]],
	"frame_rate_limit": ["帧率上限", ["30 帧/秒", "60 帧/秒", "跟随屏幕", "操作 60 帧 / 静止 30 帧"]],
}

var _preset: OptionButton
var _fields: Dictionary = {}
var _draft: Dictionary = {}
var _mobile := false


func _ready() -> void:
	var preset_values := QualitySettings.PRESET_IDS.duplicate()
	preset_values.append("custom")
	_preset = _add_option("RenderQuality", "画质预设", PRESET_LABELS, preset_values)
	_preset.item_selected.connect(_on_preset_selected)
	var previous := _preset
	for key in OPTION_LABELS:
		var labels: Array = OPTION_LABELS[key]
		var field := _add_option(key.to_pascal_case(), labels[0], labels[1], QualitySettings.OPTION_VALUES[key])
		field.item_selected.connect(_on_custom_field_selected.bind(key))
		_fields[key] = field
		previous.focus_neighbor_bottom = previous.get_path_to(field)
		field.focus_neighbor_top = field.get_path_to(previous)
		previous = field


func configure(settings: Dictionary, mobile: bool = OS.has_feature("mobile") or DCFeatureFlags.is_mobile_web()) -> void:
	_draft = settings.duplicate()
	_mobile = mobile
	set_vsync_enabled(bool(settings.get("vsync", true)))
	_refresh_options()


func set_vsync_enabled(enabled: bool) -> void:
	var frame_rate: OptionButton = _fields.get("frame_rate_limit")
	if frame_rate != null:
		frame_rate.set_item_text(2, "跟随屏幕" if _mobile or enabled else "不限")


func settings_payload() -> Dictionary:
	var custom := bool(_draft.get("graphics_custom", false))
	var payload := {"render_quality": _draft.get("render_quality", "auto"), "graphics_custom": custom}
	if custom:
		var options := QualitySettings.resolve(_draft, _mobile)
		for key in _fields:
			payload[key] = options[key]
	return payload


func focus_preset() -> void:
	if is_visible_in_tree():
		_preset.grab_focus()


func _on_preset_selected(index: int) -> void:
	var preset: String = _preset.get_item_metadata(index)
	if preset == "custom":
		_use_custom_options()
	else:
		_draft["render_quality"] = preset
		_draft["graphics_custom"] = false
	_refresh_options()


func _on_custom_field_selected(index: int, key: String) -> void:
	_use_custom_options()
	_draft[key] = (_fields[key] as OptionButton).get_item_metadata(index)
	_select_value(_preset, "custom")


func _use_custom_options() -> void:
	if bool(_draft.get("graphics_custom", false)):
		return
	var options := QualitySettings.resolve(_draft, _mobile)
	for key in _fields:
		_draft[key] = options[key]
	_draft["graphics_custom"] = true


func _refresh_options() -> void:
	var options := QualitySettings.resolve(_draft, _mobile)
	var preset = "custom" if bool(_draft.get("graphics_custom", false)) else _draft.get("render_quality", "auto")
	_select_value(_preset, preset)
	for key in _fields:
		_select_value(_fields[key], options[key])


func _add_option(node_name: String, title: String, labels: Array, values: Array) -> OptionButton:
	var label := UIControlParts.label()
	label.theme_type_variation = &"PKDossierBody"
	label.text = title
	add_child(label)
	var option := UIControlParts.option_button()
	option.name = node_name
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for index in range(values.size()):
		option.add_item(labels[index])
		option.set_item_metadata(index, values[index])
	add_child(option)
	option.add_theme_color_override("font_focus_color", option.get_theme_color("font_color"))
	var touch_height := TouchUI.units(44.0)
	TouchUI.raise_min_size(option, touch_height)
	TouchUI.raise_popup_items(option.get_popup(), touch_height)
	return option


static func _select_value(option: OptionButton, value: Variant) -> void:
	for index in range(option.item_count):
		if option.get_item_metadata(index) == value:
			option.select(index)
			return
