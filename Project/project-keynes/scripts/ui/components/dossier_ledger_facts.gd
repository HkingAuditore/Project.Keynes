extends RefCounted

static func _good_ledger_facts(row: Dictionary) -> Array:
	var dossier := CellInspectorViewModel.good_dossier_model(row)
	var anchor_text := String(row.get("cost_anchor_text", "—"))
	if anchor_text == "—" or anchor_text.is_empty():
		for item in row.get("detail_rows", []):
			if item is Dictionary and String((item as Dictionary).get("id", "")) == "cost_anchor":
				anchor_text = String((item as Dictionary).get("value", "—"))
				break
	var delta_text := String(row.get("delta", "—"))
	var facts := [
		{"label": "本地库存", "value": String(row.get("stock_plain", row.get("stock", "—"))),
			"accent": UITokens.DOSSIER_INK},
		{"label": "本地时价", "value": String(row.get("price", "—")),
			"accent": UITokens.DOSSIER_INK},
		{"label": "成本锚价", "value": anchor_text,
			"accent": UITokens.DOSSIER_INK_SOFT},
		{"label": "库存日变", "value": delta_text,
			"accent": _delta_accent(delta_text)},
	]
	var inbound := String(row.get("trade_inbound", ""))
	var outbound := String(row.get("trade_outbound", ""))
	if not inbound.is_empty():
		facts.append({"label": "在途运入", "value": inbound, "accent": UITokens.DOSSIER_VERDIGRIS})
	if not outbound.is_empty():
		facts.append({"label": "在途运出", "value": outbound, "accent": UITokens.DOSSIER_OXBLOOD})
	return facts


static func _cohort_ledger_facts(row: Dictionary) -> Array:
	var income_rows: Array = row.get("income_rows", [])
	var expense_rows: Array = row.get("expense_rows", [])
	var income_label := "人均日收"
	var primary_income := String(row.get("income", "—"))
	if not income_rows.is_empty() and income_rows[0] is Dictionary:
		var ir: Dictionary = income_rows[0]
		income_label = String(ir.get("name", income_label))
		primary_income = String(ir.get("value", primary_income))
	var expense_label := "人均日支"
	var primary_expense := String(row.get("expense", "—"))
	if not expense_rows.is_empty() and expense_rows[0] is Dictionary:
		var er: Dictionary = expense_rows[0]
		expense_label = String(er.get("name", expense_label))
		primary_expense = String(er.get("value", primary_expense))
	return [
		{"label": "阶层人口", "value": String(row.get("population", "—")),
			"accent": UITokens.DOSSIER_INK},
		{"label": "综合满意度", "value": String(row.get("satisfaction", "—")),
			"accent": UITokens.DOSSIER_INK},
		{"label": income_label, "value": primary_income,
			"accent": UITokens.DOSSIER_VERDIGRIS},
		{"label": expense_label, "value": primary_expense,
			"accent": UITokens.DOSSIER_OXBLOOD},
	]


static func _delta_accent(delta: String) -> Color:
	if delta.begins_with("+"):
		return UITokens.DOSSIER_VERDIGRIS
	if delta.begins_with("-") or delta.begins_with("−"):
		return UITokens.DOSSIER_OXBLOOD
	return UITokens.DOSSIER_INK_MUTED
