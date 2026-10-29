extends PanelContainer

## Read-only presentation of catalog effects and committed native support facts.
const Art = preload("res://scripts/ui/components/ideology_art.gd")
const Q16 := 65536.0
const WIDTH := 448.0
const TITLE_FONT = preload("res://assets/fonts/annual_pencil/Muyao-Softbrush-2.ttf")

var _column: VBoxContainer
var _scroll: ScrollContainer


func _ready() -> void:
	# Godot wraps custom tooltips in its own panel. Keep one paper surface.
	var popup := get_parent() as PopupPanel
	if popup != null:
		popup.transparent_bg = true
		popup.add_theme_stylebox_override("panel", StyleBoxEmpty.new())


func setup(data: Dictionary) -> void:
	name = "IdeologyDetailTooltip"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_stylebox_override("panel", Art.paper_style(24.0))
	Art.attach_panel_shadow(self, 0.24, 24)
	_column = VBoxContainer.new()
	_column.custom_minimum_size.x = WIDTH
	_column.add_theme_constant_override("separation", 6)
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_column)
	_header(data)
	var progress: Dictionary = data.get("progress", {})
	if not progress.is_empty():
		_progress(progress, Art.school_color(String(data.get("school_id", ""))))
	_effects("当前效果", data.get("effects", PackedStringArray()), false)
	_effects("下一境 · %s" % String(data.get("next_level_label", "")),
		data.get("next_effects", PackedStringArray()), true)
	var supports: Array = data.get("supports", [])
	if not supports.is_empty():
		_rule()
		_caption("操作条件")
		for support in supports:
			_support(support)
		_copy("圆点表示当前评分，竖线表示门槛。评分按各阶层影响力加权。", 13, Art.INK_MUTED)
	var notes: PackedStringArray = data.get("notes", PackedStringArray())
	if not notes.is_empty():
		_rule()
		_caption("关联与限制")
		for note in notes:
			_copy(String(note), 14, Art.INK_MUTED)
	var tree := Engine.get_main_loop() as SceneTree
	var viewport_height := tree.root.get_visible_rect().size.y if tree != null else 720.0
	var cap := maxf(240.0, viewport_height - 64.0)
	_scroll = ScrollContainer.new()
	_scroll.name = "DetailScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size = Vector2(WIDTH + 16, minf(cap - 48, _estimate_height(data)))
	_column.reparent(_scroll)
	add_child(_scroll)
	_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func scroll_by(pixels: int) -> void:
	_scroll.scroll_vertical += pixels


func _estimate_height(data: Dictionary) -> float:
	var font := UITokens.dossier_font("sans")
	var height := 52.0
	if not (data.get("progress", {}) as Dictionary).is_empty():
		height += 40
	for key in ["effects", "next_effects"]:
		var lines: PackedStringArray = data.get(key, PackedStringArray())
		if not lines.is_empty():
			height += 32
			for line in lines:
				height += font.get_multiline_string_size(String(line), HORIZONTAL_ALIGNMENT_LEFT, WIDTH - 14, 15).y + 7
	var supports: Array = data.get("supports", [])
	if not supports.is_empty():
		height += 52 + 74 * supports.size()
	var notes: PackedStringArray = data.get("notes", PackedStringArray())
	if not notes.is_empty():
		height += 32
		for note in notes:
			height += font.get_multiline_string_size(String(note), HORIZONTAL_ALIGNMENT_LEFT, WIDTH, 14).y + 6
	return height


func _header(data: Dictionary) -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(head)
	var emblem := TextureRect.new()
	emblem.texture = Art.emblem_for(String(data.get("school_id", "")))
	emblem.custom_minimum_size = Vector2(42, 42)
	emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(emblem)
	var identity := VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.add_theme_constant_override("separation", 3)
	head.add_child(identity)
	var title := Art.label(String(data.get("name", "")), 25, Art.INK, HORIZONTAL_ALIGNMENT_LEFT)
	title.name = "DetailTitle"
	title.add_theme_font_override("font", TITLE_FONT)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	identity.add_child(title)
	var rarity := int(data.get("rarity", 1))
	identity.add_child(Art.label("%s · %s" % [
		Art.school_name(String(data.get("school_id", ""))),
		String(Art.RARITY_NAMES.get(rarity, ""))], 14, Art.INK_MUTED, HORIZONTAL_ALIGNMENT_LEFT))
	var status := String(data.get("status", ""))
	if not status.is_empty():
		var tag := Art.label(status, 14, Art.VERMILION)
		tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		head.add_child(tag)


func _progress(data: Dictionary, accent: Color) -> void:
	var line := HBoxContainer.new()
	line.add_child(Art.label("境界 · %s" % String(data.get("level_label", "")),
		15, Art.INK, HORIZONTAL_ALIGNMENT_LEFT))
	var amount := Art.label("已完成" if bool(data.get("maxed", false)) else "%s / %s" % [
		Art.q16(int(data.get("understanding_q16", 0))),
		Art.q16(int(data.get("threshold_q16", 0)))], 14, Art.INK_MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
	amount.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(amount)
	_column.add_child(line)
	var bar := ProgressBar.new()
	bar.name = "UnderstandingProgress"
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.show_percentage = false
	bar.max_value = 1.0
	bar.value = float(data.get("progress", 0))
	bar.custom_minimum_size.y = 7
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.38, 0.29, 0.18, 0.14)
	var fill := StyleBoxFlat.new()
	fill.bg_color = accent
	bar.add_theme_stylebox_override("background", background)
	bar.add_theme_stylebox_override("fill", fill)
	_column.add_child(bar)


func _effects(title: String, lines: PackedStringArray, future: bool) -> void:
	if lines.is_empty():
		return
	_rule()
	_caption(title)
	var rows := VBoxContainer.new()
	rows.name = "NextEffects" if future else "CurrentEffects"
	rows.add_theme_constant_override("separation", 7)
	_column.add_child(rows)
	for text in lines:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 9)
		var mark := ColorRect.new()
		mark.custom_minimum_size = Vector2(3, 16)
		mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mark.color = Color(Art.INK_MUTED, 0.28) if future else Art.school_color("learning")
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(mark)
		var copy := RichTextLabel.new()
		copy.bbcode_enabled = true
		copy.fit_content = true
		copy.scroll_active = false
		copy.mouse_filter = Control.MOUSE_FILTER_IGNORE
		copy.add_theme_font_override("normal_font", UITokens.dossier_font("sans"))
		copy.add_theme_font_override("bold_font", UITokens.dossier_font("sans_strong"))
		copy.add_theme_font_size_override("normal_font_size", 15)
		copy.add_theme_font_size_override("bold_font_size", 15)
		copy.add_theme_color_override("default_color", Art.INK_MUTED if future else Art.INK)
		copy.text = _number_emphasis(String(text))
		copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		copy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(copy)
		rows.add_child(row)


func _support(data: Dictionary) -> void:
	var available := bool(data.get("available", false))
	var passed := bool(data.get("allowed", false))
	var accent := Art.school_color("harmony") if passed else Art.VERMILION
	var row := HBoxContainer.new()
	row.name = "SupportRow"
	var action := Art.label(String(data.get("action", "")), 15, Art.INK,
		HORIZONTAL_ALIGNMENT_LEFT)
	action.custom_minimum_size.x = 48
	row.add_child(action)
	var result := Art.label("支持达标" if passed else "支持不足", 14, accent,
		HORIZONTAL_ALIGNMENT_RIGHT)
	result.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not available:
		result.text = "等待结算"
		result.add_theme_color_override("font_color", Art.INK_MUTED)
	row.add_child(result)
	_column.add_child(row)
	if not available:
		return
	var metrics := HBoxContainer.new()
	metrics.add_theme_constant_override("separation", 16)
	var score := int(data.get("support_q16", 0))
	var threshold := int(data.get("threshold_q16", 0))
	metrics.add_child(Art.label("当前评分  %+.2f" % (score / Q16), 14, accent,
		HORIZONTAL_ALIGNMENT_LEFT))
	var floor_label := Art.label("门槛  ≥ %+.2f" % (threshold / Q16),
		14, Art.INK_MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
	floor_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	metrics.add_child(floor_label)
	_column.add_child(metrics)
	var gauge := SupportGauge.new()
	gauge.name = "SupportGauge"
	gauge.custom_minimum_size.y = 14
	gauge.score = float(score) / Q16
	gauge.threshold = float(threshold) / Q16
	gauge.accent = accent
	gauge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(gauge)
	var reason := String(data.get("reason", ""))
	if not reason.is_empty():
		_copy(reason, 14, Art.VERMILION)


func _caption(text: String) -> void:
	var label := Art.label(text, 16, Art.INK, HORIZONTAL_ALIGNMENT_LEFT)
	label.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	_column.add_child(label)


func _copy(text: String, font_size: int, color: Color) -> void:
	var label := Art.label(text, font_size, color, HORIZONTAL_ALIGNMENT_LEFT)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_column.add_child(label)


func _rule() -> void:
	var line := HSeparator.new()
	var style := StyleBoxLine.new()
	style.color = Color(0.38, 0.26, 0.14, 0.18)
	style.thickness = 1
	line.add_theme_stylebox_override("separator", style)
	_column.add_child(line)


## Emphasis preserves authored strings verbatim; it never derives effect values.
func _number_emphasis(text: String) -> String:
	var pattern := RegEx.new()
	pattern.compile("[+-]?[0-9]+(?:\\.[0-9]+)?[%％]?")
	var result := ""
	var cursor := 0
	for match in pattern.search_all(text):
		result += text.substr(cursor, match.get_start() - cursor).replace("[", "[lb]")
		result += "[b]%s[/b]" % match.get_string()
		cursor = match.get_end()
	return result + text.substr(cursor).replace("[", "[lb]")


class SupportGauge:
	extends Control
	var score := 0.0
	var threshold := 0.0
	var accent := Color(0.2, 0.4, 0.3)

	func _draw() -> void:
		var y := size.y * 0.5
		var left := 3.0
		var width := maxf(1.0, size.x - 6)
		draw_line(Vector2(left, y), Vector2(left + width, y),
			Color(0.38, 0.29, 0.18, 0.18), 4, true)
		var score_x := left + width * (clampf(score, -1, 1) + 1) * 0.5
		var threshold_x := left + width * (clampf(threshold, -1, 1) + 1) * 0.5
		draw_line(Vector2(left + width * 0.5, y), Vector2(score_x, y), accent, 4, true)
		draw_line(Vector2(threshold_x, 1), Vector2(threshold_x, size.y - 1), Art.INK, 1, true)
		draw_circle(Vector2(score_x, y), 4, accent)
