class_name EraRewardCatalog
extends RefCounted

const PoolScript = preload("res://scripts/effect/era_reward_pool.gd")
const OptionScript = preload("res://scripts/effect/era_reward_option.gd")
const SelectorScript = preload("res://scripts/effect/era_reward_target_selector.gd")
const WeightRuleScript = preload("res://scripts/effect/era_reward_weight_rule.gd")
const CommandTemplateScript = preload("res://scripts/effect/era_reward_command_template.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")

const Q16_ONE := 65536
const POOL_COUNT := 11
const OPTIONS_PER_POOL := 9
const FALLBACKS_PER_POOL := 3
const MAX_TARGETS := 32
const MAX_COMMANDS_PER_OPTION := 128

enum Eligibility {
	ALWAYS = 0,
	TERRITORY_AT_LEAST = 1,
	CASH_AT_LEAST = 2,
	RESEARCH_BEHIND = 3,
	SIGNAL_AT_LEAST = 4,
	TREASURY_STOCK_AT_LEAST = 5,
}

enum WeightCondition {
	NONE = 0,
	LOW_CASH = 1,
	WIDE_TERRITORY = 2,
	RESEARCH_BEHIND = 3,
	HAS_SIGNALS = 4,
	SIGNAL_PRESENT = 5,
	ROUTE_COMPLETED = 6,
}

const ERA_SPECS := [
	["stone", "石器时代", "tech.settled_knowledge"],
	["agrarian", "农耕时代", "tech.agrarian_society"],
	["kingdom", "王国时代", "tech.kingdom_administration"],
	["empire", "帝国时代", "tech.imperial_integration"],
	["exploration", "探索时代", "tech.global_exchange"],
	["enlightenment", "启蒙时代", "tech.enlightenment_institutions"],
	["steam", "蒸汽时代", "tech.industrialization"],
	["electrical", "电气时代", "tech.electrical_society"],
	["atomic", "原子时代", "tech.atomic_modernity"],
	["information", "信息时代", "tech.information_society"],
	["intelligent", "智能时代", "tech.cognitive_automation"],
]

const THEMES := [
	["food", "丰饶体系", "巩固粮食供给，并承担更高的建设协调成本。", "wheat",
		"country.output.agriculture_factor", "country.construction.cost_factor"],
	["industry", "产业跃迁", "集中扩张采掘与制造能力，但会挤压科研效率。", "industry",
		"country.output.manufacturing_factor", "country.research.cost_factor"],
	["research", "追赶工程", "投入广域科研以追赶知识前沿，但短期生产组织承压。", "flask",
		"country.research.institution_output_factor", "country.output.manufacturing_factor"],
	["trade", "物流网络", "扩大国内贸易与流通速度，但增加建设成本。", "route",
		"country.trade.capacity_factor", "country.construction.cost_factor"],
	["capital", "首都营造", "强化国家建设动员，但会牺牲部分贸易弹性。", "landmark",
		"country.construction.time_factor", "country.trade.capacity_factor"],
	["society", "社会协作", "改善知识与社会组织，但降低短期能源产出。", "people",
		"country.output.knowledge_factor", "country.output.energy_factor"],
	["state", "国家组织", "建立可靠的国家组织能力。", "shield",
		"country.construction.time_factor", ""],
	["science", "广域科研", "为全国研究机构提供稳定支持。", "book",
		"country.research.institution_output_factor", ""],
	["mobilize", "生产动员", "以国家协调推动普遍生产。", "gear",
		"country.output.manufacturing_factor", ""],
]

const THEME_SIGNAL_HINTS := [
	["resource.fertile_soil", "resource.arable_land", "resource.paddy_land",
		"resource.pasture", "bio.maize", "bio.wheat", "resource.phosphate_rock",
		"bio.rice", "bio.potato", "breakthrough.climate_modeling",
		"breakthrough.automation"],
	["resource.stone", "resource.copper_ore", "resource.iron_ore",
		"resource.timber", "resource.saltpeter", "resource.coal", "resource.coal",
		"resource.oil", "resource.bauxite", "resource.rare_earth",
		"breakthrough.automation"],
	["landform.river_valley", "breakthrough.metalworking",
		"landform.volcanic", "breakthrough.printing", "landform.coastal_estuary",
		"breakthrough.hydraulic_engineering", "breakthrough.steam_power",
		"breakthrough.electrification", "breakthrough.climate_modeling",
		"breakthrough.climate_modeling", "breakthrough.automation"],
	["landform.coast", "landform.river_valley", "landform.coastal_estuary",
		"landform.coast", "landform.coastal_estuary", "landform.river_valley",
		"resource.coal", "resource.oil", "landform.coast",
		"landform.coastal_estuary", "landform.coast"],
	["resource.stone", "resource.clay", "resource.limestone", "resource.timber",
		"resource.silver_ore", "landform.river_valley", "resource.iron_ore",
		"resource.copper_ore", "resource.bauxite", "resource.rare_earth",
		"resource.rare_earth"],
	["landform.forest", "landform.grassland", "landform.river_valley",
		"landform.high_plateau", "landform.coast", "landform.arid_basin",
		"breakthrough.industrial_organization", "breakthrough.electrification",
		"landform.mountain", "breakthrough.climate_modeling",
		"breakthrough.automation"],
]

const THEME_ROUTE_PREFIXES := [
	"route.crop.", "route.resource.", "route.institution.",
	"route.trade.", "route.geography.", "route.institution.",
]

static func build_pools() -> Array[Resource]:
	var pools: Array[Resource] = []
	for era_index in ERA_SPECS.size():
		var era: Array = ERA_SPECS[era_index]
		var pool := PoolScript.new()
		pool.stable_id = StringName("era_reward.pool.%s" % String(era[0]))
		pool.trigger_technology_id = StringName(era[2])
		pool.era_id = StringName(era[0])
		pool.era_title = String(era[1])
		pool.final_pool = era_index == ERA_SPECS.size() - 1
		for theme_index in THEMES.size():
			pool.options.append(_build_option(era_index, theme_index))
		pools.append(pool)
	return pools

static func _build_option(era_index: int, theme_index: int) -> Resource:
	var theme: Array = THEMES[theme_index]
	var option := OptionScript.new()
	option.stable_id = StringName("era_reward.%s.%s" % [
		String(ERA_SPECS[era_index][0]), String(theme[0])])
	option.title = "%s·%s" % [String(ERA_SPECS[era_index][1]), String(theme[1])]
	option.description = String(theme[2])
	option.icon_id = StringName(theme[3])
	option.base_weight = 100 + era_index * 4
	option.fallback = theme_index >= 6
	if not option.fallback:
		option.eligibility_code = [Eligibility.TERRITORY_AT_LEAST,
			Eligibility.TERRITORY_AT_LEAST, Eligibility.RESEARCH_BEHIND,
			Eligibility.TERRITORY_AT_LEAST, Eligibility.CASH_AT_LEAST,
			Eligibility.SIGNAL_AT_LEAST][theme_index]
		option.eligibility_threshold = [1, 2, 6 + era_index * 7, 3,
			(era_index + 1) * 250000, 1][theme_index]
		option.weight_rules = _weight_rules(era_index, theme_index)
	var selector := SelectorScript.new()
	selector.entity_type = SelectorScript.EntityType.COUNTRY
	selector.ranking = SelectorScript.Ranking.STABLE_HANDLE_ASC
	selector.top_n = 1
	selector.minimum_targets = 1
	var command := EffectCommandScript.new()
	command.action = 1
	command.domain = 1
	command.opcode = 1
	command.target_resolver = 1
	command.value_mode = 0
	command.value_q16 = Q16_ONE
	command.duration_days = -1
	command.stacks = 1
	command.command_key = &"era_reward.modifier"
	command.definition_key = modifier_definition_key(option.stable_id)
	var command_template := CommandTemplateScript.new()
	command_template.command = command
	command_template.target_selector = selector
	option.commands = [command_template]
	return option

static func _weight_rule(theme_index: int) -> Resource:
	var rule := WeightRuleScript.new()
	rule.condition_code = [WeightCondition.LOW_CASH, WeightCondition.WIDE_TERRITORY,
		WeightCondition.RESEARCH_BEHIND, WeightCondition.WIDE_TERRITORY,
		WeightCondition.LOW_CASH, WeightCondition.HAS_SIGNALS][theme_index]
	rule.threshold = [0, 4, 0, 5, 0, 1][theme_index]
	rule.multiplier_q16 = 98304
	rule.reason = ["当前财政偏紧", "领土规模适合专业化", "科研进度有追赶空间",
		"广域领土需要物流", "当前建设资金充足", "已有研究信号可转化"][theme_index]
	return rule

static func _weight_rules(era_index: int, theme_index: int) -> Array[Resource]:
	var rules: Array[Resource] = [_weight_rule(theme_index)]
	var signal_rule := WeightRuleScript.new()
	signal_rule.condition_code = WeightCondition.SIGNAL_PRESENT
	signal_rule.signal_id = StringName(THEME_SIGNAL_HINTS[theme_index][era_index])
	signal_rule.multiplier_q16 = 90112
	signal_rule.reason = "本国已经发现相应的资源或环境证据"
	rules.append(signal_rule)
	var route_rule := WeightRuleScript.new()
	route_rule.condition_code = WeightCondition.ROUTE_COMPLETED
	route_rule.route_tag_prefix = StringName(THEME_ROUTE_PREFIXES[theme_index])
	route_rule.multiplier_q16 = 81920
	route_rule.reason = "本国既有科技路线与该奖励相契合"
	rules.append(route_rule)
	return rules

static func modifier_definition_key(option_id: StringName) -> StringName:
	return StringName("%s.modifier" % String(option_id))

static func modifier_terms_for_option(era_index: int, theme_index: int) -> Array[Dictionary]:
	var main_percent := 12.0 + 1.3 * era_index
	var penalty_percent := 6.0 + 0.6 * era_index
	var theme: Array = THEMES[theme_index]
	var main_operation := 2
	var main_value := 1.0 + main_percent / 100.0
	if String(theme[4]).ends_with("cost_factor") or String(theme[4]).ends_with("time_factor"):
		main_value = 1.0 - main_percent / 100.0
	var terms: Array[Dictionary] = [{"stat": String(theme[4]),
		"operation": main_operation, "value": main_value}]
	if not String(theme[5]).is_empty():
		var penalty_value := 1.0 + penalty_percent / 100.0
		if not String(theme[5]).ends_with("cost_factor"):
			penalty_value = 1.0 - penalty_percent / 100.0
		terms.append({"stat": String(theme[5]), "operation": 2,
			"value": penalty_value})
	return terms

static func effect_definitions() -> Array[Resource]:
	var definitions: Array[Resource] = []
	for pool in build_pools():
		for option in pool.options:
			var definition := EffectDefinitionScript.new()
			definition.key = StringName("%s.effect" % String(option.stable_id))
			definition.version = 1
			definition.cadence_days = 3650
			var end := EffectInstructionScript.new()
			end.op = 12
			definition.instructions = [end]
			for template in option.commands:
				definition.commands.append(template.command)
			definitions.append(definition)
	return definitions

static func compile_native_catalog(technology_catalog: Dictionary) -> Dictionary:
	var pools := build_pools()
	var technology_ids: PackedStringArray = technology_catalog.get(
		"technology_ids", PackedStringArray())
	var out := {
		"era_reward_pool_ids": PackedStringArray(),
		"era_reward_pool_titles": PackedStringArray(),
		"era_reward_trigger_technology_indices": PackedInt32Array(),
		"era_reward_pool_final": PackedByteArray(),
		"era_reward_option_offsets": PackedInt32Array([0]),
		"era_reward_option_ids": PackedStringArray(),
		"era_reward_option_titles": PackedStringArray(),
		"era_reward_option_descriptions": PackedStringArray(),
		"era_reward_option_icons": PackedStringArray(),
		"era_reward_option_weights": PackedInt32Array(),
		"era_reward_option_fallback": PackedByteArray(),
		"era_reward_option_eligibility_codes": PackedInt32Array(),
		"era_reward_option_eligibility_thresholds": PackedInt64Array(),
		"era_reward_rule_offsets": PackedInt32Array([0]),
		"era_reward_rule_codes": PackedInt32Array(),
		"era_reward_rule_thresholds": PackedInt64Array(),
		"era_reward_rule_multipliers_q16": PackedInt32Array(),
		"era_reward_rule_reasons": PackedStringArray(),
		"era_reward_rule_signal_indices": PackedInt32Array(),
		"era_reward_rule_route_technology_offsets": PackedInt32Array([0]),
		"era_reward_rule_route_technology_indices": PackedInt32Array(),
		"era_reward_command_offsets": PackedInt32Array([0]),
		"era_reward_command_definition_keys": PackedStringArray(),
		"era_reward_command_effect_keys": PackedStringArray(),
		"era_reward_selector_entity_types": PackedInt32Array(),
		"era_reward_selector_filter_codes": PackedInt32Array(),
		"era_reward_selector_rankings": PackedInt32Array(),
		"era_reward_selector_top_n": PackedInt32Array(),
		"era_reward_selector_minimum": PackedInt32Array(),
	}
	var pool_seen := {}
	var option_seen := {}
	if pools.size() != POOL_COUNT:
		return {"ok": false, "reason": "era_reward_pool_count_invalid"}
	for pool in pools:
		if pool == null or pool_seen.has(pool.stable_id) or pool.options.size() != OPTIONS_PER_POOL:
			return {"ok": false, "reason": "era_reward_pool_invalid"}
		pool_seen[pool.stable_id] = true
		var trigger := technology_ids.find(String(pool.trigger_technology_id))
		if trigger < 0:
			return {"ok": false, "reason": "era_reward_trigger_technology_missing"}
		out.era_reward_pool_ids.append(String(pool.stable_id))
		out.era_reward_pool_titles.append(pool.era_title)
		out.era_reward_trigger_technology_indices.append(trigger)
		out.era_reward_pool_final.append(1 if pool.final_pool else 0)
		var fallback_count := 0
		for option in pool.options:
			if option == null or option_seen.has(option.stable_id) or option.commands.is_empty():
				return {"ok": false, "reason": "era_reward_option_invalid"}
			option_seen[option.stable_id] = true
			fallback_count += 1 if option.fallback else 0
			if option.fallback and option.eligibility_code != Eligibility.ALWAYS:
				return {"ok": false, "reason": "era_reward_fallback_conditional"}
			out.era_reward_option_ids.append(String(option.stable_id))
			out.era_reward_option_titles.append(option.title)
			out.era_reward_option_descriptions.append(option.description)
			out.era_reward_option_icons.append(String(option.icon_id))
			out.era_reward_option_weights.append(option.base_weight)
			out.era_reward_option_fallback.append(1 if option.fallback else 0)
			out.era_reward_option_eligibility_codes.append(option.eligibility_code)
			out.era_reward_option_eligibility_thresholds.append(option.eligibility_threshold)
			for rule in option.weight_rules:
				if rule == null or rule.multiplier_q16 <= 0:
					return {"ok": false, "reason": "era_reward_weight_rule_invalid"}
				out.era_reward_rule_codes.append(rule.condition_code)
				out.era_reward_rule_thresholds.append(rule.threshold)
				out.era_reward_rule_multipliers_q16.append(rule.multiplier_q16)
				out.era_reward_rule_reasons.append(rule.reason)
				var signal_index := -1
				if not String(rule.signal_id).is_empty():
					signal_index = (technology_catalog.get(
						"research_signal_ids", PackedStringArray()) as PackedStringArray).find(
							String(rule.signal_id))
					if signal_index < 0:
						return {"ok": false, "reason": "era_reward_signal_rule_unknown",
							"signal_id": String(rule.signal_id)}
				out.era_reward_rule_signal_indices.append(signal_index)
				var route_prefix := String(rule.route_tag_prefix)
				var route_matches := 0
				if not route_prefix.is_empty():
					var route_offsets: PackedInt32Array = technology_catalog.get(
						"technology_route_tag_offsets", PackedInt32Array())
					var route_tags: PackedStringArray = technology_catalog.get(
						"technology_route_tags", PackedStringArray())
					for technology_index in range(technology_ids.size()):
						for route_index in range(route_offsets[technology_index],
								route_offsets[technology_index + 1]):
							if String(route_tags[route_index]).begins_with(route_prefix):
								out.era_reward_rule_route_technology_indices.append(
									technology_index)
								route_matches += 1
								break
					if route_matches == 0:
						return {"ok": false, "reason": "era_reward_route_rule_unknown",
							"route_tag_prefix": route_prefix}
				out.era_reward_rule_route_technology_offsets.append(
					out.era_reward_rule_route_technology_indices.size())
			out.era_reward_rule_offsets.append(out.era_reward_rule_codes.size())
			var expanded_bound := 0
			for template in option.commands:
				if template == null or template.command == null or template.target_selector == null:
					return {"ok": false, "reason": "era_reward_command_template_invalid"}
				if not _command_whitelisted(template.command):
					return {"ok": false, "reason": "era_reward_command_not_whitelisted"}
				var selector = template.target_selector
				if selector.top_n < 1 or selector.top_n > MAX_TARGETS \
						or selector.minimum_targets < 1 or selector.minimum_targets > selector.top_n:
					return {"ok": false, "reason": "era_reward_selector_bound_invalid"}
				if selector.entity_type < SelectorScript.EntityType.COUNTRY \
						or selector.entity_type > SelectorScript.EntityType.PERSON \
						or selector.ranking < SelectorScript.Ranking.STABLE_HANDLE_ASC \
						or selector.ranking > SelectorScript.Ranking.PRESTIGE_DESC:
					return {"ok": false, "reason": "era_reward_selector_kind_invalid"}
				if option.fallback and (selector.entity_type != \
						SelectorScript.EntityType.COUNTRY or selector.top_n != 1):
					return {"ok": false, "reason": "era_reward_fallback_target_invalid"}
				expanded_bound += selector.top_n
				out.era_reward_command_definition_keys.append(
					String(template.command.definition_key))
				out.era_reward_command_effect_keys.append(
					"%s.effect" % String(option.stable_id))
				out.era_reward_selector_entity_types.append(selector.entity_type)
				out.era_reward_selector_filter_codes.append(selector.filter_code)
				out.era_reward_selector_rankings.append(selector.ranking)
				out.era_reward_selector_top_n.append(selector.top_n)
				out.era_reward_selector_minimum.append(selector.minimum_targets)
			if expanded_bound > MAX_COMMANDS_PER_OPTION:
				return {"ok": false, "reason": "era_reward_option_command_limit_exceeded"}
			out.era_reward_command_offsets.append(out.era_reward_command_definition_keys.size())
		if fallback_count != FALLBACKS_PER_POOL:
			return {"ok": false, "reason": "era_reward_fallback_count_invalid"}
		out.era_reward_option_offsets.append(out.era_reward_option_ids.size())
	out["ok"] = true
	return out

static func _command_whitelisted(command: Resource) -> bool:
	# Reward content has a narrower surface than the general Effect catalog.
	# Country grants must still follow Country's normal pending activation path;
	# arbitrary country mutation, reveal and policy opcodes never compile here.
	if command.action == 1:
		return command.domain >= 0 and command.domain <= 3 \
			and command.opcode in [1, 2]
	if command.action == 2:
		return command.domain == 1 and command.opcode == 4
	if command.action == 3:
		return command.domain == 2 and command.opcode in [1, 2, 3, 4, 5, 6, 7, 8]
	if command.action in [4, 5]:
		return command.opcode > 0
	return false
