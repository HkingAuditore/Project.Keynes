class_name ModifierCatalog
extends Resource

const Presentation = preload("res://scripts/modifier/modifier_catalog_presentation.gd")

const DisplayNames = preload("res://scripts/modifier/modifier_display_names.gd")

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

const StatTables = preload("res://scripts/modifier/modifier_catalog_stat_tables.gd")
const TECHNOLOGY_STATS = StatTables.TECHNOLOGY_STATS
const MILITARY_CELL_STATS = StatTables.MILITARY_CELL_STATS

const Q16_ONE = Presentation.Q16_ONE
const STAT_DISPLAY_NAMES = Presentation.STAT_DISPLAY_NAMES
const IDEOLOGY_PLAIN_STAT_NAMES = Presentation.IDEOLOGY_PLAIN_STAT_NAMES
const UNIT_FACTOR = Presentation.UNIT_FACTOR
const UNIT_RATE_BP = Presentation.UNIT_RATE_BP
const UNIT_POINTS = Presentation.UNIT_POINTS
const SECTOR_DISPLAY_NAMES = Presentation.SECTOR_DISPLAY_NAMES
const HAZARD_DISPLAY_NAMES = Presentation.HAZARD_DISPLAY_NAMES
const PRODUCTION_CLIMATE_PROFILE_DISPLAY_NAMES = Presentation.PRODUCTION_CLIMATE_PROFILE_DISPLAY_NAMES

@export var stats: Array[Resource] = []
@export var definitions: Array[Resource] = []


static func load_default() -> Resource:
	return ResourceLoader.load(DEFAULT_PATH, "Resource")


func compile_native_catalog() -> Dictionary:
	return _compile_native_catalog.call(null)

func compile_native_catalog_cooperative(context) -> Dictionary:
	return await context.dictionary("modifier", [self], _compile_native_catalog, [])

func _compile_native_catalog(context) -> Dictionary:
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
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
	for row in MILITARY_CELL_STATS:
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		var cell_key := StringName(row[0])
		if stat_ids.has(cell_key):
			return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
		stat_ids[cell_key] = out.stat_keys.size()
		out.stat_keys.append(String(cell_key))
		# Domain 2 is ECONOMY, which is where every per-cell Modifier lives:
		# `effective_value` keys the derived cell layer on
		# `(domain == ECONOMY, group_handle == cell)`, so a cell stat declared in
		# any other domain could never be merged with a card's per-cell row.
		out.stat_domains.append(2)
		out.stat_min_values.append(float(row[1]))
		out.stat_max_values.append(float(row[2]))
		out.stat_persistable.append(1)
		stat_domains_by_id.append(2)
		stat_allowed_operations_by_id.append(15)
	for row in TECHNOLOGY_STATS:
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		var key := StringName(row[0])
		if stat_ids.has(key):
			# [dup-stat-skip 2026-11-02] 军事 v1 的 stat 同时在
			# data/modifiers/default_modifier_catalog.tres（资源目录）和
			# TECHNOLOGY_STATS 里登记了。资源目录先编译，这里再遇到同名 key
			# 以前直接 `modifier_stat_key_invalid_or_duplicate` → 整个修改器目录
			# 编译失败 → country 配置被跳过 → 经济日结被拒（真机 eco_day 恒 -1）。
			# 资源目录是权威定义，重复行按跳过处理并打一行提示。
			print("[modifier] skip duplicate tech stat (resource catalog wins): %s" % String(key))
			continue
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
	var economy: Dictionary = EconomyCatalogScript.compile_native_catalog() if context == null \
		else await EconomyCatalogScript.compile_native_catalog_cooperative(context)
	if not bool(economy.get("ok", false)):
		return economy
	# Production-profile climate adaptation stats are catalog-derived. Their dense
	# IDs are resolved once by NativeEconomyRuntime and frozen into the epoch cache;
	# production hot loops never construct or look up these string keys.
	var climate_hazards := PackedStringArray([
		"drought", "flood", "cold_stress", "heat_stress",
	])
	for profile_id in economy.get("production_climate_profile_ids", PackedStringArray()):
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
	# Per-political-class satisfaction bias: ADD only (1), folded into each
	# profession of that class (and unemployed cohorts for `general`) at epoch freeze.
	var political_class_ids: Array[String] = []
	for value in economy.get("profession_class_ids", PackedStringArray()):
		var class_id := String(value).strip_edges()
		if class_id.is_empty():
			class_id = "general"
		if not political_class_ids.has(class_id):
			political_class_ids.append(class_id)
	if not political_class_ids.has("general"):
		political_class_ids.append("general")
	political_class_ids.sort()
	for class_id in political_class_ids:
		var class_satisfaction_key := StringName(
			"economy.class.%s.satisfaction_bp" % class_id)
		if stat_ids.has(class_satisfaction_key):
			return {"ok": false, "reason": "modifier_stat_key_invalid_or_duplicate"}
		stat_ids[class_satisfaction_key] = out.stat_keys.size()
		out.stat_keys.append(String(class_satisfaction_key))
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
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
				return {"ok": false, "reason": "modifier_term_invalid: key=%s known=%s value=%s" % [
					String(term.stat_key) if term != null else "<null>",
					str(stat_ids.has(term.stat_key)) if term != null else "n/a",
					str(term.value) if term != null else "n/a"]}
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
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		card_target_stats.append(
			"economy.city.good.%s.output_factor" % String(generated_good))
	for generated_building in economy.get("building_type_ids", PackedStringArray()):
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		card_target_stats.append(
			"economy.city.building.%s_output_factor" % String(generated_building))
	for generated_need in economy.need_ids:
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		card_target_stats.append(
			"economy.city.need.%s.consumption_factor" % String(generated_need))
	card_target_stats.append("economy.city.birth_factor")
	for generated_key in card_target_stats:
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
				return {"ok": false, "reason": "modifier_term_invalid: tech_term key=%s" % String(stat_key)}
			out.term_stat_ids.append(int(stat_ids[stat_key]))
			out.term_operations.append(int(technology_term_operations[term_index]))
			out.term_values.append(float(technology_term_values[term_index]))
		out.definition_term_offsets.append(out.term_values.size())
	# Era rewards are ordinary permanent country modifiers with UNIQUE_SOURCE.
	# This keeps percentage effects on the same frozen-factor consumers as
	# technologies and prevents a reward path from mutating economic ledgers.
	for era_index in EraRewardCatalogScript.ERA_SPECS.size():
		if context != null:
			await context.checkpoint("modifier")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
					return {"ok": false, "reason": "modifier_term_invalid: era_reward key=%s option=%s" % [
						String(reward_stat_key), String(option_id)]}
				out.term_stat_ids.append(int(stat_ids[reward_stat_key]))
				out.term_operations.append(int(term.operation))
				out.term_values.append(float(term.value))
			out.definition_term_offsets.append(out.term_values.size())
	out["ok"] = true
	return out


static func register_display_names(kind: StringName, names: Dictionary) -> void:
	Presentation.register_display_names(kind, names)


static func reset_display_names() -> void:
	Presentation.reset_display_names()


static func display_name_of(kind: StringName, stable_id: String) -> String:
	return Presentation.display_name_of(kind, stable_id)


static func _terrain_display_name(stable_id: String) -> String:
	return Presentation._terrain_display_name(stable_id)


static func _landform_display_name(stable_id: String) -> String:
	return Presentation._landform_display_name(stable_id)


static func _profession_display_name(stable_id: String) -> String:
	return Presentation._profession_display_name(stable_id)


static func present_stat_delta(stat_key: String, operation: int, value: float,
		magnitude_q16: int = Q16_ONE, plain_language: bool = false,
		label_override: String = "") -> String:
	return Presentation.present_stat_delta(stat_key, operation, value, magnitude_q16, plain_language, label_override)


func present_definition_for_ideology(definition_key: StringName,
		magnitude_q16: int = Q16_ONE) -> PackedStringArray:
	return Presentation.present_definition_for_ideology(definitions, definition_key, magnitude_q16)


func present_definition(definition_key: StringName,
		magnitude_q16: int = Q16_ONE) -> PackedStringArray:
	return Presentation.present_definition(definitions, definition_key, magnitude_q16)
