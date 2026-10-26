extends Button
class_name ColonizationFamilyRow

var _icon: IconBadge
var _name: Label
var _badges: BadgeRow
var _effect: Label
var _population: Label
var _population_icon: IconBadge
var _family_name := ""
var _hovered := false
var _prestige_level := -1
var _tag_text := ""
var _tag_color := UITokens.DOSSIER_BRASS
var _bar_ratio := 0.0
var _bar_color := UITokens.DOSSIER_VERDIGRIS
var _empty_style := StyleBoxEmpty.new()
var _preview_loaded := false
var _base_summary := ""


func _ready() -> void:
	if _name != null:
		return
	_icon = get_node("Margin/Line/Icon") as IconBadge
	_name = get_node("Margin/Line/Info/Name") as Label
	_badges = get_node("Margin/Line/Info/Badges") as BadgeRow
	_effect = get_node("Margin/Line/Info/Effect") as Label
	_population = get_node("Margin/Line/Population") as Label
	_population_icon = get_node_or_null("Margin/Line/PopulationIcon") as IconBadge
	toggle_mode = true
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state_name in ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed"]:
		add_theme_stylebox_override(state_name, _empty_style)
	_population.add_theme_font_override("font", UITokens.font_with_weight(650))
	_population.add_theme_font_size_override("font_size", 15)
	_population.add_theme_color_override("font_color", UITokens.ARCHIVE_INK)
	if _population_icon != null:
		_population_icon.set_semantic(&"family.metric.population", UITokens.DOSSIER_OXBLOOD)
	_name.add_theme_font_size_override("font_size", 15)
	mouse_entered.connect(func() -> void:
		_hovered = true
		_sync_visual_state()
		queue_redraw())
	mouse_exited.connect(func() -> void:
		_hovered = false
		_sync_visual_state()
		queue_redraw())
	focus_entered.connect(func() -> void:
		_sync_visual_state()
		queue_redraw())
	focus_exited.connect(func() -> void:
		_sync_visual_state()
		queue_redraw())
	toggled.connect(func(_pressed: bool) -> void:
		_sync_visual_state()
		queue_redraw())


func set_row(data: Dictionary) -> void:
	if _name == null:
		_ready()
	_prestige_level = int(data.get("prestige_level", -1))
	var accent: Color = data.get("accent",
		UITokens.DOSSIER_OXBLOOD if _prestige_level >= 3 else (
			UITokens.DOSSIER_BRASS if _prestige_level >= 1 else UITokens.ACCENT))
	var default_icon := &"family.workspace.crest" if _prestige_level >= 1 else &"family.house"
	var icon_key := StringName(data.get("icon", default_icon))
	_icon.visible = true
	_icon.set_semantic(icon_key, accent)
	_family_name = String(data.get("name", "家族"))
	_name.text = _family_name
	var badges: Array = data.get("badges", [])
	_badges.visible = not badges.is_empty()
	_badges.mouse_filter = Control.MOUSE_FILTER_PASS
	_badges.set_badges(badges)
	var effect := String(data.get("effect", "")).strip_edges()
	_effect.text = _metric_copy(effect)
	_effect.visible = not effect.is_empty()
	_base_summary = effect
	_effect.visible = true
	var pop_text := String(data.get("population_text", ""))
	if pop_text.is_empty():
		pop_text = UITokens.format_compact_number_cn(
			float(data.get("population", 0)), 0)
	_population.text = pop_text
	_population.tooltip_text = ""
	if _population_icon != null:
		_population_icon.visible = not pop_text.is_empty()
	tooltip_text = String(data.get("tooltip", ""))
	_tag_text = String(data.get("tag_text", ""))
	_tag_color = data.get("tag_color", accent) as Color
	_bar_ratio = clampf(float(data.get("bar_ratio", 0.0)), 0.0, 1.0)
	_bar_color = data.get("bar_color", UITokens.DOSSIER_VERDIGRIS) as Color
	_sync_visual_state()
	queue_redraw()


func display_name() -> String:
	return _family_name


func set_compact_summary(data: Dictionary) -> void:
	set_row(data)
	custom_minimum_size.y = 48.0
	focus_mode = Control.FOCUS_ALL
	_icon.visible = true
	_icon.custom_minimum_size = Vector2(24.0, 24.0)
	_badges.visible = false
	_name.add_theme_font_size_override("font_size", 14)
	_population.add_theme_font_size_override("font_size", 14)
	_population.add_theme_color_override("font_color", UITokens.ARCHIVE_INK)
	_population.custom_minimum_size.x = 56.0
	if _population_icon != null:
		_population_icon.custom_minimum_size = Vector2(16.0, 16.0)
		_population_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_effect.add_theme_font_size_override("font_size", 12)
	_effect.autowrap_mode = TextServer.AUTOWRAP_OFF
	_effect.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_effect.max_lines_visible = 1
	var margin := get_node("Margin") as MarginContainer
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 5)
	# The compact directory reserves its second line for family identity, not a
	# floating prestige chip that can collide with long names.
	_tag_text = ""
	_preview_loaded = false
	_sync_visual_state()
	queue_redraw()


func apply_preview_summary(traits: Dictionary, effects: Dictionary) -> void:
	if _name == null:
		_ready()
	_preview_loaded = true
	var trait_names: PackedStringArray = traits.get("display_names", PackedStringArray())
	var effect_names: PackedStringArray = effects.get("effect_display_names", PackedStringArray())
	var current_copy: PackedStringArray = effects.get("effect_current_descriptions",
		effects.get("effect_descriptions", PackedStringArray()))
	var parts := PackedStringArray()
	if not trait_names.is_empty():
		parts.append(_join_head(trait_names, 2))
	if not effect_names.is_empty():
		var effect_text := String(effect_names[0])
		if not current_copy.is_empty():
			effect_text += " · " + _short_effect_copy(String(current_copy[0]))
		parts.append(effect_text)
	if not parts.is_empty():
		_effect.text = _metric_copy(" · ".join(parts))
		_effect.visible = true
	# The right-hand dossier is the single detailed reading surface. Avoid a
	# second native tooltip that can cover it and repeat the same family facts.
	tooltip_text = ""
	_sync_visual_state()
	queue_redraw()


func has_preview_summary() -> bool:
	return _preview_loaded


static func _join_head(values: PackedStringArray, limit: int) -> String:
	var head := PackedStringArray()
	for index in mini(values.size(), limit):
		var value := String(values[index]).strip_edges()
		if not value.is_empty():
			head.append(value)
	return " · ".join(head)


static func _short_effect_copy(value: String) -> String:
	var clean := value.strip_edges()
	var label_end := clean.find("：")
	if clean.begins_with("当地当前威望档") and label_end >= 0:
		clean = clean.substr(label_end + 1).strip_edges()
	if clean.length() > 28:
		clean = clean.substr(0, 27) + "…"
	return clean


func _sync_visual_state() -> void:
	if _name == null or _effect == null or _population == null:
		return
	var active := button_pressed and toggle_mode
	_effect.visible = true
	_name.add_theme_color_override("font_color",
		UITokens.ARCHIVE_PAPER_LIGHT if active else UITokens.ARCHIVE_INK)
	_effect.add_theme_color_override("font_color",
		Color(UITokens.ARCHIVE_PAPER_LIGHT, 0.86) if active else UITokens.ARCHIVE_INK_MUTED)
	_population.add_theme_color_override("font_color",
		UITokens.ARCHIVE_PAPER_LIGHT if active else UITokens.DOSSIER_OXBLOOD)
	if _population_icon != null:
		_population_icon.modulate = Color.WHITE if active else Color(1.0, 1.0, 1.0, 0.88)
	if not _preview_loaded:
		_effect.text = _metric_copy(_default_compact_effect())
	_sync_tooltip()


func _metric_copy(value: String) -> String:
	var parts := value.split("·", false)
	if parts.size() != 3:
		return value
	return "   ".join(parts)


func _sync_tooltip() -> void:
	tooltip_text = ""


func _draw() -> void:
	var rect := Rect2(Vector2(1.0, 1.0), Vector2(maxf(2.0, size.x - 2.0), maxf(2.0, size.y - 2.0)))
	var active := button_pressed and toggle_mode
	var bg := Color(UITokens.DOSSIER_PAPER, 0.86)
	var border := Color(UITokens.DOSSIER_RULE, 0.52)
	var border_w := 1.0
	if disabled:
		bg = Color(UITokens.DOSSIER_PAPER_DEEP, 0.52)
		border = Color(UITokens.DOSSIER_RULE, 0.28)
	elif active:
		bg = UITokens.DOSSIER_OXBLOOD
		border = UITokens.DOSSIER_BRASS
		border_w = 1.5
	elif _hovered or has_focus():
		bg = Color(0.985, 0.94, 0.83, 0.96)
		border = UITokens.DOSSIER_BRASS
		border_w = 1.2
	draw_rect(rect, bg, true)
	draw_rect(rect, border, false, border_w)

	if active:
		draw_rect(Rect2(Vector2(1.0, 2.0), Vector2(4.0, maxf(2.0, size.y - 4.0))),
			UITokens.DOSSIER_BRASS, true)
	elif _hovered or has_focus():
		draw_rect(Rect2(Vector2(1.0, 4.0), Vector2(3.0, maxf(2.0, size.y - 8.0))),
			UITokens.DOSSIER_BRASS, true)
	elif _prestige_level >= 1:
		var p_col := UITokens.DOSSIER_OXBLOOD if _prestige_level >= 3 else UITokens.DOSSIER_BRASS
		draw_rect(Rect2(Vector2(1.0, 6.0), Vector2(2.5, maxf(2.0, size.y - 12.0))),
			Color(p_col, 0.72), true)

	if _bar_ratio > 0.001:
		var bar_left := 44.0
		var bar_w := maxf(16.0, size.x - bar_left - 10.0)
		var bar_y := size.y - 4.0
		draw_rect(Rect2(Vector2(bar_left, bar_y), Vector2(bar_w, 2.2)),
			UITokens.DOSSIER_TRACK, true)
		var fill_c := UITokens.DOSSIER_OXBLOOD if active else _bar_color
		draw_rect(Rect2(Vector2(bar_left, bar_y), Vector2(bar_w * _bar_ratio, 2.2)),
			Color(fill_c, 0.88), true)

	if not _tag_text.is_empty() and _name != null and size.x >= 200.0 and not active:
		var font := UITokens.dossier_font("sans_strong")
		var name_w := font.get_string_size(_family_name, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14).x
		var tag_w := font.get_string_size(_tag_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10).x + 10.0
		var tag_x := 44.0 + name_w + 8.0
		var max_tag_right := size.x - 68.0
		if tag_x + tag_w <= max_tag_right:
			var pill_rect := Rect2(Vector2(tag_x, 6.0), Vector2(tag_w, 15.0))
			draw_rect(pill_rect, Color(_tag_color, 0.15), true)
			draw_rect(pill_rect, Color(_tag_color, 0.55), false, 1.0)
			draw_string(font, Vector2(tag_x + 5.0, 17.5), _tag_text,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, _tag_color.lerp(UITokens.DOSSIER_INK, 0.25))


func _default_compact_effect() -> String:
	return _base_summary
