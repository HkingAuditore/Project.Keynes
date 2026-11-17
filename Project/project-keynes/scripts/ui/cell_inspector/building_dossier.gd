extends RefCounted

const FamilyWorkspaceProjection = preload("res://scripts/ui/family_workspace_projection.gd")

static func building_dossier_model(row: Dictionary) -> Dictionary:
	var count_text = String(row.get("count", "1 栋"))
	var count_raw = maxi(1, int(row.get("count_raw", int(FamilyWorkspaceProjection._parse_leading_float(count_text, 1.0)))))
	var owner_raw = String(row.get("owner", "业主 · 本地产业"))
	var owner_short = owner_raw.trim_prefix("业主 · ").strip_edges()
	var status_text = String(row.get("status", "正常运转"))
	var profit_label = String(row.get("profit_label", "利润"))
	var profit_text = String(row.get("profit", "—"))
	var profit_val = float(row.get("profit_float", FamilyWorkspaceProjection._parse_leading_float(profit_text, 0.0)))

	var job_rows: Array = row.get("job_rows", [])
	var staff_actual = int(row.get("staffing_actual_raw", -1))
	var staff_req = int(row.get("staffing_required_raw", -1))
	if staff_actual < 0 or staff_req < 0:
		staff_actual = 0
		staff_req = 0
		for raw_j in job_rows:
			if not (raw_j is Dictionary):
				continue
			var jval = String((raw_j as Dictionary).get("value", ""))
			var slash = jval.find("/")
			if slash >= 0:
				staff_actual += int(FamilyWorkspaceProjection._parse_leading_float(jval.substr(0, slash), 0.0))
				staff_req += int(FamilyWorkspaceProjection._parse_leading_float(jval.substr(slash + 1), 0.0))
	var staff_ratio = float(staff_actual) / float(staff_req) if staff_req > 0 else 1.0
	var staff_text = "%d / %d" % [staff_actual, staff_req] if staff_req > 0 else "—"

	var actual_util = float(row.get("actual_utilization_float", -1.0))
	var planned_util = float(row.get("planned_utilization_float", 1.0))
	if actual_util < 0.0:
		var cap_pos = status_text.find("产能")
		if cap_pos >= 0:
			actual_util = clampf(FamilyWorkspaceProjection._parse_leading_float(status_text.substr(cap_pos + 2), 100.0) / 100.0, 0.0, 1.0)
		elif status_text.find("停") >= 0 or profit_text.find("停") >= 0:
			actual_util = 0.0
		else:
			actual_util = 1.0

	var state_summary: Dictionary = row.get("state_summary", {})
	var is_halted = not state_summary.is_empty() or status_text.find("停") >= 0
	var util_text = String(state_summary.get("label", "停产")) if is_halted \
		else ("%.0f%%" % (actual_util * 100.0))
	var util_caption = "正常运转"
	if is_halted:
		util_caption = String(state_summary.get("detail", "本期暂停生产"))
	elif planned_util < 0.995:
		util_caption = "计划限产 %.0f%%" % (planned_util * 100.0)
	elif actual_util < 0.995:
		util_caption = "受人力或环境制约"
	else:
		util_caption = "满负荷运转"

	var finance: Dictionary = row.get("finance", {})
	var rev_text = String(finance.get("revenue", "—"))
	var cost_text = String(finance.get("cost", "—"))
	var profit_positive = bool(finance.get("profit_positive", not profit_text.begins_with("-") and not profit_text.begins_with("−") and not is_halted))
	var profit_caption = status_text
	if not finance.is_empty():
		profit_caption = "收 %s · 支 %s" % [rev_text, cost_text]

	var kpis = [
		{
			"id": "building_scale",
			"title": "建筑规模",
			"value": float(count_raw),
			"kind": "text",
			"text": count_text,
			"caption": "业主：%s" % owner_short if not owner_short.is_empty() else status_text,
			"positive_good": true,
			"icon": StringName(row.get("icon", &"economy.building")),
		},
		{
			"id": "building_utilization",
			"title": "产能出力",
			"value": actual_util,
			"kind": "text",
			"text": util_text,
			"caption": util_caption,
			"tone": "risk" if (is_halted or actual_util < 0.25) else ("warn" if actual_util < 0.75 else ""),
			"positive_good": true,
			"spark": row.get("utilization_spark", PackedFloat32Array()),
			"delta": float(row.get("utilization_delta", NAN)),
			"icon": &"economy.building.factory",
		},
		{
			"id": "building_staffing",
			"title": "岗位到岗",
			"value": staff_ratio,
			"kind": "text",
			"text": staff_text,
			"caption": ("到岗 %.0f%%" % (staff_ratio * 100.0)) if staff_req > 0 else "",
			"tone": "risk" if (staff_req > 0 and staff_ratio < 0.5) else ("warn" if (staff_req > 0 and staff_ratio < 0.99) else ""),
			"positive_good": true,
			"icon": &"population.profession.worker",
		},
		{
			"id": "building_profit",
			"title": "本期%s" % profit_label if profit_label in ["利润", "亏损"] else profit_label,
			"value": profit_val,
			"kind": "text",
			"text": profit_text,
			"caption": profit_caption,
			"tone": "risk" if (is_halted or not profit_positive) else "",
			"positive_good": true,
			"spark": row.get("profit_spark", PackedFloat32Array()),
			"delta": float(row.get("profit_delta", NAN)),
			"icon": &"trend.up" if (profit_positive and not is_halted) else &"trend.down",
		},
	]

	# 仅保留真实经营异常；气候减产与「正常运转」叙述性批注去掉。
	var insights = []
	if not state_summary.is_empty():
		var slabel = String(state_summary.get("label", "经营异常"))
		var sdetail = String(state_summary.get("detail", ""))
		var smeta = String(state_summary.get("meta", ""))
		var line = "%s：%s" % [slabel, sdetail] if not sdetail.is_empty() else slabel
		if not smeta.is_empty():
			line += "（%s）" % smeta
		insights.append({
			"id": "building_state_alert",
			"text": line,
			"accent": UITokens.DOSSIER_OXBLOOD,
			"icon": "status.warning",
		})

	var capacity_bars = [
		{
			"id": "cap_actual",
			"label": "实际产能",
			"icon": &"economy.building.factory",
			"value": clampf(actual_util, 0.0, 1.0),
			"marker": clampf(planned_util, 0.0, 1.0) if planned_util < 0.995 else -1.0,
			"text": util_text,
			"color": UITokens.DOSSIER_OXBLOOD if actual_util < 0.25 else (UITokens.DOSSIER_BRASS if actual_util < 0.75 else UITokens.DOSSIER_VERDIGRIS),
			"tooltip": "计划上限 %.1f%%" % (planned_util * 100.0),
		},
	]
	if bool(row.get("has_climate_profile", false)):
		var climate_cap = clampf(float(row.get("climate_capacity_float", 1.0)), 0.0, 1.0)
		var temp_fit = clampf(float(row.get("temperature_fit_float", 1.0)), 0.0, 1.0)
		var water_fit = clampf(float(row.get("water_fit_float", 1.0)), 0.0, 1.0)
		capacity_bars.append({
			"id": "cap_climate",
			"label": "气候出力",
			"icon": &"climate",
			"value": climate_cap,
			"text": "%.0f%%" % (climate_cap * 100.0),
			"color": UITokens.DOSSIER_VERDIGRIS if climate_cap >= 0.90 else (UITokens.DOSSIER_BRASS if climate_cap >= 0.60 else UITokens.DOSSIER_OXBLOOD),
			"tooltip": "温度适宜度 %.1f%% · 水分适宜度 %.1f%% · 综合气候出力 %.1f%%" % [
				temp_fit * 100.0, water_fit * 100.0, climate_cap * 100.0],
		})
		if temp_fit < 0.995 or water_fit < 0.995:
			capacity_bars.append({
				"id": "cap_temp",
				"label": "温度适宜",
				"value": temp_fit,
				"text": "%.0f%%" % (temp_fit * 100.0),
				"color": UITokens.DOSSIER_VERDIGRIS if temp_fit >= 0.85 else UITokens.DOSSIER_BRASS,
			})
			capacity_bars.append({
				"id": "cap_water",
				"label": "水分适宜",
				"value": water_fit,
				"text": "%.0f%%" % (water_fit * 100.0),
				"color": UITokens.DOSSIER_SLATE if water_fit >= 0.85 else UITokens.DOSSIER_BRASS,
			})

	var job_bars = []
	for idx in range(job_rows.size()):
		var raw_j = job_rows[idx]
		if not (raw_j is Dictionary):
			continue
		var jdict: Dictionary = raw_j
		if not bool(jdict.get("visible", true)):
			continue
		var jname = String(jdict.get("name", "岗位"))
		var jval = String(jdict.get("value", "0 / 0"))
		var jratio = float(jdict.get("ratio", -1.0))
		if jratio < 0.0:
			var slash = jval.find("/")
			if slash >= 0:
				var f = FamilyWorkspaceProjection._parse_leading_float(jval.substr(0, slash), 0.0)
				var r = FamilyWorkspaceProjection._parse_leading_float(jval.substr(slash + 1), 0.0)
				jratio = f / r if r > 0.0 else 1.0
			else:
				jratio = 1.0
		var clamped_j = clampf(jratio, 0.0, 1.0)
		var is_owner_row = jname.begins_with("业主")
		job_bars.append({
			"id": String(jdict.get("id", "job_%d" % idx)),
			"label": jname,
			"icon": &"family.metric.wealth" if is_owner_row else &"population.profession.worker",
			"value": clamped_j,
			"text": jval.split("（")[0].strip_edges(),
			"color": UITokens.DOSSIER_OXBLOOD if clamped_j < 0.50 else (UITokens.DOSSIER_BRASS if clamped_j < 0.99 else UITokens.DOSSIER_VERDIGRIS),
			"tooltip": "%s：%s" % [jname, jval],
		})

	var prod_rows: Array = row.get("production_rows", [])
	var production_candidates = []
	var unused_input_notes = PackedStringArray()
	var prod_peak = 0.001
	var has_natural_input = false
	var has_natural_gen = false
	for raw_p in prod_rows:
		if not (raw_p is Dictionary):
			continue
		var pdict: Dictionary = raw_p
		var pid = String(pdict.get("id", ""))
		if pid.begins_with("natural_input"):
			has_natural_input = true
		elif pid.begins_with("natural_generation"):
			has_natural_gen = true

	for idx in range(prod_rows.size()):
		var raw_p = prod_rows[idx]
		if not (raw_p is Dictionary):
			continue
		var pdict: Dictionary = raw_p
		var pid = String(pdict.get("id", "prod_%d" % idx))
		if pid in ["climate_fit", "climate_lost_output", "input_none", "output_none"]:
			continue
		# 仅在同时有培育与消耗时才显示“自然资源净额”，避免与单向消耗行重复。
		if pid == "resource_net" and not (has_natural_input and has_natural_gen):
			continue
		var full_name = String(pdict.get("name", ""))
		var short_name = String(pdict.get("short_name", full_name))
		var val_str = String(pdict.get("value", ""))
		var rate_num = float(pdict.get("daily_per_building_float", absf(FamilyWorkspaceProjection._parse_leading_float(val_str, 0.0))))
		var is_input = pid.begins_with("input_") or full_name.begins_with("原材料")
		if is_input and rate_num <= 0.00001:
			var cand_desc = String(pdict.get("candidates_detail", full_name.trim_prefix("原材料 · ")))
			if not cand_desc.is_empty() and cand_desc != "无":
				unused_input_notes.append(cand_desc)
			continue
		if short_name.length() > 14 and short_name.find("/") >= 0:
			var first_part = short_name.split("/")[0].strip_edges()
			short_name = "%s等" % first_part
		var compact_val = val_str.replace(" 单位/栋/日", "/栋/日")
		prod_peak = maxf(prod_peak, rate_num)
		var bar_color = UITokens.DOSSIER_VERDIGRIS
		var icon_key = &"metric.goods"
		if pid.begins_with("output_") or full_name.begins_with("产出"):
			bar_color = UITokens.DOSSIER_VERDIGRIS
			icon_key = &"metric.goods"
		elif pid.begins_with("natural_") or pid == "resource_net":
			bar_color = UITokens.DOSSIER_SLATE if val_str.find("不足") < 0 else UITokens.DOSSIER_OXBLOOD
			icon_key = &"economy.resource"
		else:
			bar_color = UITokens.DOSSIER_BRASS
			icon_key = &"economy.building.factory"
		production_candidates.append({
			"id": pid,
			"label": short_name,
			"icon": icon_key,
			"rate": rate_num,
			"text": compact_val,
			"color": bar_color,
			"tooltip": "%s：%s" % [full_name, val_str],
		})

	var production_bars = []
	for item in production_candidates:
		var rate = float(item.rate)
		production_bars.append({
			"id": item.id,
			"label": item.label,
			"icon": item.icon,
			"value": clampf(rate / prod_peak, 0.08 if rate > 0.0 else 0.0, 1.0),
			"text": item.text,
			"color": item.color,
			"tooltip": item.tooltip,
		})

	var unused_inputs_summary = ""
	if not unused_input_notes.is_empty():
		unused_inputs_summary = "可选增产投入（当前未消耗）：%s。" % "；".join(unused_input_notes)

	var cash_rev = float(finance.get("cash_revenue_float", 0.0))
	var in_kind_rev = float(finance.get("in_kind_float", 0.0))
	var subsidy_rev = float(finance.get("subsidy_float", 0.0))
	var total_rev = float(finance.get("revenue_float", FamilyWorkspaceProjection._parse_leading_float(rev_text, cash_rev + in_kind_rev)))
	var input_cost_val = float(finance.get("input_cost_float", 0.0))
	var wages_val = float(finance.get("wages_cost_float", finance.get("wages_paid_float", 0.0)))
	var maintenance_val = float(finance.get("maintenance_float", 0.0))
	var tax_val = maxf(0.0, float(finance.get("business_tax_float", 0.0)))
	var operating_cost = float(finance.get("cost_float", FamilyWorkspaceProjection._parse_leading_float(cost_text, input_cost_val + wages_val)))
	# last_revenue is the producer receipt after business tax.  Add the
	# separately published tax back only for the player-facing gross-income /
	# total-expense comparison; profit itself remains the authoritative net value.
	var gross_revenue = total_rev + tax_val
	var total_cost = operating_cost + tax_val

	# 兼容未携带细分浮点字段的旧字典（按 breakdown 解析）
	if cash_rev <= 0.0 and in_kind_rev <= 0.0 and total_rev > 0.0:
		cash_rev = total_rev
	var revenue_segments = []
	if cash_rev > 0.0001:
		revenue_segments.append({
			"label": "市场销售（税前）",
			"value": cash_rev + tax_val,
			"text": String(finance.get("gross_cash_revenue_text",
				UITokens.format_compact_number_cn(cash_rev + tax_val, 2))),
			"color": UITokens.DOSSIER_VERDIGRIS,
		})
	if in_kind_rev > 0.0001:
		revenue_segments.append({
			"label": "自用留存折算",
			"value": in_kind_rev,
			"text": String(finance.get("in_kind_text", UITokens.format_compact_number_cn(in_kind_rev, 2))),
			"color": UITokens.DOSSIER_BRASS,
		})
	if subsidy_rev > 0.0001:
		revenue_segments.append({
			"label": "经营补贴",
			"value": subsidy_rev,
			"text": String(finance.get("subsidy_text", UITokens.format_compact_number_cn(subsidy_rev, 2))),
			"color": UITokens.DOSSIER_SLATE,
		})

	var cost_segments = []
	if input_cost_val > 0.0001:
		cost_segments.append({
			"label": "原材料成本",
			"value": input_cost_val,
			"text": String(finance.get("input_cost_text", UITokens.format_compact_number_cn(input_cost_val, 2))),
			"color": UITokens.DOSSIER_OXBLOOD,
		})
	if wages_val > 0.0001:
		cost_segments.append({
			"label": "工资成本",
			"value": wages_val,
			"text": String(finance.get("wages_cost_text", UITokens.format_compact_number_cn(wages_val, 2))),
			"color": UITokens.DOSSIER_BRASS,
		})
	if maintenance_val > 0.0001:
		cost_segments.append({
			"label": "维护支出",
			"value": maintenance_val,
			"text": String(finance.get("maintenance_text", UITokens.format_compact_number_cn(maintenance_val, 2))),
			"color": UITokens.DOSSIER_SLATE,
		})
	if tax_val > 0.0001:
		cost_segments.append({
			"label": "营业税费",
			"value": tax_val,
			"text": String(finance.get("business_tax_text", UITokens.format_compact_number_cn(tax_val, 2))),
			"color": UITokens.DOSSIER_UMBER,
		})

	var finance_note = ""
	var loss_visible := profit_val < -0.0001 and not is_halted and not finance.is_empty()
	var largest_cost_label := ""
	var largest_cost_value := 0.0
	for segment in cost_segments:
		var segment_value := float(segment.get("value", 0.0))
		if segment_value > largest_cost_value:
			largest_cost_value = segment_value
			largest_cost_label = String(segment.get("label", ""))
	var loss_summary := ""
	if loss_visible:
		loss_summary = "每日亏损 %s；最大支出：%s %s" % [
			String(finance.get("profit_loss_text", UITokens.format_compact_number_cn(absf(profit_val), 2))),
			largest_cost_label, String(finance.get("largest_cost_text",
				UITokens.format_compact_number_cn(largest_cost_value, 2)))]

	return {
		"kpis": kpis,
		"insights": insights,
		"capacity_bars": capacity_bars,
		"job_bars": job_bars,
		"production_bars": production_bars,
		"unused_inputs_summary": unused_inputs_summary,
		"finance_diverging_bar": {
			"left_label": "含税总支出",
			"left_value": total_cost,
			"left_text": String(finance.get("total_cost_with_tax_text", UITokens.format_compact_number_cn(total_cost, 2))),
			"right_label": "税前总收入",
			"right_value": gross_revenue,
			"right_text": String(finance.get("gross_revenue_text", UITokens.format_compact_number_cn(gross_revenue, 2))),
		},
		"revenue_segments": revenue_segments,
		"cost_segments": cost_segments,
		"finance_note": finance_note,
		"finance_warning": String(finance.get("warning", "")),
		"loss_visible": loss_visible,
		"loss_summary": loss_summary,
		"loss_cost_segments": cost_segments,
		"loss_diverging_bar": {
			"left_label": "含税总支出",
			"left_value": total_cost,
			"left_text": String(finance.get("total_cost_with_tax_text", UITokens.format_compact_number_cn(total_cost, 2))),
			"right_label": "税前总收入",
			"right_value": gross_revenue,
			"right_text": String(finance.get("gross_revenue_text", UITokens.format_compact_number_cn(gross_revenue, 2))),
		},
	}
