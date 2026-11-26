extends RefCounted

## Builds and updates the country tax cards and their editable controls.


static func _group_basis_points(owner: EconomyWorkspace, group: Dictionary, key: String,
		fallback: PackedInt32Array = PackedInt32Array()) -> PackedInt32Array:
	var preferred_key := "%s_basis_points" % key
	var preferred: PackedInt32Array = group.get(preferred_key, PackedInt32Array())
	if not preferred.is_empty():
		return preferred
	var legacy: PackedInt32Array = group.get(key, fallback)
	if legacy.is_empty():
		return fallback
	var converted := PackedInt32Array()
	converted.resize(legacy.size())
	for i in legacy.size():
		converted[i] = int(legacy[i]) * 100
	return converted



static func _set_spin_basis_points(owner: EconomyWorkspace, spin: SpinBox, rate_basis_points: int,
		mode: int = EconomyWorkspace.TAX_MODE_PERCENT_BP) -> void:
	if spin == null:
		return
	owner._configure_spin_for_mode(spin, mode)
	if mode == EconomyWorkspace.TAX_MODE_ABSOLUTE:
		spin.set_value_no_signal(
			TaxLaneEditor.absolute_amount_to_currency(rate_basis_points))
		var line := spin.get_line_edit()
		if line != null and not line.has_focus():
			line.text = TaxLaneEditor._format_value(rate_basis_points, mode, false)
		return
	spin.set_value_no_signal(TaxLaneEditor.basis_points_to_percent(rate_basis_points))
	var line := spin.get_line_edit()
	if line == null:
		return
	var percent := TaxLaneEditor.basis_points_to_percent(rate_basis_points)
	var shown := "%d" % int(round(percent)) \
		if is_equal_approx(percent, round(percent)) else "%.2f" % percent
	if not line.has_focus() and not String(spin.suffix).is_empty():
		shown = "%s %s" % [shown, spin.suffix]
	if line.text != shown:
		line.text = shown



static func _configure_spin_for_mode(owner: EconomyWorkspace, spin: SpinBox, mode: int) -> void:
	if spin == null:
		return
	if mode == EconomyWorkspace.TAX_MODE_ABSOLUTE:
		spin.min_value = TaxLaneEditor.absolute_amount_to_currency(EconomyWorkspace.TAX_ABSOLUTE_MIN)
		spin.max_value = TaxLaneEditor.absolute_amount_to_currency(EconomyWorkspace.TAX_ABSOLUTE_MAX)
		spin.step = 1.0 if EconomyWorkspace.TouchUI.is_touch() else 0.01
		# 单位不写字：定额模式下这一行的行尾亮起一枚金币（MoneyIcon 节点），
		# 输入框里只剩数字，和顶栏国库纸签的读法一致。
		spin.suffix = ""
		spin.tooltip_text = "定额税：每人每天缴纳的金额"
		owner._set_lane_money_icon(spin, true)
	else:
		spin.min_value = -1000.0
		spin.max_value = 100.0
		spin.step = 1.0 if EconomyWorkspace.TouchUI.is_touch() else 0.01
		spin.suffix = "%"
		spin.tooltip_text = "按百分比计"
		owner._set_lane_money_icon(spin, false)


## 税额行的货币图标与 SpinBox 同级（MoneyIcon），按计税模式开关。
static func _set_lane_money_icon(owner: EconomyWorkspace, spin: SpinBox, shown: bool) -> void:
	if spin == null:
		return
	var parent := spin.get_parent()
	if parent == null:
		return
	var icon := parent.get_node_or_null("MoneyIcon") as TextureRect
	if icon == null:
		return
	if icon.texture == null:
		MoneyDisplay.apply_icon(icon, 13)
	icon.visible = shown



static func _card_mode(owner: EconomyWorkspace, card: Dictionary, kind: String, fallback: int = EconomyWorkspace.TAX_MODE_PERCENT_BP) -> int:
	return int((card.assessment_modes as Dictionary).get(kind, fallback))



static func _on_mode_selected(owner: EconomyWorkspace, index: int, key: String, kind: String) -> void:
	var card: Dictionary = owner._rows.get(key, {})
	if card.is_empty():
		return
	var mode_button := (card.modes as Dictionary).get(kind) as OptionButton
	var mode := EconomyWorkspace.TAX_MODE_PERCENT_BP
	if mode_button != null:
		mode = int(mode_button.get_item_id(index))
	(card.assessment_modes as Dictionary)[kind] = mode
	var spin := (card.spins as Dictionary)[kind] as SpinBox
	owner._configure_spin_for_mode(spin, mode)
	owner._set_spin_basis_points(spin, 0, mode)
	owner._submit_rate(kind, String(card.item_id), 0, bool(card.is_default), mode)



static func _ensure_card(owner: EconomyWorkspace, page: String, item_id: String, label: String,
		icon_key: String, is_default: bool, item_kinds: Array = []) -> Dictionary:
	var key := "%s:%s" % [page, item_id]
	if owner._rows.has(key):
		return owner._rows[key]
	var accent: Color = (EconomyWorkspace.PAGE_DEFINITIONS[page] as Dictionary).get("accent", UITokens.ACCENT)
	var panel := EconomyWorkspace.TaxCardScene.instantiate() as PanelContainer
	panel.name = "Tax_%s_%s" % [page, item_id]
	panel.custom_minimum_size = EconomyWorkspace.CARD_SIZE
	var kinds := item_kinds if not item_kinds.is_empty() else owner._page_kinds(page)
	var badge := panel.get_node("Body/Head/Icon") as IconBadge
	badge.set_semantic(StringName(icon_key), accent)
	var name_label := panel.get_node("Body/Head/Name") as Label
	name_label.text = label
	name_label.add_theme_font_override("font", UITokens.font_with_weight(600))
	var sub_label := panel.get_node("Body/Sub") as Label
	var spins := {}
	var modes := {}
	var resets := {}
	var pendings := {}
	var lane_host := panel.get_node("Body/Lanes") as VBoxContainer
	for kind in kinds:
		var kind_row := EconomyWorkspace.TaxLaneScene.instantiate() as HBoxContainer
		lane_host.add_child(kind_row)
		var kind_label := kind_row.get_node("Kind") as Label
		kind_label.text = String(EconomyWorkspace.KIND_LABELS.get(kind, kind))
		kind_label.visible = kinds.size() > 1 or page == "consumption"
		var mode_button := kind_row.get_node_or_null("Mode") as OptionButton
		if mode_button != null:
			mode_button.clear()
			mode_button.add_item("%", EconomyWorkspace.TAX_MODE_PERCENT_BP)
			# 定额税的单位是货币：下拉项用金币图标顶着，不再写「（货币）」。
			# 必须用 24px 的 MENU_ICON —— item 图标按原生像素算最小尺寸。
			mode_button.add_icon_item(MoneyDisplay.MENU_ICON, "定额", EconomyWorkspace.TAX_MODE_ABSOLUTE)
			mode_button.select(0)
			mode_button.item_selected.connect(
				owner._on_mode_selected.bind(key, kind))
			modes[kind] = mode_button
		var spin := kind_row.get_node("Spin") as SpinBox
		spin.get_line_edit().alignment = HORIZONTAL_ALIGNMENT_RIGHT
		spin.get_line_edit().text_changed.connect(
			owner._on_rate_text_changed.bind(key, kind))
		spin.get_line_edit().text_submitted.connect(
			owner._on_rate_confirmed.bind(key, kind))
		spin.get_line_edit().focus_entered.connect(
			owner._on_rate_focus_entered.bind(key, kind))
		spin.get_line_edit().focus_exited.connect(
			owner._on_rate_focus_exited.bind(key, kind))
		spin.value_changed.connect(owner._on_rate_preview.bind(key, kind))
		spins[kind] = spin
		# 触摸档：数字那一块盖一层命中区，点开游戏内数字键盘；桌面档不挂，行为逐像素不变。
		if EconomyWorkspace.TouchUI.is_touch():
			var field := EconomyWorkspace.TouchValueFieldScript.new()
			field.attach(spin, {
				"title": owner._pad_title(label, kind_label),
				"mode": func() -> int: return owner._pad_mode(key, kind),
				"hint": func() -> String:
					return "国家默认 %s" % TaxLaneEditor._format_value(
						owner._default_rate(kind), owner._default_mode(kind)),
				"commit": func(text: String, mode: int) -> void:
					owner._on_rate_confirmed(text, key, kind, mode),
			})
		var reset := kind_row.get_node("Reset") as Button
		IconButton.apply(reset, &"action.reset", IconButton.SMALL, "重置为默认税率")
		reset.pressed.connect(owner._on_reset_pressed.bind(key, kind))
		resets[kind] = reset
		var clock_badge := kind_row.get_node("Pending") as IconBadge
		clock_badge.set_semantic(&"system.clock", UITokens.BRASS_HIGHLIGHT)
		pendings[kind] = clock_badge
	owner._flow.add_child(panel)
	var result := {"control": panel, "name": name_label, "sub": sub_label,
		"spins": spins, "modes": modes, "resets": resets, "pendings": pendings,
		"overridden": {}, "rates": {}, "assessment_modes": {}, "kinds": kinds,
		"page": page, "item_id": item_id, "is_default": is_default,
		"accent": accent}
	owner._rows[key] = result
	owner._apply_card_frame(result, false)
	owner._watch_card_hover(panel)
	return result



static func _update_card(owner: EconomyWorkspace, card: Dictionary, kind_data: Dictionary) -> void:
	var signature_parts: Array[String] = []
	for kind in card.kinds:
		var data: Dictionary = kind_data.get(kind, {})
		var submitted_key := "%s:%s" % [kind, String(card.item_id)]
		if owner._submitted_tax.has(submitted_key):
			var submitted: Dictionary = owner._submitted_tax[submitted_key]
			if owner._tax_submission_reflected(card, kind, data, submitted):
				owner._submitted_tax.erase(submitted_key)
			else:
				# Preserve the player's committed value while the next authoritative
				# snapshot is still catching up.
				data = data.duplicate(false)
				data["base"] = int(submitted.get("rate", data.get("base", 0)))
				data["mode"] = int(submitted.get("mode", data.get("mode", EconomyWorkspace.TAX_MODE_PERCENT_BP)))
				data["has_override"] = bool(submitted.get("has_override", false))
		var base := int(data.get("base", 0))
		var mode := int(data.get("mode", EconomyWorkspace.TAX_MODE_PERCENT_BP))
		var overridden := bool(data.get("has_override", false))
		var visual_rate := owner._visual_rate(card, kind, base, overridden)
		signature_parts.append("%d:%d:%d:%d:%d:%d" % [
			base,
			visual_rate,
			int(data.get("effective", data.get("base", 0))),
			1 if overridden else 0,
			1 if owner._pending.has("%s:%s" % [kind, String(card.item_id)]) else 0,
			mode,
		])
	var signature := "|".join(signature_parts)
	if signature == String(card.get("signature", "")):
		return
	card["signature"] = signature
	for kind in card.kinds:
		var data: Dictionary = kind_data.get(kind, {})
		var mode := int(data.get("mode", EconomyWorkspace.TAX_MODE_PERCENT_BP))
		(card.assessment_modes as Dictionary)[kind] = mode
		var mode_button := (card.modes as Dictionary).get(kind) as OptionButton
		if mode_button != null:
			var select_index := mode_button.get_item_index(mode)
			if select_index >= 0 and mode_button.selected != select_index:
				mode_button.select(select_index)
		var pending := owner._pending.has("%s:%s" % [kind, String(card.item_id)])
		((card.pendings as Dictionary)[kind] as Control).visible = pending
		if pending:
			var pending_entry: Dictionary = owner._pending.get(
				"%s:%s" % [kind, String(card.item_id)], {})
			var spin := (card.spins as Dictionary)[kind] as SpinBox
			if pending_entry.has("rate"):
				var pending_rate := int(pending_entry.rate)
				var pending_mode := int(pending_entry.get("mode", mode))
				owner._set_spin_basis_points(spin, pending_rate, pending_mode)
			continue
		var spin := (card.spins as Dictionary)[kind] as SpinBox
		var line_edit := spin.get_line_edit()
		var draft_key := owner._item_draft_key(kind, String(card.item_id))
		if line_edit.has_focus() or spin.has_focus() or owner._draft_overrides.has(draft_key):
			(card.rates as Dictionary)[kind] = int(data.get("base", 0))
			(card.overridden as Dictionary)[kind] = bool(data.get("has_override", false))
			continue
		var base := int(data.get("base", 0))
		var effective := int(data.get("effective", base))
		var overridden := bool(data.get("has_override", false))
		var visual_rate := owner._visual_rate(card, kind, base, overridden)
		owner._set_spin_basis_points(spin, visual_rate, mode)
		line_edit.add_theme_color_override("font_color",
			UITokens.BRASS_HIGHLIGHT \
				if overridden or visual_rate != base else UITokens.ARCHIVE_INK_MUTED)
		((card.resets as Dictionary)[kind] as Button).visible = overridden
		(card.overridden as Dictionary)[kind] = overridden
		(card.rates as Dictionary)[kind] = base
		if (card.kinds as Array).size() == 1 and not bool(card.is_default):
			var sub := card.sub as Label
			sub.visible = visual_rate == base and effective != base \
				and mode == EconomyWorkspace.TAX_MODE_PERCENT_BP
			if sub.visible:
				sub.text = "修正后 %s" % owner._format_rate(effective)
	owner._refresh_override_frame(card)



static func _tax_submission_reflected(owner: EconomyWorkspace, card: Dictionary, kind: String,
		data: Dictionary, submitted: Dictionary) -> bool:
	if int(data.get("base", 0)) != int(submitted.get("rate", 0)) \
			or int(data.get("mode", EconomyWorkspace.TAX_MODE_PERCENT_BP)) != int(submitted.get("mode", EconomyWorkspace.TAX_MODE_PERCENT_BP)):
		return false
	return true if card.is_default else bool(data.get("has_override", false)) == bool(submitted.get("has_override", false))



static func _visual_rate(owner: EconomyWorkspace, card: Dictionary, kind: String, authoritative_rate: int,
			 overridden: bool) -> int:
	if bool(card.is_default) or not overridden:
		if owner._preview_defaults.has(kind):
			return int(owner._preview_defaults[kind])
		var pending_default: Dictionary = owner._pending.get(
			"%s:__default__" % kind, {})
		if pending_default.has("rate"):
			return int(pending_default.rate)
	return authoritative_rate



static func _format_rate(owner: EconomyWorkspace, rate_basis_points: int) -> String:
	var percent := TaxLaneEditor.basis_points_to_percent(rate_basis_points)
	var shown := "%d" % int(round(percent)) \
		if is_equal_approx(percent, round(percent)) else "%.2f" % percent
	return "%s%%" % shown



static func _apply_card_frame(owner: EconomyWorkspace, card: Dictionary, highlighted: bool) -> void:
	var panel := card.control as PanelContainer
	panel.theme_type_variation = &"PKDialog" \
		if bool(card.is_default) or highlighted else &"PKMetricCard"



static func _watch_card_hover(owner: EconomyWorkspace, _panel: PanelContainer) -> void:
	pass
