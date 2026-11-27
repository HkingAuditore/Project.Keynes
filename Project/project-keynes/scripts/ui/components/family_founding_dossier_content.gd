extends RefCounted

## Builds the detailed metrics, traits, effects, and prestige rows in the founding dossier.


static func _tooltip_style(owner: FamilyFoundingCard) -> StyleBox:
	# Reuse the game's hand-drawn family card frame instead of introducing a
	# flat tooltip island that reads as a different UI material.
	var source := owner.get_theme_stylebox("panel", &"MenuChapterNormal")
	if source is StyleBoxTexture:
		var style := (source as StyleBoxTexture).duplicate() as StyleBoxTexture
		style.modulate_color = Color(1.0, 0.99, 0.96, 1.0)
		style.shadow_color = Color(0.08, 0.045, 0.02, 0.38)
		style.shadow_size = 10
		style.shadow_offset = Vector2(4.0, 6.0)
		return style
	var fallback := StyleBoxFlat.new()
	fallback.bg_color = Color(0.965, 0.925, 0.835, 0.985)
	fallback.border_color = Color(UITokens.DOSSIER_BRASS, 0.82)
	fallback.border_width_left = 1
	fallback.border_width_top = 1
	fallback.border_width_right = 1
	fallback.border_width_bottom = 2
	fallback.shadow_color = Color(0.10, 0.06, 0.025, 0.24)
	fallback.shadow_size = 8
	fallback.shadow_offset = Vector2(0.0, 4.0)
	return fallback



static func _add_tooltip_header(owner: FamilyFoundingCard, column: VBoxContainer) -> void:
	var header := UIControlParts.h_box_container()
	header.add_theme_constant_override("separation", 8)
	column.add_child(header)
	var icon := FamilyFoundingCard.IconScene.instantiate() as IconBadge
	icon.custom_minimum_size = Vector2(34, 34)
	icon.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	header.add_child(icon)
	icon.set_semantic(&"family.workspace.crest", UITokens.DOSSIER_OXBLOOD)
	var title_column := UIControlParts.v_box_container()
	title_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_column.add_theme_constant_override("separation", 0)
	header.add_child(title_column)
	var title := UIControlParts.label()
	title.text = String(owner._candidate.get("family_name", "家族"))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_override("font", UITokens.dossier_font("display"))
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	title_column.add_child(title)
	var origin := UIControlParts.label()
	origin.text = owner._origin_text(owner._candidate)
	origin.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	origin.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	origin.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	title_column.add_child(origin)



static func _add_tooltip_rule(owner: FamilyFoundingCard, column: VBoxContainer) -> void:
	var rule := HSeparator.new()
	column.add_child(rule)



static func _add_tooltip_metrics(owner: FamilyFoundingCard, column: VBoxContainer) -> void:
	var grid := UIControlParts.grid_container()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 2)
	column.add_child(grid)
	var has_cash := owner._candidate_cash(owner._candidate) >= 0.0
	var cash := owner._candidate_cash(owner._candidate)
	var metrics := [
		[&"family.metric.population", UITokens.format_compact_number_cn(
			float(owner._candidate.get("founders", 0)), 0), "", UITokens.DOSSIER_OXBLOOD],
		[&"metric.treasury", "—" if not has_cash
			else UITokens.format_compact_number_cn(cash, 2),
			"" if not has_cash else "万", UITokens.DOSSIER_BRASS],
		[&"economy.building", "%d" % int(owner._candidate.get("owned_buildings", 0)),
			"", UITokens.DOSSIER_UMBER],
		[&"family.workspace.prestige", owner._prestige_roman(int(owner._candidate.get("prestige_level", 0))),
			"", UITokens.DOSSIER_OXBLOOD if int(owner._candidate.get("prestige_level", 0)) >= 3
				else UITokens.DOSSIER_BRASS],
	]
	for metric in metrics:
		var cell := UIControlParts.v_box_container()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_theme_constant_override("separation", 0)
		grid.add_child(cell)
		var heading := UIControlParts.h_box_container()
		heading.add_theme_constant_override("separation", 3)
		cell.add_child(heading)
		owner._add_icon(heading, StringName(metric[0]), metric[3] as Color, 16.0)
		var value_row := UIControlParts.h_box_container()
		value_row.add_theme_constant_override("separation", 2)
		cell.add_child(value_row)
		var value := UIControlParts.label()
		value.text = String(metric[1])
		value.add_theme_font_override("font", owner._bold_font)
		value.add_theme_font_size_override("font_size", 20)
		value.add_theme_color_override("font_color", metric[3] as Color)
		value_row.add_child(value)
		var unit := UIControlParts.label()
		unit.text = String(metric[2])
		unit.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		unit.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
		unit.size_flags_vertical = Control.SIZE_SHRINK_END
		value_row.add_child(unit)



static func _add_tooltip_section(owner: FamilyFoundingCard, column: VBoxContainer, text: String) -> void:
	var row := UIControlParts.h_box_container()
	row.add_theme_constant_override("separation", 5)
	column.add_child(row)
	var key := &"family.workspace.effects" if text.contains("效果") else &"family.workspace.prestige"
	owner._add_icon(row, key, UITokens.DOSSIER_OXBLOOD, 18.0)
	var label := UIControlParts.label()
	label.text = text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_override("font", owner._bold_font)
	label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
	row.add_child(label)



static func _add_tooltip_traits(owner: FamilyFoundingCard, column: VBoxContainer) -> void:
	var items: Array = owner._candidate.get("trait_items", [])
	var names: PackedStringArray = owner._candidate.get("trait_display_names", PackedStringArray())
	var descriptions: PackedStringArray = owner._candidate.get("trait_descriptions", PackedStringArray())
	if items.is_empty():
		for index in names.size():
			items.append({"name": names[index],
				"description": descriptions[index] if index < descriptions.size() else ""})
	if items.is_empty():
		return
	for raw in items:
		var item: Dictionary = raw
		var row := UIControlParts.v_box_container()
		row.add_theme_constant_override("separation", 1)
		column.add_child(row)
		var heading := UIControlParts.h_box_container()
		heading.add_theme_constant_override("separation", 4)
		row.add_child(heading)
		owner._add_icon(heading, &"family.workspace.preferences", UITokens.DOSSIER_OXBLOOD, 16.0)
		var name := UIControlParts.label()
		name.text = String(item.get("name", "家风"))
		name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name.add_theme_font_override("font", owner._bold_font)
		name.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		name.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
		heading.add_child(name)
		var description := UIControlParts.rich_text_label()
		description.bbcode_enabled = true
		description.fit_content = true
		description.scroll_active = false
		description.custom_minimum_size.x = FamilyFoundingCard.DOSSIER_BODY_WIDTH - 20.0
		description.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		description.add_theme_font_override("normal_font", UITokens.dossier_font("sans"))
		description.add_theme_font_override("bold_font", owner._bold_font)
		description.add_theme_font_size_override("normal_font_size", UITokens.FONT_SMALL)
		description.add_theme_font_size_override("bold_font_size", UITokens.FONT_SMALL)
		description.add_theme_color_override("default_color", UITokens.DOSSIER_INK_SOFT)
		description.text = owner._emphasize(String(item.get("description", "")))
		row.add_child(description)



static func _add_tooltip_effects(owner: FamilyFoundingCard, column: VBoxContainer) -> void:
	var effect_title := String(owner._candidate.get("effect_display_name", "")).strip_edges()
	if effect_title.is_empty():
		effect_title = "独特效果"
	var tiers: PackedStringArray = owner._candidate.get("effect_prestige_descriptions", PackedStringArray())
	var presentation := FamilyFoundingCard.FamilyBuffCopyScript.founding_effect_rows(tiers)
	var ladder_rows: Array = presentation.get("rows", [])
	var context := String(presentation.get("context", "")).strip_edges()
	var current_level := maxi(0, int(owner._candidate.get("prestige_level", 0)))
	var title_text := effect_title
	if current_level > 0:
		title_text += "  ·  %s" % owner._prestige_roman(current_level)
	var effect_header := UIControlParts.h_box_container()
	effect_header.add_theme_constant_override("separation", 6)
	column.add_child(effect_header)
	owner._add_icon(effect_header, &"family.workspace.effects", UITokens.DOSSIER_VERDIGRIS, 20.0)
	var name := UIControlParts.label()
	name.text = title_text
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name.add_theme_font_override("font", UITokens.dossier_font("display"))
	name.add_theme_font_size_override("font_size", 19)
	name.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	effect_header.add_child(name)
	if not context.is_empty():
		var context_label := UIControlParts.label()
		context_label.text = context
		context_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		context_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		context_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
		column.add_child(context_label)
	# The ladder below already contains the active tier copy once, highlighted
	# in oxblood. Repeating that paragraph above the ladder makes the dossier
	# read like two different effects.
	if not ladder_rows.is_empty():
		return
	var current_text := owner._current_effect_body(owner._candidate)
	if not current_text.is_empty():
		var current := owner._rich_tooltip_copy()
		current.text = "[color=#%s][b]%s[/b][/color]" % [
			UITokens.DOSSIER_OXBLOOD.to_html(false), owner._emphasize(current_text)]
		column.add_child(current)
	else:
		var fallback := String(owner._candidate.get("effect_description", "")).strip_edges()
		if not fallback.is_empty():
			owner._add_tooltip_muted(column, fallback)



static func _add_tooltip_prestige_ladder(owner: FamilyFoundingCard, column: VBoxContainer) -> void:
	var tiers: PackedStringArray = owner._candidate.get("effect_prestige_descriptions", PackedStringArray())
	if tiers.is_empty():
		return
	var presentation := FamilyFoundingCard.FamilyBuffCopyScript.founding_effect_rows(tiers)
	var current_level := maxi(0, int(owner._candidate.get("prestige_level", 0)))
	var rows := UIControlParts.v_box_container()
	rows.add_theme_constant_override("separation", 3)
	column.add_child(rows)
	for raw in presentation.get("rows", []):
		var row: Dictionary = raw
		var line := UIControlParts.h_box_container()
		line.add_theme_constant_override("separation", 6)
		rows.add_child(line)
		var rank := UIControlParts.panel_container()
		rank.custom_minimum_size = Vector2(34.0, 24.0)
		rank.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		rank.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var is_current := int(row.get("level", 0)) == current_level
		var rank_paper := StyleBoxFlat.new()
		rank_paper.bg_color = (UITokens.DOSSIER_OXBLOOD if is_current
			else Color(UITokens.DOSSIER_OXBLOOD, 0.09))
		rank_paper.border_color = UITokens.DOSSIER_OXBLOOD if is_current \
			else Color(UITokens.DOSSIER_OXBLOOD, 0.5)
		rank_paper.border_width_left = 1
		rank_paper.border_width_top = 1
		rank_paper.border_width_right = 1
		rank_paper.border_width_bottom = 1
		rank_paper.corner_radius_top_left = 2
		rank_paper.corner_radius_top_right = 2
		rank_paper.corner_radius_bottom_left = 2
		rank_paper.corner_radius_bottom_right = 2
		rank_paper.content_margin_left = 4.0
		rank_paper.content_margin_right = 4.0
		rank_paper.content_margin_top = 1.0
		rank_paper.content_margin_bottom = 1.0
		rank.add_theme_stylebox_override("panel", rank_paper)
		line.add_child(rank)
		var level := UIControlParts.label()
		level.text = owner._prestige_roman(int(row.get("level", 1)))
		level.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		level.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		level.add_theme_font_override("font", owner._bold_font)
		level.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		level.add_theme_color_override("font_color",
			UITokens.DOSSIER_PAPER if is_current else UITokens.DOSSIER_OXBLOOD)
		rank.add_child(level)
		var copy := owner._rich_tooltip_copy()
		var body := owner._emphasize(String(row.get("body", "")))
		copy.text = body if not is_current else "[color=#%s][b]%s[/b][/color]" % [
			UITokens.DOSSIER_OXBLOOD.to_html(false), body]
		line.add_child(copy)



static func _rich_tooltip_copy(owner: FamilyFoundingCard) -> RichTextLabel:
	var copy := UIControlParts.rich_text_label()
	copy.bbcode_enabled = true
	copy.fit_content = true
	copy.scroll_active = false
	copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy.add_theme_font_override("normal_font", UITokens.dossier_font("sans"))
	copy.add_theme_font_override("bold_font", owner._bold_font)
	copy.add_theme_font_size_override("normal_font_size", UITokens.FONT_SMALL)
	copy.add_theme_font_size_override("bold_font_size", UITokens.FONT_SMALL)
	copy.add_theme_color_override("default_color", UITokens.DOSSIER_INK_SOFT)
	return copy



static func _add_tooltip_muted(owner: FamilyFoundingCard, column: VBoxContainer, text: String) -> void:
	var label := UIControlParts.label()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	column.add_child(label)



static func _prestige_roman(owner: FamilyFoundingCard, level: int) -> String:
	return ["—", "Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ"][clampi(level, 0, 5)]
