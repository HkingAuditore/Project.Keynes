extends SceneTree

## v5 科技树契约：守住"单根 + 三档成本 + 通道预算 + 地理覆盖"四条不变量。
## 用法：
##   godot --headless --path <project> --script res://tests/technology/technology_network_v5_contract_test.gd
## 与旧的 technology_network_design_test 不同，这里不锁具体建筑清单，
## 只锁"设计意图"，因此不会因为内容增删而失效。

const NETWORK_PATH := "res://data/technology/technology_network.json"
const ROOT_ID := "tech.early_knowledge_institution"
const ROOT_NAME := "思考"
const TIER_RATIO := [0.55, 1.0, 1.8]
const TIER_TOLERANCE := 0.06

const BUDGETS := {
	"country.economy_output_factor": 0.78,
	"country.output.agriculture_factor": 3.01,
	"country.output.extractive_factor": 3.01,
	"country.output.manufacturing_factor": 3.01,
	"country.output.energy_factor": 2.01,
	"country.output.knowledge_factor": 2.01,
	"country.production.input_factor": 0.91,
	"country.construction.cost_factor": 0.81,
	"country.construction.time_factor": 0.81,
	"country.trade.capacity_factor": 1.41,
	"country.trade.speed_factor": 1.01,
	"country.research.cost_factor": 0.91,
	"country.research.institution_output_factor": 1.21,
	"country.research.agriculture_efficiency": 2.41,
	"country.research.engineering_efficiency": 2.41,
	"country.research.science_efficiency": 2.41,
	"country.research.society_efficiency": 2.41,
	"country.population.death_factor": 0.46,
}
const FAMILY_BUDGET := 2.61
const GEO_BUDGET := 1.01
const MIN_GEO_NODES := 30
const MIN_RULE_TERMS := 15


func _fail(message: String) -> void:
	printerr("V5 CONTRACT FAIL: " + message)


func _init() -> void:
	var text := FileAccess.get_file_as_string(NETWORK_PATH)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("network is not a JSON object")
		quit(1)
		return
	var data: Dictionary = parsed
	var nodes: Array = data.get("nodes", [])
	var by_id := {}
	for value in nodes:
		var node: Dictionary = value
		by_id[String(node.get("id", ""))] = node

	var failures := 0

	# ---- 1. 单一源头
	var root: Dictionary = by_id.get(ROOT_ID, {})
	if root.is_empty():
		_fail("missing root %s" % ROOT_ID)
		failures += 1
	else:
		if String(nodes[0].get("id", "")) != ROOT_ID:
			_fail("root is not the first node")
			failures += 1
		if String(root.get("display_name", "")) != ROOT_NAME:
			_fail("root display name is not 思考")
			failures += 1
		if not (root.get("hard_prerequisite_ids", []) as Array).is_empty():
			_fail("root has prerequisites")
			failures += 1
		if float(root.get("cost_points", -1.0)) != 0.0:
			_fail("root is not free")
			failures += 1
		if not bool(root.get("is_starting", false)):
			_fail("root is not a starting technology")
			failures += 1

	# ---- 2. 全树可达
	var ancestor_cache := {}
	for value in nodes:
		var node: Dictionary = value
		var technology := String(node.get("id", ""))
		if technology == ROOT_ID:
			continue
		var seen := {}
		var stack: Array = (node.get("hard_prerequisite_ids", []) as Array).duplicate()
		while not stack.is_empty():
			var current := String(stack.pop_back())
			if seen.has(current) or not by_id.has(current):
				continue
			seen[current] = true
			stack.append_array(by_id[current].get("hard_prerequisite_ids", []))
		ancestor_cache[technology] = seen
		if not seen.has(ROOT_ID):
			_fail("%s does not descend from 思考" % technology)
			failures += 1

	# ---- 3. 三档成本
	var eras: Array = data.get("eras", [])
	for era_value in eras:
		var era: Dictionary = era_value
		var era_id := String(era.get("id", ""))
		var values := {}
		for value in nodes:
			var node: Dictionary = value
			if String(node.get("era_id", "")) != era_id:
				continue
			if bool(node.get("is_starter_eligible", false)):
				if float(node.get("cost_points", -1.0)) != 0.0:
					_fail("%s starter %s is not free" % [era_id, node.get("id")])
					failures += 1
				continue
			values[float(node.get("cost_points", 0.0))] = true
		var distinct: Array = values.keys()
		distinct.sort()
		if distinct.is_empty():
			continue
		if distinct.size() == 1:
			continue
		var unit := float(distinct[distinct.size() - 2])
		for tier_index in range(3):
			var expected: float = TIER_RATIO[tier_index] * unit
			var best := 1 << 30
			for candidate in distinct:
				best = mini(best, absi(int(candidate) - int(expected)))
			if float(best) > expected * TIER_TOLERANCE:
				_fail("%s cost tier %d has no value near %.0f" % [era_id, tier_index, expected])
				failures += 1

	# ---- 4. 通道预算
	var totals := {}
	var counts := {}
	for value in nodes:
		var node: Dictionary = value
		for term_value in node.get("modifier_terms", []):
			var term: Dictionary = term_value
			var stat := String(term.get("stat", ""))
			totals[stat] = float(totals.get(stat, 0.0)) + absf(float(term.get("value", 0.0)))
			counts[stat] = int(counts.get(stat, 0)) + 1
	for stat_value in BUDGETS:
		var stat := String(stat_value)
		if float(totals.get(stat, 0.0)) > float(BUDGETS[stat]) + 0.0001:
			_fail("budget exceeded on %s: %.3f > %.3f" % [
				stat, float(totals.get(stat, 0.0)), float(BUDGETS[stat])])
			failures += 1
	for stat_value in totals:
		var stat := String(stat_value)
		if stat.begins_with("country.output.family."):
			if float(totals[stat]) > FAMILY_BUDGET + 0.0001:
				_fail("family budget exceeded on %s: %.3f" % [stat, float(totals[stat])])
				failures += 1
		elif stat.contains(".terrain.") or stat.contains(".landform."):
			if float(totals[stat]) > GEO_BUDGET + 0.0001:
				_fail("geo budget exceeded on %s: %.3f" % [stat, float(totals[stat])])
				failures += 1

	# ---- 5. 地理与军事通道覆盖
	var geo_nodes := 0
	for value in nodes:
		var node: Dictionary = value
		for term_value in node.get("modifier_terms", []):
			var stat := String((term_value as Dictionary).get("stat", ""))
			if stat.contains(".terrain.") or stat.contains(".landform."):
				geo_nodes += 1
				break
	if geo_nodes < MIN_GEO_NODES:
		_fail("geography coverage too low: %d < %d" % [geo_nodes, MIN_GEO_NODES])
		failures += 1
	var rule_terms := 0
	for stat_value in counts:
		if String(stat_value).begins_with("country.military.rule."):
			rule_terms += int(counts[stat_value])
	if rule_terms < MIN_RULE_TERMS:
		_fail("military doctrine coverage too low: %d < %d" % [rule_terms, MIN_RULE_TERMS])
		failures += 1

	# ---- 6. 无空节点
	for value in nodes:
		var node: Dictionary = value
		if (node.get("content_effects", []) as Array).is_empty() \
				and (node.get("modifier_terms", []) as Array).is_empty() \
				and (node.get("runtime_capability_tags", []) as Array).is_empty():
			_fail("%s has no effect at all" % node.get("id"))
			failures += 1


	# ---- 7. 每个节点至少要有一处能被感知到的数值或内容
	#       "可感知"有两种：① 有具体抓手（地理/条令/税制/营造/科研/投入/贸易/气候/资源）；
	#       ② 只有产出百分比但幅度 >= 2%。二者满足其一即可。
	for value in nodes:
		var node: Dictionary = value
		var terms: Array = node.get("modifier_terms", [])
		var has_content := not (node.get("content_effects", []) as Array).is_empty() \
			or not (node.get("runtime_capability_tags", []) as Array).is_empty()
		if has_content:
			continue
		var peak := 0.0
		var has_specific := false
		for term_value in terms:
			var term: Dictionary = term_value
			var stat := String(term.get("stat", ""))
			peak = maxf(peak, absf(float(term.get("value", 0.0))))
			if not stat.begins_with("country.output.") \
					and not stat.begins_with("country.economy_output_factor"):
				has_specific = true
			if stat.contains(".terrain.") or stat.contains(".landform."):
				has_specific = true
		if has_specific or peak >= 0.02:
			continue
		_fail("%s has no perceivable effect (peak=%.4f)" % [node.get("id"), peak])
		failures += 1

	print("V5 CONTRACT nodes=%d geo_nodes=%d rule_terms=%d failures=%d" % [
		nodes.size(), geo_nodes, rule_terms, failures])
	quit(0 if failures == 0 else 1)
