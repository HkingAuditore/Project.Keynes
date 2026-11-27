extends RefCounted

## Builds building, resource, and family details.


static func _build_building_details(owner: ObjectDetailDialog, row: Dictionary, tax_context: Variant = {}) -> void:
	var root := ObjectDetailDialog.BuildingDossierScene.instantiate() as VBoxContainer
	owner._content.add_child(root)
	var overview_page := root.get_node("%OverviewPage") as VBoxContainer
	var operations_page := root.get_node("%OperationsPage") as VBoxContainer
	var notes := root.get_node("%Notes") as InspectorNoteList
	var loss_card := root.get_node("%LossCard") as PanelContainer
	var loss_summary := root.get_node("%LossCard/Box/Summary") as Label
	var loss_diverging_bar := root.get_node("%LossCard/Box/DivergingBar") as DossierDivergingBar
	var loss_cost_bar := root.get_node("%LossCard/Box/CostBar") as DossierStackedBar
	var capacity_bars := root.get_node("%CapacityBars") as DossierBarList
	var job_kicker := root.get_node("%JobKicker") as Label
	var job_bars := root.get_node("%JobBars") as DossierBarList
	var unused_inputs_note := root.get_node("%UnusedInputsNote") as Label
	var finance_warning := root.get_node("%FinanceWarning") as Label
	var finance_diverging_bar := root.get_node("%FinanceDivergingBar") as DossierDivergingBar
	var revenue_stacked_bar := root.get_node("%RevenueStackedBar") as DossierStackedBar
	var cost_stacked_bar := root.get_node("%CostStackedBar") as DossierStackedBar
	var finance_note := root.get_node("%FinanceNote") as Label

	capacity_bars.label_width = 110.0
	capacity_bars.value_width = 64.0
	job_bars.label_width = 158.0
	job_bars.value_width = 64.0

	owner._fact_columns = [3]
	owner._building_refs = {
		"root": root,
		"overview_page": overview_page,
		"operations_page": operations_page,
		"notes": notes,
		"loss_card": loss_card,
		"loss_summary": loss_summary,
		"loss_diverging_bar": loss_diverging_bar,
		"loss_cost_bar": loss_cost_bar,
		"capacity_bars": capacity_bars,
		"job_kicker": job_kicker,
		"job_bars": job_bars,
		"capacity_card": root.get_node("%CapacityCard"),
		"job_rule": root.get_node("%Rule"),
		"production_card": root.get_node("%ProductionCard"),
		"production_rows": root.get_node("%ProductionRows"),
		"construction_card": root.get_node("%ConstructionCard"),
		"requirements": root.get_node("%Requirements"),
		"unused_inputs_note": unused_inputs_note,
		"finance_warning": finance_warning,
		"finance_diverging_bar": finance_diverging_bar,
		"revenue_stacked_bar": revenue_stacked_bar,
		"cost_stacked_bar": cost_stacked_bar,
		"finance_note": finance_note,
	}
	owner._section_targets["overview"] = overview_page
	owner._section_targets["operations"] = operations_page
	owner._build_tax_section("building", tax_context, row, operations_page)
	owner._apply_building_dossier_data(row, false)



static func _patch_building_dossier(owner: ObjectDetailDialog, row: Dictionary) -> void:
	owner._apply_building_dossier_data(row, true)



static func _apply_building_dossier_data(owner: ObjectDetailDialog, row: Dictionary, live_patch: bool) -> void:
	var dossier := CellInspectorViewModel.building_dossier_model(row)
	owner._apply_kpis(dossier.get("kpis", []), live_patch)
	var notes := owner._building_refs.get("notes") as InspectorNoteList
	if notes != null:
		var insights: Array = dossier.get("insights", [])
		notes.set_notes(insights)
		notes.visible = not insights.is_empty()
	var loss_card := owner._building_refs.get("loss_card") as PanelContainer
	var loss_summary := owner._building_refs.get("loss_summary") as Label
	var loss_diverging_bar := owner._building_refs.get("loss_diverging_bar") as DossierDivergingBar
	var loss_cost_bar := owner._building_refs.get("loss_cost_bar") as DossierStackedBar
	var loss_visible := bool(dossier.get("loss_visible", false))
	if loss_card != null:
		loss_card.visible = loss_visible
	if loss_summary != null:
		loss_summary.text = String(dossier.get("loss_summary", ""))
		loss_summary.visible = loss_visible
	if loss_visible:
		var loss_fd: Dictionary = dossier.get("loss_diverging_bar", {})
		if loss_diverging_bar != null:
			loss_diverging_bar.set_values(
				String(loss_fd.get("left_label", "含税总支出")),
				float(loss_fd.get("left_value", 0.0)),
				String(loss_fd.get("left_text", "0")),
				String(loss_fd.get("right_label", "税前总收入")),
				float(loss_fd.get("right_value", 0.0)),
				String(loss_fd.get("right_text", "0")))
		if loss_cost_bar != null:
			var loss_segments: Array = dossier.get("loss_cost_segments", [])
			loss_cost_bar.set_segments("支出构成", loss_segments,
				String(loss_fd.get("left_text", "0")), true)
	var cap_bars := owner._building_refs.get("capacity_bars") as DossierBarList
	if cap_bars != null:
		var cbars: Array = dossier.get("capacity_bars", [])
		cap_bars.set_rows(cbars)
		cap_bars.visible = not cbars.is_empty()
	var jbars_data: Array = dossier.get("job_bars", [])
	var job_kicker := owner._building_refs.get("job_kicker") as Label
	var job_bars := owner._building_refs.get("job_bars") as DossierBarList
	var has_jobs := not jbars_data.is_empty()
	job_kicker.visible = has_jobs
	job_bars.visible = has_jobs
	job_bars.set_rows(jbars_data)
	owner._building_refs.job_rule.visible = has_jobs and cap_bars.visible
	owner._building_refs.capacity_card.visible = has_jobs or cap_bars.visible

	var production: Array = dossier.get("production_bars", [])
	var unused_note := owner._building_refs.get("unused_inputs_note") as Label
	unused_note.text = String(dossier.get("unused_inputs_summary", ""))
	unused_note.visible = not unused_note.text.is_empty()
	owner._building_refs.production_card.visible = not production.is_empty() or unused_note.visible
	owner._building_refs.production_rows.set_rows(production)
	owner._building_refs.production_rows.visible = not production.is_empty()

	var requirements: Array = dossier.get("construction_requirements", [])
	owner._building_refs.construction_card.visible = not requirements.is_empty()
	owner._building_refs.requirements.set_rows(requirements)

	var fwarn := owner._building_refs.get("finance_warning") as Label
	if fwarn != null:
		var warn_str := String(dossier.get("finance_warning", ""))
		fwarn.text = warn_str
		fwarn.visible = not warn_str.is_empty()
	var fd: Dictionary = dossier.get("finance_diverging_bar", {})
	var fd_bar := owner._building_refs.get("finance_diverging_bar") as DossierDivergingBar
	if fd_bar != null:
		fd_bar.set_values(
			String(fd.get("left_label", "本期总成本")),
			float(fd.get("left_value", 0.0)),
			String(fd.get("left_text", "0")),
			String(fd.get("right_label", "税后总收入")),
			float(fd.get("right_value", 0.0)),
			String(fd.get("right_text", "0"))
		)
	var rev_stacked := owner._building_refs.get("revenue_stacked_bar") as DossierStackedBar
	if rev_stacked != null:
		var rev_segs: Array = dossier.get("revenue_segments", [])
		rev_stacked.visible = not rev_segs.is_empty()
		if not rev_segs.is_empty():
			rev_stacked.set_segments("收入构成（税前）", rev_segs,
				String(fd.get("right_text", "0")), true)
	var cost_stacked := owner._building_refs.get("cost_stacked_bar") as DossierStackedBar
	if cost_stacked != null:
		var cost_segs: Array = dossier.get("cost_segments", [])
		cost_stacked.visible = not cost_segs.is_empty()
		if not cost_segs.is_empty():
			cost_stacked.set_segments("成本构成", cost_segs,
				String(fd.get("left_text", "0")), true)
	var fnote := owner._building_refs.get("finance_note") as Label
	if fnote != null:
		var note_str := String(dossier.get("finance_note", ""))
		fnote.text = note_str
		fnote.visible = not note_str.is_empty()



static func _build_resource_details(owner: ObjectDetailDialog, row: Dictionary) -> void:
	owner._section_targets["overview"] = owner._add_fact_grid(owner._facts_for_row("resource", row))



static func _build_family_details(owner: ObjectDetailDialog, row: Dictionary) -> void:
	owner._section_targets["overview"] = owner._add_fact_grid(owner._facts_for_row("family", row))
	var people_target := owner._add_rows_card("家族特性", "family.house", UITokens.DOSSIER_INK,
		row.get("trait_rows", []))
	owner._add_rows_card("行为偏好", "growth", UITokens.DOSSIER_VERDIGRIS,
		row.get("behavior_rows", []))
	var branch_target := owner._add_rows_card("地块威望", "family.house", UITokens.DOSSIER_INK,
		row.get("branch_rows", []))
	var action_target := owner._add_branch_colonization_buttons(int(row.get("family_handle", 0)),
		row.get("branch_rows", []))
	if branch_target != null:
		people_target = branch_target
	elif action_target != null:
		people_target = action_target
	var family_effect_target := owner._add_rows_card("家族效果", "growth", UITokens.DOSSIER_BRASS,
		row.get("effect_rows", []))
	var effects_target := owner._add_rows_card("已激活加成", "growth", UITokens.DOSSIER_BRASS,
		row.get("modifier_rows", []))
	var trigger_target := owner._add_rows_card("累计触发", "resource", UITokens.DOSSIER_BRASS,
		row.get("trigger_rows", []))
	if family_effect_target != null:
		effects_target = family_effect_target
	elif effects_target == null:
		effects_target = trigger_target
	var people: Array = row.get("notable_person_rows", [])
	if not people.is_empty():
		var notable_target := owner._add_rows_card("主要人物", "family.house", UITokens.DOSSIER_INK, people)
		if people_target == null:
			people_target = notable_target
	if people_target != null:
		owner._section_targets["operations"] = people_target
	if family_effect_target != null:
		owner._section_targets["effects"] = family_effect_target
	elif effects_target != null:
		owner._section_targets["effects"] = effects_target
	elif trigger_target != null:
		owner._section_targets["effects"] = trigger_target



static func _add_branch_colonization_buttons(owner: ObjectDetailDialog, family_handle: int, branches: Array) -> Control:
	if family_handle == 0 or branches.is_empty():
		return null
	var panel := ObjectDetailDialog.RowsCardScene.instantiate() as PanelContainer
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.clip_contents = false
	owner._content.add_child(panel)
	(panel.get_node("Box/TitleRow/Icon") as IconBadge).set_semantic(
		&"family.house", UITokens.DOSSIER_OXBLOOD)
	var title := panel.get_node("Box/TitleRow/Title") as Label
	title.text = "选择开拓源分支"
	title.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	var rows := panel.get_node("Box/Rows") as VBoxContainer
	for raw in branches:
		var branch: Dictionary = raw
		var source_cell := int(branch.get("cell", -1))
		if source_cell < 0:
			continue
		var button := ObjectDetailDialog.ActionButtonScene.instantiate() as Button
		button.clip_text = true
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.text = "%s · 从此城派遣" % String(branch.get(
			"name", "地块 %d" % source_cell))
		var owned: bool = owner._player_controller != null and \
			owner._player_controller.has_method("is_player_owned_cell") and \
			bool(owner._player_controller.is_player_owned_cell(source_cell))
		button.disabled = not owned
		button.tooltip_text = "仅玩家领土内的家族分支可以派遣" if not owned \
			else "选择一个可见的无主或本国陆地作为目标"
		button.pressed.connect(func() -> void:
			owner.colonization_requested.emit(family_handle, source_cell))
		rows.add_child(button)
	return panel



static func _delta_accent(owner: ObjectDetailDialog, delta: String) -> Color:
	return ObjectDetailDialog.LedgerFacts._delta_accent(delta)
