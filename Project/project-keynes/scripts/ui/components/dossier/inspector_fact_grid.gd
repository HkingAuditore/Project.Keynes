extends DossierChart
class_name InspectorFactGrid

## 地块卷宗事实表：两列“标签 / 数值 · 说明”，取代会被截断的指标卡网格。
## 数据形状沿用视图模型的 metrics（id/title/value/subtitle/icon/accent）。
## 每日补丁只改值：同 id 数值变化时该格短暂泛黄，不重建节点。

const ROW_HEIGHT := 62.0
const TWO_COLUMN_MIN_WIDTH := 300.0
const ICON_SIZE := 24.0
const FLASH_SECONDS := 0.9

var _facts: Array = []
var _values: Dictionary = {}
var _flash: Dictionary = {}
var _flash_tween: Tween
var _flash_level := 0.0


func _init() -> void:
	super()
	custom_minimum_size = Vector2(0.0, ROW_HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func set_facts(facts: Array) -> void:
	var changed := false
	var next_values := {}
	for raw in facts:
		var fact: Dictionary = raw
		var fact_id := String(fact.get("id", ""))
		var value := String(fact.get("value", ""))
		next_values[fact_id] = value
		if _values.has(fact_id) and String(_values[fact_id]) != value:
			_flash[fact_id] = true
			changed = true
	var first := _facts.is_empty()
	_facts = facts.duplicate()
	_values = next_values
	_update_height()
	if first:
		_start_animation()
	elif changed:
		_start_flash()
	queue_redraw()


func fact_count() -> int:
	return _facts.size()


func _columns() -> int:
	return 2 if size.x >= TWO_COLUMN_MIN_WIDTH or size.x <= 1.0 else 1


func _update_height() -> void:
	var rows := int(ceil(float(_facts.size()) / float(_columns())))
	custom_minimum_size.y = maxf(1.0, rows) * ROW_HEIGHT


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_height()


func _start_flash() -> void:
	if not is_inside_tree():
		_flash.clear()
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_level = 1.0
	_flash_tween = create_tween()
	_flash_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_flash_tween.tween_method(_set_flash_level, 1.0, 0.0, FLASH_SECONDS)
	_flash_tween.tween_callback(func() -> void: _flash.clear())


func _set_flash_level(value: float) -> void:
	_flash_level = value
	queue_redraw()


func _cell_rect(index: int) -> Rect2:
	var columns := _columns()
	var width := size.x / float(columns)
	return Rect2(Vector2(width * float(index % columns), ROW_HEIGHT * float(index / columns)),
		Vector2(width, ROW_HEIGHT))


func _get_tooltip(at_position: Vector2) -> String:
	for i in range(_facts.size()):
		if _cell_rect(i).has_point(at_position):
			var fact: Dictionary = _facts[i]
			var lines := PackedStringArray(["%s：%s" % [String(fact.get("title", "")),
				String(fact.get("value", ""))]])
			for key in ["subtitle", "tooltip"]:
				var extra := String(fact.get(key, ""))
				if extra != "":
					lines.append(extra)
			return "\n".join(lines)
	return ""


static func tone_color(accent: Color) -> Color:
	if accent.is_equal_approx(UITokens.RISK):
		return UITokens.DOSSIER_OXBLOOD
	if accent.is_equal_approx(UITokens.GOOD):
		return UITokens.DOSSIER_VERDIGRIS
	if accent.is_equal_approx(UITokens.WARN):
		return UITokens.DOSSIER_BRASS
	return UITokens.DOSSIER_INK


func _draw() -> void:
	var columns := _columns()
	var count := _facts.size()
	for i in range(count):
		var fact: Dictionary = _facts[i]
		var rect := _cell_rect(i)
		var appear := clampf(_grow * float(count + 2) - float(i), 0.0, 1.0) \
			if _has_grown else 1.0
		if appear <= 0.0:
			continue
		var lift := (1.0 - appear) * 6.0
		var fact_id := String(fact.get("id", ""))
		if _flash.has(fact_id) and _flash_level > 0.0:
			draw_rect(rect.grow(-2.0), Color(UITokens.DOSSIER_BRASS, 0.22 * _flash_level))
		var x := rect.position.x + 8.0
		var icon_key := IconBadge.normalize_icon(String(fact.get("icon", "")))
		var label_x := x
		if icon_key != "":
			_icon(StringName(icon_key), Rect2(Vector2(x, rect.position.y + 6.0 + lift),
				Vector2(ICON_SIZE, ICON_SIZE)), Color(UITokens.DOSSIER_INK_MUTED, appear))
			label_x += ICON_SIZE + 5.0
		var inner_right := rect.end.x - 8.0
		_text(Vector2(label_x, rect.position.y + 25.0 + lift),
			_fit_text(String(fact.get("title", "")), UITokens.FONT_SMALL, inner_right - label_x),
			UITokens.FONT_SMALL, Color(UITokens.DOSSIER_INK_MUTED, appear))
		var value := String(fact.get("value", ""))
		var value_color := tone_color(fact.get("accent", UITokens.ACCENT))
		var baseline := rect.position.y + 53.0 + lift
		var value_width := 0.0
		if bool(fact.get("money", false)):
			# 金额事实：数字前画金币，单位不写成字（见 MoneyDisplay）。
			var shown := _fit_text(value, 21,
				inner_right - x - MoneyDisplay.slot_width(21), "sans_strong")
			value_width = _money_text(Vector2(x, baseline), shown, 21,
				Color(value_color, appear), "sans_strong")
		else:
			var value_text := _fit_text(value, 21, inner_right - x, "sans_strong")
			_text(Vector2(x, baseline), value_text, 21, Color(value_color, appear), "sans_strong")
			value_width = _text_width(value_text, 21, "sans_strong")
		var subtitle := String(fact.get("subtitle", ""))
		if subtitle != "":
			var sub_x := x + value_width + 6.0
			if inner_right - sub_x > 60.0:
				_text(Vector2(sub_x, baseline - 1.0), _fit_text(subtitle, UITokens.FONT_SMALL, inner_right - sub_x),
					UITokens.FONT_SMALL, Color(UITokens.DOSSIER_INK_MUTED, appear))
		var row_count := int(ceil(float(count) / float(columns)))
		if i % columns == 0 and i / columns < row_count - 1:
			draw_line(Vector2(6.0, rect.end.y - 0.5), Vector2(size.x - 6.0, rect.end.y - 0.5),
				Color(UITokens.DOSSIER_RULE, 0.5 * appear), 1.0)
		if columns == 2 and i % 2 == 0 and i + 1 < count:
			draw_line(Vector2(rect.end.x - 0.5, rect.position.y + 8.0),
				Vector2(rect.end.x - 0.5, rect.end.y - 8.0), Color(UITokens.DOSSIER_RULE, 0.6), 1.0)
