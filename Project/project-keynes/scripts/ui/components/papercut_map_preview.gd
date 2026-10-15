extends PanelContainer
class_name PapercutMapPreview

const SeaChartShader := preload("res://shaders/sea_chart_astrolabe.gdshader")

var _state: Dictionary = {
	"country_name": "新国家",
	"foreign_count": 5,
	"map_width": 60,
	"map_height": 40,
	"seed": 1024,
	"land_layout": "two",
	"land_layout_label": "两个大陆",
	"num_continents": 2,
	"continent_size": 0.50,
	"sea_level": 0.50,
	"continent_spacing": 92,
	"island_amount": 38,
	"wetness": 55,
	"lake_density": 45,
	"river_density": 55,
	"volcano_amount": 40,
	"is_pkmap": false,
	"pkmap_file": "",
	"pkmap_meta": "",
}

var _canvas: Control
var _sea_rect: ColorRect
var _sea_mat: ShaderMaterial
var _stage: PaperAtlasStage
var _title_label: Label
var _seed_badge: Label
var _scope_val: Label
var _land_val: Label
var _climate_val: Label
var _polity_val: Label
var _reveal := 1.0
var _reveal_tween: Tween
var _last_layout_signature := ""


func _ready() -> void:
	_canvas = get_node_or_null("Margin/Column/CanvasFrame/MapCanvas") as Control
	_title_label = get_node_or_null("Margin/Column/HeaderRow/Title") as Label
	_seed_badge = get_node_or_null("Margin/Column/HeaderRow/SeedBadge") as Label
	_scope_val = get_node_or_null("Margin/Column/SummaryGrid/ScopeBox/Value") as Label
	_land_val = get_node_or_null("Margin/Column/SummaryGrid/LandBox/Value") as Label
	_climate_val = get_node_or_null("Margin/Column/SummaryGrid/ClimateBox/Value") as Label
	_polity_val = get_node_or_null("Margin/Column/SummaryGrid/PolityBox/Value") as Label
	if _canvas != null:
		_sea_rect = ColorRect.new()
		_sea_rect.mouse_filter = MOUSE_FILTER_IGNORE
		_sea_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_sea_mat = ShaderMaterial.new()
		_sea_mat.shader = SeaChartShader
		_sea_mat.set_shader_parameter("compass_uv", Vector2(0.83, 0.25))
		_sea_mat.set_shader_parameter("compass_scale", 0.22)
		_sea_mat.set_shader_parameter("secondary_rose_uv", Vector2(0.18, 0.78))
		_sea_mat.set_shader_parameter("show_neatline", 1.0)
		_sea_rect.material = _sea_mat
		_canvas.add_child(_sea_rect)
		_canvas.resized.connect(_sync_canvas_shader)

		_stage = PaperAtlasStage.new()
		_stage.interactive_parallax = false
		_canvas.add_child(_stage)
		_stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_sync_canvas_shader()

	_sync_shader_params()
	_refresh_labels()


func _sync_canvas_shader() -> void:
	if _sea_mat != null and _canvas != null:
		_sea_mat.set_shader_parameter("viewport_size", _canvas.size.max(Vector2.ONE))
		_sea_mat.set_shader_parameter("motion_scale", 0.0 if UIAnimation.reduced_motion() else 1.0)


func set_preview_state(next_state: Dictionary, animate_reveal: bool = false) -> void:
	for k in next_state:
		_state[k] = next_state[k]
	var sig := "%s|%d|%d|%.2f|%.2f|%d|%d|%s" % [
		String(_state.get("land_layout", "")),
		int(_state.get("seed", 0)),
		int(_state.get("num_continents", 2)),
		float(_state.get("continent_size", 0.5)),
		float(_state.get("sea_level", 0.5)),
		int(_state.get("continent_spacing", 92)),
		int(_state.get("island_amount", 38)),
		str(bool(_state.get("is_pkmap", false))),
	]
	if (animate_reveal or sig != _last_layout_signature) and is_inside_tree():
		_last_layout_signature = sig
		_trigger_reveal()
	else:
		_sync_shader_params()
	_refresh_labels()


func _trigger_reveal() -> void:
	_sync_shader_params()
	if _stage == null:
		return
	if _reveal_tween != null and _reveal_tween.is_valid():
		_reveal_tween.kill()
	if UIAnimation.reduced_motion():
		_stage.reveal = 1.0
		return
	_stage.reveal = 0.25
	_reveal_tween = create_tween()
	_reveal_tween.tween_property(_stage, "reveal", 1.0, UITokens.MENU_PAGE_TRANSITION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _sync_shader_params() -> void:
	if _stage != null:
		_stage.set_layout_state(_state)
	if _sea_mat != null:
		_sea_mat.set_shader_parameter("seed_offset", float(int(_state.get("seed", 1)) % 1000))
		_sea_mat.set_shader_parameter("motion_scale", 0.0 if UIAnimation.reduced_motion() else 1.0)


func _refresh_labels() -> void:
	var w := maxi(10, int(_state.get("map_width", 60)))
	var h := maxi(8, int(_state.get("map_height", 40)))
	var cells := w * h
	var is_pkmap := bool(_state.get("is_pkmap", false))
	var seed_num := int(_state.get("seed", 1))
	if _title_label != null:
		_title_label.text = "地图预览"
	if _seed_badge != null:
		_seed_badge.text = "#%d" % seed_num
	if _scope_val != null:
		_scope_val.text = "%d × %d (%s 格)" % [w, h, UITokens.format_compact_number_cn(float(cells), 2)]
	if _land_val != null:
		if is_pkmap:
			var fname := String(_state.get("pkmap_file", ""))
			_land_val.text = fname if not fname.is_empty() else "未选择文件"
		else:
			var layout_lbl := String(_state.get("land_layout_label", "两个大陆"))
			var sea_pct := int(round(float(_state.get("sea_level", 0.50)) * 100.0))
			_land_val.text = "%s · 海平面 %d%%" % [layout_lbl, sea_pct]
	if _climate_val != null:
		var wet := int(_state.get("wetness", 55))
		var riv := int(_state.get("river_density", 55))
		_climate_val.text = "湿润 %d%% · 河流 %d%%" % [wet, riv]
	if _polity_val != null:
		var cname := String(_state.get("country_name", "新国家")).strip_edges()
		if cname.is_empty():
			cname = "新国家"
		var fcount := int(_state.get("foreign_count", 5))
		_polity_val.text = "%s · 外国 %d" % [cname, fcount]
