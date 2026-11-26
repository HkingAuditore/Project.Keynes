extends RefCounted

## Submits tax requests and tracks the displayed receipts.


static func _on_rate_confirmed(owner: EconomyWorkspace, text: String, key: String, kind: String,
		mode_override: int = -1) -> void:
	var card: Dictionary = owner._rows.get(key, {})
	if not card.is_empty() and (card.spins as Dictionary).has(kind):
		var spin := (card.spins as Dictionary)[kind] as SpinBox
		if mode_override >= 0 and mode_override != owner._card_mode(card, kind):
			# 玩家在键盘上换了口径：先把下拉与解析口径对齐，再按新量纲解析，
			# 最后只落一条命令 —— 不必先发一条「归零」再发真正的税率。
			owner._apply_tax_mode(card, kind, spin, mode_override)
		var mode := owner._card_mode(card, kind)
		var fallback_value := TaxLaneEditor.currency_to_absolute_amount(float(spin.value)) \
			if mode == EconomyWorkspace.TAX_MODE_ABSOLUTE else TaxLaneEditor.percent_to_basis_points(float(spin.value))
		var fallback := int((card.rates as Dictionary).get(kind, fallback_value))
		var rate := TaxLaneEditor.parse_value_text(text, fallback, mode)
		if rate != fallback:
			owner._set_spin_basis_points(spin, rate, mode)
	owner._confirm_spin(key, kind)



static func _on_rate_text_changed(owner: EconomyWorkspace, text: String, key: String, kind: String) -> void:
	var card: Dictionary = owner._rows.get(key, {})
	if card.is_empty() or not (card.spins as Dictionary).has(kind):
		return
	var mode := owner._card_mode(card, kind)
	if mode != EconomyWorkspace.TAX_MODE_ABSOLUTE or text.strip_edges() in ["", "-", "+", ".", "-.", "+."]:
		return
	var spin := (card.spins as Dictionary)[kind] as SpinBox
	var line := spin.get_line_edit()
	if line != null and line.has_focus():
		return
	var fallback := int((card.rates as Dictionary).get(kind,
		TaxLaneEditor.currency_to_absolute_amount(float(spin.value))))
	var rate := TaxLaneEditor.parse_value_text(text, fallback, mode)
	if rate == fallback:
		return
	var shown := TaxLaneEditor._format_value(rate, mode, false)
	if line.text == shown:
		return
	line.set_block_signals(true)
	line.text = shown
	line.set_block_signals(false)



static func _on_rate_focus_entered(owner: EconomyWorkspace, key: String, kind: String) -> void:
	if owner._draft_commit_key == key and owner._draft_commit_kind == kind:
		owner._stop_draft_timer()



static func _on_rate_focus_exited(owner: EconomyWorkspace, key: String, kind: String) -> void:
	owner._confirm_spin(key, kind)



static func _on_rate_preview(owner: EconomyWorkspace, value: float, key: String, kind: String) -> void:
	var card: Dictionary = owner._rows.get(key, {})
	if card.is_empty():
		return
	var mode := owner._card_mode(card, kind)
	var rate := TaxLaneEditor.currency_to_absolute_amount(value) \
		if mode == EconomyWorkspace.TAX_MODE_ABSOLUTE else TaxLaneEditor.percent_to_basis_points(value)
	if bool(card.is_default):
		var authoritative := int((card.rates as Dictionary).get(kind, 0))
		if rate == authoritative and not owner._has_pending_default(kind):
			owner._preview_defaults.erase(kind)
		else:
			owner._preview_defaults[kind] = rate
		# Preview changes only presentation. The command remains confirmed on
		# Enter/focus loss and retains its next-day authoritative boundary.
		owner._refresh_page()
		return
	var item_id := String(card.item_id)
	if owner._pending.has("%s:%s" % [kind, item_id]):
		return
	var current := int((card.rates as Dictionary).get(kind, 0))
	var draft_key := owner._item_draft_key(kind, item_id)
	if rate == current:
		owner._draft_overrides.erase(draft_key)
		if owner._draft_commit_key == key and owner._draft_commit_kind == kind:
			owner._stop_draft_timer()
		return
	owner._draft_overrides[draft_key] = rate
	var spin := (card.spins as Dictionary)[kind] as SpinBox
	if spin.get_line_edit().has_focus():
		if owner._draft_commit_key == key and owner._draft_commit_kind == kind:
			owner._stop_draft_timer()
		return
	owner._schedule_draft_commit(key, kind)



static func _schedule_draft_commit(owner: EconomyWorkspace, key: String, kind: String) -> void:
	owner._draft_commit_key = key
	owner._draft_commit_kind = kind
	if owner._draft_timer != null:
		owner._draft_timer.start()



static func _stop_draft_timer(owner: EconomyWorkspace) -> void:
	if owner._draft_timer != null:
		owner._draft_timer.stop()
	owner._draft_commit_key = ""
	owner._draft_commit_kind = ""



static func _on_draft_commit_timeout(owner: EconomyWorkspace) -> void:
	var key := owner._draft_commit_key
	var kind := owner._draft_commit_kind
	owner._draft_commit_key = ""
	owner._draft_commit_kind = ""
	if key.is_empty() or kind.is_empty():
		return
	owner._confirm_spin(key, kind)



static func _item_draft_key(owner: EconomyWorkspace, kind: String, item_id: String) -> String:
	return "%s:%s" % [kind, item_id]


# Typing a rate is the override: a value equal to the inherited default clears
# the override instead, so no separate override toggle exists anywhere.
static func _confirm_spin(owner: EconomyWorkspace, key: String, kind: String) -> void:
	var card: Dictionary = owner._rows.get(key, {})
	if card.is_empty():
		return
	var spin := (card.spins as Dictionary)[kind] as SpinBox
	var mode := owner._card_mode(card, kind)
	var fallback := int((card.rates as Dictionary).get(kind, 0))
	var rate := fallback
	if mode == EconomyWorkspace.TAX_MODE_ABSOLUTE:
		rate = TaxLaneEditor.parse_value_text(
			spin.get_line_edit().text, fallback, mode)
	else:
		rate = TaxLaneEditor.parse_rate_text(spin.get_line_edit().text, fallback)
	if rate != fallback:
		owner._set_spin_basis_points(spin, rate, mode)
	var current := int((card.rates as Dictionary).get(kind, 0))
	var overridden := bool((card.overridden as Dictionary).get(kind, false))
	var item_id := String(card.item_id)
	owner._draft_overrides.erase(owner._item_draft_key(kind, item_id))
	if owner._draft_commit_key == key and owner._draft_commit_kind == kind:
		owner._stop_draft_timer()
	if bool(card.is_default):
		if rate != current or owner._preview_defaults.has(kind):
			owner._submit_rate(kind, String(card.item_id), rate, true, mode)
		else:
			owner._preview_defaults.erase(kind)
			owner._refresh_page()
		return
	if not overridden and rate == owner._default_rate(kind) and mode == owner._default_mode(kind):
		return
	if rate == current and not overridden:
		return
	var default_rate := owner._default_rate(kind)
	if rate == default_rate and overridden and mode == owner._default_mode(kind):
		owner._clear_override(kind, String(card.item_id))
	elif rate != current:
		owner._submit_rate(kind, String(card.item_id), rate, false, mode)



static func _default_mode(owner: EconomyWorkspace, kind: String) -> int:
	var policy: Dictionary = owner._model.get("tax_policy", {})
	var modes: PackedInt32Array = policy.get(
		"default_assessment_modes", PackedInt32Array())
	var kind_id := int(EconomyWorkspace.TAX_KIND.get(kind, -1))
	if kind_id < 0 or kind_id >= modes.size():
		return EconomyWorkspace.TAX_MODE_PERCENT_BP
	return int(modes[kind_id])



static func _default_rate(owner: EconomyWorkspace, kind: String) -> int:
	if owner._preview_defaults.has(kind):
		return int(owner._preview_defaults[kind])
	var pending_default: Dictionary = owner._pending.get("%s:__default__" % kind, {})
	if pending_default.has("rate"):
		return int(pending_default.rate)
	var policy: Dictionary = owner._model.get("tax_policy", {})
	var defaults := owner._basis_points_array(policy.get("default_rates_basis_points", PackedInt32Array()),
		policy.get("default_rates", PackedInt32Array()))
	var kind_id := int(EconomyWorkspace.TAX_KIND[kind])
	return int(defaults[kind_id]) if kind_id < defaults.size() else 0



static func _on_reset_pressed(owner: EconomyWorkspace, key: String, kind: String) -> void:
	var card: Dictionary = owner._rows.get(key, {})
	if card.is_empty():
		return
	owner._clear_override(kind, String(card.item_id))



static func _clear_override(owner: EconomyWorkspace, kind: String, item_id: String) -> void:
	if owner._player_controller == null:
		return
	owner._draft_overrides.erase(owner._item_draft_key(kind, item_id))
	var result: Dictionary = owner._player_controller.request_command(
		&"country.tax.clear_override", {
			"kind": int(EconomyWorkspace.TAX_KIND[kind]), "item_id": StringName(item_id)})
	if bool(result.get("ok", false)):
		owner._mark_pending(kind, item_id, owner._default_rate(kind), "clear")
		owner._submitted_tax["%s:%s" % [kind, item_id]] = {
			"rate": owner._default_rate(kind),
			"mode": owner._default_mode(kind),
			"has_override": false,
		}
		var card: Dictionary = owner._rows.get("%s:%s" % [owner._kind_page(kind), item_id], {})
		if not card.is_empty():
			var default_rate := owner._default_rate(kind)
			var spin := (card.spins as Dictionary)[kind] as SpinBox
			owner._set_spin_basis_points(spin, default_rate)
			spin.get_line_edit().add_theme_color_override("font_color", UITokens.ARCHIVE_INK_MUTED)
			(card.rates as Dictionary)[kind] = default_rate
			(card.overridden as Dictionary)[kind] = false
			((card.resets as Dictionary)[kind] as Button).visible = false
			owner._refresh_override_frame(card)
		if owner._tax_groups != null:
			owner._tax_groups.refresh_active_headers(owner._page, owner._rows)
	else:
		owner._set_status(String(result.get("reason", "税率覆盖清除命令提交失败")))



static func _submit_rate(owner: EconomyWorkspace, kind: String, item_id: String, rate: int, is_default: bool,
		mode: int = EconomyWorkspace.TAX_MODE_PERCENT_BP) -> void:
	if owner._player_controller == null:
		return
	var result: Dictionary
	if is_default:
		result = owner._player_controller.request_command(&"country.tax.set_default", {
			"kind": int(EconomyWorkspace.TAX_KIND[kind]), "rate_basis_points": rate,
			"tax_assessment_mode": mode})
	else:
		result = owner._player_controller.request_command(&"country.tax.set_override", {
			"kind": int(EconomyWorkspace.TAX_KIND[kind]), "item_id": StringName(item_id),
			"rate_basis_points": rate, "tax_assessment_mode": mode})
	if bool(result.get("ok", false)):
		if is_default:
			owner._preview_defaults.erase(kind)
		owner._mark_pending(kind, item_id, rate, "set", mode)
		owner._submitted_tax["%s:%s" % [kind, item_id]] = {
			"rate": rate,
			"mode": mode,
			"has_override": not is_default,
		}
		var card: Dictionary = owner._rows.get("%s:%s" % [owner._kind_page(kind), item_id], {})
		if not card.is_empty():
			var spin := (card.spins as Dictionary)[kind] as SpinBox
			owner._set_spin_basis_points(spin, rate, mode)
			spin.get_line_edit().add_theme_color_override("font_color",
				UITokens.BRASS_HIGHLIGHT)
			(card.rates as Dictionary)[kind] = rate
			(card.assessment_modes as Dictionary)[kind] = mode
			if not is_default:
				(card.overridden as Dictionary)[kind] = true
				((card.resets as Dictionary)[kind] as Button).visible = true
			owner._refresh_override_frame(card)
		if is_default:
			owner._refresh_page()
		elif owner._tax_groups != null:
			owner._tax_groups.refresh_active_headers(owner._page, owner._rows)
	else:
		if is_default:
			owner._preview_defaults.erase(kind)
			var card: Dictionary = owner._rows.get(
				"%s:__default__" % owner._kind_page(kind), {})
			if not card.is_empty():
				owner._set_spin_basis_points(
					(card.spins as Dictionary)[kind] as SpinBox,
					int((card.rates as Dictionary).get(kind, 0)),
					owner._card_mode(card, kind))
			owner._refresh_page()
		owner._set_status(String(result.get("reason", "税率命令提交失败")))



static func _refresh_override_frame(owner: EconomyWorkspace, card: Dictionary) -> void:
	var any_override := false
	for value in (card.overridden as Dictionary).values():
		any_override = any_override or bool(value)
	(card.name as Label).add_theme_color_override("font_color",
		UITokens.ARCHIVE_BRASS.lerp(UITokens.ARCHIVE_INK, 0.35) \
			if any_override else UITokens.ARCHIVE_INK)
	owner._apply_card_frame(card, any_override)



static func _mark_pending(owner: EconomyWorkspace, kind: String, item_id: String,
		optimistic_rate: int = 0, op: String = "set",
		mode: int = EconomyWorkspace.TAX_MODE_PERCENT_BP) -> void:
	var key := "%s:%s" % [kind, item_id]
	var policy: Dictionary = owner._model.get("tax_policy", {})
	owner._pending[key] = {
		"effective_day": owner._effective_day(),
		"policy_version": int(policy.get("policy_version", -1)),
		"rate": optimistic_rate,
		"mode": mode,
		"op": op,
	}
	var card: Dictionary = owner._rows.get("%s:%s" % [owner._kind_page(kind), item_id], {})
	if not card.is_empty():
		((card.pendings as Dictionary)[kind] as Control).visible = true



static func _has_pending_default(owner: EconomyWorkspace, kind: String) -> bool:
	return owner._pending.has("%s:__default__" % kind)



static func _resolve_pending_commands(owner: EconomyWorkspace) -> void:
	var policy: Dictionary = owner._model.get("tax_policy", {})
	if not bool(policy.get("ok", false)):
		return
	var current_day := int(owner._model.get("current_day", -1))
	var current_version := int(policy.get("policy_version", -1))
	var resolved: Array[String] = []
	for key_value in owner._pending:
		var key := String(key_value)
		var pending: Dictionary = owner._pending[key]
		if current_day < int(pending.get("effective_day", current_day + 1)) \
				or current_version <= int(pending.get("policy_version", current_version)):
			continue
		if not owner._policy_reflects_pending(key, pending):
			continue
		resolved.append(key)
	for key in resolved:
		owner._pending.erase(key)
		var kind := key.get_slice(":", 0)
		var card: Dictionary = owner._rows.get(
			"%s:%s" % [owner._kind_page(kind), key.get_slice(":", 1)], {})
		if not card.is_empty() and (card.pendings as Dictionary).has(kind):
			((card.pendings as Dictionary)[kind] as Control).visible = false



static func _policy_reflects_pending(owner: EconomyWorkspace, key: String, pending: Dictionary) -> bool:
	var policy: Dictionary = owner._model.get("tax_policy", {})
	var kind := key.get_slice(":", 0)
	var item_id := key.substr(kind.length() + 1)
	var op := String(pending.get("op", "set"))
	var kind_id := int(EconomyWorkspace.TAX_KIND.get(kind, -1))
	if item_id == "__default__":
		var defaults := owner._basis_points_array(policy.get("default_rates_basis_points", PackedInt32Array()),
			policy.get("default_rates", PackedInt32Array()))
		return kind_id >= 0 and kind_id < defaults.size() and pending.has("rate") \
			and int(defaults[kind_id]) == int(pending.rate)
	var group: Dictionary = policy.get(kind, {})
	var ids: PackedStringArray = PackedStringArray()
	if kind == "income":
		ids = policy.get("profession_ids", PackedStringArray())
	elif kind == "business":
		ids = policy.get("building_type_ids", PackedStringArray())
	else:
		ids = policy.get("good_ids", PackedStringArray())
	var index := ids.find(item_id)
	var rates := owner._group_basis_points(group, "rates")
	var flags: PackedByteArray = group.get("has_override", PackedByteArray())
	if index < 0 or index >= rates.size():
		return false
	var overridden := index < flags.size() and flags[index] != 0
	if op == "clear":
		return not overridden
	return overridden and int(rates[index]) == int(pending.get("rate", -1))



static func _effective_day(owner: EconomyWorkspace) -> int:
	return int(owner._model.get("current_day", -1)) + 1
