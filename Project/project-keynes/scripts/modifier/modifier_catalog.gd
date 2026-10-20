class_name ModifierCatalog
extends Resource

const DEFAULT_PATH := "res://data/modifiers/default_modifier_catalog.tres"
const StatDefinitionScript = preload("res://scripts/modifier/modifier_stat_definition.gd")
const DefinitionScript = preload("res://scripts/modifier/modifier_definition.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EraRewardCatalogScript = preload("res://scripts/effect/era_reward_catalog.gd")
const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")
const LandformTypeScript = preload("res://scripts/geography/landform_type.gd")

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
	["country.production.input_factor", 0.40, 4.0],
	["country.household.consumption_factor", 0.40, 4.0],
	["country.resource.use_factor", 0.40, 4.0],
	["country.population.death_factor", 0.3333, 4.0],
	["country.construction.cost_factor", 0.40, 4.0],
	["country.construction.time_factor", 0.40, 4.0],
	["country.trade.capacity_factor", 0.0, 8.0],
	["country.trade.speed_factor", 0.0, 8.0],
	["country.climate.drought_loss_factor", 0.20, 1.0],
	["country.climate.flood_loss_factor", 0.20, 1.0],
	["country.climate.cold_stress_factor", 0.20, 1.0],
	["country.climate.heat_stress_factor", 0.20, 1.0],
	# Frozen by the Country epoch snapshot; ideology accrual reads it read-only.
	["country.ideology.point_gain_factor", 0.0, 4.0],
	# Same freeze path, different consumption points. Appended rather than
	# grouped with the line above so the dense stat ids of everything already
	# declared do not move: ids are assigned in this order at every compile, and
	# a shipped save's modifier rows are keyed by definition, not by stat id, but
	# keeping the existing ids stable makes any diff of a compiled catalog readable.
	["country.ideology.understanding_gain_factor", 0.0, 4.0],
	["country.ideology.reroll_cost_factor", 0.0, 4.0],
	# Draw-side, and the only two ideology stats that are ADDITIVE rather than
	# multiplicative. `era_decay_floor_bp` is a floor under the era decay curve
	# (0 = no floor, 10000 = no decay at all); `offer_choice_bonus` adds rows to
	# the draw offer (0..2, because the native array caps at 5). Both read 0 when
	# absent, which is why they are ranged from 0 rather than from 1.
	["country.ideology.era_decay_floor_bp", 0.0, 10000.0],
	["country.ideology.offer_choice_bonus", 0.0, 2.0],
]
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
	"country.construction.cost_factor": "国家建设成本",
	"country.construction.time_factor": "国家建设耗时",
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
	"country.trade.capacity_factor": "国内贸易容量",
	"country.trade.speed_factor": "贸易速度",
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

static var _dimension_display_names: Dictionary = {}

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
		# L1-6: aggregation policy per stat. Emitted for every stat so the native
		# parser never has to special-case "the resource declared it but a
		# generated stat did not" -- generated stats are Sum, which is what the
		# column default says anyway.
		"stat_aggregate_policies": PackedInt32Array(),
		"stat_source_caps": PackedInt32Array(),
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
	# Production-profile climate adaptation stats are catalog-derived. Their dense
	# IDs are resolved once by NativeEconomyRuntime and frozen into the epoch cache;
	# production hot loops never construct or look up these string keys.
	var climate_hazards := PackedStringArray([
		"drought", "flood", "cold_stress", "heat_stress",
	])
	for profile_id in economy.get("production_climate_profile_ids", PackedStringArray()):
		for hazard in climate_hazards:
			var key := "country.climate.profile.%s.%s_loss_factor" % [profile_id, hazard]
			if stat_ids.has(key):
				return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
			stat_ids[key] = out.stat_keys.size()
			out.stat_keys.append(key)
			out.stat_domains.append(1)
			out.stat_min_values.append(0.20)
			out.stat_max_values.append(1.0)
			out.stat_persistable.append(1)
			stat_domains_by_id.append(1)
			stat_allowed_operations_by_id.append(15)
	# Selector-addressable city stats are generated from stable economy IDs at
	# the cold catalog boundary. Runtime consumers resolve them to dense IDs and
	# only read frozen POD factors in hot loops.
	var economy_factor_groups := [
		["economy.city.need.%s.consumption_factor", economy.need_ids, 4.0],
		["economy.city.good.%s.consumption_factor", economy.good_ids, 4.0],
		["economy.city.good.%s.output_factor", economy.good_ids, 16.0],
		["economy.city.building.%s.output_factor",
			economy.get("building_type_ids", PackedStringArray()), 16.0],
		["economy.city.resource.%s.regen_factor",
			economy.get("building_resource_ids", PackedStringArray()), 4.0],
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
			out.stat_max_values.append(float(group[2]))
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
	# Good factors target the physical product/input/household good instead of
	# whichever building family happens to handle it. All three sets are country
	# stats frozen to dense Q16 tables at the economy epoch boundary.
	for good_id in economy.good_ids:
		for pattern in [
			"country.output.good.%s_factor",
			"country.input.good.%s_factor",
			"country.consumption.good.%s_factor",
		]:
			var good_key := StringName(String(pattern) % String(good_id))
			if stat_ids.has(good_key):
				return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
			stat_ids[good_key] = out.stat_keys.size()
			out.stat_keys.append(String(good_key))
			out.stat_domains.append(1)
			out.stat_min_values.append(0.0)
			out.stat_max_values.append(8.0)
			out.stat_persistable.append(1)
			stat_domains_by_id.append(1)
			stat_allowed_operations_by_id.append(15)
	# Resource factors distinguish extraction/capacity efficiency from managed
	# regeneration created by production methods such as forestry or aquaculture.
	for resource_id in economy.get("building_resource_ids", PackedStringArray()):
		for pattern in [
			"country.resource.%s.use_factor",
			"country.resource.%s.managed_generation_factor",
		]:
			var resource_key := StringName(String(pattern) % String(resource_id))
			if stat_ids.has(resource_key):
				return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
			stat_ids[resource_key] = out.stat_keys.size()
			out.stat_keys.append(String(resource_key))
			out.stat_domains.append(1)
			out.stat_min_values.append(0.0)
			out.stat_max_values.append(8.0)
			out.stat_persistable.append(1)
			stat_domains_by_id.append(1)
			stat_allowed_operations_by_id.append(15)
	# Geography x sector effects are deliberately finite catalog products. Their
	# numeric order is shared with the native terrain/landform arrays.
	var sector_ids: PackedStringArray = economy.get(
		"modifier_sector_ids", PackedStringArray())
	for geography_group in [
		["landform", economy.get("modifier_landform_ids", PackedStringArray())],
		["terrain", economy.get("modifier_terrain_ids", PackedStringArray())],
	]:
		for geography_id in geography_group[1]:
			for sector_id in sector_ids:
				var geography_key := StringName("country.output.%s.%s.%s_factor" % [
					String(geography_group[0]), String(geography_id), String(sector_id)])
				if stat_ids.has(geography_key):
					return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
				stat_ids[geography_key] = out.stat_keys.size()
				out.stat_keys.append(String(geography_key))
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
			var tax_key := StringName("country.tax.%s.%s.rate_bp" % [
				String(group[0]), String(item_id)])
			if stat_ids.has(tax_key):
				return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
			stat_ids[tax_key] = out.stat_keys.size()
			out.stat_keys.append(String(tax_key))
			out.stat_domains.append(1)
			out.stat_min_values.append(-100000.0)
			out.stat_max_values.append(10000.0)
			out.stat_persistable.append(1)
			stat_domains_by_id.append(1)
			stat_allowed_operations_by_id.append(15)
	# Fill the two aggregate columns in one pass, at the end, in `stat_keys` order.
	# Doing it here instead of at the eight append sites is deliberate: a stat can
	# be declared by the resource, by a constant table, by an economy-derived loop
	# or by a tax loop, and one missed `append` would misalign the column against
	# `stat_keys` -- a silent off-by-one that only shows up as the wrong stat
	# taking the wrong policy.
	if out.stat_aggregate_policies.size() != out.stat_keys.size():
		out.stat_aggregate_policies = PackedInt32Array()
		out.stat_source_caps = PackedInt32Array()
		for index in out.stat_keys.size():
			var policy := 0
			var cap := 0
			for stat in stats:
				if stat != null and String(stat.key) == String(out.stat_keys[index]):
					policy = int(stat.aggregate_policy)
					cap = int(stat.source_cap)
					break
			out.stat_aggregate_policies.append(policy)
			out.stat_source_caps.append(cap)
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
	return String(bucket.get(stable_id, stable_id))


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
					return {"label": "%s 建筑系产出" % display_name_of(&"family", tail),
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
			return {"label": "%s %s损失" % [parts[3],
				String(HAZARD_DISPLAY_NAMES.get(hazard, hazard))], "unit": UNIT_FACTOR}
		# country.tax.<kind>.<stable_id>.rate_bp
		if parts[0] == "country" and parts[1] == "tax" and parts[4] == "rate_bp":
			var target := parts[3]
			var target_name := target
			match parts[2]:
				"income":
					target_name = display_name_of(&"profession", target)
					return {"label": "%s 所得税率" % target_name, "unit": UNIT_RATE_BP}
				"consumption":
					target_name = display_name_of(&"good", target)
					return {"label": "%s 消费税" % target_name, "unit": UNIT_RATE_BP}
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
						return {"label": "%s 需求消费" % display_name_of(&"need", city_id),
							"unit": UNIT_FACTOR}
				"resource":
					if parts[4] == "regen_factor":
						return {"label": "%s 城市再生" % display_name_of(&"resource", city_id),
							"unit": UNIT_FACTOR}
			return {}
	return {}


static func present_stat_delta(stat_key: String, operation: int, value: float,
		magnitude_q16: int = Q16_ONE) -> String:
	if not is_finite(value):
		return ""
	var label := String(STAT_DISPLAY_NAMES.get(stat_key, ""))
	var unit := UNIT_FACTOR
	if label.is_empty():
		var described := _describe_stat_key(stat_key)
		if described.is_empty():
			return ""
		label = String(described.get("label", ""))
		unit = int(described.get("unit", UNIT_FACTOR))
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
	if unit == UNIT_RATE_BP and (operation == 0 or operation == 1):
		# Rate stats are authored in basis points, so additive terms never fit the
		# whole-percent formatting below (a 15 bp change would render as +0%).
		if absf(delta) < 0.5:
			return ""
		return "%s %+.2f%%" % [label, delta * 0.01]
	var percent := int(round(delta * 100.0))
	if percent == 0:
		return ""
	return "%s %+d%%" % [label, percent]


func present_definition(definition_key: StringName,
		magnitude_q16: int = Q16_ONE) -> PackedStringArray:
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
