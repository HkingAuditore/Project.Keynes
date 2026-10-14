extends PanelContainer
class_name PapercutMapPreview

const PapercutReliefShader := preload("res://shaders/papercut_relief_map.gdshader")

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
var _mat: ShaderMaterial
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
		_mat = ShaderMaterial.new()
		_mat.shader = PapercutReliefShader
		_mat.set_shader_parameter("map_center_bias", Vector2(0.50, 0.50))
		_mat.set_shader_parameter("compass_uv", Vector2(0.84, 0.78))
		_mat.set_shader_parameter("compass_scale", 0.14)
		_mat.set_shader_parameter("show_outer_frame", true)
		_canvas.material = _mat
		_canvas.draw.connect(_draw_map_canvas)
		_canvas.resized.connect(func() -> void: _canvas.queue_redraw())
	_sync_shader_params()
	_refresh_labels()
	if _canvas != null:
		_canvas.queue_redraw()


func set_preview_state(next_state: Dictionary, animate_reveal: bool = false) -> void:
	for k in next_state:
		_state[k] = next_state[k]
	var sig := "%s|%d|%d|%.2f|%.2f|%s" % [
		String(_state.get("land_layout", "")),
		int(_state.get("seed", 0)),
		int(_state.get("num_continents", 2)),
		float(_state.get("continent_size", 0.5)),
		float(_state.get("sea_level", 0.5)),
		str(bool(_state.get("is_pkmap", false))),
	]
	if (animate_reveal or sig != _last_layout_signature) and is_inside_tree():
		_last_layout_signature = sig
		_trigger_reveal()
	else:
		_sync_shader_params()
	_refresh_labels()
	if _canvas != null:
		_canvas.queue_redraw()


func _trigger_reveal() -> void:
	if _reveal_tween != null and _reveal_tween.is_valid():
		_reveal_tween.kill()
	_reveal = 0.35
	_sync_shader_params()
	_reveal_tween = create_tween()
	_reveal_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_reveal_tween.tween_method(
		func(v: float) -> void:
			_reveal = v
			if _mat != null:
				_mat.set_shader_parameter("reveal_progress", _reveal),
		0.35, 1.0, UITokens.ANIM_SLOW
	)


func _sync_shader_params() -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("seed_val", float(int(_state.get("seed", 1024)) % 10000))
	_mat.set_shader_parameter("num_continents", clampi(int(_state.get("num_continents", 2)), 1, 8))
	_mat.set_shader_parameter("continent_size", clampf(float(_state.get("continent_size", 0.50)), 0.2, 0.9))
	_mat.set_shader_parameter("sea_level", clampf(float(_state.get("sea_level", 0.50)), 0.1, 0.8))
	_mat.set_shader_parameter("continent_spacing", clampf(float(_state.get("continent_spacing", 92)) / 100.0, 0.0, 1.0))
	_mat.set_shader_parameter("island_amount", clampf(float(_state.get("island_amount", 38)) / 100.0, 0.0, 1.0))
	_mat.set_shader_parameter("wetness", clampf(float(_state.get("wetness", 55)) / 100.0, 0.0, 1.0))
	_mat.set_shader_parameter("river_density", clampf(float(_state.get("river_density", 55)) / 100.0, 0.0, 1.0))
	_mat.set_shader_parameter("lake_density", clampf(float(_state.get("lake_density", 45)) / 100.0, 0.0, 1.0))
	_mat.set_shader_parameter("reveal_progress", _reveal)


func _refresh_labels() -> void:
	var w := maxi(10, int(_state.get("map_width", 60)))
	var h := maxi(8, int(_state.get("map_height", 40)))
	var cells := w * h
	var is_pkmap := bool(_state.get("is_pkmap", false))
	var seed_num := int(_state.get("seed", 1))
	if _title_label != null:
		_title_label.text = "作者地图" if is_pkmap else "地图预览"
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


func _draw_map_canvas() -> void:
	if _canvas == null or _canvas.size.x <= 8.0 or _canvas.size.y <= 8.0:
		return
	if _mat != null:
		_mat.set_shader_parameter("viewport_size", _canvas.size)
	_canvas.draw_rect(Rect2(Vector2.ZERO, _canvas.size), Color.WHITE)
