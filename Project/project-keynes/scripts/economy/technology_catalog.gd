class_name TechnologyCatalog
extends RefCounted

const DOMAIN_IDS := ["agriculture", "engineering", "science", "society"]
const DOMAIN_NAMES := ["农业", "工程", "科学", "社会"]
const DOMAIN_COLORS := [
	Color(0.39, 0.62, 0.31), Color(0.72, 0.48, 0.24),
	Color(0.28, 0.58, 0.74), Color(0.67, 0.48, 0.68),
]
const STARTING_IDS := [
	"tech.hunting", "tech.gathering", "tech.stone_knapping", "tech.fire_control",
]
const FLAG_ERA_KEY := 1
const FLAG_MILESTONE := 2
const FLAG_STARTING := 4

const ERA_ROWS := [
	["stone", "石器时代", "tech.settled_knowledge"],
	["bronze", "青铜时代", "tech.organized_settlements"],
	["classical", "古典时代", "tech.classical_synthesis"],
	["feudal", "封建时代", "tech.institutional_learning"],
	["exploration", "探索时代", "tech.global_exchange"],
	["enlightenment", "启蒙时代", "tech.enlightenment_institutions"],
	["steam", "蒸汽时代", "tech.industrialization"],
	["electrical", "电气时代", "tech.electrical_society"],
	["atomic", "原子时代", "tech.atomic_modernity"],
	["information", "信息时代", "tech.information_society"],
	["ai", "人工智能时代", "tech.cognitive_automation"],
]

# id, name, era, domain, cost, prerequisites, is_key, effect
const TECHNOLOGY_ROWS := [
	["tech.hunting", "狩猎", "stone", "society", 0, [], false, "开局根科技"],
	["tech.gathering", "采集", "stone", "agriculture", 0, [], false, "开局根科技"],
	["tech.stone_knapping", "石器打制", "stone", "engineering", 0, [], false, "开局根科技"],
	["tech.fire_control", "火的控制", "stone", "science", 0, [], false, "开局根科技"],
	["tech.seasonal_foraging", "冬季采集", "stone", "agriculture", 2000, ["tech.gathering"], true, "农业产出 +5%"],
	["tech.composite_tools", "复合工具", "stone", "engineering", 2000, ["tech.stone_knapping"], true, "制造产出 +5%"],
	["tech.natural_observation", "自然观察", "stone", "science", 2500, ["tech.fire_control"], true, "科学研究效率 +5%"],
	["tech.oral_tradition", "口述传统", "stone", "society", 2500, ["tech.hunting"], true, "解锁传知者与科研议事圈"],
	["tech.controlled_burning", "控制焚烧", "stone", "agriculture", 3500, ["tech.seasonal_foraging", "tech.fire_control"], false, "农业与采掘产出 +5%"],
	["tech.communal_specialization", "共同体分工", "stone", "society", 3500, ["tech.oral_tradition", "tech.composite_tools"], false, "施工时间 -5%"],
	["tech.settled_knowledge", "定居知识", "stone", "society", 5000, [], false, "开启青铜时代"],
	["tech.crop_domestication", "作物驯化", "bronze", "agriculture", 6000, ["tech.settled_knowledge", "tech.seasonal_foraging"], false, "农业产出 +5%"],
	["tech.pottery", "陶器", "bronze", "engineering", 6000, ["tech.settled_knowledge", "tech.composite_tools"], false, "解锁陶器产业"],
	["tech.bronze_casting", "青铜铸造", "bronze", "engineering", 7500, ["tech.pottery"], true, "制造产出 +10%"],
	["tech.celestial_calendars", "天文历法", "bronze", "science", 7500, ["tech.settled_knowledge", "tech.natural_observation"], true, "科学研究效率 +10%"],
	["tech.record_keeping", "记录制度", "bronze", "society", 9000, ["tech.settled_knowledge", "tech.oral_tradition"], true, "解锁书记员与书记学校"],
	["tech.irrigation", "灌溉", "bronze", "agriculture", 9000, ["tech.crop_domestication", "tech.celestial_calendars"], true, "农业产出 +15%"],
	["tech.organized_settlements", "组织化聚落", "bronze", "society", 12000, [], false, "开启古典时代"],
	["tech.writing", "文字", "classical", "society", 15000, ["tech.organized_settlements", "tech.record_keeping"], false, "解锁文字与手稿产业"],
	["tech.masonry", "砖石工程", "classical", "engineering", 15000, ["tech.organized_settlements", "tech.bronze_casting"], false, "施工成本 -10%"],
	["tech.natural_philosophy", "自然哲学", "classical", "science", 18000, ["tech.organized_settlements", "tech.celestial_calendars"], true, "科学研究效率 +10%"],
	["tech.crop_rotation", "轮作", "classical", "agriculture", 18000, ["tech.organized_settlements", "tech.irrigation"], true, "农业产出 +10%"],
	["tech.road_engineering", "道路工程", "classical", "engineering", 22000, ["tech.masonry"], true, "国内贸易容量 +15%"],
	["tech.scholarly_academies", "学术学院", "classical", "society", 22000, ["tech.writing", "tech.natural_philosophy"], true, "解锁学者与古典学院"],
	["tech.classical_synthesis", "古典综合", "classical", "society", 30000, [], false, "开启封建时代"],
	["tech.three_field_system", "三圃制", "feudal", "agriculture", 35000, ["tech.classical_synthesis", "tech.crop_rotation"], true, "农业产出 +15%"],
	["tech.water_power", "水力机械", "feudal", "engineering", 35000, ["tech.classical_synthesis", "tech.road_engineering"], true, "能源产出 +15%"],
	["tech.manuscript_culture", "手抄本文化", "feudal", "science", 42000, ["tech.classical_synthesis", "tech.natural_philosophy"], false, "知识产出 +10%"],
	["tech.guild_organization", "行会组织", "feudal", "society", 42000, ["tech.classical_synthesis", "tech.scholarly_academies"], true, "制造产出 +10%"],
	["tech.scholastic_method", "经院方法", "feudal", "science", 50000, ["tech.manuscript_culture"], true, "研究成本 -10%"],
	["tech.chartered_universities", "特许大学", "feudal", "society", 50000, ["tech.guild_organization", "tech.scholastic_method"], false, "解锁特许大学"],
	["tech.institutional_learning", "制度化学术", "feudal", "society", 70000, [], false, "开启探索时代"],
	["tech.agronomic_exchange", "农艺交流", "exploration", "agriculture", 80000, ["tech.institutional_learning", "tech.three_field_system"], true, "农业产出 +15%"],
	["tech.oceanic_navigation", "远洋航海", "exploration", "engineering", 80000, ["tech.institutional_learning", "tech.water_power"], true, "国内贸易速度 +15%"],
	["tech.cartography", "测绘学", "exploration", "science", 95000, ["tech.institutional_learning", "tech.scholastic_method"], true, "国内贸易容量 +15%"],
	["tech.printing_press", "印刷术", "exploration", "society", 95000, ["tech.institutional_learning", "tech.guild_organization"], true, "解锁印刷学社"],
	["tech.ship_design", "远洋船舶设计", "exploration", "engineering", 115000, ["tech.oceanic_navigation", "tech.cartography"], false, "国内贸易容量 +20%"],
	["tech.double_entry_bookkeeping", "复式记账", "exploration", "society", 115000, ["tech.printing_press", "tech.cartography"], false, "施工成本 -10%"],
	["tech.global_exchange", "全球交流", "exploration", "society", 160000, [], false, "开启启蒙时代"],
	["tech.agricultural_improvement", "农业改良", "enlightenment", "agriculture", 180000, ["tech.global_exchange", "tech.agronomic_exchange"], true, "农业产出 +20%"],
	["tech.precision_engineering", "精密工程", "enlightenment", "engineering", 180000, ["tech.global_exchange", "tech.oceanic_navigation"], true, "制造产出 +15%"],
	["tech.experimental_science", "实验科学", "enlightenment", "science", 215000, ["tech.global_exchange", "tech.cartography"], true, "解锁科学家与博学学会"],
	["tech.political_economy", "政治经济学", "enlightenment", "society", 215000, ["tech.global_exchange", "tech.printing_press"], true, "贸易容量 +10%、施工成本 -5%"],
	["tech.probability_statistics", "概率统计", "enlightenment", "science", 260000, ["tech.experimental_science"], false, "科学研究效率 +15%"],
	["tech.standardization", "工业标准化", "enlightenment", "engineering", 260000, ["tech.precision_engineering", "tech.political_economy"], false, "制造产出 +15%"],
	["tech.enlightenment_institutions", "启蒙制度", "enlightenment", "society", 360000, [], false, "核心：研究成本 -20%"],
	["tech.mechanized_agriculture", "机械化农业", "steam", "agriculture", 400000, ["tech.enlightenment_institutions", "tech.agricultural_improvement"], true, "核心：农业产出 +25%"],
	["tech.steam_power", "蒸汽动力", "steam", "engineering", 400000, ["tech.enlightenment_institutions", "tech.precision_engineering"], true, "核心：能源产出 +25%"],
	["tech.thermodynamics", "热力学", "steam", "science", 480000, ["tech.enlightenment_institutions", "tech.experimental_science"], true, "能源产出 +15%"],
	["tech.industrial_organization", "工业组织", "steam", "society", 480000, ["tech.enlightenment_institutions", "tech.political_economy"], true, "施工时间 -15%"],
	["tech.coke_smelting", "焦炭冶炼", "steam", "engineering", 580000, ["tech.steam_power", "tech.thermodynamics"], false, "制造产出 +15%"],
	["tech.rail_logistics", "铁路物流", "steam", "society", 580000, ["tech.steam_power", "tech.industrial_organization"], false, "贸易容量 +20%、速度 +10%"],
	["tech.industrialization", "工业化", "steam", "society", 800000, [], false, "开启电气时代"],
	["tech.synthetic_fertilizer", "合成肥料", "electrical", "agriculture", 900000, ["tech.industrialization", "tech.mechanized_agriculture"], true, "农业产出 +20%"],
	["tech.electrification", "电气化", "electrical", "engineering", 900000, ["tech.industrialization", "tech.steam_power"], true, "核心：能源产出 +30%"],
	["tech.electrochemistry", "电化学", "electrical", "science", 1080000, ["tech.industrialization", "tech.thermodynamics"], true, "制造产出 +15%"],
	["tech.public_education", "公共教育", "electrical", "society", 1080000, ["tech.industrialization", "tech.industrial_organization"], true, "社会研究效率 +15%"],
	["tech.radio", "无线电", "electrical", "science", 1300000, ["tech.electrification", "tech.electrochemistry"], false, "知识产出 +15%"],
	["tech.mass_production", "大规模生产", "electrical", "engineering", 1300000, ["tech.electrification", "tech.public_education"], false, "制造产出 +20%"],
	["tech.electrical_society", "电气社会", "electrical", "society", 1800000, [], false, "开启原子时代"],
	["tech.industrial_agronomy", "工业农学", "atomic", "agriculture", 2000000, ["tech.electrical_society", "tech.synthetic_fertilizer"], true, "农业产出 +20%"],
	["tech.advanced_metallurgy", "先进冶金", "atomic", "engineering", 2000000, ["tech.electrical_society", "tech.electrification"], true, "制造产出 +20%"],
	["tech.nuclear_fission", "核裂变", "atomic", "science", 2400000, ["tech.electrical_society", "tech.electrochemistry"], true, "能源产出 +20%"],
	["tech.national_laboratories", "国家实验室", "atomic", "society", 2400000, ["tech.electrical_society", "tech.public_education"], true, "解锁国家实验室、知识产出 +20%"],
	["tech.geological_prospecting", "地质勘探", "atomic", "science", 2900000, ["tech.nuclear_fission"], false, "采掘产出 +20%"],
	["tech.operations_research", "运筹学", "atomic", "society", 2900000, ["tech.national_laboratories", "tech.advanced_metallurgy"], false, "施工时间 -15%、贸易容量 +10%"],
	["tech.atomic_modernity", "原子现代性", "atomic", "society", 4000000, [], false, "开启信息时代"],
	["tech.precision_agriculture", "精准农业", "information", "agriculture", 4500000, ["tech.atomic_modernity", "tech.industrial_agronomy"], true, "农业产出 +20%"],
	["tech.digital_computing", "数字计算", "information", "engineering", 4500000, ["tech.atomic_modernity", "tech.advanced_metallurgy"], false, "核心：知识产出 +25%"],
	["tech.information_theory", "信息论", "information", "science", 5400000, ["tech.atomic_modernity", "tech.nuclear_fission"], true, "科学研究效率 +20%"],
	["tech.knowledge_economy", "知识经济", "information", "society", 5400000, ["tech.atomic_modernity", "tech.national_laboratories"], true, "社会研究效率 +20%"],
	["tech.software_engineering", "软件工程", "information", "engineering", 6500000, ["tech.digital_computing", "tech.information_theory"], true, "知识产出 +15%、制造产出 +10%"],
	["tech.networked_computing", "网络计算", "information", "society", 6500000, ["tech.digital_computing", "tech.knowledge_economy"], false, "贸易容量 +20%、速度 +15%"],
	["tech.information_society", "信息社会", "information", "society", 9000000, [], false, "开启人工智能时代"],
	["tech.automated_agriculture", "自动化农业", "ai", "agriculture", 10000000, ["tech.information_society", "tech.precision_agriculture"], true, "农业产出 +20%"],
	["tech.machine_learning", "机器学习", "ai", "science", 10000000, ["tech.information_society", "tech.information_theory", "tech.digital_computing"], false, "核心：知识产出 +30%"],
	["tech.neural_networks", "神经网络", "ai", "science", 12000000, ["tech.machine_learning"], true, "科学研究效率 +20%"],
	["tech.human_machine_collaboration", "人机协作", "ai", "society", 12000000, ["tech.information_society", "tech.knowledge_economy"], true, "社会研究效率 +20%"],
	["tech.autonomous_systems", "自主系统", "ai", "engineering", 14500000, ["tech.machine_learning", "tech.software_engineering"], true, "制造产出 +20%"],
	["tech.distributed_intelligence", "分布式智能", "ai", "engineering", 14500000, ["tech.autonomous_systems", "tech.human_machine_collaboration"], false, "贸易容量 +20%、知识产出 +10%"],
	["tech.cognitive_automation", "认知自动化", "ai", "society", 20000000, [], false, "完成科技树、研究成本 -10%"],
]

static func compile_native_catalog() -> Dictionary:
	var ids := PackedStringArray()
	var names := PackedStringArray()
	var era_ids := PackedStringArray()
	var domain_indices := PackedInt32Array()
	var costs := PackedInt64Array()
	var prerequisite_offsets := PackedInt32Array([0])
	var prerequisites := PackedInt32Array()
	var milestone_offsets := PackedInt32Array([0])
	var milestone_candidates := PackedInt32Array()
	var milestone_required := PackedInt32Array()
	var flags := PackedInt32Array()
	var effects := PackedStringArray()
	var id_to_index := {}
	var era_index := {}
	for i in range(ERA_ROWS.size()):
		era_index[String(ERA_ROWS[i][0])] = i
	for row in TECHNOLOGY_ROWS:
		var id := String(row[0])
		if not id.begins_with("tech.") or id_to_index.has(id):
			return {"ok": false, "reason": "technology_id_invalid_or_duplicate", "id": id}
		id_to_index[id] = ids.size()
		ids.append(id)
		names.append(String(row[1]))
	for row in TECHNOLOGY_ROWS:
		var era := String(row[2])
		var domain := DOMAIN_IDS.find(String(row[3]))
		if not era_index.has(era) or domain < 0 or int(row[4]) < 0:
			return {"ok": false, "reason": "technology_metadata_invalid", "id": String(row[0])}
		era_ids.append(era)
		domain_indices.append(domain)
		costs.append(int(row[4]) * 1000)
		for prerequisite in row[5]:
			var prerequisite_id := String(prerequisite)
			if not id_to_index.has(prerequisite_id):
				return {"ok": false, "reason": "technology_prerequisite_missing", "id": String(row[0]), "prerequisite": prerequisite_id}
			var prerequisite_index := int(id_to_index[prerequisite_id])
			if prerequisite_index >= ids.find(String(row[0])):
				return {"ok": false, "reason": "technology_catalog_not_topological", "id": String(row[0])}
			prerequisites.append(prerequisite_index)
		prerequisite_offsets.append(prerequisites.size())
		milestone_offsets.append(milestone_candidates.size())
		milestone_required.append(0)
		flags.append((1 if bool(row[6]) else 0) | (4 if STARTING_IDS.has(String(row[0])) else 0))
		effects.append(String(row[7]))
	for era_row in ERA_ROWS:
		var milestone_id := String(era_row[2])
		var milestone_index := int(id_to_index.get(milestone_id, -1))
		if milestone_index < 0:
			return {"ok": false, "reason": "technology_milestone_missing", "id": milestone_id}
		var candidates := []
		for i in range(ids.size()):
			if String(era_ids[i]) == String(era_row[0]) and (int(flags[i]) & 1) != 0:
				candidates.append(i)
		if candidates.size() != 4:
			return {"ok": false, "reason": "technology_era_key_count_invalid", "era": String(era_row[0]), "count": candidates.size()}
		var insert_at := int(milestone_offsets[milestone_index])
		for candidate in candidates:
			milestone_candidates.insert(insert_at, candidate)
			insert_at += 1
		for i in range(milestone_index + 1, milestone_offsets.size()):
			milestone_offsets[i] += candidates.size()
		milestone_required[milestone_index] = 2
		flags[milestone_index] = int(flags[milestone_index]) | 2
	var era_ids_out := PackedStringArray()
	var era_names := PackedStringArray()
	var era_milestones := PackedInt32Array()
	for row in ERA_ROWS:
		era_ids_out.append(String(row[0]))
		era_names.append(String(row[1]))
		era_milestones.append(int(id_to_index[String(row[2])]))
	return {
		"ok": true,
		"technology_ids": ids,
		"technology_display_names": names,
		"technology_era_ids": era_ids,
		"technology_domain_indices": domain_indices,
		"technology_costs": costs,
		"technology_prerequisite_offsets": prerequisite_offsets,
		"technology_prerequisites": prerequisites,
		"technology_milestone_offsets": milestone_offsets,
		"technology_milestone_candidates": milestone_candidates,
		"technology_milestone_required_counts": milestone_required,
		"technology_flags": flags,
		"technology_effect_summaries": effects,
		"technology_modifier_definition_keys": _modifier_definition_keys(ids),
		"technology_domain_ids": PackedStringArray(DOMAIN_IDS),
		"technology_domain_display_names": PackedStringArray(DOMAIN_NAMES),
		"technology_domain_default_weights_bp": PackedInt32Array([2500, 2500, 2500, 2500]),
		"technology_era_ids_ordered": era_ids_out,
		"technology_era_display_names": era_names,
		"technology_era_milestone_indices": era_milestones,
		"starting_technology_ids": PackedStringArray(STARTING_IDS),
	}

static func _modifier_definition_keys(ids: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for id in ids:
		out.append("technology.%s" % String(id).trim_prefix("tech."))
	return out

static func modifier_terms(technology_id: String, domain: int, flags: int) -> Array[Dictionary]:
	if (flags & FLAG_STARTING) != 0:
		return []
	var terms: Array[Dictionary] = []
	var research_stats := [
		"country.research.agriculture_efficiency",
		"country.research.engineering_efficiency",
		"country.research.science_efficiency",
		"country.research.society_efficiency",
	]
	var sector_stats := [
		"country.output.agriculture_factor",
		"country.output.manufacturing_factor",
		"country.output.knowledge_factor",
		"country.trade.capacity_factor",
	]
	terms.append({"stat": research_stats[domain], "operation": 0,
		"value": 0.02 if (flags & FLAG_ERA_KEY) != 0 else 0.01})
	terms.append({"stat": sector_stats[domain], "operation": 0,
		"value": 0.06 if (flags & FLAG_ERA_KEY) != 0 else 0.04})
	if domain == 1:
		terms.append({"stat": "country.construction.time_factor", "operation": 2,
			"value": 0.99})
	elif domain == 2:
		terms.append({"stat": "country.research.institution_output_factor",
			"operation": 0, "value": 0.03})
	elif domain == 3:
		terms.append({"stat": "country.trade.speed_factor", "operation": 0,
			"value": 0.01})
	if technology_id in ["tech.enlightenment_institutions", "tech.digital_computing"]:
		terms.append({"stat": "country.research.cost_factor", "operation": 2,
			"value": 0.85 if technology_id.ends_with("digital_computing") else 0.90})
	if technology_id in ["tech.mechanized_agriculture"]:
		terms.append({"stat": "country.output.agriculture_factor", "operation": 0,
			"value": 0.30})
	if technology_id in ["tech.steam_power", "tech.electrification"]:
		terms.append({"stat": "country.output.energy_factor", "operation": 0,
			"value": 0.30})
	if technology_id == "tech.machine_learning":
		terms.append({"stat": "country.research.institution_output_factor",
			"operation": 0, "value": 0.30})
	return terms

static func public_definitions() -> Array[Dictionary]:
	var compiled := compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return []
	var out: Array[Dictionary] = []
	var ids: PackedStringArray = compiled.technology_ids
	for i in range(ids.size()):
		var prerequisites_out := PackedStringArray()
		for edge in range(compiled.technology_prerequisite_offsets[i], compiled.technology_prerequisite_offsets[i + 1]):
			prerequisites_out.append(ids[compiled.technology_prerequisites[edge]])
		var candidates_out := PackedStringArray()
		for edge in range(compiled.technology_milestone_offsets[i], compiled.technology_milestone_offsets[i + 1]):
			candidates_out.append(ids[compiled.technology_milestone_candidates[edge]])
		out.append({
			"id": ids[i],
			"display_name": compiled.technology_display_names[i],
			"era_id": compiled.technology_era_ids[i],
			"domain_id": DOMAIN_IDS[compiled.technology_domain_indices[i]],
			"cost_points": int(compiled.technology_costs[i]) / 1000,
			"prerequisite_ids": prerequisites_out,
			"milestone_candidate_ids": candidates_out,
			"milestone_required_count": compiled.technology_milestone_required_counts[i],
			"is_milestone": (int(compiled.technology_flags[i]) & 2) != 0,
			"is_era_key": (int(compiled.technology_flags[i]) & 1) != 0,
			"is_starting": (int(compiled.technology_flags[i]) & 4) != 0,
			"effect_summary": compiled.technology_effect_summaries[i],
		})
	return out

# Era and domain presentation metadata is authored here so no reader has to
# rediscover display names from raw ids.
static func public_era_metadata() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for index in range(ERA_ROWS.size()):
		var row: Array = ERA_ROWS[index]
		out.append({
			"id": String(row[0]),
			"display_name": String(row[1]),
			"milestone_id": String(row[2]),
			"sort_order": index,
		})
	return out

static func public_domain_metadata() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for index in range(DOMAIN_IDS.size()):
		out.append({
			"id": String(DOMAIN_IDS[index]),
			"display_name": String(DOMAIN_NAMES[index]),
			"accent": DOMAIN_COLORS[index],
			"sort_order": index,
		})
	return out
