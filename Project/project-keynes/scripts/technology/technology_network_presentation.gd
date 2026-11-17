extends RefCounted

const MODIFIER_SUBJECT_NAMES := {
	"country.climate.cold_stress_factor": "寒冷损失",
	"country.climate.drought_loss_factor": "旱灾损失",
	"country.climate.flood_loss_factor": "洪灾损失",
	"country.climate.heat_stress_factor": "热害损失",
	"country.construction.cost_factor": "国家建设成本",
	"country.output.agriculture_factor": "农业部门产出",
	"country.output.energy_factor": "能源部门产出",
	"country.output.extractive_factor": "采掘部门产出",
	"country.output.knowledge_factor": "知识部门产出",
	"country.output.manufacturing_factor": "制造部门产出",
	"country.research.agriculture_efficiency": "农业领域研究效率",
	"country.research.engineering_efficiency": "工程领域研究效率",
	"country.research.science_efficiency": "科学领域研究效率",
	"country.research.society_efficiency": "社会领域研究效率",
	"country.research.institution_output_factor": "科研机构产出",
	"country.trade.capacity_factor": "国内贸易容量",
	"country.trade.speed_factor": "贸易速度",
}

static func normalize_effect_summaries(payload: Dictionary) -> bool:
	var changed := false
	for node_value in payload.get("nodes", []):
		var node: Dictionary = node_value
		var summary := effect_summary(node)
		if String(node.get("effect_summary", "")) != summary:
			node["effect_summary"] = summary
			changed = true
	return changed


static func effect_summary(node: Dictionary) -> String:
	var parts := PackedStringArray()
	var seen := {}
	# 同类解锁合并成一句：三个物资写成「解锁物资：毛皮、野味、生皮」，
	# 而不是把「解锁物资：」重复三遍。
	var grouped := {}
	var group_order := PackedStringArray()
	for effect_value in node.get("content_effects", []):
		var effect: Dictionary = effect_value
		# Goods already permitted by a hard ancestor keep their binding but are
		# not repeated as a new unlock in the player-facing summary.
		if String(effect.get("operation", "")) != "unlock" \
				or not bool(effect.get("summary_visible", true)):
			continue
		var display_name := String(effect.get("display_name", effect.get("id", "")))
		var prefix := ""
		match String(effect.get("kind", "")):
			"building": prefix = "解锁建筑"
			"good": prefix = "解锁物资"
			"resource": prefix = "可利用资源"
			# 运行时能力（例如水运航道）没有建筑/物资载体，但玩家需要知道它开了什么。
			"runtime":
				prefix = "开启航道" if String(effect.get("id", "")).begins_with("water.") \
					else "开放能力"
			_: continue
		if not grouped.has(prefix):
			grouped[prefix] = []
			group_order.append(prefix)
		var names: Array = grouped[prefix]
		if not names.has(display_name):
			names.append(display_name)
		grouped[prefix] = names
	for prefix in group_order:
		var names: Array = grouped[prefix]
		if names.is_empty():
			continue
		var text := "%s：%s" % [prefix, "、".join(PackedStringArray(names))]
		if not seen.has(text):
			seen[text] = true
			parts.append(text)
	for term_value in node.get("modifier_terms", []):
		var term: Dictionary = term_value
		var text := "%s %s" % [modifier_effect_subject(term), modifier_delta(term)]
		if not seen.has(text):
			seen[text] = true
			parts.append(text)
	# 「作为必要支撑：…」这类说明对玩家没有信息量，已移除；
	# support_buildings 仍保留在数据里，供审计与详情面板使用。
	if parts.is_empty():
		return "完成时代里程碑并开放下一时代" if bool(node.get(
			"is_milestone", false)) else ""
	# Era milestones are no longer researched; their Modifier terms are the
	# buff granted by Era Advancement (docs/cpp-dots-runtime/era-advancement-runtime.md).
	if bool(node.get("is_milestone", false)):
		return "时代晋升效果：" + "；".join(parts)
	return "；".join(parts)


static func modifier_effect_subject(term: Dictionary) -> String:
	var stat := String(term.get("stat", ""))
	var subject := String(term.get("subject_display_name", "")).strip_edges()
	if subject.is_empty():
		subject = String(MODIFIER_SUBJECT_NAMES.get(stat, stat))
	if stat.begins_with("country.output.family."):
		return "「%s」生产家族建筑产出" % subject
	if stat.begins_with("country.output.building."):
		return "建筑「%s」产出" % subject
	if stat.begins_with("country.output.good."):
		return "商品「%s」产量" % subject
	if stat.begins_with("country.output.terrain.") \
			or stat.begins_with("country.output.landform."):
		return "地理专长「%s」产出" % subject
	if stat.begins_with("country.input.good."):
		return "商品「%s」生产投入" % subject
	if stat.begins_with("country.consumption.good."):
		return "商品「%s」家庭消费" % subject
	return subject


static func modifier_delta(term: Dictionary) -> String:
	var stat := String(term.get("stat", ""))
	var operation := int(term.get("operation", 0))
	var value := float(term.get("value", 0.0))
	var delta := value
	match operation:
		1: delta = -value
		2: delta = value - 1.0
		3: delta = 1.0 / value - 1.0 if not is_zero_approx(value) else 0.0
	var percent := delta * 100.0
	# 基准点（_bp）类统计：值的单位是 0.01%，直接乘 100 会变成 +20000% 这种胡话。
	if stat.ends_with("_bp"):
		# 基准点：100 bp = 1%。玩家看得懂的是百分比，不是 bp。
		percent = delta / 100.0
		var points := ("%.2f" % absf(percent)).rstrip("0").rstrip(".")
		return "%s%s%%" % ["+" if percent >= 0.0 else "-", points]
	var amount := ("%.1f" % absf(percent)).rstrip("0").rstrip(".")
	return "%s%s%%" % ["+" if percent >= 0.0 else "-", amount]


static func audit_report(payload: Dictionary, stats: Dictionary) -> String:
	var effect_counts := {
		"全社会或部门": 0,
		"精确物资产出": 0,
		"精确物资投入": 0,
		"居民物资消费": 0,
		"自然资源": 0,
		"地理×产业": 0,
		"国家气候适应": 0,
		"生产类型气候适应": 0,
	}
	for node_value in payload.nodes:
		for term_value in (node_value as Dictionary).get("modifier_terms", []):
			var stat := String((term_value as Dictionary).get("stat", ""))
			if stat.begins_with("country.output.good."):
				effect_counts["精确物资产出"] += 1
			elif stat.begins_with("country.input.good."):
				effect_counts["精确物资投入"] += 1
			elif stat.begins_with("country.consumption.good."):
				effect_counts["居民物资消费"] += 1
			elif stat.begins_with("country.resource."):
				effect_counts["自然资源"] += 1
			elif stat.begins_with("country.output.terrain.") \
					or stat.begins_with("country.output.landform."):
				effect_counts["地理×产业"] += 1
			elif stat.begins_with("country.climate.profile."):
				effect_counts["生产类型气候适应"] += 1
			elif stat.begins_with("country.climate."):
				effect_counts["国家气候适应"] += 1
			else:
				effect_counts["全社会或部门"] += 1
	var lines := PackedStringArray([
		"# Technology Network v4 Audit", "",
		"- Research nodes: %d" % (payload.nodes as Array).size(),
		"- Application intersections: %d (static, zero-cost)" % (payload.get("application_intersections", []) as Array).size(),
		"- Nodes: %d" % (payload.nodes as Array).size(),
		"- Branch families: %d" % (payload.branch_families as Array).size(),
		"- Hard prerequisite edges: %d (no indegree cap)" % int(stats.hard_edges),
		"- Alternative evidence edges: %d" % int(stats.alternative_edges),
		"- Milestone candidate edges: %d (8–18 per era, require 4–7)" % int(stats.milestone_candidate_edges),
		"- Nodes with research routes: %d" % int(stats.research_route_nodes),
		"- Research routes: %d" % int(stats.research_route_count),
		"- Authored branch successor edges: %d" % int(stats.branch_successor_edges),
		"- Unlock-only/no-Modifier nodes: %d" % int(stats.empty_modifier_nodes), "",
		"## Explicit effect semantics", "",
		"- Societal/sector terms: %d" % int(effect_counts["全社会或部门"]),
		"- Exact-good output terms: %d" % int(effect_counts["精确物资产出"]),
		"- Exact-good input terms: %d" % int(effect_counts["精确物资投入"]),
		"- Household good-consumption terms: %d" % int(effect_counts["居民物资消费"]),
		"- Natural-resource terms: %d" % int(effect_counts["自然资源"]),
		"- Geography × sector terms: %d" % int(effect_counts["地理×产业"]),
		"- Country climate-adaptation terms: %d" % int(effect_counts["国家气候适应"]),
		"- Production-profile climate-adaptation terms: %d" % int(
			effect_counts["生产类型气候适应"]),
		"- Missing runtime consumers: 0", "",
		"## Branch families", "",
	])
	for family_value in payload.branch_families:
		var family: Dictionary = family_value
		var members := 0
		for node_value in payload.nodes:
			if String((node_value as Dictionary).branch_family_id) == String(family.id):
				members += 1
		lines.append("- %s (`%s`): %d nodes" % [String(family.display_name), String(family.id), members])
	return "\n".join(lines) + "\n"
