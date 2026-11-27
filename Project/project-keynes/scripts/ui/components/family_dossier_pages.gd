extends RefCounted

## Builds the detailed trait, preference, effect, person, and branch pages.


static func _build_trait_page(owner: FamilyWorkspace, page: VBoxContainer, rows: Array) -> void:
	if rows.is_empty():
		owner._add_empty_label(page, "这个家族尚未形成可记录的特性。")
		return
	owner._add_section_label(page, "家风特性")
	for raw in rows:
		var row: Dictionary = raw
		var card := owner._new_card()
		page.add_child(card)
		var body := owner._card_body(card)
		var header_row := owner._add_title_value_row(body, String(row.get("name", "特性")),
			String(row.get("kind_label", row.get("value", "附加特性"))))
		owner._append_trait_badges(header_row, row)
		var detail := String(row.get("detail", "无"))
		owner._add_wrapped_label(body, detail, true)
		var effect_summary := String(row.get("effect_summary", ""))
		if not effect_summary.strip_edges().is_empty() and \
				owner._family_display_key(effect_summary) != owner._family_display_key(detail):
			owner._add_wrapped_label(body, effect_summary, false)



static func _build_preference_page(owner: FamilyWorkspace, page: VBoxContainer, rows: Array) -> void:
	if rows.is_empty():
		return
	var current_axis := ""
	for raw in rows:
		var row: Dictionary = raw
		var axis_name := String(row.get("axis_name", "行为"))
		if axis_name != current_axis:
			current_axis = axis_name
			owner._add_section_label(page, "%s偏好" % axis_name)
		var card := owner._new_card()
		page.add_child(card)
		var body := owner._card_body(card)
		var top_row := FamilyWorkspace.FamilyHBoxScene.instantiate() as HBoxContainer
		top_row.add_theme_constant_override("separation", 8)
		body.add_child(top_row)
		var badge := FamilyWorkspace.IconBadgeScene.instantiate() as IconBadge
		badge.custom_minimum_size = Vector2(22.0, 22.0)
		var factor_pct := float(row.get("factor_percent", 100.0))
		var accent := UITokens.GOOD if factor_pct >= 105.0 \
			else (UITokens.RISK if factor_pct <= 95.0 else UITokens.WARN)
		badge.set_semantic(owner._preference_icon_key(row), accent)
		top_row.add_child(badge)
		var title_label := FamilyWorkspace.FamilyLabelScene.instantiate() as Label
		title_label.text = String(row.get("name", "偏好"))
		title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		title_label.theme_type_variation = &"FamilyStrongLabel"
		title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		top_row.add_child(title_label)
		var value_label := FamilyWorkspace.FamilyLabelScene.instantiate() as Label
		value_label.text = String(row.get("factor_text", row.get("value", "100%")))
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value_label.size_flags_horizontal = Control.SIZE_SHRINK_END
		value_label.theme_type_variation = &"PKDossierValue"
		value_label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
		top_row.add_child(value_label)
		var meter := FamilyWorkspace.MeterListScene.instantiate() as InspectorMeterList
		meter.name = "PrefMeter"
		meter.set_meters([owner._preference_meter_dict(row)])
		body.add_child(meter)



static func _preference_meter_dict(owner: FamilyWorkspace, row: Dictionary) -> Dictionary:
	var factor_pct := float(row.get("factor_percent", 100.0))
	var signed_delta := factor_pct - 100.0
	var delta_text := "%s%.0f%%" % [
		"+" if signed_delta >= 0.0 else "−", absf(signed_delta)]
	var accent := UITokens.GOOD if factor_pct >= 105.0 \
		else (UITokens.RISK if factor_pct <= 95.0 else UITokens.WARN)
	return {
		"id": String(row.get("id", row.get("name", "pref"))),
		"label": String(row.get("axis_name", "权重")),
		"value": clampf(factor_pct / 200.0, 0.0, 1.0),
		"marker": 0.5,
		"value_text": "基线 100%",
		"status_label": "偏离 %s" % delta_text,
		"accent": accent,
	}



static func _build_effect_page(owner: FamilyWorkspace, page: VBoxContainer, rows: Array) -> void:
	if rows.is_empty():
		return
	var current_cell := -999999
	for raw in rows:
		var row: Dictionary = raw
		var cell := int(row.get("cell", -1))
		if cell != current_cell:
			current_cell = cell
			var settlement := String(row.get("settlement_name", "")).strip_edges()
			var section_title := ("%s（地块 %d）" % [settlement, cell] \
				if not settlement.is_empty() else "地块 %d" % cell) \
				if cell >= 0 else "家族整体"
			owner._add_section_label(page, section_title)
		var card := owner._new_card()
		page.add_child(card)
		var body := owner._card_body(card)
		var p_level := int(row.get("prestige_level", 0))
		var status_text := String(row.get("value", ""))
		if String(row.get("kind", "")) == "effect":
			status_text = "稀有效果 · 威望 %s" % CellInspectorViewModel._prestige_text(p_level)
		owner._add_title_value(body, String(row.get("title", row.get("name", "效果"))), status_text)
		owner._add_wrapped_label(body, String(row.get("detail", "")), true)
		var tiers: Array = row.get("tier_statements", [])
		if not tiers.is_empty():
			var ladder := FamilyWorkspace.FamilyVBoxScene.instantiate() as VBoxContainer
			ladder.name = "TierLadder"
			ladder.add_theme_constant_override("separation", 4)
			body.add_child(ladder)
			for tier_idx in range(tiers.size()):
				var tier_panel := FamilyWorkspace.FamilyCardScene.instantiate() as PanelContainer
				var is_active_tier := (tier_idx + 1) == p_level
				tier_panel.theme_type_variation = &"FamilyTierActive" \
					if is_active_tier else &"FamilyTierLocked"
				ladder.add_child(tier_panel)
				var tier_body := owner._card_body(tier_panel)
				var tier_label := FamilyWorkspace.FamilyLabelScene.instantiate() as Label
				var prefix := "【当前生效】" if is_active_tier \
					else ("【已达成】" if (tier_idx + 1) < p_level else "【待解锁】")
				tier_label.text = "%s %s" % [prefix, String(tiers[tier_idx])]
				tier_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				tier_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				tier_label.theme_type_variation = &"FamilyStrongLabel" \
					if is_active_tier else &"FamilyMutedLabel"
				tier_body.add_child(tier_label)
		if String(row.get("kind", "")) == "trigger":
			var trigger_meter := FamilyWorkspace.MeterListScene.instantiate() as InspectorMeterList
			trigger_meter.name = "TriggerMeter"
			trigger_meter.set_meters([{
				"id": String(row.get("id", "trigger")),
				"label": "触发进度",
				"value": clampf(float(row.get("progress_ratio", 0.0)), 0.0, 1.0),
				"value_text": "%d / %d" % [int(row.get("progress", 0)), int(row.get("threshold", 1))],
				"status_label": "已触发 %d 次" % int(row.get("completed", 0)),
				"accent": UITokens.WARN,
			}])
			body.add_child(trigger_meter)



static func _build_people_page(owner: FamilyWorkspace, page: VBoxContainer, rows: Array) -> void:
	if rows.is_empty():
		return
	var table := DossierLedgerTable.new()
	table.name = "PeoplePageLedger"
	table.row_height = 28.0
	table.set_columns(owner._people_ledger_columns(), "worth", true)
	table.set_rows(owner._people_ledger_rows(rows))
	page.add_child(table)
	var grid := FamilyWorkspace.FamilyGridScene.instantiate() as GridContainer
	grid.name = "PeoplePageGrid"
	grid.columns = 2 if owner.size.x >= 680.0 else 1
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 12)
	page.add_child(grid)
	for raw in rows:
		var row: Dictionary = raw
		var card := owner._new_card()
		grid.add_child(card)
		var card_body := owner._card_body(card)
		var horizontal := FamilyWorkspace.FamilyHBoxScene.instantiate() as HBoxContainer
		horizontal.add_theme_constant_override("separation", 10)
		card_body.add_child(horizontal)
		var portrait := FamilyWorkspace.FamilyTextureScene.instantiate() as TextureRect
		portrait.name = "Portrait"
		portrait.custom_minimum_size = Vector2(48.0, 56.0)
		portrait.texture = IconCatalog.texture_for_key(&"family.workspace.person")
		portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		horizontal.add_child(portrait)
		var text_box := FamilyWorkspace.FamilyVBoxScene.instantiate() as VBoxContainer
		text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_box.add_theme_constant_override("separation", 2)
		horizontal.add_child(text_box)
		owner._add_title_value(text_box, String(row.get("name", "未命名人物")),
			String(row.get("role", "家族成员")))
		owner._add_wrapped_label(text_box, String(row.get("profession", "身份未详")), true)
		var building := String(row.get("building", ""))
		owner._add_wrapped_label(text_box,
			"所属产业：%s" % building if not building.is_empty() else "所属产业：无", true)
		var facts := FamilyWorkspace.FactGridScene.instantiate() as InspectorFactGrid
		facts.name = "PersonFacts"
		facts.set_facts(owner._person_fact_cells(row))
		card_body.add_child(facts)
		var cashflow_bar := DossierDivergingBar.new()
		cashflow_bar.name = "PersonCashflowBar"
		owner._update_person_cashflow_bar(cashflow_bar, row)
		card_body.add_child(cashflow_bar)



static func _person_fact_cells(owner: FamilyWorkspace, row: Dictionary) -> Array:
	var person_id := String(row.get("id", row.get("name", "person")))
	var net_worth := String(row.get("net_worth_text", ""))
	if net_worth.is_empty():
		var role_str := String(row.get("role", "家族成员"))
		var prof_str := String(row.get("profession", "家族实业"))
		var bld_str := String(row.get("building", "家族本宅"))
		return [
			{"id": "%s_role" % person_id, "title": "家族职务", "value": role_str,
				"icon": "family.house", "accent": UITokens.RESOURCE},
			{"id": "%s_prof" % person_id, "title": "从业身份", "value": prof_str,
				"icon": "population.profession.owner", "accent": UITokens.WARN},
			{"id": "%s_bld" % person_id, "title": "执掌产业",
				"value": bld_str if not bld_str.is_empty() else "家族本宅",
				"icon": "economy.building", "accent": UITokens.GOOD},
			{"id": "%s_state" % person_id, "title": "履职状态", "value": "在职主理",
				"icon": "population.heart", "accent": UITokens.ECO},
		]
	var cash := String(row.get("cash_claim_text", ""))
	var equity := String(row.get("equity_share_text", "—"))
	var attr_asset := String(row.get("attributed_asset_text", ""))
	var net_flow := String(row.get("net_cashflow_text", "—"))
	var sat := String(row.get("satisfaction_text", "—"))
	return [
		{"id": "%s_worth" % person_id, "title": "个人净资产", "money": true, "value": net_worth,
			"subtitle": "现金 %s" % cash if not cash.is_empty() else "",
			"icon": "metric.treasury", "accent": UITokens.RESOURCE},
		{"id": "%s_equity" % person_id, "title": "家族股权占比", "value": equity,
			"subtitle": "权益 %s" % attr_asset if not attr_asset.is_empty() else "",
			"icon": "economy.building", "accent": UITokens.WARN},
		{"id": "%s_flow" % person_id, "title": "周期净收支", "money": true, "value": net_flow,
			"icon": "country.economy",
			"accent": UITokens.RISK if net_flow.begins_with("−") else UITokens.GOOD},
		{"id": "%s_sat" % person_id, "title": "生存满足", "value": sat,
			"icon": "population.heart", "accent": UITokens.ECO},
	]



static func _update_person_cashflow_bar(owner: FamilyWorkspace, bar: DossierDivergingBar, row: Dictionary) -> void:
	var has_flow := row.has("income_val") or row.has("expense_val")
	var exp_val := float(row.get("expense_val", 0.35 if not has_flow else 0.0))
	var inc_val := float(row.get("income_val", 0.65 if not has_flow else 0.0))
	var exp_text := String(row.get("expense_text", "稳健支出" if not has_flow else "0"))
	var inc_text := String(row.get("income_text", "经营盈余" if not has_flow else "0"))
	bar.set_values("周期消费与税负", exp_val, exp_text, "周期薪资与分红", inc_val, inc_text)



static func _build_branch_page(owner: FamilyWorkspace, page: VBoxContainer, rows: Array) -> void:
	if rows.is_empty():
		return
	owner._add_section_label(page, "家族晋升 · 家风特性")
	var trait_rows: Array = owner._model.get("pages", {}).get("traits", [])
	var trait_names := PackedStringArray()
	for trait_row in trait_rows:
		if trait_row is Dictionary and not String(trait_row.get("name", "")).strip_edges().is_empty():
			trait_names.append(String(trait_row.get("name", "")))
	if not trait_names.is_empty():
		owner._add_wrapped_label(page, "本家族家风：%s" % " · ".join(trait_names), true)
	for raw in rows:
		var row: Dictionary = raw
		var card := owner._new_card()
		page.add_child(card)
		var body := owner._card_body(card)
		owner._add_title_value(body, "地块 %d" % int(row.get("cell", -1)),
			"威望 %s · %s" % [String(row.get("prestige_label", "0")),
			String(row.get("prestige_text", "0%"))])
		owner._add_wrapped_label(body, "人口 %s · 现金 %s · 建筑 %s" % [
			String(row.get("population_share_text", "0%")),
			String(row.get("cash_share_text", "0%")),
			String(row.get("building_share_text", "0%"))], true)
		owner._add_wrapped_label(body, "晋级目标 %s · 复核 %d/%d" % [
			String(row.get("target_label", "0")), int(row.get("review_streak", 0)),
			int(row.get("review_required", 2))], true)
		var meters := FamilyWorkspace.MeterListScene.instantiate() as InspectorMeterList
		meters.name = "BranchMeters"
		meters.set_meters(owner._branch_meter_dicts(row))
		body.add_child(meters)
		var action := FamilyWorkspace.FamilyButtonScene.instantiate() as Button
		action.text = "从此城派遣"
		action.theme_type_variation = &"FamilyActionButton"
		action.disabled = not owner._colonization_available(int(row.get("cell", -1)))
		action.tooltip_text = "保留此城与家族，打开派遣工作区选择目的地"
		action.pressed.connect(func() -> void:
			owner.colonization_requested.emit(owner._family_handle, int(row.get("cell", -1))))
		body.add_child(action)



static func _branch_meter_dicts(owner: FamilyWorkspace, row: Dictionary) -> Array:
	var cell := int(row.get("cell", -1))
	var score_pct := float(row.get("prestige_percent",
		float(int(row.get("prestige_score_q16", 0))) * 100.0 / 65536.0))
	var pop_pct := float(int(row.get("population_share_q16", 0))) * 100.0 / 65536.0
	var cash_pct := float(int(row.get("cash_share_q16", 0))) * 100.0 / 65536.0
	var bld_pct := float(int(row.get("building_share_q16", 0))) * 100.0 / 65536.0
	return [
		{"id": "br_%d_score" % cell, "label": "威望总分",
			"value": clampf(score_pct / 100.0, 0.0, 1.0),
			"status_label": "据点综合威望",
			"accent": UITokens.WARN},
		{"id": "br_%d_pop" % cell, "label": "人口份额",
			"value": clampf(pop_pct / 100.0, 0.0, 1.0),
			"value_text": String(row.get("population_share_text", "%.1f%%" % pop_pct)),
			"status_label": String(row.get("population_count_text", "")),
			"accent": UITokens.ECO},
		{"id": "br_%d_cash" % cell, "label": "资金份额",
			"value": clampf(cash_pct / 100.0, 0.0, 1.0),
			"value_text": String(row.get("cash_share_text", "%.1f%%" % cash_pct)),
			"status_label": String(row.get("cash_amount_text", "")),
			"accent": UITokens.RESOURCE},
		{"id": "br_%d_bld" % cell, "label": "产业份额",
			"value": clampf(bld_pct / 100.0, 0.0, 1.0),
			"value_text": String(row.get("building_share_text", "%.1f%%" % bld_pct)),
			"status_label": String(row.get("building_asset_text", "")),
			"accent": UITokens.WATER},
	]
