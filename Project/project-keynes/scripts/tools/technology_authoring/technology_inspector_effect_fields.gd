extends RefCounted

## Builds the inspector editors for modifiers, unlocks, bindings and enabling buildings.

static func _build_modifier_terms(inspector: TechnologyAuthoringInspector, row_data: Dictionary, key: String, label: String) -> void:
	var box := inspector._add_block("%s（上限 6 条）" % label, key)
	var terms: Array = row_data.get(key, [])
	for slot in range(terms.size()):
		var term: Dictionary = terms[slot]
		var captured := slot
		var frame := VBoxContainer.new()
		frame.add_theme_constant_override("separation", 2)
		box.add_child(frame)
		var head := HBoxContainer.new()
		frame.add_child(head)
		var stat_button := Button.new()
		stat_button.text = String(term.get("stat", "（选择 stat）"))
		stat_button.clip_text = true
		stat_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		stat_button.tooltip_text = inspector._editor.call("stat_hint", String(term.get("stat", "")))
		head.add_child(stat_button)
		stat_button.pressed.connect(func() -> void:
			inspector._editor.call("open_stat_picker", func(picked: String) -> void:
				inspector._editor.call("commit_term_field", inspector._technology_id, captured, "stat", picked)))
		var operation := OptionButton.new()
		for index in range(TechnologyAuthoringInspector.OPERATION_NAMES.size()):
			operation.add_item(String(TechnologyAuthoringInspector.OPERATION_NAMES[index]), index)
		operation.select(clampi(int(term.get("operation", 0)), 0, 3))
		head.add_child(operation)
		operation.item_selected.connect(func(index: int) -> void:
			inspector._editor.call("commit_term_field", inspector._technology_id, captured, "operation",
				float(index)))
		var value := SpinBox.new()
		value.min_value = -1000.0
		value.max_value = 1000.0
		value.step = 0.01
		value.value = float(term.get("value", 0.0))
		head.add_child(value)
		value.value_changed.connect(func(next: float) -> void:
			inspector._editor.call("commit_term_field", inspector._technology_id, captured, "value", next))
		var remove := Button.new()
		remove.text = "移除"
		head.add_child(remove)
		remove.pressed.connect(func() -> void:
			inspector._editor.call("remove_term", inspector._technology_id, captured))
		var subject := HBoxContainer.new()
		frame.add_child(subject)
		inspector._term_line(subject, "对象类型", String(term.get("subject_kind", "")), captured,
			"subject_kind", 96, true)
		inspector._term_line(subject, "对象 ID", String(term.get("subject_id", "")), captured,
			"subject_id", 120, false)
		inspector._term_line(subject, "对象名称", String(term.get("subject_display_name", "")),
			captured, "subject_display_name", 120, false)
		var semantics := HBoxContainer.new()
		frame.add_child(semantics)
		inspector._term_line(semantics, "效果类别", String(term.get("effect_class", "")), captured,
			"effect_class", 120, true)
		inspector._term_line(semantics, "运行时消费者", String(term.get("runtime_consumer", "")),
			captured, "runtime_consumer", 200, true)
		var rationale := HBoxContainer.new()
		frame.add_child(rationale)
		inspector._term_line(rationale, "效果理由", String(term.get("effect_rationale", "")),
			captured, "effect_rationale", 320, false)
		var preview := Label.new()
		preview.text = "玩家文案预览：%s %s" % [
			inspector._editor.call("term_subject_label", term),
			TechnologyAuthoringInspector.ValidatorScript.modifier_delta(term)]
		preview.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
		frame.add_child(preview)
		if TechnologyAuthoringInspector.ValidatorScript.same_target_conflict(row_data, term):
			var conflict := Label.new()
			conflict.text = "冲突：本科技同时解锁并加成 %s（technology_unlock_same_target_modifier）" % String(
				term.get("subject_id", ""))
			conflict.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			conflict.add_theme_color_override("font_color", UITokens.RISK)
			frame.add_child(conflict)
		var status := String(term.get("implementation_status", ""))
		if status != "runtime_consumed":
			var warning := Label.new()
			warning.text = "implementation_status 必须为 runtime_consumed，当前为「%s」" % status
			warning.add_theme_color_override("font_color", UITokens.RISK)
			frame.add_child(warning)
			var fix := Button.new()
			fix.text = "修正为 runtime_consumed"
			frame.add_child(fix)
			fix.pressed.connect(func() -> void:
				inspector._editor.call("commit_term_field", inspector._technology_id, captured,
					"implementation_status", "runtime_consumed"))
		box.add_child(HSeparator.new())
	if terms.size() < 6:
		var add := Button.new()
		add.text = "添加 Modifier 项"
		box.add_child(add)
		add.pressed.connect(func() -> void: inspector._editor.call("add_term", inspector._technology_id))


static func _term_line(inspector: TechnologyAuthoringInspector, row: HBoxContainer, label: String, value: String, slot: int,
		key: String, width: int, suggest: bool) -> void:
	var caption := Label.new()
	caption.text = label
	row.add_child(caption)
	var field := LineEdit.new()
	field.text = value
	field.custom_minimum_size.x = width
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	field.text_submitted.connect(func(text: String) -> void:
		inspector._editor.call("commit_term_field", inspector._technology_id, slot, key, text))
	field.focus_exited.connect(func() -> void:
		inspector._editor.call("commit_term_field", inspector._technology_id, slot, key, field.text))
	if not suggest:
		return
	var pick := Button.new()
	pick.text = "…"
	row.add_child(pick)
	pick.pressed.connect(func() -> void:
		inspector._editor.call("open_term_value_picker", key,
			func(picked: String) -> void:
				field.text = picked
				inspector._editor.call("commit_term_field", inspector._technology_id, slot, key, picked)))


# --------------------------------------------------------------------------
# Content unlocks
# --------------------------------------------------------------------------


static func _build_content_effects(inspector: TechnologyAuthoringInspector, row_data: Dictionary, key: String, label: String) -> void:
	var box := inspector._add_block(label, key)
	var effects: Array = row_data.get(key, [])
	for slot in range(effects.size()):
		var effect: Dictionary = effects[slot]
		var captured := slot
		var row := HBoxContainer.new()
		box.add_child(row)
		var caption := Label.new()
		caption.text = "%s · %s" % [String(effect.get("kind", "")), String(effect.get("id", ""))]
		caption.custom_minimum_size.x = 200
		caption.tooltip_text = JSON.stringify(effect, "  ")
		row.add_child(caption)
		var operation := Label.new()
		operation.text = String(effect.get("operation", ""))
		row.add_child(operation)
		var exists := bool(inspector._editor.call("content_exists", String(effect.get("kind", "")),
			String(effect.get("id", ""))))
		var state := Label.new()
		state.text = "已存在" if exists else "内容不存在"
		state.add_theme_color_override("font_color",
			UITokens.GOOD if exists else UITokens.RISK)
		row.add_child(state)
		var remove := Button.new()
		remove.text = "移除"
		row.add_child(remove)
		remove.pressed.connect(func() -> void:
			inspector._editor.call("remove_array_entry", inspector._technology_id, key, captured))
	var add := Button.new()
	add.text = "添加解锁效果"
	box.add_child(add)
	add.pressed.connect(func() -> void:
		inspector._editor.call("prompt_content_effect", inspector._technology_id))


static func _build_expected_bindings(inspector: TechnologyAuthoringInspector, row_data: Dictionary, key: String, label: String) -> void:
	var box := inspector._add_block("%s（kind 1=物资 2=建筑 3=资源）" % label, key)
	var bindings: Array = row_data.get(key, [])
	for slot in range(bindings.size()):
		var binding: Dictionary = bindings[slot]
		var captured := slot
		var row := HBoxContainer.new()
		box.add_child(row)
		var caption := Label.new()
		caption.text = "kind %d · %s" % [int(binding.get("kind", 0)),
			String(binding.get("id", ""))]
		caption.custom_minimum_size.x = 240
		row.add_child(caption)
		var remove := Button.new()
		remove.text = "移除"
		row.add_child(remove)
		remove.pressed.connect(func() -> void:
			inspector._editor.call("remove_array_entry", inspector._technology_id, key, captured))
	var add := Button.new()
	add.text = "从解锁效果同步预期绑定"
	box.add_child(add)
	add.pressed.connect(func() -> void:
		inspector._editor.call("sync_expected_bindings", inspector._technology_id))


static func _build_support_buildings(inspector: TechnologyAuthoringInspector, row_data: Dictionary, key: String, label: String) -> void:
	var box := inspector._add_block(label, key)
	var rows: Array = row_data.get(key, [])
	for slot in range(rows.size()):
		var entry: Dictionary = rows[slot]
		var captured := slot
		var row := HBoxContainer.new()
		box.add_child(row)
		var caption := Label.new()
		caption.text = "%s（%s）" % [String(entry.get("name", "")), String(entry.get("id", ""))]
		caption.custom_minimum_size.x = 240
		row.add_child(caption)
		var remove := Button.new()
		remove.text = "移除"
		row.add_child(remove)
		remove.pressed.connect(func() -> void:
			inspector._editor.call("remove_array_entry", inspector._technology_id, key, captured))
	var add := Button.new()
	add.text = "添加支撑建筑"
	box.add_child(add)
	add.pressed.connect(func() -> void:
		inspector._editor.call("prompt_support_building", inspector._technology_id))


# --------------------------------------------------------------------------
# Research routes and knowledge basis
# --------------------------------------------------------------------------
