extends RefCounted
class_name EraIndicatorViewModel

const Catalog = preload("res://scripts/economy/technology_catalog.gd")
var _eras: Array[Dictionary] = Catalog.public_era_metadata()
var _catalog: Dictionary = Catalog.compile_native_catalog()

func build_overview(country_facade, economy_facade, handle: int, ledger: EconomyGdpLedger) -> Dictionary:
	var model := {
		"country_name": "国家概况",
		"gdp": "—", "per_capita_gdp": "—", "territory": "—", "cpi": "—", "ppi": "—",
		"satisfaction": "—", "living_standard": "—", "alerts": [],
		"gdp_tooltip": "年度 GDP：本年累计产值",
		"per_capita_gdp_tooltip": "人均 GDP：年度 GDP ÷ 全国人口；与年度 GDP 同口径（读数前的金币图标即单位）。",
		"territory_tooltip": "领土：当前国家持有的有效地块数",
		"cpi_tooltip": "居民消费价格指数：食品、纺织与消费品按居民需求量加权的现价／成本锚；1.00× 表示等于成本锚。",
		"ppi_tooltip": "生产者价格指数：按有效生产供给量加权的现价／成本锚；1.00× 表示等于成本锚。",
		"satisfaction_tooltip": "人民平均满意度：全国人口加权的「综合满意度」（八维加权，按生存与基本生活封顶）；生存维度另见民生告警。",
		"living_standard_tooltip": "人民生活水平：按人口加权的生活水平等级均值（0 赤贫至 6 奢华）。",
	}
	if country_facade == null or handle == 0:
		return model
	# section_mask=0 只取国家摘要，不构建科技/贸易/税务工作区快照。
	var shell: Dictionary = country_facade.ui_snapshot(handle, 0)
	if bool(shell.get("ok", false)):
		var summary: Dictionary = shell.get("summary", {})
		model.country_name = String(summary.get("country_name", "国家概况"))
		model.territory = UITokens.format_compact_number_cn(float(summary.get("territory_count", 0)), 0)
	if ledger != null and ledger.ready():
		model.gdp = UITokens.format_compact_number_cn(ledger.national_ytd() / 10000.0, 2)
		var national_per_capita := ledger.national_per_capita()
		if not is_nan(national_per_capita) and national_per_capita >= 0.0:
			model.per_capita_gdp = UITokens.format_compact_number_cn(
				national_per_capita / 10000.0, 2)
	if economy_facade != null:
		var economy: Dictionary = economy_facade.country_economy_overview(handle, "summary")
		if bool(economy.get("ok", false)):
			var population := int(economy.get("population", 0))
			if bool(economy.get("consumer_price_index_valid", false)):
				model.cpi = _format_index(int(economy.get("consumer_price_index_q16", 0)))
			if bool(economy.get("producer_price_index_valid", false)):
				model.ppi = _format_index(int(economy.get("producer_price_index_q16", 0)))
			if population > 0:
				model.satisfaction = _format_percent(float(
					economy.get("satisfaction_q16", 0)) / 65536.0, 1)
			if bool(economy.get("living_standard_level_valid", false)):
				model.living_standard = _format_living_standard(
					int(economy.get("living_standard_level_q16", 0)))
			model.alerts = build_alerts(economy)
	return model


static func build_alerts(economy: Dictionary) -> Array[Dictionary]:
	var alerts: Array[Dictionary] = []
	var population := int(economy.get("population", 0))
	var unemployed := int(economy.get("unemployed", 0))
	if population > 0 and unemployed * 10 >= population:
		alerts.append(_alert("unemployment", "situation.unemployment", "失业率偏高",
			float(unemployed) / float(population), 0.10,
			"失业人口 ÷ 全国人口；触发线 10%。"))
	if population > 0 and int(economy.get("survival_satisfaction_q16", -1)) >= 0 \
			and int(economy.get("survival_satisfaction_q16", -1)) <= 49152:
		alerts.append(_alert("survival", "situation.food_shortage", "生存满意度不足",
			float(economy.get("survival_satisfaction_q16", 0)) / 65536.0, 0.75,
			"全国人口加权生存满意度；低于或等于 75% 时提示。"))
	if bool(economy.get("consumer_shortage_valid", false)):
		var shortage := int(economy.get("consumer_shortage_q16", 0))
		if shortage >= 16384:
			alerts.append(_alert("consumer_shortage", "situation.consumer_shortage",
				"纺织与消费品短缺", float(shortage) / 65536.0, 0.25,
				"纺织与消费品按居民需求量加权的短缺率；触发线 25%。"))
	if bool(economy.get("industrial_shortage_valid", false)):
		var shortage := int(economy.get("industrial_shortage_q16", 0))
		if shortage >= 16384:
			alerts.append(_alert("industrial_shortage", "situation.industry_shortage",
				"工业物资短缺", float(shortage) / 65536.0, 0.25,
				"生产物资按企业需求量加权的短缺率；触发线 25%。"))
	var job_capacity := int(economy.get("job_capacity", 0))
	var job_openings := int(economy.get("job_openings", 0))
	if job_capacity > 0 and job_openings * 10 >= job_capacity:
		alerts.append(_alert("vacancies", "situation.vacant_jobs", "岗位空缺严重",
			float(job_openings) / float(job_capacity), 0.10,
			"空缺岗位 ÷ 岗位容量；触发线 10%。"))
	return alerts


static func _alert(key: String, icon: String, label: String, ratio: float,
		threshold: float, method: String) -> Dictionary:
	return {
		"key": key, "icon": icon, "label": label,
		"value": _format_percent(ratio, 1),
		"tooltip": "%s：%s\n%s" % [label, _format_percent(ratio, 2), method],
		"threshold": _format_percent(threshold, 0),
	}


static func _format_index(q16: int) -> String:
	return "%.2f×" % (float(q16) / 65536.0)


static func _format_living_standard(q16: int) -> String:
	var level := clampf(float(q16) / 65536.0, 0.0, 6.0)
	var whole := clampi(int(floor(level + 0.5)), 0, 6)
	var names := ["赤贫", "挣扎", "贫困", "温饱", "小康", "富裕", "奢华"]
	return "%.2f级·%s" % [level, names[whole]]


static func _format_percent(ratio: float, digits: int) -> String:
	var number := String.num(ratio * 100.0, digits)
	if digits > 0:
		if not number.contains("."):
			number += "."
		var decimal_count := number.length() - number.find(".") - 1
		while decimal_count < digits:
			number += "0"
			decimal_count += 1
	return number + "%"

# 只读已提交快照：state 4 等待 ACK，state 5 才能晋升。
func build(research: Dictionary) -> Dictionary:
	var states: PackedInt32Array = research.get("technology_states", PackedInt32Array())
	if states.is_empty() or _eras.is_empty():
		return {}
	var milestones: PackedInt32Array = _catalog.get("technology_era_milestone_indices", PackedInt32Array())
	var costs = _catalog.get("technology_costs", PackedInt64Array())
	var progress: PackedInt64Array = research.get("technology_progress", PackedInt64Array())
	var queues: PackedInt32Array = research.get("queue_technology_indices", PackedInt32Array())
	var current := 0
	var researching := -1
	for i in range(mini(milestones.size(), _eras.size())):
		var tech := int(milestones[i])
		if tech < 0 or tech >= states.size():
			continue
		if states[tech] >= 5:
			current = i
		elif researching < 0 and (states[tech] == 3 or states[tech] == 4) and (queues.has(tech) or states[tech] == 4):
			researching = i
	var ratio := 0.0
	if researching >= 0:
		var tech := int(milestones[researching])
		if states[tech] == 4:
			ratio = 1.0
		elif tech < progress.size() and tech < costs.size():
			ratio = clampf(float(progress[tech]) / maxf(1.0, float(costs[tech])), 0.0, 1.0)
	return {"era_index": current, "era_id": String(_eras[current].id),
		"era_name": String(_eras[current].display_name), "researching": researching >= 0,
		"research_name": String(_eras[researching].display_name) if researching >= 0 else "",
		"progress": ratio}
