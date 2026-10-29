extends RefCounted
class_name EraIndicatorViewModel

const Catalog = preload("res://scripts/economy/technology_catalog.gd")
var _eras: Array[Dictionary] = Catalog.public_era_metadata()
var _catalog: Dictionary = Catalog.compile_native_catalog()

func build_overview(country_facade, economy_facade, handle: int, ledger: EconomyGdpLedger) -> Dictionary:
	var model := {"country_name": "国家概况", "gdp": "—", "cash": "—", "population": "—", "territory": "—"}
	if country_facade == null or handle == 0:
		return model
	# section_mask=0 只取国家摘要，不构建科技/贸易/税务工作区快照。
	var shell: Dictionary = country_facade.ui_snapshot(handle, 0)
	if bool(shell.get("ok", false)):
		var summary: Dictionary = shell.get("summary", {})
		model.country_name = String(summary.get("country_name", "国家概况"))
		model.territory = UITokens.format_compact_number_cn(float(summary.get("territory_count", 0)), 0)
	var treasury: Dictionary = country_facade.treasury_snapshot(handle)
	if bool(treasury.get("ok", false)):
		model.cash = UITokens.format_compact_number_cn(float(treasury.get("cash", 0)) / 10000.0, 2)
	if ledger != null and ledger.ready():
		model.gdp = UITokens.format_compact_number_cn(ledger.national_ytd() / 10000.0, 2)
	if economy_facade != null:
		var economy: Dictionary = economy_facade.country_economy_overview(handle, "summary")
		if bool(economy.get("ok", false)):
			model.population = UITokens.format_compact_number_cn(float(economy.get("population", 0)), 0)
	return model

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
