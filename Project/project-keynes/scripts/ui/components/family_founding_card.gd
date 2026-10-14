extends PanelContainer
class_name FamilyFoundingCard

const FamilyBuffCopyScript = preload("res://scripts/family/family_buff_copy.gd")
const TextRowScene = preload("res://scenes/ui/family/family_founding_text_row.tscn")

signal selected()
signal details_requested()

@onready var _icon: IconBadge = %Icon
@onready var _title: Label = %Title
@onready var _origin: Label = %Origin
@onready var _trait_summary: Label = %TraitSummary
@onready var _effect_preview: Label = %EffectPreview
@onready var _traits_list: VBoxContainer = %TraitsList
@onready var _effect_title: Label = %EffectTitle
@onready var _effect_tiers_box: VBoxContainer = %EffectTiersBox
@onready var _details_clip: Control = %DetailsClip
@onready var _details_content: VBoxContainer = %DetailsContent
@onready var _details_toggle: Button = %DetailsToggle
@onready var _choose: Button = %Choose

var _candidate_empty := true
var _details_expanded := false
var _details_revision := 0
var _details_preparing := false
var _normal_style: StyleBox
var _hover_style: StyleBox


func _ready() -> void:
	_normal_style = get_theme_stylebox("panel", &"PKDossierNote").duplicate()
	_hover_style = _normal_style.duplicate()
	if _hover_style is StyleBoxTexture:
		(_hover_style as StyleBoxTexture).modulate_color = UITokens.ARCHIVE_BUTTON_HOVER
	elif _hover_style is StyleBoxFlat:
		(_hover_style as StyleBoxFlat).border_color = UITokens.ARCHIVE_BRASS
	add_theme_stylebox_override("panel", _normal_style)
	_choose.pressed.connect(func() -> void: selected.emit())
	_details_toggle.pressed.connect(func() -> void: details_requested.emit())
	for button in [_details_toggle, _choose]:
		button.focus_entered.connect(func() -> void: _update_highlight(true))
		button.focus_exited.connect(func() -> void: _update_highlight(false))
		UIAnimation.bind_hover_glow(button)
	mouse_entered.connect(func() -> void: _update_highlight(true))
	mouse_exited.connect(func() -> void: _update_highlight(false))
	_details_content.minimum_size_changed.connect(_schedule_detail_fit)
	resized.connect(_schedule_detail_fit)
	_details_toggle.add_theme_color_override("font_focus_color", UITokens.ARCHIVE_INK)


func _update_highlight(hovered: bool) -> void:
	var active := not _candidate_empty and (hovered or _details_expanded
		or _choose.has_focus() or _details_toggle.has_focus())
	add_theme_stylebox_override("panel", _hover_style if active else _normal_style)


func set_candidate(candidate: Dictionary) -> void:
	_candidate_empty = candidate.is_empty()
	set_details_expanded(false, false)
	_title.text = String(candidate.get("family_name", "暂无候选"))
	_icon.set_semantic(&"family.house", UITokens.DOSSIER_OXBLOOD)
	var building := String(candidate.get("building_display_name", "")).strip_edges()
	var profession := String(candidate.get("owner_profession_display_name", "")).strip_edges()
	var founders := UITokens.format_compact_number_cn(float(candidate.get("founders", 0)), 0)
	var origins := PackedStringArray()
	if not building.is_empty():
		origins.append(building)
	if not profession.is_empty():
		origins.append("%s出身" % profession)
	origins.append("创始族人 %s 人" % founders)
	_origin.text = " · ".join(origins) if not _candidate_empty else "当前没有可扶持的家族。"
	var names: PackedStringArray = candidate.get("trait_display_names", PackedStringArray())
	var descriptions: PackedStringArray = candidate.get("trait_descriptions", PackedStringArray())
	var items: Array = candidate.get("trait_items", [])
	if names.is_empty():
		for item in items:
			if item is Dictionary:
				names.append(String(item.get("name", "")))
	_trait_summary.text = "家风：%s" % " · ".join(names) if not names.is_empty() else "家风：暂无"
	_clear_rows(_traits_list)
	if not items.is_empty():
		for item in items:
			if item is Dictionary:
				_add_trait_row(String(item.get("name", "家风")), String(item.get("description", "")))
	else:
		for index in names.size():
			_add_trait_row(names[index], descriptions[index] if index < descriptions.size() else "")
	if _traits_list.get_child_count() == 0:
		_add_copy(_traits_list, "暂无已登记的家风偏好")
	var effect_name := String(candidate.get("effect_display_name", "")).strip_edges()
	var raw_description := String(candidate.get("effect_description", "")).strip_edges()
	var tiers: PackedStringArray = candidate.get("effect_prestige_descriptions", PackedStringArray())
	if tiers.is_empty() and not raw_description.is_empty():
		tiers = FamilyBuffCopyScript.prestige_statements(raw_description)
	var preview := FamilyBuffCopyScript.founding_effect_preview(tiers, raw_description)
	preview = preview.replace("该家族分支所在的本地块会持续获得以下效果：", "本地")
	_effect_preview.text = "家族效果：无" if effect_name.is_empty() else "%s · %s" % [effect_name, preview]
	_effect_title.text = "家族效果 · %s（威望晋升后生效）" % effect_name if not effect_name.is_empty() else "家族效果：无"
	_clear_rows(_effect_tiers_box)
	for statement in tiers:
		if not statement.strip_edges().is_empty():
			_add_copy(_effect_tiers_box, statement)
	if _effect_tiers_box.get_child_count() == 0:
		_add_copy(_effect_tiers_box, raw_description if not raw_description.is_empty() else "不携带额外家族效果。")
	_effect_preview.tooltip_text = String(candidate.get("effect_full_description", ""))
	_choose.disabled = _candidate_empty
	_details_toggle.disabled = _candidate_empty
	_choose.tooltip_text = "扶持「%s」在本地立族，其余两户将不再出现。" % _title.text
	_update_highlight(false)


func _clear_rows(container: Container) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _add_trait_row(trait_name: String, description: String) -> void:
	var row := TextRowScene.instantiate() as VBoxContainer
	_traits_list.add_child(row)
	var heading := row.get_node("Heading") as Label
	heading.text = trait_name
	heading.visible = true
	heading.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
	var copy := row.get_node("Copy") as Label
	copy.text = description
	copy.visible = not description.strip_edges().is_empty()
	copy.add_theme_font_size_override("font_size", UITokens.FONT_BODY)


func _add_copy(container: Container, text: String, variation: StringName = &"PKDossierBody") -> void:
	var row := TextRowScene.instantiate() as VBoxContainer
	var label := row.get_node("Copy") as Label
	label.text = text
	label.theme_type_variation = variation
	label.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
	container.add_child(row)


func set_details_expanded(expanded: bool, animate: bool = true) -> void:
	_details_revision += 1
	_details_expanded = expanded and not _candidate_empty
	_details_toggle.set_pressed_no_signal(_details_expanded)
	_details_toggle.text = "收起详情" if _details_expanded else "查看详情"
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
