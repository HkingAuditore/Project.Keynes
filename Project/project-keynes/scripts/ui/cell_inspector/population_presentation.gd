extends RefCounted

static func _gdp_metrics(host, cell_idx: int) -> Array:
	var h = host
	var gdp = host._local_gdp(cell_idx)
	if gdp.is_empty():
		return []
	var ytd = float(gdp.get("ytd", 0.0))
	var per_day = float(gdp.get("per_day", 0.0))
	var days = int(gdp.get("days_counted", 0))
	var days_per_year = maxi(1, int(gdp.get("days_per_year", 365)))
	# 卡面只放一个数；「已计走到哪一天」「日均」「与全国人均的差距」都进 tooltip，
	# 否则窄面板里会被截成「已计 10/3…」「全国 11.62…」这类读不完的碎字。
	var metrics = [{
		"id": "population_gdp", "title": "本地年度产值", "money": true,
		"value": h._money_text(int(round(ytd))),
		"subtitle": "",
		"accent": UITokens.ECO, "icon": "metric.treasury",
		"tooltip": "已计 %d/%d 天 · 日均 %s" % [
			days, days_per_year, host._money_text(int(round(per_day)))],
	}]
	var per_capita = float(gdp.get("per_capita", NAN))
	var national_per_capita = float(gdp.get("national_per_capita", NAN))
	if is_nan(per_capita):
		return metrics
	var comparison = ""
	if not is_nan(national_per_capita) and national_per_capita > 0.0:
		var gap = (per_capita - national_per_capita) / national_per_capita * 100.0
		comparison = "全国人均 %s（本地%s%.0f%%）" % [
			host._money_text(int(round(national_per_capita))),
			"高于" if gap >= 0.0 else "低于", absf(gap)]
	metrics.append({
		"id": "population_gdp_per_capita", "title": "人均年度产值", "money": true,
		"value": h._money_text(int(round(per_capita))),
		"subtitle": "", "accent": UITokens.ACCENT,
		"icon": "family.metric.wealth",
		"tooltip": comparison,
	})
	return metrics


static func _group_demand_rows_by_usage(host, rows: Array) -> Array:
	var h = host
	var groups = []
	var group_indices = {}
	for raw_row in rows:
		var row: Dictionary = raw_row
		if not bool(row.get("visible", false)):
			continue
		var need_names: Array = row.get("need_names", [])
		var group_name = "、".join(need_names) if not need_names.is_empty() else "其他"
		if not group_indices.has(group_name):
			group_indices[group_name] = groups.size()
			groups.append({
				"id": "demand_usage_%d" % groups.size(),
				"name": group_name,
				"rows": [],
			})
		var group_idx = int(group_indices[group_name])
		var group: Dictionary = groups[group_idx]
		var group_rows: Array = group.get("rows", [])
		group_rows.append(row)
		group["rows"] = group_rows
		var satisfaction_total = 0
		var satisfaction_count = 0
		var group_cost_raw = 0
		var group_qty_raw = 0
		for group_row in group_rows:
			var rdict = group_row as Dictionary
			var value = int(rdict.get("need_satisfaction_q16", -1))
			if value >= 0:
				satisfaction_total += value
				satisfaction_count += 1
			var q_raw = int(rdict.get("quantity_raw", 0))
			if q_raw > 0:
				group_qty_raw += q_raw
				var c_raw = int(rdict.get("daily_cost_raw", 0))
				if c_raw > 0:
					group_cost_raw += c_raw
		var sat_ratio = float(satisfaction_total) / 65536.0 / float(satisfaction_count) \
			if satisfaction_count > 0 else -1.0
		group["satisfaction_ratio"] = sat_ratio
		group["daily_cost_raw"] = group_cost_raw
		group["quantity_raw"] = group_qty_raw
		group["satisfaction"] = "满足 %.0f%%" % (sat_ratio * 100.0) \
			if sat_ratio >= 0.0 else ""
		groups[group_idx] = group
	return groups


static func _local_gdp(_gdp_ledger, cell_idx: int) -> Dictionary:
	if _gdp_ledger == null or not _gdp_ledger.ready():
		return {}
	if not _gdp_ledger.tracks_cell(cell_idx):
		return {}
	var population: int = _gdp_ledger.cell_population(cell_idx)
	if population <= 0:
		return {}
	return {
		"ytd": _gdp_ledger.cell_ytd(cell_idx),
		"per_day": _gdp_ledger.cell_per_day(cell_idx),
		"population": population,
		"per_capita": _gdp_ledger.cell_per_capita(cell_idx),
		"national_per_capita": _gdp_ledger.national_per_capita(),
		"days_counted": _gdp_ledger.days_counted(),
		"days_per_year": _gdp_ledger.days_per_year(),
		"year_index": _gdp_ledger.year_index(),
	}
