class_name ModifierCatalog
extends Resource

const DEFAULT_PATH := "res://data/modifiers/default_modifier_catalog.tres"
const StatDefinitionScript = preload("res://scripts/modifier/modifier_stat_definition.gd")
const DefinitionScript = preload("res://scripts/modifier/modifier_definition.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EraRewardCatalogScript = preload("res://scripts/effect/era_reward_catalog.gd")

const TECHNOLOGY_STATS := [
	["country.research.agriculture_efficiency", 0.0, 6.0],
	["country.research.engineering_efficiency", 0.0, 6.0],
	["country.research.science_efficiency", 0.0, 6.0],
	["country.research.society_efficiency", 0.0, 6.0],
	["country.research.cost_factor", 0.65, 4.0],
	["country.research.institution_output_factor", 0.0, 8.0],
	["country.output.agriculture_factor", 0.0, 8.0],
	["country.output.extractive_factor", 0.0, 8.0],
	["country.output.manufacturing_factor", 0.0, 8.0],
	["country.output.energy_factor", 0.0, 8.0],
	["country.output.knowledge_factor", 0.0, 8.0],
	["country.construction.cost_factor", 0.40, 4.0],
	["country.construction.time_factor", 0.40, 4.0],
	["country.trade.capacity_factor", 0.0, 8.0],
	["country.trade.speed_factor", 0.0, 8.0],
	["country.climate.drought_loss_factor", 0.20, 1.0],
	["country.climate.flood_loss_factor", 0.20, 1.0],
	["country.climate.cold_stress_factor", 0.20, 1.0],
	["country.climate.heat_stress_factor", 0.20, 1.0],
]

@export var stats: Array[Resource] = []
@export var definitions: Array[Resource] = []


static func load_default() -> Resource:
	return ResourceLoader.load(DEFAULT_PATH, "Resource")


func compile_native_catalog() -> Dictionary:
	var out := {
		"stat_keys": PackedStringArray(),
		"stat_domains": PackedInt32Array(),
		"stat_min_values": PackedFloat64Array(),
		"stat_max_values": PackedFloat64Array(),
		"stat_persistable": PackedByteArray(),
		"definition_keys": PackedStringArray(),
		"definition_versions": PackedInt32Array(),
		"definition_domains": PackedInt32Array(),
		"definition_policies": PackedInt32Array(),
		"definition_max_stacks": PackedInt32Array(),
		"definition_default_duration": PackedInt32Array(),
		"definition_term_offsets": PackedInt32Array([0]),
		"term_stat_ids": PackedInt32Array(),
		"term_operations": PackedInt32Array(),
		"term_values": PackedFloat64Array(),
	}
	var stat_ids := {}
	var stat_domains_by_id := PackedInt32Array()
	var stat_allowed_operations_by_id := PackedInt32Array()
	for stat in stats:
		if stat == null or stat.key == &"" or stat_ids.has(stat.key):
			return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
		if not is_finite(stat.min_value) or not is_finite(stat.max_value) \
				or stat.min_value > stat.max_value:
			return {"ok": false, "reason": "modifier_stat_range_invalid"}
		stat_ids[stat.key] = out.stat_keys.size()
		out.stat_keys.append(String(stat.key))
		out.stat_domains.append(stat.domain)
		out.stat_min_values.append(stat.min_value)
		out.stat_max_values.append(stat.max_value)
		out.stat_persistable.append(1 if stat.persistable else 0)
		stat_domains_by_id.append(stat.domain)
		stat_allowed_operations_by_id.append(stat.allowed_operations)
	for row in TECHNOLOGY_STATS:
		var key := StringName(row[0])
		if stat_ids.has(key):
			return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
		stat_ids[key] = out.stat_keys.size()
		out.stat_keys.append(String(key))
		out.stat_domains.append(1)
		out.stat_min_values.append(float(row[1]))
		out.stat_max_values.append(float(row[2]))
		out.stat_persistable.append(1)
		stat_domains_by_id.append(1)
		stat_allowed_operations_by_id.append(15)
	var economy: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(economy.get("ok", false)):
		return economy
	# Selector-addressable city stats are generated from stable economy IDs at
	# the cold catalog boundary. Runtime consumers resolve them to dense IDs and
	# only read frozen POD factors in hot loops.
	var economy_factor_groups := [
		["economy.city.need.%s.consumption_factor", economy.need_ids],
		["economy.city.good.%s.consumption_factor", economy.good_ids],
		["economy.city.resource.%s.regen_factor",
			economy.get("building_resource_ids", PackedStringArray())],
	]
	for group in economy_factor_groups:
		for item_id in group[1]:
			var factor_key := StringName(String(group[0]) % String(item_id))
			if stat_ids.has(factor_key):
				return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
			stat_ids[factor_key] = out.stat_keys.size()
			out.stat_keys.append(String(factor_key))
			out.stat_domains.append(2)
			out.stat_min_values.append(0.0)
			out.stat_max_values.append(4.0)
			out.stat_persistable.append(1)
			stat_domains_by_id.append(2)
			stat_allowed_operations_by_id.append(15)
	var family_ids: PackedStringArray = economy.get(
		"building_upgrade_family_ids", PackedStringArray())
	for family_id in family_ids:
		var family_key := StringName("country.output.family.%s_factor" % String(family_id))
		if stat_ids.has(family_key):
			return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
		stat_ids[family_key] = out.stat_keys.size()
		out.stat_keys.append(String(family_key))
		out.stat_domains.append(1)
		out.stat_min_values.append(0.0)
		out.stat_max_values.append(8.0)
		out.stat_persistable.append(1)
		stat_domains_by_id.append(1)
		stat_allowed_operations_by_id.append(15)
	for building_id in economy.get("building_type_ids", PackedStringArray()):
		var building_key := StringName(
			"country.output.building.%s_factor" % String(building_id))
		if stat_ids.has(building_key):
			return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
		stat_ids[building_key] = out.stat_keys.size()
		out.stat_keys.append(String(building_key))
		out.stat_domains.append(1)
		out.stat_min_values.append(0.0)
		out.stat_max_values.append(8.0)
		out.stat_persistable.append(1)
		stat_domains_by_id.append(1)
		stat_allowed_operations_by_id.append(15)
	var tax_stat_groups := [
		["income", economy.profession_ids],
		["consumption", economy.good_ids],
		["business", economy.building_type_ids],
		["import", economy.good_ids],
		["export", economy.good_ids],
	]
	for group in tax_stat_groups:
		for item_id in group[1]:
			var tax_key := StringName("country.tax.%s.%s.rate_pct" % [
				String(group[0]), String(item_id)])
			if stat_ids.has(tax_key):
				return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
			stat_ids[tax_key] = out.stat_keys.size()
			out.stat_keys.append(String(tax_key))
			out.stat_domains.append(1)
			out.stat_min_values.append(-100.0)
			out.stat_max_values.append(100.0)
			out.stat_persistable.append(1)
			stat_domains_by_id.append(1)
			stat_allowed_operations_by_id.append(15)
	var definition_keys := {}
	for definition in definitions:
		if definition == null or definition.key == &"" \
				or definition_keys.has(definition.key) or definition.version <= 0 \
				or definition.max_stacks <= 0 or definition.terms.is_empty():
			return {"ok": false, "reason": "modifier_definition_invalid_or_duplicate"}
		if definition.default_duration_days != -1 and definition.default_duration_days <= 0:
			return {"ok": false, "reason": "modifier_definition_duration_invalid"}
		definition_keys[definition.key] = true
		out.definition_keys.append(String(definition.key))
		out.definition_versions.append(definition.version)
		out.definition_domains.append(definition.domain)
		out.definition_policies.append(definition.stack_policy)
		out.definition_max_stacks.append(definition.max_stacks)
		out.definition_default_duration.append(definition.default_duration_days)
		for term in definition.terms:
			if term == null or not stat_ids.has(term.stat_key) or not is_finite(term.value):
				return {"ok": false, "reason": "modifier_term_invalid"}
			var term_stat_id := int(stat_ids[term.stat_key])
			if stat_domains_by_id[term_stat_id] != definition.domain \
					or (stat_allowed_operations_by_id[term_stat_id] \
					& (1 << term.operation)) == 0:
				return {"ok": false, "reason": "modifier_term_domain_or_operation_invalid"}
			if term.operation == 3 and term.value == 0.0:
				return {"ok": false, "reason": "modifier_term_division_by_zero"}
			out.term_stat_ids.append(int(stat_ids[term.stat_key]))
			out.term_operations.append(term.operation)
			out.term_values.append(term.value)
		out.definition_term_offsets.append(out.term_values.size())
	var technologies: Dictionary = TechnologyCatalogScript.compile_native_catalog()
	if not bool(technologies.get("ok", false)):
		return technologies
	var technology_term_offsets: PackedInt32Array = \
		technologies.technology_modifier_term_offsets
	var technology_term_keys: PackedStringArray = \
		technologies.technology_modifier_term_stat_keys
	var technology_term_operations: PackedInt32Array = \
		technologies.technology_modifier_term_operations
	var technology_term_values: PackedFloat64Array = \
		technologies.technology_modifier_term_values
	for i in range(technologies.technology_ids.size()):
		if (int(technologies.technology_flags[i]) & TechnologyCatalogScript.FLAG_STARTING) != 0:
			continue
		var definition_key := String(technologies.technology_modifier_definition_keys[i])
		# Unlock-only technologies intentionally have no Modifier definition. Their
		# adoption still runs through EffectRuntime and the country ACK boundary.
		if definition_key.is_empty():
			continue
		if definition_keys.has(definition_key):
			return {"ok": false, "reason": "modifier_definition_invalid_or_duplicate"}
		definition_keys[definition_key] = true
		out.definition_keys.append(definition_key)
		out.definition_versions.append(1)
		out.definition_domains.append(1)
		out.definition_policies.append(1)
		out.definition_max_stacks.append(1)
		out.definition_default_duration.append(-1)
		for term_index in range(technology_term_offsets[i], technology_term_offsets[i + 1]):
			var stat_key := StringName(technology_term_keys[term_index])
			if not stat_ids.has(stat_key):
				return {"ok": false, "reason": "modifier_term_invalid"}
			out.term_stat_ids.append(int(stat_ids[stat_key]))
			out.term_operations.append(int(technology_term_operations[term_index]))
			out.term_values.append(float(technology_term_values[term_index]))
		out.definition_term_offsets.append(out.term_values.size())
	# Era rewards are ordinary permanent country modifiers with UNIQUE_SOURCE.
	# This keeps percentage effects on the same frozen-factor consumers as
	# technologies and prevents a reward path from mutating economic ledgers.
	for era_index in EraRewardCatalogScript.ERA_SPECS.size():
		for theme_index in EraRewardCatalogScript.THEMES.size():
			var option_id := StringName("era_reward.%s.%s" % [
				String(EraRewardCatalogScript.ERA_SPECS[era_index][0]),
				String(EraRewardCatalogScript.THEMES[theme_index][0])])
			var reward_definition_key := String(
				EraRewardCatalogScript.modifier_definition_key(option_id))
			if definition_keys.has(reward_definition_key):
				return {"ok": false, "reason": "modifier_definition_invalid_or_duplicate"}
			definition_keys[reward_definition_key] = true
			out.definition_keys.append(reward_definition_key)
			out.definition_versions.append(1)
			out.definition_domains.append(1)
			out.definition_policies.append(1)
			out.definition_max_stacks.append(1)
			out.definition_default_duration.append(-1)
			for term in EraRewardCatalogScript.modifier_terms_for_option(
					era_index, theme_index):
				var reward_stat_key := StringName(term.stat)
				if not stat_ids.has(reward_stat_key):
					return {"ok": false, "reason": "modifier_term_invalid"}
				out.term_stat_ids.append(int(stat_ids[reward_stat_key]))
				out.term_operations.append(int(term.operation))
				out.term_values.append(float(term.value))
			out.definition_term_offsets.append(out.term_values.size())
	out["ok"] = true
	return out
