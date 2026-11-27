extends RefCounted

## Display names and modifier text for authored stats and definitions.

const DisplayNames = preload("res://scripts/modifier/modifier_display_names.gd")
const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")
const LandformTypeScript = preload("res://scripts/geography/landform_type.gd")
const GoodProfileRegistryScript = preload("res://scripts/data/good_profile_registry.gd")
const ResourceProfileRegistryScript = preload(
	"res://scripts/data/resource_profile_registry.gd")

const Q16_ONE := 65536
const STAT_DISPLAY_NAMES := {
	"country.economy_output_factor": "全社会经济产出",
	"country.production.input_factor": "全社会生产投入",
	"country.household.consumption_factor": "全社会家庭消费",
	"country.resource.use_factor": "全社会自然资源耗用",
	"country.population.death_factor": "人口自然死亡率",
	"country.climate.cold_stress_factor": "寒冷损失",
	"country.climate.drought_loss_factor": "旱灾损失",
	"country.climate.flood_loss_factor": "洪灾损失",
	"country.climate.heat_stress_factor": "热害损失",
	"country.construction.cost_factor": "全国建设成本",
	"country.construction.time_factor": "全国建设耗时",
	"country.output.agriculture_factor": "农业部门产出",
	"country.output.extractive_factor": "采掘部门产出",
	"country.output.manufacturing_factor": "制造部门产出",
	"country.output.energy_factor": "能源部门产出",
	"country.output.knowledge_factor": "知识部门产出",
	"country.research.engineering_efficiency": "工程领域研究效率",
	"country.research.science_efficiency": "科学领域研究效率",
	"country.research.society_efficiency": "社会领域研究效率",
	"country.research.agriculture_efficiency": "农业领域研究效率",
	"country.research.cost_factor": "研究成本",
	"country.research.institution_output_factor": "研究机构产出",
	"country.ideology.point_gain_factor": "理念点获取",
	"country.ideology.understanding_gain_factor": "理念理解速度",
	"country.ideology.reroll_cost_factor": "理念重抽费用",
	"country.ideology.point_population_factor": "人口增长理念点",
	"country.ideology.point_building_factor": "建筑增长理念点",
	"country.ideology.point_trade_factor": "贸易理念点",
	"country.ideology.opinion_factor_floor": "理念点获取的民意加成下限",
	"country.ideology.school_strength_factor.agrarian": "农本理念强度",
	"country.ideology.school_strength_factor.commerce": "商贸理念强度",
	"country.ideology.school_strength_factor.learning": "学识理念强度",
	"country.ideology.school_strength_factor.mobilization": "动员理念强度",
	"country.ideology.school_strength_factor.industry": "工造理念强度",
	"country.ideology.school_strength_factor.harmony": "调和理念强度",
	"country.trade.capacity_factor": "国内贸易容量",
	"country.trade.speed_factor": "贸易速度",
	"country.military.supply_consumption_factor": "补给消耗",
	"country.military.organization_recovery_factor": "组织度恢复",
	"country.military.occupation_tax_efficiency": "占领税效率",
	"country.military.attack_factor": "全国部队攻击",
	"country.military.defense_factor": "全国部队防御",
	"country.military.speed_factor": "部队速度",
	"country.military.logistics_move_factor": "本土行军",
	"country.military.supply_transport_factor": "车队速度",
	"country.military.barracks_capacity_factor": "兵额",
	"country.military.levy_rate": "单格征召上限",
	"country.military.wage_factor": "军饷系数",
	"country.military.training_time_factor": "训练时长",
	"country.military.desertion_factor": "逃兵比例",
	"country.military.casualty_factor": "伤亡",
	"country.military.attrition_factor": "恶劣环境减员",
	"country.military.morale_add": "全国部队士气",
	"country.military.fortification_factor": "本国工事强度",
	"country.military.frontage_factor": "战斗宽度",
	"country.military.militia_factor": "民兵战力",
	"country.military.naval_transport_factor": "海运运力",
	"country.military.vision_add": "部队视野",
	"country.military.convoy_escort_factor": "车队护卫",
	"country.military.rule.mutual_support": "犄角之势参数",
	"country.military.rule.last_stand": "背水一战参数",
	"country.military.rule.blitz": "闪击参数",
	"country.military.rule.hold_the_line": "寸土不让参数",
	"country.military.rule.encirclement": "合围参数",
	"country.military.rule.home_ground": "本土作战参数",
	# Cell-level (channel A). The wording names the CELL, not the country: a card
	# face that said "全国部队攻击" for a stat that only moves one cell's garrison
	# would promise something the runtime does not do.
	"military.cell.attack_factor": "当地驻军攻击",
	"military.cell.defense_factor": "当地驻军防御",
	"military.cell.organization_recovery_factor": "当地驻军组织度恢复",
	"military.cell.supply_consumption_factor": "当地驻军补给消耗",
	"military.cell.barracks_capacity_factor": "当地兵营兵额",
	"military.cell.training_speed_factor": "当地训练速度",
}
## Ideology cards have their own audience-facing wording. Keep this map separate
## from the shared stat labels so other panels keep their established terms.
const IDEOLOGY_PLAIN_STAT_NAMES := {
	"country.output.agriculture_factor": "农业部门产出",
	"country.output.extractive_factor": "采掘部门产出",
	"country.output.manufacturing_factor": "制造部门产出",
	"country.output.energy_factor": "能源部门产出",
	"country.output.knowledge_factor": "知识部门产出",
	"country.research.agriculture_efficiency": "农业领域研究效率",
	"country.research.engineering_efficiency": "工程领域研究效率",
	"country.research.science_efficiency": "科学领域研究效率",
	"country.research.society_efficiency": "社会领域研究效率",
	"country.research.institution_output_factor": "研究机构产出",
	"country.production.input_factor": "全社会生产投入",
	"country.climate.cold_stress_factor": "寒冷损失",
	"country.climate.heat_stress_factor": "热害损失",
	"country.climate.drought_loss_factor": "旱灾损失",
	"country.climate.flood_loss_factor": "洪灾损失",
	"country.household.consumption_factor": "全社会家庭消费",
	"country.resource.use_factor": "全社会自然资源耗用",
	"country.trade.capacity_factor": "国内贸易容量",
	"country.trade.speed_factor": "贸易速度",
	"country.resource.fertile_soil.managed_generation_factor": "肥沃土壤自然恢复速度",
	"country.resource.freshwater_fish.managed_generation_factor": "淡水鱼群自然恢复速度",
	"country.resource.timber.managed_generation_factor": "木材自然恢复速度",
	"country.resource.wild_game.managed_generation_factor": "野生动物自然恢复速度",
	"country.resource.pasture.managed_generation_factor": "牧场自然恢复速度",
}

# Selector-addressable stat keys (see compile_native_catalog() below) are expanded
# from stable IDs, so there are thousands of them and they cannot be enumerated in
# STAT_DISPLAY_NAMES. They are rendered as "<family label><dimension display name>"
# instead. Dimension display names come from two places:
#   * EconomyFacade registers the ids it already loads for the UI (building/good/
#     profession/need) through register_display_names() at configure time;
#   * terrain/landform/sector/hazard resolve statically here.
# Anything not registered falls back to the raw stable id, so headless tests and
# editor previews keep working without any economy bootstrap.
const UNIT_FACTOR := 0
const UNIT_RATE_BP := 1
const UNIT_POINTS := 2

const SECTOR_DISPLAY_NAMES := {
	"agriculture": "农业",
	"extractive": "采掘",
	"manufacturing": "制造",
	"energy": "能源",
	"knowledge": "知识",
}
const HAZARD_DISPLAY_NAMES := {
	"drought": "旱灾",
	"flood": "洪灾",
	"cold_stress": "寒害",
	"heat_stress": "热害",
}
const PRODUCTION_CLIMATE_PROFILE_DISPLAY_NAMES := {
	"dryland_crop": "旱作作物",
	"paddy_crop": "水田作物",
}

static var _dimension_display_names: Dictionary = {}


## Registers stable-id to display-name mappings for selector dimensions.
## Callers pass the same dictionaries the UI already uses, so a modifier line and
## the tooltip that explains it never disagree. Safe to call repeatedly; only
## changed entries invalidate anything, and nothing is cached downstream.
static func register_display_names(kind: StringName, names: Dictionary) -> void:
	if names.is_empty():
		return
	var bucket: Dictionary = _dimension_display_names.get(kind, {})
	for key in names:
		bucket[String(key)] = String(names[key])
	_dimension_display_names[kind] = bucket


## Drops every registered dimension name (tests only).
static func reset_display_names() -> void:
	_dimension_display_names.clear()


static func display_name_of(kind: StringName, stable_id: String) -> String:
	var bucket: Dictionary = _dimension_display_names.get(kind, {})
	if bucket.has(stable_id):
		return String(bucket[stable_id])
	# Headless catalog views can run before EconomyFacade registers names. Read
	# the authoritative profile catalogs directly so card faces never fall back
	# to a stable ID merely because of bootstrap order.
	if kind == &"good":
		var good: Resource = GoodProfileRegistryScript.profile_by_id(stable_id)
		if good != null:
			var good_name := String(good.get("display_name")).strip_edges()
			if not good_name.is_empty():
				return good_name
	elif kind == &"resource":
		for resource_value in ResourceProfileRegistryScript.ordered():
			var resource: Resource = resource_value
			if resource == null or String(resource.get("id")) != stable_id:
				continue
			var resource_name := String(resource.get("display_name")).strip_edges()
			if not resource_name.is_empty():
				return resource_name
	return stable_id


static func _terrain_display_name(stable_id: String) -> String:
	var terrain: int = int(TerrainTypeScript.TERRAIN.get(stable_id.to_upper(), -1))
	if terrain < 0:
		return stable_id
	return TerrainTypeScript.terrain_name_cn(terrain)


static func _landform_display_name(stable_id: String) -> String:
	var landform: int = int(LandformTypeScript.LF.get(stable_id.to_upper(), -1))
	if landform < 0:
		return stable_id
	return LandformTypeScript.name_cn(landform)


static func _strip_suffix(value: String, suffix: String) -> String:
	if not value.ends_with(suffix):
		return ""
	return value.substr(0, value.length() - suffix.length())


## Resolves a selector-addressable stat key into {"label", "unit"}.
## Returns {} for keys this formatter does not understand.
static func _describe_stat_key(stat_key: String) -> Dictionary:
	var parts := stat_key.split(".")
	var count := parts.size()
	if count == 4:
		# country.output.<family|good|building>.<stable_id>_factor
		if parts[0] == "country" and parts[1] == "output":
			var tail := _strip_suffix(parts[3], "_factor")
			if tail.is_empty():
				return {}
			match parts[2]:
				"building":
					return {"label": "%s 产出" % display_name_of(&"building", tail),
						"unit": UNIT_FACTOR}
				"good":
					return {"label": "%s 全国产出" % display_name_of(&"good", tail),
						"unit": UNIT_FACTOR}
				"family":
					return {"label": "%s 建筑系产" % display_name_of(&"family", tail),
						"unit": UNIT_FACTOR}
			return {}
		# country.input|consumption.good.<stable_id>_factor
		if parts[0] == "country" and parts[2] == "good":
			var good_tail := _strip_suffix(parts[3], "_factor")
			if good_tail.is_empty():
				return {}
			match parts[1]:
				"input":
					return {"label": "%s 全国投入" % display_name_of(&"good", good_tail),
						"unit": UNIT_FACTOR}
				"consumption":
					return {"label": "%s 全国消费" % display_name_of(&"good", good_tail),
						"unit": UNIT_FACTOR}
			return {}
		# economy.profession.<profession_id>.<tax_tolerance_factor|satisfaction_bp>
		if parts[0] == "economy" and parts[1] == "profession":
			var profession_name := _profession_display_name(parts[2])
			match parts[3]:
				"tax_tolerance_factor":
					return {"label": "%s 税负容忍" % profession_name,
						"unit": UNIT_FACTOR, "profession_id": parts[2],
						"profession_metric": "tax_tolerance"}
				"satisfaction_bp":
					return {"label": profession_name,
						"unit": UNIT_POINTS, "profession_id": parts[2],
						"profession_metric": "satisfaction"}
			return {}
		# economy.class.<class_id>.satisfaction_bp
		if parts[0] == "economy" and parts[1] == "class" \
				and parts[3] == "satisfaction_bp":
			var class_label := String(DisplayNames.POLITICAL_CLASS_DISPLAY_NAMES.get(
				parts[2], parts[2]))
			return {"label": "%s满意度" % class_label, "unit": UNIT_POINTS}
		# country.resource.<stable_id>.<use_factor|managed_generation_factor>
		if parts[0] == "country" and parts[1] == "resource":
			var resource_name := display_name_of(&"resource", parts[2])
			match parts[3]:
				"use_factor":
					return {"label": "%s 耗用" % resource_name, "unit": UNIT_FACTOR}
				"managed_generation_factor":
					return {"label": "%s 管护再生" % resource_name, "unit": UNIT_FACTOR}
			return {}
		return {}
	if count == 5:
		# country.output.<terrain|landform>.<geography_id>.<sector>_factor
		if parts[0] == "country" and parts[1] == "output" \
				and (parts[2] == "terrain" or parts[2] == "landform"):
			var sector := _strip_suffix(parts[4], "_factor")
			if sector.is_empty():
				return {}
			var geography_name := _landform_display_name(parts[3])
			if parts[2] == "terrain":
				geography_name = _terrain_display_name(parts[3])
			var sector_name := String(SECTOR_DISPLAY_NAMES.get(sector, sector))
			return {"label": "%s·%s 产出" % [geography_name, sector_name],
				"unit": UNIT_FACTOR}
		# country.climate.profile.<profile_id>.<hazard>_loss_factor
		if parts[0] == "country" and parts[1] == "climate" and parts[2] == "profile":
			var hazard := _strip_suffix(parts[4], "_loss_factor")
			if hazard.is_empty():
				return {}
			var profile_name := String(PRODUCTION_CLIMATE_PROFILE_DISPLAY_NAMES.get(
				parts[3], parts[3]))
			return {"label": "%s%s损失" % [profile_name,
				String(HAZARD_DISPLAY_NAMES.get(hazard, hazard))], "unit": UNIT_FACTOR}
		# country.tax.<kind>.<stable_id>.rate_bp
		if parts[0] == "country" and parts[1] == "tax" and parts[4] == "rate_bp":
			var target := parts[3]
			var target_name := target
			match parts[2]:
				"income":
					target_name = _profession_display_name(target)
					return {"label": "%s 所得税" % target_name, "unit": UNIT_RATE_BP}
				"consumption":
					target_name = display_name_of(&"good", target)
					return {"label": "%s 消费" % target_name, "unit": UNIT_RATE_BP}
				"business":
					target_name = display_name_of(&"building", target)
					return {"label": "%s 营业税率" % target_name, "unit": UNIT_RATE_BP}
				"import":
					target_name = display_name_of(&"good", target)
					return {"label": "%s 进口税率" % target_name, "unit": UNIT_RATE_BP}
				"export":
					target_name = display_name_of(&"good", target)
					return {"label": "%s 出口税率" % target_name, "unit": UNIT_RATE_BP}
			return {}
		# economy.city.<need|good|building|resource>.<stable_id>.<suffix>
		if parts[0] == "economy" and parts[1] == "city":
			var city_id := parts[3]
			match parts[2]:
				"building":
					if parts[4] == "output_factor":
						return {"label": "%s 城市产出" % display_name_of(&"building", city_id),
							"unit": UNIT_FACTOR}
				"good":
					match parts[4]:
						"output_factor":
							return {"label": "%s 城市产出" % display_name_of(&"good", city_id),
								"unit": UNIT_FACTOR}
						"consumption_factor":
							return {"label": "%s 城市消费" % display_name_of(&"good", city_id),
								"unit": UNIT_FACTOR}
				"need":
					if parts[4] == "consumption_factor":
						return {"label": "%s 需求消" % display_name_of(&"need", city_id),
							"unit": UNIT_FACTOR}
				"resource":
					if parts[4] == "regen_factor":
						return {"label": "%s 城市再生" % display_name_of(&"resource", city_id),
							"unit": UNIT_FACTOR}
			return {}
	return {}


static func present_stat_delta(stat_key: String, operation: int, value: float,
		magnitude_q16: int = Q16_ONE, plain_language: bool = false,
		label_override: String = "") -> String:
	if not is_finite(value):
		return ""
	var label := String(STAT_DISPLAY_NAMES.get(stat_key, ""))
	var unit := UNIT_FACTOR
	var profession_id := ""
	var profession_metric := ""
	if label.is_empty():
		var described := _describe_stat_key(stat_key)
		if described.is_empty():
			return ""
		label = String(described.get("label", ""))
		unit = int(described.get("unit", UNIT_FACTOR))
		profession_id = String(described.get("profession_id", ""))
		profession_metric = String(described.get("profession_metric", ""))
	elif plain_language:
		label = String(IDEOLOGY_PLAIN_STAT_NAMES.get(stat_key, label))
	if plain_language and not label_override.is_empty():
		label = label_override
	if label.is_empty():
		return ""
	var magnitude := float(magnitude_q16) / float(Q16_ONE)
	var delta := 0.0
	match operation:
		0:
			delta = value * magnitude
		1:
			delta = -value * magnitude
		2:
			delta = (value - 1.0) * magnitude
		3:
			if is_zero_approx(value):
				return ""
			delta = ((1.0 / value) - 1.0) * magnitude
		_:
			return ""
	var is_tolerance := profession_metric == "tax_tolerance"
	var is_satisfaction := profession_metric == "satisfaction"
	if not profession_id.is_empty():
		label = _profession_display_name(profession_id)
		if is_satisfaction and plain_language:
			label += "满意度"
		elif is_satisfaction:
			pass
		elif plain_language and is_tolerance:
			pass
		elif is_tolerance:
			label += " 税负容忍"
	if unit == UNIT_RATE_BP and (operation == 0 or operation == 1):
		# Rate stats are authored in basis points, so additive terms never fit the
		# whole-percent formatting below (a 15 bp change would render as +0%).
		if absf(delta) < 0.5:
			return ""
		var rate_points := delta * 0.01
		if plain_language:
			var plain_label := label.replace(" 所得税", "所得税率") \
				.replace(" 消费", "消费税率").replace(" 营业税率", "营业税率") \
				.replace(" 进口税率", "进口税率").replace(" 出口税率", "出口税率")
			return "%s%s %s 个百分点" % [plain_label,
				"提高" if rate_points > 0.0 else "降低",
				_format_decimal(absf(rate_points))]
		return "%s %+.2f%%" % [label, rate_points]
	if unit == UNIT_POINTS and (operation == 0 or operation == 1):
		if absf(delta) < 0.5:
			return ""
		var satisfaction_points := delta * 0.01
		if plain_language:
			return "%s%s %s 点" % [label,
				"提高" if delta > 0.0 else "降低",
				_format_decimal(absf(satisfaction_points))]
		return "%s %+.2f 点" % [label, satisfaction_points]
	var percent := int(round(delta * 100.0))
	if percent == 0:
		return ""
	# This stat is an additive offset on the opinion-factor floor, not a
	# multiplicative percentage. One authored step therefore changes the floor
	# by one percentage point.
	if plain_language and stat_key == "country.ideology.opinion_factor_floor":
		return "%s%s %d 个百分点" % [label,
			"提高" if percent > 0 else "降低", absi(percent)]
	if plain_language and is_tolerance:
		return "%s对税负的承受能力%s %d%%" % [label,
			"提高" if percent > 0 else "降低", absi(percent)]
	if plain_language and is_satisfaction:
		return "%s%s %d 点" % [label,
			"提高" if delta > 0.0 else "降低", absi(percent)]
	return "%s %+d%%" % [label, percent]


static func _profession_display_name(stable_id: String) -> String:
	var registered := display_name_of(&"profession", stable_id)
	if registered != stable_id:
		return registered
	return String(DisplayNames.PROFESSION_DISPLAY_NAMES.get(stable_id, stable_id))


static func _format_decimal(value: float) -> String:
	var text := "%.2f" % value
	text = text.trim_suffix("0").trim_suffix("0").trim_suffix(".")
	return text


static func present_definition_for_ideology(definitions: Array[Resource], definition_key: StringName,
		magnitude_q16: int = Q16_ONE) -> PackedStringArray:
	var lines := PackedStringArray()
	if definition_key == &"":
		return lines
	for definition in definitions:
		if definition == null or definition.key != definition_key:
			continue
		var profession_terms: Dictionary = {}
		var names_by_kind: Dictionary = {}
		for term in definition.terms:
			if term == null:
				continue
			var stat_key := String(term.stat_key)
			var described := _describe_stat_key(stat_key)
			var unit := int(described.get("unit", UNIT_FACTOR))
			var label := String(described.get("label", stat_key))
			if not described.is_empty():
				label = String(IDEOLOGY_PLAIN_STAT_NAMES.get(stat_key, label))
			if stat_key.begins_with("country.input.good."):
				label = "%s生产原料需求量" % display_name_of(&"good",
					_strip_suffix(stat_key.split(".")[3], "_factor"))
			elif stat_key.begins_with("country.consumption.good."):
				label = "%s家庭消费需求量" % display_name_of(&"good",
					_strip_suffix(stat_key.split(".")[3], "_factor"))
			elif stat_key.begins_with("country.climate.profile."):
				label = label.replace("损失", "生产损失")
			if label.begins_with("全国自然资源") \
					and label.ends_with("恢复速度"):
				label = label.replace("全国自然资源", "自然资源")
			if not described.is_empty() and unit in [UNIT_FACTOR, UNIT_POINTS] \
					and stat_key.begins_with("economy.profession."):
				var parts := stat_key.split(".")
				if parts.size() == 4 and parts[3] in [
						"tax_tolerance_factor", "satisfaction_bp"]:
					var line := present_stat_delta(stat_key, int(term.operation),
						float(term.value), magnitude_q16, true)
					if not line.is_empty():
						var group_key := "%s|%d|%s" % [parts[3],
							int(term.operation), var_to_str(term.value)]
						profession_terms[group_key] = int(
							profession_terms.get(group_key, 0)) + 1
						var names: PackedStringArray = names_by_kind.get(group_key,
							PackedStringArray())
						names.append(_profession_display_name(parts[2]))
						names_by_kind[group_key] = names
					continue
			var line := present_stat_delta(stat_key, int(term.operation),
				float(term.value), magnitude_q16, true,
				"" if described.is_empty() else label)
			if not line.is_empty() and not lines.has(line):
				lines.append(line)
		for group_key in names_by_kind:
			var names: PackedStringArray = names_by_kind[group_key]
			var group_parts := String(group_key).split("|")
			var sample_key := "economy.profession.%s.%s" % [
				_profession_id_for_display_name(
					names[0] if not names.is_empty() else "unknown"),
				group_parts[0]]
			var sample_label := present_stat_delta(sample_key, int(group_parts[1]),
				float(group_parts[2]), magnitude_q16, true)
			if sample_label.is_empty():
				continue
			if int(profession_terms[group_key]) >= _known_profession_count():
				var split := sample_label.find("对税")
				if split >= 0:
					lines.append("全国各职业%s" % sample_label.substr(split))
				else:
					var satisfaction := sample_label.rfind("满意")
					lines.append("全国各职业%s" % sample_label.substr(
						satisfaction if satisfaction >= 0 else 0))
			else:
				var split := sample_label.find("对税")
				if split < 0:
					split = sample_label.rfind("满意")
				lines.append("%s%s" % ["、".join(names),
					sample_label.substr(split if split >= 0 else 0)])
		break
	return lines


static func _profession_id_for_display_name(display_name: String) -> String:
	for stable_id in DisplayNames.PROFESSION_DISPLAY_NAMES:
		if String(DisplayNames.PROFESSION_DISPLAY_NAMES[stable_id]) == display_name:
			return String(stable_id)
	return display_name


static func _known_profession_count() -> int:
	return DisplayNames.PROFESSION_DISPLAY_NAMES.size()


static func present_definition(definitions: Array[Resource], definition_key: StringName,
		magnitude_q16: int = Q16_ONE) -> PackedStringArray:
	if String(definition_key).begins_with("ideology."):
		return present_definition_for_ideology(definitions, definition_key, magnitude_q16)
	var lines := PackedStringArray()
	if definition_key == &"":
		return lines
	for definition in definitions:
		if definition == null or definition.key != definition_key:
			continue
		for term in definition.terms:
			if term == null:
				continue
			var line := present_stat_delta(String(term.stat_key),
				int(term.operation), float(term.value), magnitude_q16)
			if not line.is_empty() and not lines.has(line):
				lines.append(line)
		break
	return lines
