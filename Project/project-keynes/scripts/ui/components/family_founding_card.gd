extends PanelContainer
class_name FamilyFoundingCard

const FamilyBuffCopyScript = preload("res://scripts/family/family_buff_copy.gd")

signal selected()

@onready var _top_accent: ColorRect = %TopAccent
@onready var _icon: IconBadge = %Icon
@onready var _category: Label = %Category
@onready var _title: Label = %Title
@onready var _founder_badge: PanelContainer = %FounderBadge
@onready var _founder_value: Label = %FounderValue
@onready var _industry_icon: IconBadge = %IndustryIcon
@onready var _industry_value: Label = %IndustryValue
@onready var _profession_icon: IconBadge = %ProfessionIcon
@onready var _profession_value: Label = %ProfessionValue
@onready var _traits_icon: TextureRect = %TraitsIcon
@onready var _traits_count: Label = %TraitsCount
@onready var _traits_list: VBoxContainer = %TraitsList
@onready var _effect_box: PanelContainer = %EffectBox
@onready var _effect_icon: TextureRect = %EffectIcon
@onready var _effect_title: Label = %EffectTitle
@onready var _tier_toggle: Button = %TierToggle
@onready var _effect_preview: Label = %EffectPreview
@onready var _effect_tiers_box: VBoxContainer = %EffectTiersBox
@onready var _industry: Label = %Industry
@onready var _traits: Label = %Traits
@onready var _effect: Label = %Effect
@onready var _choose: Button = %Choose

var _candidate_empty := true
var _tiers_expanded := false
var _normal_style: StyleBoxFlat
var _hover_style: StyleBoxFlat
var _highlight_tween: Tween


func _ready() -> void:
	_build_card_styles()
	add_theme_stylebox_override("panel", _normal_style)
	if _traits_icon != null:
		_traits_icon.texture = IconCatalog.texture_for_key(&"family.workspace.traits")
	if _effect_icon != null:
		_effect_icon.texture = IconCatalog.texture_for_key(&"family.workspace.effects")
	_choose.pressed.connect(func() -> void: selected.emit())
	_choose.focus_entered.connect(func() -> void: _set_card_highlighted(true))
	_choose.focus_exited.connect(func() -> void: _set_card_highlighted(false))
	mouse_entered.connect(func() -> void: _set_card_highlighted(true))
	mouse_exited.connect(func() -> void:
		if not _choose.has_focus():
			_set_card_highlighted(false))
	if _tier_toggle != null:
		_tier_toggle.toggled.connect(_on_tier_toggle_toggled)


func _build_card_styles() -> void:
	_normal_style = StyleBoxFlat.new()
	_normal_style.bg_color = Color(0.968, 0.928, 0.822, 0.97)
	_normal_style.border_width_left = 1
	_normal_style.border_width_top = 1
	_normal_style.border_width_right = 1
	_normal_style.border_width_bottom = 2
	_normal_style.border_color = Color(0.44, 0.30, 0.17, 0.56)
	_normal_style.corner_radius_top_left = 4
	_normal_style.corner_radius_top_right = 4
	_normal_style.corner_radius_bottom_left = 4
	_normal_style.corner_radius_bottom_right = 4
	_normal_style.shadow_color = Color(0.08, 0.05, 0.02, 0.18)
	_normal_style.shadow_size = 6
	_normal_style.shadow_offset = Vector2(0, 2)

	_hover_style = _normal_style.duplicate() as StyleBoxFlat
	_hover_style.bg_color = Color(0.988, 0.952, 0.858, 0.99)
	_hover_style.border_width_left = 2
	_hover_style.border_width_top = 2
	_hover_style.border_width_right = 2
	_hover_style.border_width_bottom = 3
	_hover_style.border_color = Color(0.72, 0.49, 0.22, 0.95)
	_hover_style.shadow_color = Color(0.08, 0.05, 0.02, 0.28)
	_hover_style.shadow_size = 10
	_hover_style.shadow_offset = Vector2(0, 4)


func _set_card_highlighted(active: bool) -> void:
	if _candidate_empty:
		add_theme_stylebox_override("panel", _normal_style)
		if _top_accent != null:
			_top_accent.color = Color(0.42, 0.29, 0.16, 0.38)
		return
	add_theme_stylebox_override("panel", _hover_style if active else _normal_style)
	if _top_accent == null:
		return
	if _highlight_tween != null and _highlight_tween.is_valid():
		_highlight_tween.kill()
	_highlight_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	var target_color := UITokens.DOSSIER_BRASS if active else UITokens.DOSSIER_OXBLOOD
	_highlight_tween.tween_property(_top_accent, "color", target_color, UITokens.ANIM_FAST)


func set_candidate(candidate: Dictionary) -> void:
	_candidate_empty = candidate.is_empty()
	_tiers_expanded = false
	if _tier_toggle != null:
		_tier_toggle.set_pressed_no_signal(false)
	_icon.set_semantic(&"family.house",
		UITokens.DOSSIER_OXBLOOD if not _candidate_empty else UITokens.DOSSIER_INK_MUTED)
	var building := String(candidate.get("building_display_name", "")).strip_edges()
	_category.text = "扶持候选 · %s" % building if not building.is_empty() else "扶持候选"
	_title.text = String(candidate.get("family_name", "暂无候选"))
	var profession := String(candidate.get("owner_profession_display_name", "")).strip_edges()
	var founders := int(candidate.get("founders", 0))
	var founders_text := "%s 人" % UITokens.format_compact_number_cn(float(founders), 0)
	if _founder_value != null:
		_founder_value.text = founders_text if not _candidate_empty else "—"
	if _founder_badge != null:
		_founder_badge.visible = not _candidate_empty

	var building_icon_key := String(candidate.get("building_icon_key", "")).strip_edges()
	if building_icon_key.is_empty():
		building_icon_key = _fallback_building_icon(building)
	_industry_icon.set_semantic(StringName(building_icon_key), UITokens.GEO)
	_industry_value.text = building if not building.is_empty() else ("—" if _candidate_empty else "本地产业")
	_industry_value.tooltip_text = _industry_value.text

	var profession_icon_key := String(candidate.get("profession_icon_key", "")).strip_edges()
	if profession_icon_key.is_empty():
		profession_icon_key = "population.profession.owner"
	_profession_icon.set_semantic(StringName(profession_icon_key), UITokens.DOSSIER_SLATE)
	if _candidate_empty:
		_profession_value.text = "—"
	elif not profession.is_empty():
		_profession_value.text = "%s · %s" % [profession, founders_text]
	else:
		_profession_value.text = "创始 %s" % founders_text
	_profession_value.tooltip_text = _profession_value.text

	if _candidate_empty:
		_industry.text = "当前没有可扶持的家族。"
	elif profession.is_empty():
		_industry.text = "立族产业：%s · 创始族人 %d 人" % [building, founders]
	else:
		_industry.text = "立族产业：%s · %s出身 · 创始族人 %d 人" % [
			building, profession, founders]

	var names: PackedStringArray = candidate.get("trait_display_names", PackedStringArray())
	var descriptions: PackedStringArray = candidate.get("trait_descriptions", PackedStringArray())
	var lines := PackedStringArray()
	for index in names.size():
		var description := String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		lines.append("· %s%s" % [names[index],
			"：" + description if not description.is_empty() else ""])
	_traits.text = "家风：\n%s" % "\n".join(lines) if not lines.is_empty() else "家风：暂无"

	var trait_items := _resolve_trait_items(candidate, names, descriptions)
	_rebuild_trait_list(trait_items)

	var effect_name := String(candidate.get("effect_display_name", "")).strip_edges()
	var raw_effect_desc := String(candidate.get("effect_description", "")).strip_edges()
	var prestige_statements: PackedStringArray = candidate.get(
		"effect_prestige_descriptions", PackedStringArray())
	if prestige_statements.is_empty() and not raw_effect_desc.is_empty():
		prestige_statements = FamilyBuffCopyScript.prestige_statements(raw_effect_desc)
	var effect_preview := FamilyBuffCopyScript.founding_effect_preview(
		prestige_statements, raw_effect_desc)
	if effect_preview.is_empty() and not effect_name.is_empty():
		effect_preview = "立族后随家族威望晋升解锁「%s」五档加成。" % effect_name

	if effect_name.is_empty():
		_effect.text = "家族效果：无"
	elif effect_preview.is_empty():
		_effect.text = "家族效果：%s" % effect_name
	else:
		_effect.text = "家族效果：%s — %s" % [effect_name, effect_preview]

	_populate_effect_box(effect_name, effect_preview, prestige_statements,
		String(candidate.get("effect_full_description", "")).strip_edges())

	_choose.disabled = _candidate_empty
	_choose.text = "扶持此家族" if _candidate_empty else "扶持「%s」" % _title.text
	_choose.tooltip_text = "当前没有可扶持的家族" if _candidate_empty \
		else "扶持「%s」在本地立族" % _title.text
	_set_card_highlighted(false)


func _resolve_trait_items(candidate: Dictionary, names: PackedStringArray,
		descriptions: PackedStringArray) -> Array[Dictionary]:
	var provided: Array = candidate.get("trait_items", [])
	var out: Array[Dictionary] = []
	if not provided.is_empty():
		for item in provided:
			if item is Dictionary:
				out.append(item)
		return out
	for index in range(names.size()):
		var name_text := String(names[index]).strip_edges()
		if name_text.is_empty():
			continue
		var desc_text := String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		out.append({
			"name": name_text,
			"description": desc_text,
			"axis": _infer_axis_from_text(desc_text),
			"axis_label": FamilyBuffCopyScript.axis_short_label(
				_infer_axis_from_text(desc_text)),
			"badges": FamilyBuffCopyScript.extract_trait_badges(desc_text),
			"factor_percent": FamilyBuffCopyScript.trait_factor_percent(desc_text, 0.65),
		})
	return out


func _rebuild_trait_list(items: Array[Dictionary]) -> void:
	if _traits_list == null:
		return
	for child in _traits_list.get_children():
		_traits_list.remove_child(child)
		child.queue_free()
	if _traits_count != null:
		_traits_count.text = "%d 项" % items.size() if not items.is_empty() else "无"
	if items.is_empty():
		var empty_label := Label.new()
		empty_label.text = "暂无已登记的家风偏好" if not _candidate_empty else "暂无候选家族"
		empty_label.theme_type_variation = &"PKDossierMuted"
		_traits_list.add_child(empty_label)
		return
	for item in items:
		_traits_list.add_child(_create_trait_item_card(item))


func _create_trait_item_card(item: Dictionary) -> PanelContainer:
	var badges: Array = item.get("badges", [])
	var factor_percent := float(item.get("factor_percent", 100.0))
	var accent := _trait_accent_color(badges, factor_percent)

	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.988, 0.956, 0.868, 0.78)
	style.border_width_left = 3
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = accent
	style.corner_radius_top_left = 2
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 2
	style.corner_radius_bottom_right = 3
	style.content_margin_left = 8.0
	style.content_margin_top = 5.0
	style.content_margin_right = 8.0
	style.content_margin_bottom = 5.0
	card.add_theme_stylebox_override("panel", style)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 3)
	card.add_child(box)

	var header := HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_theme_constant_override("separation", 5)
	box.add_child(header)

	var name_label := Label.new()
	name_label.text = String(item.get("name", "家风"))
	name_label.theme_type_variation = &"PKDossierRowText"
	header.add_child(name_label)

	var axis_label := String(item.get("axis_label", "")).strip_edges()
	if not axis_label.is_empty():
		var axis_tag := Label.new()
		axis_tag.text = "· %s" % axis_label
		axis_tag.theme_type_variation = &"PKDossierMuted"
		header.add_child(axis_tag)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	for badge_raw in badges:
		if not badge_raw is Dictionary:
			continue
		var badge_data: Dictionary = badge_raw
		header.add_child(_create_delta_pill(
			String(badge_data.get("text", "")),
			bool(badge_data.get("positive", true))))

	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0.0, 5.0)
	bar.min_value = 0.0
	bar.max_value = 200.0
	bar.show_percentage = false
	bar.value = clampf(factor_percent, 0.0, 200.0)
	var track := StyleBoxFlat.new()
	track.bg_color = UITokens.DOSSIER_TRACK
	track.corner_radius_top_left = 2
	track.corner_radius_top_right = 2
	track.corner_radius_bottom_left = 2
	track.corner_radius_bottom_right = 2
	var fill := StyleBoxFlat.new()
	fill.bg_color = accent
	fill.corner_radius_top_left = 2
	fill.corner_radius_top_right = 2
	fill.corner_radius_bottom_left = 2
	fill.corner_radius_bottom_right = 2
	bar.add_theme_stylebox_override("background", track)
	bar.add_theme_stylebox_override("fill", fill)
	box.add_child(bar)

	var desc_text := String(item.get("description", "")).strip_edges()
	if not desc_text.is_empty():
		var desc := Label.new()
		desc.text = desc_text
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		desc.theme_type_variation = &"PKDossierBody"
		box.add_child(desc)

	card.tooltip_text = "%s：%s" % [name_label.text, desc_text] \
		if not desc_text.is_empty() else name_label.text
	return card


func _create_delta_pill(text: String, positive: bool) -> PanelContainer:
	var pill := PanelContainer.new()
	var pill_color := UITokens.DOSSIER_VERDIGRIS if positive else UITokens.DOSSIER_OXBLOOD
	var style := StyleBoxFlat.new()
	style.bg_color = Color(pill_color.r, pill_color.g, pill_color.b, 0.14)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(pill_color.r, pill_color.g, pill_color.b, 0.62)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.content_margin_left = 6.0
	style.content_margin_top = 1.0
	style.content_margin_right = 6.0
	style.content_margin_bottom = 1.0
	pill.add_theme_stylebox_override("panel", style)
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"PKDossierCaption"
	label.add_theme_color_override("font_color", pill_color)
	pill.add_child(label)
	return pill


func _populate_effect_box(effect_name: String, effect_preview: String,
		prestige_statements: PackedStringArray, full_description: String) -> void:
	if _effect_title != null:
		_effect_title.text = "家族效果 · %s" % effect_name \
			if not effect_name.is_empty() else "家族效果 · 无"
	if _effect_preview != null:
		_effect_preview.text = effect_preview \
			if not effect_preview.is_empty() else "当前候选不携带额外家族效果。"
	if _effect_tiers_box != null:
		for child in _effect_tiers_box.get_children():
			_effect_tiers_box.remove_child(child)
			child.queue_free()
		for idx in range(prestige_statements.size()):
			var line_text := String(prestige_statements[idx]).strip_edges()
			if line_text.is_empty():
				continue
			var row_label := Label.new()
			row_label.text = line_text
			row_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			row_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row_label.theme_type_variation = &"PKDossierCaption"
			if idx == 0:
				row_label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
			_effect_tiers_box.add_child(row_label)
		_effect_tiers_box.visible = false
	var has_tiers := prestige_statements.size() > 1
	if _tier_toggle != null:
		_tier_toggle.visible = has_tiers
		_tier_toggle.text = "威望Ⅰ~Ⅴ ▾"
	if _effect_box != null:
		var tip := full_description if not full_description.is_empty() \
			else "\n".join(prestige_statements)
		if tip.is_empty():
			tip = effect_preview
		_effect_box.tooltip_text = "%s\n%s" % [_effect_title.text, tip] \
			if not tip.is_empty() else _effect_title.text


func _on_tier_toggle_toggled(expanded: bool) -> void:
	_tiers_expanded = expanded
	if _tier_toggle != null:
		_tier_toggle.text = "收起五档 ▴" if expanded else "威望Ⅰ~Ⅴ ▾"
	if _effect_tiers_box != null:
		_effect_tiers_box.visible = expanded
		if expanded:
			UIAnimation.crossfade(_effect_tiers_box, UITokens.ANIM_FAST)


static func _trait_accent_color(badges: Array, factor_percent: float) -> Color:
	if not badges.is_empty() and badges[0] is Dictionary:
		return UITokens.DOSSIER_VERDIGRIS if bool(badges[0].get("positive", true)) \
			else UITokens.DOSSIER_OXBLOOD
	return UITokens.DOSSIER_VERDIGRIS if factor_percent >= 100.0 else UITokens.DOSSIER_OXBLOOD


static func _infer_axis_from_text(desc: String) -> int:
	if desc.contains("投资"):
		return 0
	if desc.contains("受雇") or desc.contains("从业") or desc.contains("工人"):
		return 1
	if desc.contains("消费") or desc.contains("需求"):
		return 2
	return -1


static func _fallback_building_icon(building_name: String) -> String:
	if building_name.contains("采集"):
		return "economy.building.gathering"
	if building_name.contains("狩猎") or building_name.contains("猎"):
		return "economy.building.hunting"
	if building_name.contains("伐木") or building_name.contains("林"):
		return "economy.building.forestry"
	if building_name.contains("渔"):
		return "economy.building.fishing"
	if building_name.contains("农") or building_name.contains("田") or building_name.contains("牧"):
		return "economy.building.farm"
	if building_name.contains("矿") or building_name.contains("石"):
		return "economy.building.mine"
	return "economy.building"


func candidate_empty() -> bool:
	return _candidate_empty


func choose_button() -> Button:
	return _choose


func tier_toggle_button() -> Button:
	return _tier_toggle


func is_tiers_expanded() -> bool:
	return _tiers_expanded
