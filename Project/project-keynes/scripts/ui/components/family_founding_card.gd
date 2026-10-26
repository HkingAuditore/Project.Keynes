extends PanelContainer
class_name FamilyFoundingCard

const FamilyBuffCopyScript = preload("res://scripts/family/family_buff_copy.gd")
const TextRowScene = preload("res://scenes/ui/family/family_founding_text_row.tscn")
const IconScene = preload("res://scenes/ui/icon_badge.tscn")
const DOSSIER_WIDTH := 388.0
const DOSSIER_MAX_HEIGHT := 560.0
const DOSSIER_BODY_WIDTH := 344.0
const DOSSIER_SCREEN_MARGIN := 18.0
const DOSSIER_SAFE_TOP := 52.0

signal selected()
signal details_requested()

@onready var _icon: IconBadge = %Icon
@onready var _title: Label = %Title
@onready var _origin: Label = %Origin
@onready var _population: Label = %Population
@onready var _population_icon: IconBadge = %PopulationIcon
@onready var _trait_icon: IconBadge = %TraitIcon
@onready var _effect_kicker_icon: IconBadge = %EffectKickerIcon
@onready var _trait_summary: Label = %TraitSummary
@onready var _effect_preview: RichTextLabel = %EffectPreview
@onready var _meta: Label = %Meta
@onready var _badges: BadgeRow = %Badges
@onready var _traits_list: VBoxContainer = %TraitsList
@onready var _effect_title: Label = %EffectTitle
@onready var _effect_tiers_box: VBoxContainer = %EffectTiersBox
@onready var _effect_context: RichTextLabel = %EffectContext
@onready var _details_clip: Control = %DetailsClip
@onready var _details_content: VBoxContainer = %DetailsContent
@onready var _details_toggle: Button = %DetailsToggle
@onready var _choose: Button = %Choose

var _candidate := {}
var _candidate_empty := true
var _details_expanded := false
var _details_revision := 0
var _details_preparing := false
var _normal_style: StyleBox
var _hover_style: StyleBox
var _bold_font: FontVariation
var _dossier_popup: PanelContainer
var _dossier_popup_revision := 0
var _dossier_hide_timer: Timer


func _ready() -> void:
	_bold_font = UITokens.font_with_weight(760)
	_bold_font.variation_embolden = 0.6
	_style_copy(_effect_preview)
	_style_copy(_effect_context)
	%Population.tooltip_text = ""
	%TraitSummary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	%EffectPreview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	%Meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_population_icon.set_semantic(&"family.metric.population", UITokens.DOSSIER_OXBLOOD)
	_trait_icon.set_semantic(&"family.workspace.preferences", UITokens.DOSSIER_OXBLOOD)
	_effect_kicker_icon.set_semantic(&"family.workspace.effects", UITokens.DOSSIER_VERDIGRIS)
	(%EffectIcon as IconBadge).set_semantic(&"family.workspace.effects", UITokens.DOSSIER_OXBLOOD)
	_normal_style = get_theme_stylebox("panel", &"PKDossierNote").duplicate()
	_hover_style = _normal_style.duplicate()
	if _hover_style is StyleBoxTexture:
		(_hover_style as StyleBoxTexture).modulate_color = UITokens.ARCHIVE_BUTTON_HOVER
	elif _hover_style is StyleBoxFlat:
		(_hover_style as StyleBoxFlat).border_color = UITokens.ARCHIVE_BRASS
	add_theme_stylebox_override("panel", _normal_style)
	_choose.pressed.connect(func() -> void: selected.emit())
	_details_toggle.pressed.connect(func() -> void: details_requested.emit())
	_details_toggle.text = "▾"
	_details_toggle.add_theme_font_size_override("font_size", 18)
	_details_toggle.add_theme_color_override("font_color", UITokens.ARCHIVE_INK_MUTED)
	_details_toggle.add_theme_color_override("font_hover_color", UITokens.DOSSIER_OXBLOOD)
	for button in [_details_toggle, _choose]:
		button.focus_entered.connect(func() -> void: _update_highlight(true))
		button.focus_exited.connect(func() -> void: _update_highlight(false))
		UIAnimation.bind_hover_glow(button)
		button.mouse_entered.connect(func() -> void: _cancel_dossier_hide())
	mouse_entered.connect(func() -> void: _update_highlight(true))
	mouse_exited.connect(func() -> void: _update_highlight(false))
	mouse_entered.connect(_show_dossier_popup)
	mouse_exited.connect(_schedule_dossier_hide)
	_dossier_hide_timer = Timer.new()
	_dossier_hide_timer.one_shot = true
	_dossier_hide_timer.wait_time = 0.08
	_dossier_hide_timer.timeout.connect(_hide_dossier_popup)
	add_child(_dossier_hide_timer)
	_details_content.minimum_size_changed.connect(_schedule_detail_fit)
	resized.connect(_schedule_detail_fit)
	_details_toggle.add_theme_color_override("font_focus_color", UITokens.ARCHIVE_INK)
	_apply_readability_overrides()
	tree_exiting.connect(_hide_dossier_popup)


func _apply_readability_overrides() -> void:
	_title.add_theme_color_override("font_color", UITokens.ARCHIVE_INK)
	_origin.add_theme_color_override("font_color", UITokens.ARCHIVE_INK_MUTED)
	_population.add_theme_color_override("font_color", UITokens.ARCHIVE_OXBLOOD)
	_trait_summary.add_theme_color_override("font_color", UITokens.ARCHIVE_INK)
	_effect_preview.add_theme_color_override("default_color", UITokens.ARCHIVE_INK_MUTED)
	_meta.add_theme_color_override("font_color", UITokens.ARCHIVE_INK_MUTED)


func _update_highlight(hovered: bool) -> void:
	var active := not _candidate_empty and (hovered or _details_expanded
		or _choose.has_focus() or _details_toggle.has_focus())
	add_theme_stylebox_override("panel", _hover_style if active else _normal_style)


func set_candidate(candidate: Dictionary) -> void:
	_candidate = candidate.duplicate(true)
	_candidate_empty = candidate.is_empty()
	if _candidate_empty:
		_hide_dossier_popup()
	set_details_expanded(false, false)
	_icon.set_semantic(&"family.workspace.crest" if not _candidate_empty else &"family.house",
		UITokens.DOSSIER_OXBLOOD)
	if _candidate_empty:
		_title.text = "暂无候选"
		_origin.text = "当前没有可扶持的家族。"
		_population.text = "—"
		_trait_summary.text = "—"
		_effect_preview.text = "—"
		_meta.text = ""
		_badges.visible = false
		_clear_rows(_traits_list)
		_add_copy(_traits_list, "暂无已登记的家风偏好")
		_clear_rows(_effect_tiers_box)
		_add_copy(_effect_tiers_box, "不携带额外家族效果。")
		_effect_title.text = "家族效果"
		_effect_context.visible = false
		_choose.disabled = true
		_details_toggle.disabled = true
		_update_highlight(false)
		return

	_title.text = String(candidate.get("family_name", "未命名家族"))
	_origin.text = _origin_text(candidate)
	_population.text = UITokens.format_compact_number_cn(
		float(candidate.get("founders", 0)), 0)
	_population.tooltip_text = ""
	_trait_summary.text = _trait_names_text(candidate)
	_effect_preview.text = _effect_summary_bbcode(candidate, true)
	_meta.text = _meta_text(candidate)
	var meta_badges := _meta_badges(candidate)
	_badges.visible = not meta_badges.is_empty()
	if _badges.visible:
		_badges.set_badges(meta_badges)
	_refresh_details(candidate)
	_choose.disabled = _candidate_empty
	_details_toggle.disabled = _candidate_empty
	_choose.text = String(candidate.get("choice_label", "扶持此家族"))
	_choose.tooltip_text = String(candidate.get("choice_tooltip",
		"扶持「%s」在本地立族，其余两户将不再出现。" % _title.text))
	_update_highlight(false)


func _origin_text(candidate: Dictionary) -> String:
	var parts := PackedStringArray()
	var building := String(candidate.get("building_display_name", "")).strip_edges()
	var profession := String(candidate.get("owner_profession_display_name", "")).strip_edges()
	if not building.is_empty():
		parts.append(building)
	if not profession.is_empty():
		parts.append(profession)
	return " · ".join(parts) if not parts.is_empty() else "待立新族"


func _trait_names_text(candidate: Dictionary) -> String:
	var names: PackedStringArray = candidate.get("trait_display_names", PackedStringArray())
	var items: Array = candidate.get("trait_items", [])
	if names.is_empty():
		for item in items:
			if item is Dictionary:
				var name := String(item.get("name", "")).strip_edges()
				if not name.is_empty():
					names.append(name)
	return " · ".join(names) if not names.is_empty() else "尚无可考家风"


func _effect_short_text(candidate: Dictionary) -> String:
	var description := _current_effect_body(candidate)
	for prefix in ["成功开拓时，新地块会获得以下效果：", "成功开拓时，新地块获得以下效果：",
			"该家族分支所在的本地块会持续获得以下效果：", "该家族所在的本地块会持续获得以下效果："]:
		description = description.trim_prefix(prefix)
	var colon := description.find("：")
	if colon >= 0 and colon < 32:
		description = description.substr(colon + 1).strip_edges()
	if description.length() > 44:
		description = description.substr(0, 43) + "…"
	return description


func _current_effect_body(candidate: Dictionary) -> String:
	var tiers: PackedStringArray = candidate.get("effect_prestige_descriptions", PackedStringArray())
	if tiers.is_empty():
		tiers = FamilyBuffCopyScript.prestige_statements(
			String(candidate.get("effect_description", "")))
	var level := maxi(1, int(candidate.get("prestige_level", 1)))
	var presentation := FamilyBuffCopyScript.founding_effect_rows(tiers)
	for row in presentation.get("rows", []):
		if int(row.get("level", 0)) == level:
			return String(row.get("body", "")).strip_edges()
	return ""


func _meta_text(candidate: Dictionary) -> String:
	var parts := PackedStringArray()
	var cash := _candidate_cash(candidate)
	if cash >= 0.0:
		parts.append("现银 %s 万" % UITokens.format_compact_number_cn(cash, 2))
	var buildings := int(candidate.get("owned_buildings", 0))
	if buildings > 0:
		parts.append("产业 %d" % buildings)
	var assignable := int(candidate.get("assignable_population",
		candidate.get("available_population", -1)))
	if assignable >= 0:
		parts.append("可派 %s 人" % UITokens.format_compact_number_cn(float(assignable), 0))
	return " · ".join(parts)


func _meta_badges(candidate: Dictionary) -> Array:
	var badges: Array = []
	var prestige := int(candidate.get("prestige_level", 0))
	if prestige > 0:
		badges.append({
			"text": "威望 %s" % _prestige_roman(prestige),
			"accent": UITokens.DOSSIER_OXBLOOD if prestige >= 3 else UITokens.DOSSIER_BRASS,
			"tooltip": "当前家族威望档位",
		})
	return badges


func _candidate_cash(candidate: Dictionary) -> float:
	if candidate.has("cash_claim"):
		return maxf(0.0, float(candidate.get("cash_claim", 0)) / 10000.0)
	if candidate.has("cash"):
		return maxf(0.0, float(candidate.get("cash", 0)) / 10000.0)
	return -1.0


func _refresh_details(candidate: Dictionary) -> void:
	var names: PackedStringArray = candidate.get("trait_display_names", PackedStringArray())
	var descriptions: PackedStringArray = candidate.get("trait_descriptions", PackedStringArray())
	var items: Array = candidate.get("trait_items", [])
	if names.is_empty():
		for item in items:
			if item is Dictionary:
				names.append(String(item.get("name", "")))
	_clear_rows(_traits_list)
	if not items.is_empty():
		for item in items:
			if item is Dictionary:
				_add_trait_row(item)
	else:
		for index in names.size():
			_add_trait_row({
				"name": names[index],
				"description": descriptions[index] if index < descriptions.size() else "",
			})
	if _traits_list.get_child_count() == 0:
		_add_copy(_traits_list, "暂无已登记的家风偏好")
	var effect_name := String(candidate.get("effect_display_name", "")).strip_edges()
	var raw_description := String(candidate.get("effect_description", "")).strip_edges()
	var tiers: PackedStringArray = candidate.get("effect_prestige_descriptions", PackedStringArray())
	if tiers.is_empty() and not raw_description.is_empty():
		tiers = FamilyBuffCopyScript.prestige_statements(raw_description)
	_effect_title.text = "家族效果 · %s" % effect_name if not effect_name.is_empty() else "家族效果"
	_clear_rows(_effect_tiers_box)
	var presentation := FamilyBuffCopyScript.founding_effect_rows(tiers)
	var context := String(presentation.get("context", ""))
	_effect_context.visible = not context.is_empty()
	_effect_context.text = "[b]生效条件[/b]  %s" % _escape_copy(context)
	for row in presentation.get("rows", []):
		if not String(row.get("body", "")).is_empty():
			_add_effect_row(row)
	if _effect_tiers_box.get_child_count() == 0:
		_add_copy(_effect_tiers_box, raw_description if not raw_description.is_empty() else "不携带额外家族效果。")


func _effect_summary_bbcode(candidate: Dictionary, compact: bool) -> String:
	var effect_name := String(candidate.get("effect_display_name", "")).strip_edges()
	var description := _effect_short_text(candidate) if compact \
		else _current_effect_description(candidate)
	if effect_name.is_empty() and description.is_empty():
		return "[color=#%s]不携带额外家族效果[/color]" % UITokens.ARCHIVE_INK_MUTED.to_html(false)
	var safe_name := "[b]%s[/b]" % _escape_copy(effect_name) if not effect_name.is_empty() else ""
	var safe_copy := _emphasize(description)
	if safe_name.is_empty():
		return safe_copy
	if safe_copy.is_empty():
		return safe_name
	if compact:
		return "%s  [color=#%s]·[/color]  %s" % [
			safe_name, UITokens.DOSSIER_BRASS.to_html(false), safe_copy]
	return "%s\n%s" % [safe_name, safe_copy]


func _current_effect_description(candidate: Dictionary) -> String:
	var tiers: PackedStringArray = candidate.get("effect_prestige_descriptions", PackedStringArray())
	var level := maxi(1, int(candidate.get("prestige_level", 1)))
	if not tiers.is_empty():
		var statement := String(FamilyBuffCopyScript.statement_for_prestige(tiers, level)).strip_edges()
		if not statement.is_empty():
			return statement
	var raw := String(candidate.get("effect_description", "")).strip_edges()
	if raw.is_empty():
		raw = FamilyBuffCopyScript.founding_effect_preview(tiers,
			String(candidate.get("effect_full_description", "")))
	if raw.begins_with("当前未达威望"):
		return ""
	var label_end := raw.find("：")
	if raw.begins_with("威望") and label_end >= 0:
		raw = raw.substr(label_end + 1)
	return raw


func _clear_rows(container: Container) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _add_trait_row(item: Dictionary) -> void:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", UITokens.SPACE_XS)
	_traits_list.add_child(row)
	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", UITokens.SPACE_XS)
	row.add_child(heading)
	_add_icon(heading, &"family.workspace.preferences", UITokens.DOSSIER_SLATE)
	var title := _rich_copy()
	title.text = "[b]%s[/b]" % _escape_copy(String(item.get("name", "家风")))
	heading.add_child(title)
	var factor := float(item.get("factor_percent", 0.0))
	if factor > 0.0:
		var factor_label := Label.new()
		factor_label.text = "%d%%" % int(round(factor))
		factor_label.add_theme_font_override("font", _bold_font)
		factor_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		factor_label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
		heading.add_child(factor_label)
	var axis_label := String(item.get("axis_label", "")).strip_edges()
	if not axis_label.is_empty():
		var axis := Label.new()
		axis.text = axis_label
		axis.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		axis.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
		heading.add_child(axis)
	var description := String(item.get("description", ""))
	var copy := _rich_copy()
	copy.text = _emphasize(description)
	copy.visible = not description.strip_edges().is_empty()
	row.add_child(copy)
	row.add_child(HSeparator.new())


func _add_effect_row(data: Dictionary) -> void:
	var band := PanelContainer.new()
	var paper := StyleBoxFlat.new()
	paper.bg_color = UITokens.DOSSIER_PAPER_SHADE
	paper.border_color = UITokens.DOSSIER_RULE
	paper.border_width_bottom = 1
	paper.content_margin_left = UITokens.SPACE_SM
	paper.content_margin_right = UITokens.SPACE_SM
	paper.content_margin_top = UITokens.SPACE_SM
	paper.content_margin_bottom = UITokens.SPACE_SM
	band.add_theme_stylebox_override("panel", paper)
	band.tooltip_text = String(data.get("original", ""))
	_effect_tiers_box.add_child(band)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", UITokens.SPACE_MD)
	band.add_child(line)
	var level := int(data.get("level", 1))
	var rank := VBoxContainer.new()
	rank.custom_minimum_size.x = 62
	line.add_child(rank)
	var label := Label.new()
	label.text = "威望 %s" % _prestige_roman(level)
	label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
	label.add_theme_font_override("font", _bold_font)
	label.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
	rank.add_child(label)
	var marks := HBoxContainer.new()
	marks.add_theme_constant_override("separation", 3)
	rank.add_child(marks)
	for index in 5:
		var mark := ColorRect.new()
		mark.custom_minimum_size = Vector2(9, 3)
		mark.color = UITokens.DOSSIER_BRASS if index < level else UITokens.DOSSIER_TRACK
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		marks.add_child(mark)
	var copy := _rich_copy()
	copy.text = _emphasize(String(data.get("body", "")))
	line.add_child(copy)


func _add_icon(parent: Node, key: StringName, color: Color, size: float = 24.0) -> void:
	var icon := IconScene.instantiate() as IconBadge
	icon.custom_minimum_size = Vector2(size, size)
	parent.add_child(icon)
	icon.set_semantic(key, color)


func _rich_copy() -> RichTextLabel:
	var copy := RichTextLabel.new()
	_style_copy(copy)
	return copy


func _style_copy(copy: RichTextLabel) -> void:
	copy.bbcode_enabled = true
	copy.fit_content = true
	copy.scroll_active = false
	copy.mouse_filter = Control.MOUSE_FILTER_IGNORE
	copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy.add_theme_font_override("normal_font", UITokens.dossier_font("sans"))
	copy.add_theme_font_override("bold_font", _bold_font)
	copy.add_theme_font_size_override("normal_font_size", UITokens.FONT_BODY)
	copy.add_theme_font_size_override("bold_font_size", UITokens.FONT_BODY)
	copy.add_theme_color_override("default_color", UITokens.DOSSIER_INK_SOFT)


func _escape_copy(value: String) -> String:
	return value.replace("[", "[lb]")


func _emphasize(value: String) -> String:
	var safe := _escape_copy(value)
	var regex := RegEx.new()
	regex.compile("[+-]?[0-9]+(?:\\.[0-9]+)?%?")
	var matches := regex.search_all(safe)
	for index in range(matches.size() - 1, -1, -1):
		var found := matches[index]
		var highlighted := "[b][color=#%s]%s[/color][/b]" % [
			UITokens.DOSSIER_OXBLOOD.to_html(false), found.get_string()]
		safe = safe.substr(0, found.get_start()) + highlighted + safe.substr(found.get_end())
	return safe


func _add_copy(container: Container, text: String, variation: StringName = &"PKDossierBody") -> void:
	var row := TextRowScene.instantiate() as VBoxContainer
	var label := row.get_node("Copy") as Label
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.theme_type_variation = variation
	label.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
	container.add_child(row)


func set_details_expanded(expanded: bool, animate: bool = true) -> void:
	_details_revision += 1
	_details_expanded = expanded and not _candidate_empty
	_details_toggle.set_pressed_no_signal(_details_expanded)
	_details_toggle.text = "▴" if _details_expanded else "▾"
	_details_toggle.tooltip_text = "收起详情" if _details_expanded else "展开详情"
	_details_toggle.add_theme_color_override("font_focus_color",
		UITokens.ARCHIVE_PAPER_LIGHT if _details_expanded else UITokens.ARCHIVE_INK)
	UIAnimation.cancel(_details_clip)
	_details_preparing = false
	if not _details_expanded:
		if animate and _details_clip.visible:
			UIAnimation.reveal_vertical(_details_clip, _details_content, false)
		else:
			_details_clip.visible = false
			_details_clip.custom_minimum_size.y = 0.0
			_details_content.modulate.a = 1.0
		_update_highlight(false)
		return
	_details_clip.visible = true
	_details_preparing = true
	var revision := _details_revision
	if animate:
		_details_content.modulate.a = 0.0
	await get_tree().process_frame
	if not is_inside_tree() or revision != _details_revision:
		return
	_details_content.offset_left = 0.0
	_details_content.offset_right = 0.0
	await get_tree().process_frame
	if not is_inside_tree() or revision != _details_revision:
		return
	_details_preparing = false
	if animate:
		UIAnimation.reveal_vertical(_details_clip, _details_content, true)
	else:
		_details_clip.custom_minimum_size.y = _details_content.get_combined_minimum_size().y
		_details_content.modulate.a = 1.0
	_update_highlight(false)


func _schedule_detail_fit() -> void:
	if _details_expanded:
		call_deferred("_fit_details")


func _fit_details() -> void:
	if not _details_expanded or _details_preparing:
		return
	_details_content.offset_left = 0.0
	_details_content.offset_right = 0.0
	if not _details_clip.has_meta("_ui_active_tween"):
		_details_clip.custom_minimum_size.y = _details_content.get_combined_minimum_size().y


func candidate_empty() -> bool:
	return _candidate_empty


func choose_button() -> Button:
	return _choose


func details_button() -> Button:
	return _details_toggle


func is_details_expanded() -> bool:
	return _details_expanded


func _show_dossier_popup() -> void:
	if _candidate_empty or not is_inside_tree():
		return
	_cancel_dossier_hide()
	_hide_dossier_popup()
	_dossier_popup_revision += 1
	var revision := _dossier_popup_revision
	_dossier_popup = PanelContainer.new()
	_dossier_popup.name = "FamilyDossierPopup"
	_dossier_popup.custom_minimum_size = Vector2(DOSSIER_WIDTH, 1.0)
	_dossier_popup.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_dossier_popup.mouse_filter = Control.MOUSE_FILTER_STOP
	_dossier_popup.z_index = 100
	_dossier_popup.modulate.a = 0.0
	_dossier_popup.add_theme_stylebox_override("panel", _tooltip_style())
	var paper := Panel.new()
	paper.name = "DossierPaper"
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	paper.z_index = 0
	var paper_style := StyleBoxFlat.new()
	paper_style.bg_color = UITokens.DOSSIER_PAPER
	paper_style.corner_radius_top_left = 2
	paper_style.corner_radius_top_right = 2
	paper_style.corner_radius_bottom_left = 2
	paper_style.corner_radius_bottom_right = 2
	paper_style.shadow_color = Color(0.08, 0.045, 0.02, 0.38)
	paper_style.shadow_size = 10
	paper_style.shadow_offset = Vector2(4.0, 6.0)
	paper.add_theme_stylebox_override("panel", paper_style)
	_dossier_popup.add_child(paper)
	paper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	paper.offset_left = 7.0
	paper.offset_top = 7.0
	paper.offset_right = -7.0
	paper.offset_bottom = -7.0
	var frame := Panel.new()
	frame.name = "DossierFrame"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_theme_stylebox_override("panel", _tooltip_style())
	_dossier_popup.add_child(frame)
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 15)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 15)
	_dossier_popup.add_child(margin)
	var stack := VBoxContainer.new()
	stack.mouse_filter = Control.MOUSE_FILTER_STOP
	stack.add_theme_constant_override("separation", 7)
	margin.add_child(stack)
	_add_tooltip_header(stack)
	_add_tooltip_rule(stack)
	var body_scroll := ScrollContainer.new()
	body_scroll.name = "DossierBodyScroll"
	body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	body_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	stack.add_child(body_scroll)
	var body_stack := VBoxContainer.new()
	body_stack.custom_minimum_size.x = DOSSIER_BODY_WIDTH
	body_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_stack.add_theme_constant_override("separation", 7)
	body_scroll.add_child(body_stack)
	_add_tooltip_metrics(body_stack)
	var rule := HSeparator.new()
	body_stack.add_child(rule)
	_add_tooltip_traits(body_stack)
	_add_tooltip_effects(body_stack)
	_add_tooltip_prestige_ladder(body_stack)
	_dossier_popup.mouse_entered.connect(_cancel_dossier_hide)
	_dossier_popup.mouse_exited.connect(_schedule_dossier_hide)
	var overlay_host := _overlay_host()
	overlay_host.add_child(_dossier_popup)
	_layout_dossier_popup()
	await get_tree().process_frame
	if not is_instance_valid(_dossier_popup) or revision != _dossier_popup_revision:
		return
	_layout_dossier_popup()
	await get_tree().process_frame
	if not is_instance_valid(_dossier_popup) or revision != _dossier_popup_revision:
		return
	_layout_dossier_popup()
	if UIAnimation.reduced_motion():
		_dossier_popup.modulate.a = 1.0
	else:
		var tween := _dossier_popup.create_tween()
		tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_dossier_popup.position += Vector2(0.0, 5.0)
		tween.set_parallel(true)
		tween.tween_property(_dossier_popup, "modulate:a", 1.0, UITokens.ANIM_FAST)
		tween.tween_property(_dossier_popup, "position:y",
			_dossier_popup.position.y - 5.0, UITokens.ANIM_FAST)
		tween.set_parallel(false)
		tween.tween_callback(func() -> void:
			if is_instance_valid(_dossier_popup):
				_dossier_popup.modulate.a = 1.0)
	await get_tree().create_timer(UITokens.ANIM_FAST).timeout
	if is_instance_valid(_dossier_popup) and revision == _dossier_popup_revision:
		_dossier_popup.modulate.a = 1.0


func _hide_dossier_popup() -> void:
	_dossier_popup_revision += 1
	if _dossier_popup == null:
		return
	if is_instance_valid(_dossier_popup):
		_dossier_popup.queue_free()
	_dossier_popup = null


func _schedule_dossier_hide() -> void:
	if _dossier_hide_timer != null:
		_dossier_hide_timer.start()


func _cancel_dossier_hide() -> void:
	if _dossier_hide_timer != null:
		_dossier_hide_timer.stop()


func _process(_delta: float) -> void:
	if _dossier_popup == null or not is_instance_valid(_dossier_popup):
		return
	if get_global_rect().has_point(get_global_mouse_position()) \
			or _dossier_popup.get_global_rect().has_point(get_global_mouse_position()):
		_cancel_dossier_hide()


func _layout_dossier_popup() -> void:
	if _dossier_popup == null or not is_instance_valid(_dossier_popup) \
			or not _dossier_popup.is_inside_tree():
		return
	var canvas_transform := get_viewport().get_canvas_transform()
	var scale := maxf(0.001, canvas_transform.get_scale().x)
	var visible_rect := get_viewport().get_visible_rect()
	var screen_origin := canvas_transform.affine_inverse() * visible_rect.position
	var screen_end := canvas_transform.affine_inverse() \
		* (visible_rect.position + visible_rect.size)
	var margin := DOSSIER_SCREEN_MARGIN / scale
	var safe_top := DOSSIER_SAFE_TOP / scale
	var gap := 12.0 / scale
	var min_y := screen_origin.y + safe_top
	var available_height := maxf(240.0, screen_end.y - min_y - margin)
	var popup_height := minf(DOSSIER_MAX_HEIGHT, available_height)
	var popup_size := Vector2(DOSSIER_WIDTH, popup_height)
	_dossier_popup.size = popup_size
	var anchor := get_global_rect()
	var x := anchor.end.x + gap
	if x + popup_size.x > screen_end.x - margin:
		x = anchor.position.x - popup_size.x - gap
	if x < screen_origin.x + margin:
		x = clampf(anchor.position.x, screen_origin.x + margin,
			maxf(screen_origin.x + margin, screen_end.x - popup_size.x - margin))
	var max_y := maxf(min_y, screen_end.y - popup_size.y - margin)
	var desired_y := anchor.position.y
	if desired_y > max_y:
		desired_y = maxf(min_y, anchor.end.y - popup_size.y)
	var y := clampf(desired_y, min_y, max_y)
	_dossier_popup.position = Vector2(roundf(x), roundf(y))


func _overlay_host() -> Node:
	# Stay inside the current UI CanvasLayer so the dossier follows UI scaling
	# and shares the existing modal/tooltip ordering.
	var modal_layer := get_tree().root.find_child("ModalLayer", true, false)
	if modal_layer != null:
		return modal_layer
	return get_tree().current_scene if get_tree().current_scene != null else get_tree().root


func _tooltip_style() -> StyleBox:
	# Reuse the game's hand-drawn family card frame instead of introducing a
	# flat tooltip island that reads as a different UI material.
	var source := get_theme_stylebox("panel", &"MenuChapterNormal")
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


func _add_tooltip_header(column: VBoxContainer) -> void:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	column.add_child(header)
	var icon := IconScene.instantiate() as IconBadge
	icon.custom_minimum_size = Vector2(34, 34)
	icon.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	header.add_child(icon)
	icon.set_semantic(&"family.workspace.crest", UITokens.DOSSIER_OXBLOOD)
	var title_column := VBoxContainer.new()
	title_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_column.add_theme_constant_override("separation", 0)
	header.add_child(title_column)
	var title := Label.new()
	title.text = String(_candidate.get("family_name", "家族"))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_override("font", UITokens.dossier_font("display"))
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	title_column.add_child(title)
	var origin := Label.new()
	origin.text = _origin_text(_candidate)
	origin.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	origin.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	origin.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	title_column.add_child(origin)


func _add_tooltip_rule(column: VBoxContainer) -> void:
	var rule := HSeparator.new()
	column.add_child(rule)


func _add_tooltip_metrics(column: VBoxContainer) -> void:
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 2)
	column.add_child(grid)
	var has_cash := _candidate_cash(_candidate) >= 0.0
	var cash := _candidate_cash(_candidate)
	var metrics := [
		[&"family.metric.population", UITokens.format_compact_number_cn(
			float(_candidate.get("founders", 0)), 0), "", UITokens.DOSSIER_OXBLOOD],
		[&"metric.treasury", "—" if not has_cash
			else UITokens.format_compact_number_cn(cash, 2),
			"" if not has_cash else "万", UITokens.DOSSIER_BRASS],
		[&"economy.building", "%d" % int(_candidate.get("owned_buildings", 0)),
			"", UITokens.DOSSIER_UMBER],
		[&"family.workspace.prestige", _prestige_roman(int(_candidate.get("prestige_level", 0))),
			"", UITokens.DOSSIER_OXBLOOD if int(_candidate.get("prestige_level", 0)) >= 3
				else UITokens.DOSSIER_BRASS],
	]
	for metric in metrics:
		var cell := VBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_theme_constant_override("separation", 0)
		grid.add_child(cell)
		var heading := HBoxContainer.new()
		heading.add_theme_constant_override("separation", 3)
		cell.add_child(heading)
		_add_icon(heading, StringName(metric[0]), metric[3] as Color, 16.0)
		var value_row := HBoxContainer.new()
		value_row.add_theme_constant_override("separation", 2)
		cell.add_child(value_row)
		var value := Label.new()
		value.text = String(metric[1])
		value.add_theme_font_override("font", _bold_font)
		value.add_theme_font_size_override("font_size", 20)
		value.add_theme_color_override("font_color", metric[3] as Color)
		value_row.add_child(value)
		var unit := Label.new()
		unit.text = String(metric[2])
		unit.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		unit.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
		unit.size_flags_vertical = Control.SIZE_SHRINK_END
		value_row.add_child(unit)


func _add_tooltip_section(column: VBoxContainer, text: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	column.add_child(row)
	var key := &"family.workspace.effects" if text.contains("效果") else &"family.workspace.prestige"
	_add_icon(row, key, UITokens.DOSSIER_OXBLOOD, 18.0)
	var label := Label.new()
	label.text = text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_override("font", _bold_font)
	label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
	row.add_child(label)


func _add_tooltip_traits(column: VBoxContainer) -> void:
	var items: Array = _candidate.get("trait_items", [])
	var names: PackedStringArray = _candidate.get("trait_display_names", PackedStringArray())
	var descriptions: PackedStringArray = _candidate.get("trait_descriptions", PackedStringArray())
	if items.is_empty():
		for index in names.size():
			items.append({"name": names[index],
				"description": descriptions[index] if index < descriptions.size() else ""})
	if items.is_empty():
		_add_tooltip_muted(column, "尚无可考家风")
		return
	for raw in items:
		var item: Dictionary = raw
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 1)
		column.add_child(row)
		var heading := HBoxContainer.new()
		heading.add_theme_constant_override("separation", 4)
		row.add_child(heading)
		_add_icon(heading, &"family.workspace.preferences", UITokens.DOSSIER_OXBLOOD, 16.0)
		var name := Label.new()
		name.text = String(item.get("name", "家风"))
		name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name.add_theme_font_override("font", _bold_font)
		name.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		name.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
		heading.add_child(name)
		var description := RichTextLabel.new()
		description.bbcode_enabled = true
		description.fit_content = true
		description.scroll_active = false
		description.custom_minimum_size.x = DOSSIER_BODY_WIDTH - 20.0
		description.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		description.add_theme_font_override("normal_font", UITokens.dossier_font("sans"))
		description.add_theme_font_override("bold_font", _bold_font)
		description.add_theme_font_size_override("normal_font_size", UITokens.FONT_SMALL)
		description.add_theme_font_size_override("bold_font_size", UITokens.FONT_SMALL)
		description.add_theme_color_override("default_color", UITokens.DOSSIER_INK_SOFT)
		description.text = _emphasize(String(item.get("description", "")))
		row.add_child(description)


func _add_tooltip_effects(column: VBoxContainer) -> void:
	var effect_title := String(_candidate.get("effect_display_name", "")).strip_edges()
	if effect_title.is_empty():
		effect_title = "家族效果"
	var tiers: PackedStringArray = _candidate.get("effect_prestige_descriptions", PackedStringArray())
	var presentation := FamilyBuffCopyScript.founding_effect_rows(tiers)
	var ladder_rows: Array = presentation.get("rows", [])
	var context := String(presentation.get("context", "")).strip_edges()
	var current_level := maxi(0, int(_candidate.get("prestige_level", 0)))
	var title_text := effect_title
	if current_level > 0:
		title_text += "  ·  %s" % _prestige_roman(current_level)
	var effect_header := HBoxContainer.new()
	effect_header.add_theme_constant_override("separation", 6)
	column.add_child(effect_header)
	_add_icon(effect_header, &"family.workspace.effects", UITokens.DOSSIER_VERDIGRIS, 20.0)
	var name := Label.new()
	name.text = title_text
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name.add_theme_font_override("font", UITokens.dossier_font("display"))
	name.add_theme_font_size_override("font_size", 19)
	name.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	effect_header.add_child(name)
	if not context.is_empty():
		var context_label := Label.new()
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
	var current_text := _current_effect_body(_candidate)
	if not current_text.is_empty():
		var current := _rich_tooltip_copy()
		current.text = "[color=#%s][b]%s[/b][/color]" % [
			UITokens.DOSSIER_OXBLOOD.to_html(false), _emphasize(current_text)]
		column.add_child(current)
	else:
		var fallback := String(_candidate.get("effect_description", "")).strip_edges()
		if fallback.is_empty():
			fallback = "无额外效果"
		_add_tooltip_muted(column, fallback)


func _add_tooltip_prestige_ladder(column: VBoxContainer) -> void:
	var tiers: PackedStringArray = _candidate.get("effect_prestige_descriptions", PackedStringArray())
	if tiers.is_empty():
		return
	var presentation := FamilyBuffCopyScript.founding_effect_rows(tiers)
	var current_level := maxi(0, int(_candidate.get("prestige_level", 0)))
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 3)
	column.add_child(rows)
	for raw in presentation.get("rows", []):
		var row: Dictionary = raw
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 6)
		rows.add_child(line)
		var rank := PanelContainer.new()
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
		var level := Label.new()
		level.text = _prestige_roman(int(row.get("level", 1)))
		level.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		level.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		level.add_theme_font_override("font", _bold_font)
		level.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		level.add_theme_color_override("font_color",
			UITokens.DOSSIER_PAPER if is_current else UITokens.DOSSIER_OXBLOOD)
		rank.add_child(level)
		var copy := _rich_tooltip_copy()
		var body := _emphasize(String(row.get("body", "")))
		copy.text = body if not is_current else "[color=#%s][b]%s[/b][/color]" % [
			UITokens.DOSSIER_OXBLOOD.to_html(false), body]
		line.add_child(copy)


func _rich_tooltip_copy() -> RichTextLabel:
	var copy := RichTextLabel.new()
	copy.bbcode_enabled = true
	copy.fit_content = true
	copy.scroll_active = false
	copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy.add_theme_font_override("normal_font", UITokens.dossier_font("sans"))
	copy.add_theme_font_override("bold_font", _bold_font)
	copy.add_theme_font_size_override("normal_font_size", UITokens.FONT_SMALL)
	copy.add_theme_font_size_override("bold_font_size", UITokens.FONT_SMALL)
	copy.add_theme_color_override("default_color", UITokens.DOSSIER_INK_SOFT)
	return copy


func _add_tooltip_muted(column: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	column.add_child(label)


func _prestige_roman(level: int) -> String:
	return ["—", "Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ"][clampi(level, 0, 5)]
