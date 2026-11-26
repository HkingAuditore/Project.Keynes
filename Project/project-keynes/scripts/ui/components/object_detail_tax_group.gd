extends RefCounted

## 对象详情页「整组调税」一行控件的构建助手，保持 ObjectDetailDialog 体积在基线内。

const RateFieldScene := preload("res://scenes/ui/setup_spin.tscn")


static func add_controls(parent: VBoxContainer, subject: String,
		section_tax_kind: int, target_item_id: String, prefill_rate: int,
		group_host: Control) -> void:
	var axes: Array = group_host.tax_group_axes(subject)
	if axes.is_empty():
		return
	var group_box := UIControlParts.h_box_container()
	group_box.name = "TaxGroupBox"
	group_box.add_theme_constant_override("separation", 8)
	var axis_picker := UIControlParts.option_button()
	axis_picker.name = "Axis"
	axis_picker.custom_minimum_size = Vector2(118.0, 30.0)
	for axis_index in range(axes.size()):
		var axis: Dictionary = axes[axis_index]
		axis_picker.add_item(String(axis.get("label", "")))
		axis_picker.set_item_tooltip(axis_index, String(axis.get("hint", "")))
	axis_picker.selected = 0
	axis_picker.tooltip_text = String((axes[0] as Dictionary).get("hint", ""))
	group_box.add_child(axis_picker)

	var group_note := UIControlParts.label()
	group_note.name = "Note"
	group_note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	group_note.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	group_box.add_child(group_note)

	var rate_spin := RateFieldScene.instantiate() as SpinBox
	rate_spin.name = "Rate"
	rate_spin.custom_minimum_size = Vector2(88.0, 30.0)
	rate_spin.min_value = -1000.0
	rate_spin.max_value = 100.0
	rate_spin.step = 0.01
	rate_spin.suffix = "%"
	rate_spin.tooltip_text = "整组统一设成这个税率（百分比）"
	rate_spin.get_line_edit().alignment = HORIZONTAL_ALIGNMENT_RIGHT
	rate_spin.set_value_no_signal(clampf(
		TaxLaneEditor.basis_points_to_percent(prefill_rate), -1000.0, 100.0))
	group_box.add_child(rate_spin)

	var group_button := UIControlParts.button()
	group_button.name = "Apply"
	group_button.text = "整组设为"
	group_box.add_child(group_button)

	var state := {"ids": PackedStringArray(), "label": ""}
	var refresh := func() -> void:
		var axis: Dictionary = axes[int(axis_picker.selected)]
		var info: Dictionary = group_host.tax_group_ids_for(
			String(axis.get("id", "")), target_item_id, subject)
		var ids: PackedStringArray = info.get("item_ids", PackedStringArray())
		state["ids"] = ids
		var label := String(info.get("label", ""))
		state["label"] = label
		axis_picker.tooltip_text = String(axis.get("hint", ""))
		if ids.is_empty():
			group_note.text = "整组：这一轴没有可分组的项目"
			group_button.disabled = true
			return
		if ids.size() <= 1:
			group_note.text = "整组：%s · 仅 1 项，直接改上面那一行" % label
			group_button.disabled = true
			return
		group_note.text = "整组：%s · %d 项" % [label, ids.size()]
		group_button.disabled = false
		group_button.tooltip_text = "改的是全国「%s」这一组 %d 项的税率，不是这一格" % [
			label, ids.size()]
	axis_picker.item_selected.connect(func(_index: int) -> void: refresh.call())
	group_button.pressed.connect(func() -> void:
		var ids: PackedStringArray = state["ids"]
		if ids.is_empty():
			return
		var rate_bp := clampi(int(round(rate_spin.value * 100.0)),
			TaxLaneEditor.TAX_RATE_MIN_BP, TaxLaneEditor.TAX_RATE_MAX_BP)
		var result: Dictionary = group_host.request_tax_group_override(
			section_tax_kind, ids, rate_bp)
		if bool(result.get("ok", false)):
			group_note.text = "整组已提交 %s · %d 项（分 %d 批）" % [
				TaxLaneEditor._format_value(rate_bp, TaxLaneEditor.TAX_MODE_PERCENT_BP),
				int(result.get("submitted", 0)), int(result.get("chunks", 1))]
		else:
			group_note.text = "整组未全部生效：%d/%d 批被拒（%s），已提交 %d 项" % [
				int(result.get("failed_chunks", 0)), int(result.get("chunks", 0)),
				String(result.get("reason", "被拒")),
				int(result.get("submitted", 0))])
	refresh.call()
	parent.add_child(group_box)
