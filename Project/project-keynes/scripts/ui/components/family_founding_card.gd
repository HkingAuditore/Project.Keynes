extends PanelContainer
class_name FamilyFoundingCard

const DossierContent = preload("res://scripts/ui/components/family_founding_dossier_content.gd")

const CardSummary = preload("res://scripts/ui/components/family_founding_card_summary.gd")

const FamilyBuffCopyScript = preload("res://scripts/family/family_buff_copy.gd")
const TextRowScene = preload("res://scenes/ui/family/family_founding_text_row.tscn")
const IconScene = preload("res://scenes/ui/icon_badge.tscn")
const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const DOSSIER_WIDTH := 388.0
const DOSSIER_MAX_HEIGHT := 560.0
const DOSSIER_BODY_WIDTH := 344.0
const DOSSIER_SCREEN_MARGIN := 18.0
const DOSSIER_SAFE_TOP := 52.0
## 指针位移超过这个阈值才算"真的动了"，用来启用详情浮窗的逐帧复核。
const HOVER_POLL_EPSILON_PX := 0.75

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
var _hover_poll_armed := false
var _poll_mouse := Vector2(-1, -1)


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
	_details_toggle.text = "▼"
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
		_title.text = "无候选"
		_origin.text = "可扶持家族：无"
		_population.text = ""
		_trait_summary.text = ""
		_effect_preview.text = ""
		_meta.text = ""
		_badges.visible = false
		_clear_rows(_traits_list)
		_clear_rows(_effect_tiers_box)
		_effect_title.visible = false
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
	return CardSummary._origin_text(self, candidate)


func _trait_names_text(candidate: Dictionary) -> String:
	return CardSummary._trait_names_text(self, candidate)


func _effect_short_text(candidate: Dictionary) -> String:
	return CardSummary._effect_short_text(self, candidate)


func _current_effect_body(candidate: Dictionary) -> String:
	return CardSummary._current_effect_body(self, candidate)


func _meta_text(candidate: Dictionary) -> String:
	return CardSummary._meta_text(self, candidate)


func _meta_badges(candidate: Dictionary) -> Array:
	return CardSummary._meta_badges(self, candidate)


func _candidate_cash(candidate: Dictionary) -> float:
	return CardSummary._candidate_cash(self, candidate)


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
	var effect_name := String(candidate.get("effect_display_name", "")).strip_edges()
	var raw_description := String(candidate.get("effect_description", "")).strip_edges()
	var tiers: PackedStringArray = candidate.get("effect_prestige_descriptions", PackedStringArray())
	if tiers.is_empty() and not raw_description.is_empty():
		tiers = FamilyBuffCopyScript.prestige_statements(raw_description)
	_effect_title.text = "独特效果 · %s" % effect_name
	_effect_title.visible = not effect_name.is_empty()
	_clear_rows(_effect_tiers_box)
	var presentation := FamilyBuffCopyScript.founding_effect_rows(tiers)
	var context := String(presentation.get("context", ""))
	_effect_context.visible = not context.is_empty()
	_effect_context.text = "[b]生效条件[/b]  %s" % _escape_copy(context)
	for row in presentation.get("rows", []):
		if not String(row.get("body", "")).is_empty():
			_add_effect_row(row)
	if _effect_tiers_box.get_child_count() == 0 and not raw_description.is_empty():
		_add_copy(_effect_tiers_box, raw_description)
	# 标题跟着内容走：没有效果正文时整节不渲染，不留一行空标题。
	_effect_title.visible = _effect_title.visible and _effect_tiers_box.get_child_count() > 0


func _effect_summary_bbcode(candidate: Dictionary, compact: bool) -> String:
	var effect_name := String(candidate.get("effect_display_name", "")).strip_edges()
	var description := _effect_short_text(candidate) if compact \
		else _current_effect_description(candidate)
	if effect_name.is_empty() and description.is_empty():
		return "[color=#%s]独特效果：无[/color]" % UITokens.ARCHIVE_INK_MUTED.to_html(false)
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
	var row := UIControlParts.v_box_container()
	row.add_theme_constant_override("separation", UITokens.SPACE_XS)
	_traits_list.add_child(row)
	var heading := UIControlParts.h_box_container()
	heading.add_theme_constant_override("separation", UITokens.SPACE_XS)
	row.add_child(heading)
	_add_icon(heading, &"family.workspace.preferences", UITokens.DOSSIER_SLATE)
	var title := _rich_copy()
	title.text = "[b]%s[/b]" % _escape_copy(String(item.get("name", "家风")))
	heading.add_child(title)
	var factor := float(item.get("factor_percent", 0.0))
	if factor > 0.0:
		var factor_label := UIControlParts.label()
		factor_label.text = "倾向 %d%%" % int(round(factor))
		factor_label.add_theme_font_override("font", _bold_font)
		factor_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		factor_label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
		heading.add_child(factor_label)
	var axis_label := String(item.get("axis_label", "")).strip_edges()
	if not axis_label.is_empty():
		var axis := UIControlParts.label()
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
	var band := UIControlParts.panel_container()
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
	var line := UIControlParts.h_box_container()
	line.add_theme_constant_override("separation", UITokens.SPACE_MD)
	band.add_child(line)
	var level := int(data.get("level", 1))
	var rank := UIControlParts.v_box_container()
	rank.custom_minimum_size.x = 62
	line.add_child(rank)
	var label := UIControlParts.label()
	label.text = "威望 %s" % _prestige_roman(level)
	label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
	label.add_theme_font_override("font", _bold_font)
	label.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
	rank.add_child(label)
	var marks := UIControlParts.h_box_container()
	marks.add_theme_constant_override("separation", 3)
	rank.add_child(marks)
	for index in 5:
		var mark := UIControlParts.color_rect()
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
	var copy := UIControlParts.rich_text_label()
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
	if _details_expanded:
		hide_dossier_popup()
	_details_toggle.set_pressed_no_signal(_details_expanded)
	_details_toggle.text = "▲" if _details_expanded else "▼"
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
	if TouchUI.is_touch() or _details_expanded:
		return
	_cancel_dossier_hide()
	_hide_dossier_popup()
	# 合成 hover（自动化 QA 直接 emit mouse_entered）没有真实指针移动；逐帧
	# 几何复核只在确实观察到指针移动后才启用，否则浮窗刚出现就会被收回。
	_hover_poll_armed = false
	_poll_mouse = get_viewport().get_mouse_position()
	_dossier_popup_revision += 1
	var revision := _dossier_popup_revision
	_dossier_popup = UIControlParts.panel_container()
	_dossier_popup.name = "FamilyDossierPopup"
	# 同名浮窗在同一帧里换新时引擎会把新节点改名，查找请认这个标记而不是名字。
	_dossier_popup.set_meta("family_dossier_popup", true)
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
	var margin := UIControlParts.margin_container()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 15)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 15)
	_dossier_popup.add_child(margin)
	var stack := UIControlParts.v_box_container()
	stack.mouse_filter = Control.MOUSE_FILTER_STOP
	stack.add_theme_constant_override("separation", 7)
	margin.add_child(stack)
	_add_tooltip_header(stack)
	_add_tooltip_rule(stack)
	var body_scroll := UIControlParts.scroll_container()
	body_scroll.name = "DossierBodyScroll"
	body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	body_scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	stack.add_child(body_scroll)
	var body_stack := UIControlParts.v_box_container()
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


## 折叠面板、关闭扶持或换悬停对象时由外部强制收回，不必等指针事件。
func hide_dossier_popup() -> void:
	_cancel_dossier_hide()
	_hide_dossier_popup()


func _hide_dossier_popup() -> void:
	_dossier_popup_revision += 1
	if _dossier_popup == null:
		return
	if is_instance_valid(_dossier_popup):
		_dossier_popup.queue_free()
	_dossier_popup = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		if not is_visible_in_tree():
			hide_dossier_popup()
	elif what == NOTIFICATION_WM_MOUSE_EXIT or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		# 只回收"指针确实已经不在卡片上"的悬浮窗：这两条通知在部分窗口状态下会
		# 早于指针真正离开触发，无条件收起会让详情刚出现就消失。
		if not is_inside_tree() \
				or not hover_point_hits(get_viewport().get_mouse_position()):
			hide_dossier_popup()


func _schedule_dossier_hide() -> void:
	if _dossier_hide_timer != null:
		_dossier_hide_timer.start()


func _cancel_dossier_hide() -> void:
	if _dossier_hide_timer != null:
		_dossier_hide_timer.stop()


## 详情浮窗的存续只认三件事：卡片还在显示、浮窗还在显示、指针仍落在两者之上。
## 折叠面板、关闭扶持、候选列表在指针下滚走，都不会补发 mouse_exited；只靠
## 信号收窗，漏掉一次就把详情永久留在屏幕上。所以这里逐帧复核。
func _process(_delta: float) -> void:
	if _dossier_popup == null or not is_instance_valid(_dossier_popup):
		return
	if not is_inside_tree() or not is_visible_in_tree() \
			or not _dossier_popup.is_visible_in_tree():
		_hide_dossier_popup()
		return
	var mouse := get_viewport().get_mouse_position()
	if mouse.distance_to(_poll_mouse) > HOVER_POLL_EPSILON_PX:
		_poll_mouse = mouse
		_hover_poll_armed = true
	if not _hover_poll_armed:
		return
	if hover_point_hits(mouse):
		_cancel_dossier_hide()
		return
	if _dossier_hide_timer != null and _dossier_hide_timer.is_stopped():
		_dossier_hide_timer.start()


## 指针是否仍落在卡片本身或它的详情浮窗上，坐标统一按 viewport 空间比较。
func hover_point_hits(mouse: Vector2) -> bool:
	if _screen_rect(self).has_point(mouse):
		return true
	if _dossier_popup != null and is_instance_valid(_dossier_popup):
		return _screen_rect(_dossier_popup).has_point(mouse)
	return false


## 控件在屏幕（viewport）空间的矩形。get_global_transform_with_canvas() 是
## 「局部 → viewport」的完整变换，必须喂控件自己的局部矩形；拿已经带全局平移的
## get_global_rect() 再过一遍，等于平移两次，矩形会被推到屏幕外。
## 浮窗挂在 ModalLayer 上，和卡片不在同一画布，也不能用卡片自己的
## get_global_mouse_position() 去比。
static func _screen_rect(control: Control) -> Rect2:
	if control == null:
		return Rect2()
	var xform := control.get_global_transform_with_canvas()
	var rect := Rect2(Vector2.ZERO, control.size)
	var first := xform * rect.position
	var last := xform * rect.end
	return Rect2(
		Vector2(minf(first.x, last.x), minf(first.y, last.y)),
		Vector2(absf(last.x - first.x), absf(last.y - first.y)))


func _layout_dossier_popup() -> void:
	if _dossier_popup == null or not is_instance_valid(_dossier_popup) \
			or not _dossier_popup.is_inside_tree():
		return
	# 悬浮窗挂在 ModalLayer，坐标必须按 UI 画布计算。Viewport 的 canvas
	# transform 属于地图画布并包含 MapCamera 缩放，直接取其逆矩阵会让固定在
	# UI 层的悬浮窗随地图缩放漂移。
	var popup_parent := _dossier_popup.get_parent() as CanvasItem
	if popup_parent == null:
		return
	var parent_transform := popup_parent.get_global_transform_with_canvas()
	var parent_inverse := parent_transform.affine_inverse()
	var viewport_rect := get_viewport().get_visible_rect()
	var viewport_min := parent_inverse * viewport_rect.position
	var viewport_max := parent_inverse * (viewport_rect.position + viewport_rect.size)
	var screen_origin := Vector2(minf(viewport_min.x, viewport_max.x),
		minf(viewport_min.y, viewport_max.y))
	var screen_end := Vector2(maxf(viewport_min.x, viewport_max.x),
		maxf(viewport_min.y, viewport_max.y))
	var parent_scale := maxf(0.001, parent_transform.get_scale().x)
	var margin := DOSSIER_SCREEN_MARGIN / parent_scale
	var safe_top := DOSSIER_SAFE_TOP / parent_scale
	var gap := 12.0 / parent_scale
	var min_y := screen_origin.y + safe_top
	var available_height := maxf(240.0, screen_end.y - min_y - margin)
	var popup_height := minf(DOSSIER_MAX_HEIGHT, available_height)
	var popup_size := Vector2(DOSSIER_WIDTH, popup_height)
	_dossier_popup.size = popup_size
	var anchor_global := get_global_transform_with_canvas()
	var anchor_min := parent_inverse * (anchor_global * Vector2.ZERO)
	var anchor_max := parent_inverse * (anchor_global * size)
	var anchor := Rect2(
		Vector2(minf(anchor_min.x, anchor_max.x), minf(anchor_min.y, anchor_max.y)),
		Vector2(absf(anchor_max.x - anchor_min.x), absf(anchor_max.y - anchor_min.y)))
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
	return DossierContent._tooltip_style(self)


func _add_tooltip_header(column: VBoxContainer) -> void:
	DossierContent._add_tooltip_header(self, column)


func _add_tooltip_rule(column: VBoxContainer) -> void:
	DossierContent._add_tooltip_rule(self, column)


func _add_tooltip_metrics(column: VBoxContainer) -> void:
	DossierContent._add_tooltip_metrics(self, column)


func _add_tooltip_section(column: VBoxContainer, text: String) -> void:
	DossierContent._add_tooltip_section(self, column, text)


func _add_tooltip_traits(column: VBoxContainer) -> void:
	DossierContent._add_tooltip_traits(self, column)


func _add_tooltip_effects(column: VBoxContainer) -> void:
	DossierContent._add_tooltip_effects(self, column)


func _add_tooltip_prestige_ladder(column: VBoxContainer) -> void:
	DossierContent._add_tooltip_prestige_ladder(self, column)


func _rich_tooltip_copy() -> RichTextLabel:
	return DossierContent._rich_tooltip_copy(self)


func _add_tooltip_muted(column: VBoxContainer, text: String) -> void:
	DossierContent._add_tooltip_muted(self, column, text)


func _prestige_roman(level: int) -> String:
	return DossierContent._prestige_roman(self, level)
