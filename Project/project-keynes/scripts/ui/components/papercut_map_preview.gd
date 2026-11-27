extends PanelContainer
class_name PapercutMapPreview

const CHART := preload("res://assets/ui/tabletop/chart.webp")

var _state: Dictionary = {
	"country_name": "",
	"foreign_count": 0,
	"map_width": 60,
	"map_height": 40,
	"seed": 0,
	"land_layout": "two",
	"land_layout_label": "",
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
var _has_state := false


func _ready() -> void:
	_canvas = get_node_or_null("Margin/Column/CanvasFrame/MapCanvas") as Control
	_title_label = get_node_or_null("Margin/Column/HeaderRow/Title") as Label
	_seed_badge = get_node_or_null("Margin/Column/HeaderRow/SeedBadge") as Label
	_scope_val = get_node_or_null("Margin/Column/SummaryGrid/ScopeBox/Value") as Label
	_land_val = get_node_or_null("Margin/Column/SummaryGrid/LandBox/Value") as Label
	_climate_val = get_node_or_null("Margin/Column/SummaryGrid/ClimateBox/Value") as Label
	_polity_val = get_node_or_null("Margin/Column/SummaryGrid/PolityBox/Value") as Label
	if _canvas != null:
		var sheet := TextureRect.new()
		sheet.texture = CHART
		sheet.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		sheet.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		sheet.mouse_filter = MOUSE_FILTER_IGNORE
		_canvas.add_child(sheet)
		sheet.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

		_stage = PaperAtlasStage.new()
		_stage.interactive_parallax = false
		_canvas.add_child(_stage)
		_stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_sync_stage()
	_refresh_labels()


func set_preview_state(next_state: Dictionary, animate_reveal: bool = false) -> void:
	for k in next_state:
		_state[k] = next_state[k]
	_has_state = true
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
		_sync_stage()
	_refresh_labels()


func _trigger_reveal() -> void:
	_sync_stage()
	if _stage == null:
		return
	if _reveal_tween != null and _reveal_tween.is_valid():
		_reveal_tween.kill()
	if UIAnimation.reduced_motion():
		_stage.reveal = 1.0
		_stage.scale.y = 1.0
		return
	_stage.pivot_offset = Vector2(0, _stage.size.y * 0.5)
	_stage.scale.y = 0.68
	_stage.reveal = 0.25
	_reveal_tween = create_tween().set_parallel(true)
	_reveal_tween.tween_property(_stage, "scale:y", 1.0, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_reveal_tween.tween_property(_stage, "reveal", 1.0, UITokens.MENU_PAGE_TRANSITION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _sync_stage() -> void:
	if _stage != null:
		_stage.set_layout_state(_state)


func _refresh_labels() -> void:
	if not _has_state:
		for label in [_seed_badge, _scope_val, _land_val, _climate_val, _polity_val]:
			if label != null:
				(label as Label).text = ""
		return
	var w := maxi(10, int(_state.get("map_width", 60)))
	var h := maxi(8, int(_state.get("map_height", 40)))
	var cells := w * h
	var is_pkmap := bool(_state.get("is_pkmap", false))
	var seed_num := int(_state.get("seed", 0))
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
			var layout_lbl := String(_state.get("land_layout_label", ""))
			var sea_pct := int(round(float(_state.get("sea_level", 0.50)) * 100.0))
			_land_val.text = "%s · 海平面 %d%%" % [layout_lbl, sea_pct] \
				if not layout_lbl.is_empty() else ""
	if _climate_val != null:
		var wet := int(_state.get("wetness", 55))
		var riv := int(_state.get("river_density", 55))
		_climate_val.text = "湿润 %d%% · 河流 %d%%" % [wet, riv]
	if _polity_val != null:
		var cname := String(_state.get("country_name", "")).strip_edges()
		var fcount := int(_state.get("foreign_count", 0))
		_polity_val.text = "%s · 外国 %d" % [cname, fcount] \
			if not cname.is_empty() else ""
