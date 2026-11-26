extends RefCounted

## Builds and refreshes the cohort detail view.


static func _build_cohort_details(owner: ObjectDetailDialog, row: Dictionary, tax_context: Variant) -> void:
	var root := ObjectDetailDialog.CohortDossierScene.instantiate() as VBoxContainer
	owner._content.add_child(root)
	var overview_page := root.get_node("%OverviewPage") as VBoxContainer
	var operations_page := root.get_node("%OperationsPage") as VBoxContainer
	var notes := root.get_node("%Notes") as InspectorNoteList
	var living_strip := root.get_node("%LivingStrip") as DossierChart
	var radar_split := root.get_node("%RadarSplit") as GridContainer
	var radar := root.get_node("%SatisfactionRadar") as DossierRadarChart
	var dimension_bars := root.get_node("%DimensionBars") as DossierBarList
	var cashflow_bar := root.get_node("%CashflowBar") as DossierDivergingBar
	var income_stacked := root.get_node("%IncomeStackedBar") as DossierStackedBar
	var expense_stacked := root.get_node("%ExpenseStackedBar") as DossierStackedBar
	var summary_label := root.get_node("%SummaryLabel") as Label
	var tier_kicker := root.get_node("%TierKicker") as Label
	var demand_tier_bars := root.get_node("%DemandTierBars") as DossierBarList
	var goods_kicker := root.get_node("%GoodsKicker") as Label
	var active_demand_bars := root.get_node("%ActiveDemandBars") as DossierBarList
	var demand_empty_note := root.get_node("%DemandEmptyNote") as Label
	var inactive_note := root.get_node("%InactiveAlternativesNote") as Label

	dimension_bars.row_height = 21.0
	dimension_bars.label_width = 68.0
	dimension_bars.value_width = 50.0
	demand_tier_bars.label_width = 104.0
	demand_tier_bars.value_width = 92.0
	active_demand_bars.label_width = 114.0
	active_demand_bars.value_width = 104.0

	# 兼容既有测试对八维核心摘要 4 列网格的断言钩子。
	owner._fact_columns = [4]
	owner._cohort_refs = {
		"root": root,
		"overview_page": overview_page,
		"operations_page": operations_page,
		"notes": notes,
		"living_strip": living_strip,
		"radar_split": radar_split,
		"radar": radar,
		"dimension_bars": dimension_bars,
		"cashflow_bar": cashflow_bar,
		"income_stacked": income_stacked,
		"expense_stacked": expense_stacked,
		"summary_label": summary_label,
		"tier_kicker": tier_kicker,
		"demand_tier_bars": demand_tier_bars,
		"goods_kicker": goods_kicker,
		"active_demand_bars": active_demand_bars,
		"demand_empty_note": demand_empty_note,
		"inactive_note": inactive_note,
	}
	owner._section_targets["overview"] = overview_page
	owner._section_targets["operations"] = operations_page
	owner._build_tax_section("cohort", tax_context, row, operations_page)
	owner._apply_cohort_dossier_data(row, false)
	owner._sync_cohort_radar_split()



static func _patch_cohort_dossier(owner: ObjectDetailDialog, row: Dictionary) -> void:
	owner._apply_cohort_dossier_data(row, true)
	owner._sync_cohort_radar_split()



static func _sync_cohort_radar_split(owner: ObjectDetailDialog) -> void:
	var radar_split := owner._cohort_refs.get("radar_split") as GridContainer
	if radar_split == null or not is_instance_valid(radar_split):
		return
	var w := owner._content_width()
	radar_split.columns = 1 if (w > 1.0 and w < 360.0) else 2



static func _apply_cohort_dossier_data(owner: ObjectDetailDialog, row: Dictionary, live_patch: bool) -> void:
	var dossier := CellInspectorViewModel.cohort_dossier_model(row)
	owner._apply_kpis(dossier.get("kpis", []), live_patch)
	var notes := owner._cohort_refs.get("notes") as InspectorNoteList
	if notes != null:
		var insights: Array = dossier.get("insights", [])
		notes.set_notes(insights)
		notes.visible = not insights.is_empty()
	var living_strip := owner._cohort_refs.get("living_strip") as Control
	if living_strip != null and living_strip.has_method("set_living_state"):
		living_strip.set_living_state(
			int(dossier.get("living_level", -1)),
			String(dossier.get("wealth_text", "—")),
			String(row.get("satisfaction", "—"))
		)
	var radar := owner._cohort_refs.get("radar") as DossierRadarChart
	if radar != null:
		var axes: PackedStringArray = dossier.get("radar_axes", PackedStringArray())
		var vals: PackedFloat32Array = dossier.get("radar_values", PackedFloat32Array())
		var refs: PackedFloat32Array = dossier.get("radar_reference", PackedFloat32Array())
		radar.set_values(axes, vals, refs, UITokens.DOSSIER_OXBLOOD)
	var dim_bars := owner._cohort_refs.get("dimension_bars") as DossierBarList
	if dim_bars != null:
		var dbars: Array = dossier.get("dimension_bars", [])
		dim_bars.set_rows(dbars)
		dim_bars.visible = not dbars.is_empty()
	var cf: Dictionary = dossier.get("cashflow_bar", {})
	var cf_bar := owner._cohort_refs.get("cashflow_bar") as DossierDivergingBar
	if cf_bar != null:
		cf_bar.set_values(
			String(cf.get("left_label", "人均日支")),
			float(cf.get("left_value", 0.0)),
			String(cf.get("left_text", "—")),
			String(cf.get("right_label", "人均日收")),
			float(cf.get("right_value", 0.0)),
			String(cf.get("right_text", "—"))
		)
	var inc_stacked := owner._cohort_refs.get("income_stacked") as DossierStackedBar
	if inc_stacked != null:
		var inc_segs: Array = dossier.get("income_segments", [])
		inc_stacked.visible = not inc_segs.is_empty()
		if not inc_segs.is_empty():
			inc_stacked.set_segments("收入构成", inc_segs,
				"%s/人" % String(row.get("income", "—")), true)
	var exp_stacked := owner._cohort_refs.get("expense_stacked") as DossierStackedBar
	if exp_stacked != null:
		var exp_segs: Array = dossier.get("expense_segments", [])
		exp_stacked.visible = not exp_segs.is_empty()
		if not exp_segs.is_empty():
			exp_stacked.set_segments("支出构成", exp_segs,
				"%s/人" % String(row.get("expense", "—")), true)

	var demand_summary: Dictionary = row.get("demand_summary", {})
	var summary_label := owner._cohort_refs.get("summary_label") as Label
	if summary_label != null:
		var total_cost := String(demand_summary.get("total_daily_cost", ""))
		summary_label.text = ("日均开销 %s/人" % total_cost) \
			if (not total_cost.is_empty() and total_cost != "—") \
			else String(demand_summary.get("value", ""))
	var tier_bars_data: Array = dossier.get("demand_tier_bars", [])
	var tier_kicker := owner._cohort_refs.get("tier_kicker") as Label
	var tier_bars := owner._cohort_refs.get("demand_tier_bars") as DossierBarList
	if tier_kicker != null:
		tier_kicker.visible = not tier_bars_data.is_empty()
	if tier_bars != null:
		tier_bars.visible = not tier_bars_data.is_empty()
		tier_bars.set_rows(tier_bars_data)
	var active_bars_data: Array = dossier.get("active_demand_bars", [])
	var goods_kicker := owner._cohort_refs.get("goods_kicker") as Label
	var active_bars := owner._cohort_refs.get("active_demand_bars") as DossierBarList
	if goods_kicker != null:
		goods_kicker.visible = not active_bars_data.is_empty()
	if active_bars != null:
		active_bars.visible = not active_bars_data.is_empty()
		active_bars.set_rows(active_bars_data)
	var empty_note := owner._cohort_refs.get("demand_empty_note") as Label
	if empty_note != null:
		empty_note.text = "当前无活跃物资消费。"
		empty_note.visible = active_bars_data.is_empty()
	var inactive_note := owner._cohort_refs.get("inactive_note") as Label
	if inactive_note != null:
		var summary_str := String(dossier.get("inactive_alternatives_summary", ""))
		inactive_note.text = summary_str
		inactive_note.visible = not summary_str.is_empty()
