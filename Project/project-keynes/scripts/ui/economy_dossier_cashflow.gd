extends RefCounted

## Shapes national cashflow history and receipts.


static func cashflow_model(owner: EconomyDossierViewModel, window_days: int = EconomyDossierViewModel.DEFAULT_CASHFLOW_WINDOW_DAYS) -> Dictionary:
	var history = owner._model.get("fiscal_history", null)
	var fiscal: Dictionary = owner._model.get("fiscal", {})
	if history is EconomyFiscalHistory:
		return EconomyDossierViewModel.cashflow_from_history(history, fiscal, window_days)
	return EconomyDossierViewModel.build_cashflow(fiscal)



static func cashflow_from_history(history: EconomyFiscalHistory, fiscal: Dictionary,
		window_days: int = EconomyDossierViewModel.DEFAULT_CASHFLOW_WINDOW_DAYS) -> Dictionary:
	var rolling := history.rolling_snapshot(window_days)
	var flow: Dictionary
	if bool(rolling.get("ok", false)):
		flow = EconomyDossierViewModel.build_rolling_cashflow(rolling)
	else:
		flow = EconomyDossierViewModel.build_cashflow(history.display_snapshot(fiscal))
	flow["history_available"] = history.size() > 0 or history.latest_cash_day() >= 0
	flow["can_roll"] = history.cash_size() >= 2
	flow["income_series"] = EconomyDossierViewModel._series_money(history.income_series())
	flow["expense_series"] = EconomyDossierViewModel._series_money(history.expense_series())
	return flow


## 把窗口内去重后的结算事件折算成日均，再用国库现金首尾差补齐未细分项目。
## `rolling` 来自 `EconomyFiscalHistory.rolling_snapshot()`，金额仍是原生
## 1/10000 货币单位。
static func build_rolling_cashflow(rolling: Dictionary) -> Dictionary:
	var days := maxi(1, int(rolling.get("covered_days", 1)))
	var daily := {
		"ok": true,
		"has_settlement": true,
		"sample_day": int(rolling.get("sample_day", -1)),
		"tax_kinds": rolling.get("tax_kinds", PackedStringArray()),
		"tax_base": EconomyDossierViewModel._average_values(rolling.get("tax_base", PackedInt64Array()), days),
		"collected": EconomyDossierViewModel._average_values(rolling.get("collected", PackedInt64Array()), days),
		"subsidy_requested": EconomyDossierViewModel._average_values(
			rolling.get("subsidy_requested", PackedInt64Array()), days),
		"subsidy_paid": EconomyDossierViewModel._average_values(
			rolling.get("subsidy_paid", PackedInt64Array()), days),
		"non_tax_outflow_kinds": rolling.get(
			"non_tax_outflow_kinds", PackedStringArray()),
		"non_tax_outflow": EconomyDossierViewModel._average_values(
			rolling.get("non_tax_outflow", PackedInt64Array()), days),
	}
	var flow := EconomyDossierViewModel.build_cashflow(daily)
	if not bool(flow.get("ok", false)):
		flow["history_available"] = true
		return flow
	var other_change := float(rolling.get("unclassified_change", 0)) / float(days)
	if absf(other_change) > 0.000001:
		if other_change > 0.0:
			var income_segment: Dictionary = EconomyDossierViewModel._flow_segments([{
				"label": EconomyDossierViewModel.OTHER_TREASURY_CHANGE_LABEL,
				"value": other_change,
			}], UITokens.DOSSIER_BRASS)[0]
			(flow["income_segments"] as Array).append(income_segment)
			flow["income_total"] = float(flow.get("income_total", 0.0)) \
				+ other_change / EconomyDossierViewModel.MONEY_SCALE
			(flow["detail_rows"] as Array).append(
				EconomyDossierViewModel._other_treasury_change_row(other_change, true))
		else:
			var expense_segment: Dictionary = EconomyDossierViewModel._flow_segments([{
				"label": EconomyDossierViewModel.OTHER_TREASURY_CHANGE_LABEL,
				"value": -other_change,
			}], UITokens.DOSSIER_OXBLOOD)[0]
			(flow["expense_segments"] as Array).append(expense_segment)
			flow["expense_total"] = float(flow.get("expense_total", 0.0)) \
				+ (-other_change) / EconomyDossierViewModel.MONEY_SCALE
			(flow["detail_rows"] as Array).append(
				EconomyDossierViewModel._other_treasury_change_row(-other_change, false))
	var income := float(flow.get("income_total", 0.0))
	var expense := float(flow.get("expense_total", 0.0))
	var net := income - expense
	var window := int(rolling.get("window_days", days))
	var covered := int(rolling.get("covered_days", days))
	var partial := covered < window
	var label := "近 %d 日 · 日均" % window
	flow["rolling"] = true
	flow["window_days"] = window
	flow["covered_days"] = covered
	flow["event_days"] = int(rolling.get("event_days", 0))
	flow["is_partial"] = partial
	flow["window_label"] = label
	flow["window_text"] = label + (" · 实际 %d 日" % covered if partial else "")
	flow["coverage_text"] = "实际 %d 日" % covered if partial else ""
	flow["cash_change"] = float(rolling.get("cash_change", 0)) / EconomyDossierViewModel.MONEY_SCALE
	flow["classified_net"] = float(rolling.get("classified_net", 0)) / EconomyDossierViewModel.MONEY_SCALE
	flow["other_change"] = other_change / EconomyDossierViewModel.MONEY_SCALE
	flow["income_text"] = EconomyDossierViewModel._money_text(income * EconomyDossierViewModel.MONEY_SCALE)
	flow["expense_text"] = EconomyDossierViewModel._money_text(expense * EconomyDossierViewModel.MONEY_SCALE)
	flow["net"] = net
	flow["net_text"] = ("+" if net >= 0.0 else "−") \
		+ EconomyDossierViewModel._money_text(absf(net) * EconomyDossierViewModel.MONEY_SCALE)
	flow["net_positive"] = net >= 0.0
	flow["day_text"] = String(flow.get("window_text", label))
	flow["series_is_settlement"] = true
	return flow



static func _series_money(values: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(values.size())
	for index in range(values.size()):
		out[index] = values[index] / EconomyDossierViewModel.MONEY_SCALE
	return out



static func _average_values(values, days: int) -> PackedFloat64Array:
	var divisor := maxf(1.0, float(days))
	var out := PackedFloat64Array()
	if values == null:
		return out
	out.resize(values.size())
	for index in range(values.size()):
		out[index] = float(values[index]) / divisor
	return out



static func _other_treasury_change_row(amount: float, positive: bool) -> Dictionary:
	var money := EconomyDossierViewModel._cashflow_cell(amount, UITokens.DOSSIER_BRASS if positive \
		else UITokens.DOSSIER_OXBLOOD)
	return {
		"id": EconomyFiscalHistory.OTHER_TREASURY_CHANGE_ID,
		"cells": {
			"name": {"text": EconomyDossierViewModel.OTHER_TREASURY_CHANGE_LABEL},
			"base": EconomyDossierViewModel._cashflow_cell(0.0),
			"collected": money if positive else EconomyDossierViewModel._cashflow_cell(0.0),
			"requested": EconomyDossierViewModel._cashflow_cell(0.0),
			"paid": EconomyDossierViewModel._cashflow_cell(0.0) if positive else money,
		},
	}


## 财政快照 → 两侧堆叠段、逐税种明细行与当日合计。
## 堆叠段只放非零项（零税率税种不该占一段），明细表则五个税种全列。
## 支出一侧除五类税种的负税率补贴外，还有一条非税支出「科研采购」：国库把
## 现金付给本地商人换取科技值，钱确实离开了国库，所以必须进支出侧与净额，
## 否则国库现金在掉、账面净额却是零（`fiscal.research_purchase_cash`）。
static func build_cashflow(fiscal: Dictionary) -> Dictionary:
	var empty := {"ok": false, "income_total": 0.0, "expense_total": 0.0, "net": 0.0,
		"income_text": "0", "expense_text": "0", "net_text": "0",
		"net_positive": true, "day_text": "", "detail_rows": [],
		"income_segments": [], "expense_segments": [],
		"income_series": PackedFloat32Array(), "expense_series": PackedFloat32Array()}
	if not bool(fiscal.get("ok", false)) or fiscal.is_empty():
		empty["reason"] = EconomyDossierViewModel._reason(fiscal)
		return empty
	var kind_ids = fiscal.get("tax_kinds", PackedStringArray())
	var collected = fiscal.get("collected", PackedInt64Array())
	var paid = fiscal.get("subsidy_paid", PackedInt64Array())
	var bases = fiscal.get("tax_base", PackedInt64Array())
	var requested = fiscal.get("subsidy_requested", PackedInt64Array())
	var non_tax_ids = fiscal.get("non_tax_outflow_kinds", PackedStringArray())
	var non_tax_values = fiscal.get("non_tax_outflow", PackedInt64Array())
	var inflow_raw: Array = []
	var outflow_raw: Array = []
	var rows: Array = []
	var income_total := 0.0
	var expense_total := 0.0
	for index in range(EconomyDossierViewModel.CASHFLOW_KINDS.size()):
		var meta := EconomyDossierViewModel._cashflow_meta(kind_ids, index)
		var inflow := maxf(0.0, EconomyDossierViewModel._at(collected, index))
		var outflow := maxf(0.0, EconomyDossierViewModel._at(paid, index))
		income_total += inflow
		expense_total += outflow
		if inflow > 0.0:
			inflow_raw.append({"label": String(meta.name), "value": inflow})
		if outflow > 0.0:
			outflow_raw.append({"label": String(meta.subsidy), "value": outflow})
		rows.append({"id": String(meta.id), "cells": {
			"name": {"text": String(meta.name)},
			"base": EconomyDossierViewModel._cashflow_cell(EconomyDossierViewModel._at(bases, index)),
			"collected": EconomyDossierViewModel._cashflow_cell(inflow, UITokens.DOSSIER_VERDIGRIS),
			"requested": EconomyDossierViewModel._cashflow_cell(EconomyDossierViewModel._at(requested, index)),
			"paid": EconomyDossierViewModel._cashflow_cell(outflow, UITokens.DOSSIER_OXBLOOD),
		}})
	# 非税支出与税种补贴并列进入支出侧：钱都是国库掏的，只是没有税种凭证。
	# 非税行只在真的发生时才出现——五个税种即使为零也常列（行是账簿），
	# 但这几项不是税种，零值写一行只会让人以为漏了一笔税。
	for index in range(maxi(non_tax_ids.size(), non_tax_values.size())):
		var amount := maxf(0.0, EconomyDossierViewModel._at(non_tax_values, index))
		if amount <= 0.0:
			continue
		var label := EconomyDossierViewModel._non_tax_outflow_label(non_tax_ids, index)
		expense_total += amount
		outflow_raw.append({"label": label, "value": amount})
		rows.append({"id": EconomyDossierViewModel._non_tax_outflow_id(non_tax_ids, index), "cells": {
			"name": {"text": label},
			"base": EconomyDossierViewModel._cashflow_cell(0.0),
			"collected": EconomyDossierViewModel._cashflow_cell(0.0),
			"requested": EconomyDossierViewModel._cashflow_cell(0.0),
			"paid": EconomyDossierViewModel._cashflow_cell(amount, UITokens.DOSSIER_OXBLOOD),
		}})
	var net := income_total - expense_total
	var day := int(fiscal.get("sample_day", -1))
	return {
		"ok": true,
		"income_total": income_total / EconomyDossierViewModel.MONEY_SCALE,
		"expense_total": expense_total / EconomyDossierViewModel.MONEY_SCALE,
		"net": net / EconomyDossierViewModel.MONEY_SCALE,
		"income_text": EconomyDossierViewModel._money_text(income_total),
		"expense_text": EconomyDossierViewModel._money_text(expense_total),
		"net_text": ("+" if net >= 0.0 else "−") + EconomyDossierViewModel._money_text(absf(net)),
		"net_positive": net >= 0.0,
		"day_text": ("%s · 上次结算" % WorldClock.date_text_for_day(day)
			if bool(fiscal.get("carried_forward", false)) else WorldClock.date_text_for_day(day)) if day >= 0 else "",
		"detail_rows": rows,
		"income_segments": EconomyDossierViewModel._flow_segments(inflow_raw, UITokens.DOSSIER_VERDIGRIS),
		"expense_segments": EconomyDossierViewModel._flow_segments(outflow_raw, UITokens.DOSSIER_OXBLOOD),
	}


## 占比堆叠段：按金额降序，越靠前颜色越深，所以段的顺序本身就是排名。
static func _flow_segments(raw: Array, base: Color) -> Array:
	raw.sort_custom(func(a, b): return float(a.value) > float(b.value))
	var segments: Array = []
	for index in range(raw.size()):
		var value := float(raw[index].value)
		segments.append({"label": String(raw[index].label), "value": value / EconomyDossierViewModel.MONEY_SCALE,
			"text": EconomyDossierViewModel._money_text(value),
			"color": base.lerp(UITokens.DOSSIER_PAPER, minf(0.13 * float(index), 0.5))})
	return segments


## 明细表的零值写成短横线：一整列 0 会盖过真正有数的那一格。
static func _cashflow_cell(raw: float, color: Color = UITokens.DOSSIER_INK) -> Dictionary:
	if raw <= 0.0:
		return {"text": "—", "value": 0.0, "color": UITokens.DOSSIER_INK_MUTED}
	return {"text": EconomyDossierViewModel._money_text(raw), "value": raw / EconomyDossierViewModel.MONEY_SCALE, "color": color,
		"strong": color != UITokens.DOSSIER_INK}



static func _cashflow_meta(kind_ids, index: int) -> Dictionary:
	if index < kind_ids.size():
		var kind := String(kind_ids[index])
		for meta in EconomyDossierViewModel.CASHFLOW_KINDS:
			if String(meta.id) == kind:
				return meta
	return EconomyDossierViewModel.CASHFLOW_KINDS[index] if index < EconomyDossierViewModel.CASHFLOW_KINDS.size() else EconomyDossierViewModel.CASHFLOW_KINDS[0]


## 非税支出的稳定 id：快照自带 kinds 时按 id 对齐，缺失时用序号兜底，
## 这样明细行的 id 在原生新增条目后仍然稳定。
static func _non_tax_outflow_id(kind_ids, index: int) -> String:
	if index >= 0 and index < kind_ids.size():
		var kind := String(kind_ids[index])
		if not kind.is_empty():
			return kind
	return "non_tax_%d" % index



static func _non_tax_outflow_label(kind_ids, index: int) -> String:
	var id := EconomyDossierViewModel._non_tax_outflow_id(kind_ids, index)
	for meta in EconomyDossierViewModel.NON_TAX_OUTFLOW_KINDS:
		if String(meta.id) == id:
			return String(meta.label)
	return EconomyDossierViewModel.NON_TAX_OUTFLOW_FALLBACK_LABEL
