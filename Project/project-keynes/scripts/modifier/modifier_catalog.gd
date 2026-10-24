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
const GoodProfileRegistryScript = preload("res://scripts/data/good_profile_registry.gd")
const ResourceProfileRegistryScript = preload(
	"res://scripts/data/resource_profile_registry.gd")

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
	# X6-a: per-term point multipliers. Same epoch freeze path as point_gain,
	# but each applies to exactly one ledger term and clamps to [0.5, 3.0].
	["country.ideology.point_population_factor", 0.5, 3.0],
	["country.ideology.point_building_factor", 0.5, 3.0],
	["country.ideology.point_trade_factor", 0.5, 3.0],
	# social_media: base floor under the opinion factor. ADD-only, so the card's
	# -0.1 is a point offset instead of a multiplier on 0.5.
	["country.ideology.opinion_factor_floor", 0.3, 0.5],
	# Global school-strength multipliers frozen into the Ideology POD. One
	# explicit stat per school keeps Modifier POD buckets keyed by stat id
	# instead of introducing a sub-key dimension no consumer reads today.
	["country.ideology.school_strength_factor.agrarian", 0.5, 2.0],
	["country.ideology.school_strength_factor.commerce", 0.5, 2.0],
	["country.ideology.school_strength_factor.learning", 0.5, 2.0],
	["country.ideology.school_strength_factor.mobilization", 0.5, 2.0],
	["country.ideology.school_strength_factor.industry", 0.5, 2.0],
	["country.ideology.school_strength_factor.harmony", 0.5, 2.0],
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
}
## Ideology cards have their own audience-facing wording. Keep this map separate
## from the shared stat labels so other panels keep their established terms.
const IDEOLOGY_PLAIN_STAT_NAMES := {
	"country.output.agriculture_factor": "农业产出",
	"country.output.extractive_factor": "采掘产出",
	"country.output.manufacturing_factor": "制造业产出",
	"country.output.energy_factor": "能源产出",
	"country.output.knowledge_factor": "知识产出",
	"country.research.agriculture_efficiency": "农业研究速度",
	"country.research.engineering_efficiency": "工程研究速度",
	"country.research.science_efficiency": "科学研究速度",
	"country.research.society_efficiency": "社会研究速度",
	"country.research.institution_output_factor": "研究机构产出",
	"country.production.input_factor": "生产所需原料",
	"country.household.consumption_factor": "家庭消费需求",
	"country.resource.use_factor": "自然资源消耗",
	"country.trade.capacity_factor": "每次贸易可成交的货物量",
	"country.trade.speed_factor": "贸易运输速度",
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
		# social_media authors a negative ADD point offset; every other ideology
		# scalar remains a general multiplicative factor.
		stat_allowed_operations_by_id.append(
			1 if key == &"country.ideology.opinion_factor_floor" else 15)
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
	# R-4 X16: per-profession tax tolerance and satisfaction bias.
	#
	# `tax_tolerance_factor` scales how much tax burden a profession tolerates before
	# its satisfaction tax dimension starts falling; MULTIPLY only (4), because an
	# "additive tolerance" has no meaning (the reader multiplies a Q16 factor).
	# `satisfaction_bp` is a basis-point offset on the cohort's composite satisfaction;
	# ADD only (1), because summing offsets is the whole model.
	#
	# The bit values are spelled out rather than 15: allowing all four operations here
	# would let a card SUBTRACT a tolerance into a negative factor, which the reader
	# clamps but which would silently mean the opposite of what the card says.
	for profession_id in economy.profession_ids:
		var tolerance_key := StringName(
			"economy.profession.%s.tax_tolerance_factor" % String(profession_id))
		if stat_ids.has(tolerance_key):
			return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
		stat_ids[tolerance_key] = out.stat_keys.size()
		out.stat_keys.append(String(tolerance_key))
		out.stat_domains.append(1)
		out.stat_min_values.append(0.5)
		out.stat_max_values.append(3.0)
		out.stat_persistable.append(1)
		stat_domains_by_id.append(1)
		stat_allowed_operations_by_id.append(4)
		var satisfaction_key := StringName(
			"economy.profession.%s.satisfaction_bp" % String(profession_id))
		if stat_ids.has(satisfaction_key):
			return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
		stat_ids[satisfaction_key] = out.stat_keys.size()
		out.stat_keys.append(String(satisfaction_key))
		out.stat_domains.append(1)
		out.stat_min_values.append(-2500.0)
		out.stat_max_values.append(2500.0)
		out.stat_persistable.append(1)
		stat_domains_by_id.append(1)
		stat_allowed_operations_by_id.append(1)
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
			# P2-D: a cell-scope stat can only be summed. MaxSource/TopNSources
			# keep ONE contributing row and drop the rest, so a card authored to
			# lift every settlement would reach exactly one of them -- and the
			# loss is invisible, because the surviving row still reads correct.
			if policy != 0:
				var scope_key := String(out.stat_keys[index])
				if scope_key.begins_with("city.") \
						or scope_key.begins_with("economy.city."):
					return {"ok": false,
						"reason": "modifier_city_stat_requires_sum:" + scope_key}
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
	# P3 / option 1: one definition per per-good output stat, so a card can name
	# "this good's output here" instead of the aggregate factor. Without these a
	# cell card can only ever write `economy.city.output_factor`, which the
	# per-cell read path does not consult -- the coefficient plane would produce
	# entries nothing reads.
	#
	# Default value 1.0 (a no-op multiply): the real magnitude rides on the
	# command's `value_q16`, exactly like every authored definition.
	# Which city stats a CARD may target. The criterion is "does gdext read this
	# stat per cell", not "is it registered": `_city_resource_regen_stat_ids` and
	# the aggregate `economy.city.output_factor` have zero read sites, so a card
	# aimed at them would compile, store a row, and change nothing. They are
	# deliberately absent, and `IDEOLOGY_CITY_DEAD_STATS` in the generator names
	# them so the gap stays visible instead of looking like an oversight.
	var card_target_stats := PackedStringArray()
	for generated_good in economy.good_ids:
		card_target_stats.append(
			"economy.city.good.%s.output_factor" % String(generated_good))
	for generated_building in economy.get("building_type_ids", PackedStringArray()):
		card_target_stats.append(
			"economy.city.building.%s_output_factor" % String(generated_building))
	for generated_need in economy.need_ids:
		card_target_stats.append(
			"economy.city.need.%s.consumption_factor" % String(generated_need))
	card_target_stats.append("economy.city.birth_factor")
	for generated_key in card_target_stats:
		if not stat_ids.has(generated_key):
			continue
		if definition_keys.has(generated_key):
			return {"ok": false, "reason": "modifier_definition_invalid_or_duplicate"}
		definition_keys[generated_key] = true
		out.definition_keys.append(generated_key)
		out.definition_versions.append(1)
		out.definition_domains.append(2)
		# UNIQUE_SOURCE matches the other per-city definitions: one row per
		# (source, cell) so two cards on the same cell stack instead of
		# replacing each other.
		out.definition_policies.append(1)
		out.definition_max_stacks.append(1)
		out.definition_default_duration.append(-1)
		out.term_stat_ids.append(int(stat_ids[generated_key]))
		# ADD 1.0, not MULTIPLY 1.0 -- and the difference is not cosmetic. The
		# command magnitude is the effect itself (+5% -> 0.05) for the whole
		# ideology city family, so an ADD term with value 1.0 makes
		# `magnitude x 1.0` land as a delta. A MULTIPLY term would read the same
		# 0.05 as "x0.05", i.e. a 95% cut.
		out.term_operations.append(0)
		out.term_values.append(1.0)
		out.definition_term_offsets.append(out.term_values.size())
		# The `.cut` twin. Modifier magnitudes are clamped to [0, 4] and cannot
		# carry a sign, so a debuff has to be a SUBTRACT term on a separate
		# definition -- the same shape the `ideology.city.*` family already uses.
		var cut_key := generated_key + ".cut"
		if definition_keys.has(cut_key):
			return {"ok": false, "reason": "modifier_definition_invalid_or_duplicate"}
		definition_keys[cut_key] = true
		out.definition_keys.append(cut_key)
		out.definition_versions.append(1)
		out.definition_domains.append(2)
		out.definition_policies.append(1)
		out.definition_max_stacks.append(1)
		out.definition_default_duration.append(-1)
		out.term_stat_ids.append(int(stat_ids[generated_key]))
		out.term_operations.append(1)
		out.term_values.append(1.0)
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
		# economy.profession.<profession_id>.<tax_tolerance_factor|satisfaction_bp>
		if parts[0] == "economy" and parts[1] == "profession":
			var profession_name := _profession_display_name(parts[2])
			match parts[3]:
				"tax_tolerance_factor":
					return {"label": "%s 税负容忍度" % profession_name,
						"unit": UNIT_FACTOR, "profession_id": parts[2],
						"profession_metric": "tax_tolerance"}
				"satisfaction_bp":
					return {"label": profession_name,
						"unit": UNIT_POINTS, "profession_id": parts[2],
						"profession_metric": "satisfaction"}
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
			label += " 税负容忍度"
	if unit == UNIT_RATE_BP and (operation == 0 or operation == 1):
		# Rate stats are authored in basis points, so additive terms never fit the
		# whole-percent formatting below (a 15 bp change would render as +0%).
		if absf(delta) < 0.5:
			return ""
		var rate_points := delta * 0.01
		if plain_language:
			var plain_label := label.replace(" 所得税率", "所得税率") \
				.replace(" 消费税", "消费税").replace(" 营业税率", "营业税率") \
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


const PROFESSION_DISPLAY_NAMES := {
	"agricultural_worker": "农业工人",
	"ai_researcher": "AI 研究员",
	"apprentice": "学徒",
	"artisan": "工匠",
	"chemist": "化学家",
	"construction_worker": "建筑工人",
	"cooperative_member": "合作社成员",
	"corvee_worker": "徭役劳动者",
	"data_scientist": "数据科学家",
	"electrician": "电工",
	"engineer": "工程师",
	"enslaved_laborer": "奴隶劳工",
	"fisher": "渔民",
	"forager": "采集者",
	"forestry_worker": "林业工人",
	"guild_master": "行会师傅",
	"household_farmer": "家庭小农",
	"hunter": "猎人",
	"indentured_laborer": "契约劳工",
	"industrial_worker": "产业工人",
	"industrialist": "工业资本家",
	"journeyman": "熟练工",
	"landlord": "地主",
	"lorekeeper": "传知者",
	"machinist": "机械师",
	"manager": "经理",
	"merchant": "商人",
	"metallurgist": "冶金师",
	"miner": "矿工",
	"natural_philosopher": "自然哲学家",
	"pastoralist": "牧民",
	"petroleum_worker": "石油工人",
	"research_scientist": "研究科学家",
	"researcher": "研究员",
	"scholar": "学者",
	"scientist": "科学家",
	"scribe": "书记员",
	"serf": "农奴",
	"sharecropper": "分成佃农",
	"subsistence_farmer": "自给农民",
	"technician": "技术员",
	"tenant_farmer": "佃农",
	"transport_worker": "运输工人",
	"unemployed": "失业者",
	"worker": "工人",
}


static func _profession_display_name(stable_id: String) -> String:
	var registered := display_name_of(&"profession", stable_id)
	if registered != stable_id:
		return registered
	return String(PROFESSION_DISPLAY_NAMES.get(stable_id, stable_id))


static func _format_decimal(value: float) -> String:
	var text := "%.2f" % value
	text = text.trim_suffix("0").trim_suffix("0").trim_suffix(".")
	return text


func present_definition_for_ideology(definition_key: StringName,
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
				var split := sample_label.find("对税负")
				if split >= 0:
					lines.append("全国各职业%s" % sample_label.substr(split))
				else:
					var satisfaction := sample_label.rfind("满意度")
					lines.append("全国各职业%s" % sample_label.substr(
						satisfaction if satisfaction >= 0 else 0))
			else:
				var split := sample_label.find("对税负")
				if split < 0:
					split = sample_label.rfind("满意度")
				lines.append("%s%s" % ["、".join(names),
					sample_label.substr(split if split >= 0 else 0)])
		break
	return lines


static func _profession_id_for_display_name(display_name: String) -> String:
	for stable_id in PROFESSION_DISPLAY_NAMES:
		if String(PROFESSION_DISPLAY_NAMES[stable_id]) == display_name:
			return String(stable_id)
	return display_name


static func _known_profession_count() -> int:
	return PROFESSION_DISPLAY_NAMES.size()


func present_definition(definition_key: StringName,
		magnitude_q16: int = Q16_ONE) -> PackedStringArray:
	if String(definition_key).begins_with("ideology."):
		return present_definition_for_ideology(definition_key, magnitude_q16)
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
