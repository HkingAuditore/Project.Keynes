class_name EffectDomainCatalog
extends RefCounted

const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const FamilyTraitCatalogScript = preload("res://scripts/family/family_trait_catalog.gd")
const FamilyEffectCatalogScript = preload("res://scripts/family/family_effect_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const IdeologyEffectCatalogScript = preload("res://scripts/ideology/ideology_effect_catalog.gd")
const IdeologyEffectDefinitionScript = preload("res://scripts/ideology/ideology_effect_definition.gd")
const IdeologyEffectParameterScript = preload(
	"res://scripts/ideology/ideology_effect_parameter.gd")
const IdeologySynergyDefinitionScript = preload(
	"res://scripts/ideology/ideology_synergy_definition.gd")
const EraRewardCatalogScript = preload("res://scripts/effect/era_reward_catalog.gd")
const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")
const TargetTagDictionaryScript = preload("res://scripts/effect/target_tag_dictionary.gd")

const Q16_ONE := 65536

## Ideology-local scalar ids appended after NativeEconomyRuntime's metric range.
## No constant here: PackedStringArray construction is not a GDScript constant
## expression. These are appended to the packaged `metric_keys` below.
const SCALAR_METRIC_KEYS := [
	"ideology.scalar.equipped_count",
	"ideology.scalar.route_count.clan",
	"ideology.scalar.route_count.cropland",
	"ideology.scalar.route_count.era",
	"ideology.scalar.route_count.fiscal",
	"ideology.scalar.route_count.granary",
	"ideology.scalar.route_count.labor",
	"ideology.scalar.route_count.learning",
	"ideology.scalar.route_count.livelihood",
	"ideology.scalar.route_count.market",
	"ideology.scalar.route_count.mining",
	"ideology.scalar.route_count.season",
	"ideology.scalar.route_count.terrain",
	"ideology.scalar.route_count.thoroughfare",
	"ideology.scalar.route_count.workshop",
	"ideology.scalar.active_synergy_count",
	"ideology.scalar.unlocked_era",
]

## Builds the shared Effect IR from existing authoritative domain catalogs.
## Domain catalogs remain the source of truth; this only creates executable
## programs and never duplicates domain state. Tests may inject a FamilyEffect
## catalog fixture; production callers omit the override and load the default.
## `ideology_effect_catalog_override` exists for the same reason and one more:
## the tag-name resolution (L5-14) only runs on authored cards, and there is no
## shipped card using it yet, so without an injection point the compiler path
## would be dead code that only the helper's unit test ever touches.
static func build(family_effect_catalog_override: Resource = null,
		ideology_effect_catalog_override: Resource = null) -> Resource:
	if family_effect_catalog_override == null \
			and ideology_effect_catalog_override == null:
		var precompiled := LoadingCatalogCache.effect_catalog()
		if precompiled != null:
			return precompiled
	var catalog: Resource = EffectCatalogScript.load_default()
	if catalog == null:
		catalog = EffectCatalogScript.new()
	# Metric zero remains the legacy family branch magnitude used by existing
	# Modifier programs. Additional typed metrics are reserved for declarative
	# FamilyEffect conditions and keep the same stable dense ordering.
	catalog.metric_keys = PackedStringArray([
		"family.magnitude_q16",
		"family.population",
		"family.cash_claim",
		"branch.prestige_q16",
		"branch.population",
		"cell.temperature_q16",
		"cell.precipitation_q16",
		"cell.resource_shortage_q16",
		"cell.trade_events",
		"cell.population",
		"cell.landform",
		"cell.essentials_shortage_q16",
		"branch.is_local_prestige_max",
		"cell.rain_event",
		"cell.resource_abundance_q16",
		"family.has_owned_manufacturing",
		"family.distinct_sector_count",
		"family.dominant_sector_id",
		"family.dominant_sector_share_q16",
		"family.complete_chain_count",
		"family.max_local_chain_share_q16",
		"family.max_chain_upgrade_family_id",
		"cell.unemployment_q16",
		"cell.resource_class_count",
		"cell.manufacturing_building_count",
		"cell.distinct_sector_count",
		"cell.dominant_sector_id",
		"cell.dominant_sector_share_q16",
		"cell.complete_chain_count",
		"cell.has_extractive_resource",
		"cell.legal_building_type_count",
		"cell.vacant_profession_count",
		"family.branch_count",
		"family.remote_branch_count",
		"family.cash_per_capita_vs_cell_q16",
		"cell.knowledge_building_class_count",
		"cell.can_produce_corn",
		# --- Output-share metrics (ids 37..46) -----------------------------
		# The *_SECTOR_SHARE_Q16 rows above count BUILDINGS, so raising a sector
		# output coefficient leaves them unmoved. These are aggregated from
		# group.last_output (already net of the output factor), so an
		# "industry share >= X -> boost" condition actually closes the loop.
		# Index order below MUST match the C++ FamilyEffectMetricId enum, since
		# the array index is the metric id.
		"cell.sector_output_share.agriculture_q16",
		"cell.sector_output_share.extractive_q16",
		"cell.sector_output_share.manufacturing_q16",
		"cell.sector_output_share.energy_q16",
		"cell.sector_output_share.knowledge_q16",
		"cell.dominant_sector_output_share_q16",
		# Resources (building_resource_ids: iron, corn, ...) and goods
		# (building_outputs[].good_id) are separate id spaces. The stock rows
		# answer "this cell is rich in iron"; the output rows answer "this cell
		# mostly produces X".
		"cell.dominant_resource_id",
		"cell.dominant_resource_stock_share_q16",
		"cell.dominant_output_good_id",
		"cell.top_output_good_share_q16",
		# --- Country scalars (ids 47..49) -----------------------------------
		# Read from the frozen CountryClassOpinionSnapshot, the same source
		# ideology point accrual uses, so a condition never samples a country
		# mid-write. research_speed / build_speed are intentionally absent: the
		# project models neither, and a metric that always reads 0 would make
		# such a card silently inert.
		"country.population_q16",
		"country.buildings_installed",
		"country.trade_base_value_q16",
		# --- Terrain axis (id 50) -------------------------------------------
		# NOT the same id space as `cell.landform` (id 10): that one is the
		# LandformType axis (plain / hills / delta / ...), this one is
		# TerrainType (grassland / floodplain / ...). 「河谷」is a floodplain
		# TERRAIN, so it could not be tagged at all while only landform existed.
		"cell.terrain",
		# --- X3: the cell's profession mix (ids 51..53) ----------------------
		# One id for "this is a hunters' camp", one share for "single-profession
		# town >= 80%", one count for diversity. Deliberately not one metric per
		# profession: the profession list is data-driven, and an enum edited on
		# every content change rots.
		"cell.dominant_profession_id",
		"cell.dominant_profession_share_q16",
		"cell.profession_count",
		# --- X2: the neighbourhood (id 54) ----------------------------------
		# Sum of the six neighbours' populations. The cheap half of X2: O(6) per
		# sample instead of walking every neighbour's buildings.
		"cell.neighbor_population_q16",
		# --- X11: what the state takes (id 55) ------------------------------
		# Mean income-tax rate across professions, basis points (10000 = 100%).
		"country.income_tax_burden_bp",
		# --- X7: how much of the country looks a certain way (ids 56..61) ---
		# Counts of the country's OWN cells matching a compiled-in tag list
		# (economy_runtime_family_buff.cpp `kCountryTagCountSlots`). Slot order
		# is the metric order; appending a tag means appending an id.
		"country.agriculture_cell_count",
		"country.extractive_cell_count",
		"country.manufacturing_cell_count",
		"country.chained_cell_count",
		"country.specialized_cell_count",
		"country.market_cell_count",
		"country.settlement_cell_count",
		# Per-good counts reuse the same slot table: `cell.produces.<good>` is
		# "dominant output good == that good", so a slot is the whole feature.
		"country.silver_cell_count",
		"country.salt_cell_count",
		"country.iron_ore_cell_count",
		"country.coal_cell_count",
		# Distinct goods with at least one specialized cell (share >= 60%).
		# Cannot be derived from tag counts: duplicates must collapse.
		"country.distinct_specialized_good_count",
		# R-4: net tax burden of this cell's cohorts over the current epoch, as a
		# Q16 ratio (0 = untaxed, Q16_ONE = every unit of income taken).
		"cell.net_tax_burden_q16",
		# R-4: country treasury cash as a percentage of one year of national income,
		# as a COUNT of percentage points (1 point = 1%). A ramp's `per` is a fraction
		# of the value, so a count here is what the generator's lint expects.
		"country.treasury_reserve_ratio_pct",
		# --- 19 §3.2 reservation (ids 70..86) ---------------------------------
		# Placeholders: the owning lane renames its key to the real metric name when
		# it implements the sampler. A reserved.* key is never bound by the generator.
		"cell.temperature_annual_q16",
		"cell.dry_streak_days",
		"cell.hazard_today_mask",
		"cell.days_since_hazard",
		"cell.temperature_anomaly_q16",
		"cell.geo_flags",
		"cell.waterway_component_size",
		"country.class_satisfaction_q16",
		"country.weighted_satisfaction_q16",
		"country.completed_tech_count",
		"country.completed_tech_count.agriculture",
		"country.completed_tech_count.engineering",
		"country.completed_tech_count.science",
		"country.completed_tech_count.society",
		"cell.family_branch_count",
		"cell.max_branch_prestige_q16",
		"cell.family_asset_share_q16",
		"cell.neighbor_distinct_goods",
		"country.hazard_free_cell_share_q16",
		# X14 extension: committed `farmer` class satisfaction. This is a
		# separate row from metric 77 (general) so petition_box can gate on the
		# class the design names.
		"country.farmer_satisfaction_q16",
		# X9-b: country-level family aggregates rebuilt at FAMILY_COMMIT.
		"country.family_remote_branch_count",
		"country.families_with_at_least_3_branches",
		"country.max_family_age_days",
		"country.avg_family_age_days",
		# X2 extension: count of the six neighbours whose agriculture output
		# share is at least 50%. 95 remains a reserved X3-b slot.
		"cell.neighbor_agriculture_count",
		"reserved.x3b_95",
		# X3-b profession shares, measured across the cell's known-profession
		# population (the same denominator as metrics 51..53).
		"cell.profession_share_farmer_q16",
		"cell.profession_share_industrial_q16",
		"cell.profession_share_cooperative_q16",
		# X14 extension used by trade_unions: committed `worker` class satisfaction.
		"country.worker_class_satisfaction_q16",
		"reserved.x3b_100",
		"reserved.x3b_101",
		# X7-b: committed country counts for infrastructure/science cards.
		"country.energy_cell_count",
		"country.abundant_mountain_forest_cell_count",
		"country.landform_signal_count",
		"country.weather_signal_count",
		"country.bio_signal_count",
		# The allocation reserves 102-107 for X7-b but names only five
		# mechanics; keep the final slot explicit rather than shifting a count.
		"reserved.x7b_107",
	])
	# --- Ideology-local scalars -------------------------------------------
	# These are not Economy metrics and are never sampled by
	# NativeEconomyRuntime. NativeIdeologyRuntime fills them into the same
	# per-instance slab immediately before reconciling the card's programs.
	# Values are Q16 fixed-point counts; unlocked_era is also value*Q16.
	# They append to whatever Economy declares: Economy owns the prefix and
	# may grow without forcing this lane to guess or reserve a base id.
	for scalar_metric_key in SCALAR_METRIC_KEYS:
		catalog.metric_keys.append(String(scalar_metric_key))
	catalog.behavior_command_keys = PackedStringArray()
	var definitions: Array[Resource] = []

	var technology_catalog := TechnologyCatalogScript.compile_native_catalog()
	if not bool(technology_catalog.get("ok", false)):
		return _reject("effect_catalog_technology_unavailable")
	var technology_ids: PackedStringArray = technology_catalog.get(
		"technology_ids", PackedStringArray())
	var technology_modifiers: PackedStringArray = technology_catalog.get(
		"technology_modifier_definition_keys", PackedStringArray())
	var technology_recipes: PackedStringArray = technology_catalog.get(
		"technology_effect_recipe_ids", PackedStringArray())
	var technology_recipe_versions: PackedInt32Array = technology_catalog.get(
		"technology_effect_recipe_versions", PackedInt32Array())
	var technology_flags: PackedInt32Array = technology_catalog.get(
		"technology_flags", PackedInt32Array())
	var definition_seen := {}
	if technology_recipes.size() != technology_ids.size() \
			or technology_recipe_versions.size() != technology_ids.size():
		return _reject("effect_catalog_technology_recipe_shape_invalid")
	for i in range(mini(technology_ids.size(), technology_modifiers.size())):
		if i < technology_flags.size() and (int(technology_flags[i]) & TechnologyCatalogScript.FLAG_STARTING) != 0:
			continue
		var modifier_key := String(technology_modifiers[i])
		var program_key := String(technology_recipes[i])
		if definition_seen.has(program_key):
			continue
		definition_seen[program_key] = true
		definitions.append(_technology_definition(program_key,
			int(technology_recipe_versions[i]), String(technology_ids[i]), modifier_key,
			i, int(technology_catalog.technology_domain_indices[i])))
	for row in TriggerCatalogScript.breakthrough_effect_rows():
		var program_key := "trigger.country.%s" % String(row.signal_id)
		if definition_seen.has(program_key):
			return _reject("effect_catalog_trigger_country_key_duplicate")
		definition_seen[program_key] = true
		definitions.append(_trigger_country_signal_definition(
			String(row.signal_id), int(row.signal_index),
			StringName(row.command_key)))
	var era_reward_ir := EraRewardCatalogScript.compile_native_catalog(technology_catalog)
	if not bool(era_reward_ir.get("ok", false)):
		return _reject("effect_catalog_era_reward_unavailable")
	for reward_definition in EraRewardCatalogScript.effect_definitions():
		var reward_key := String(reward_definition.key)
		if definition_seen.has(reward_key):
			return _reject("effect_catalog_era_reward_key_duplicate")
		definition_seen[reward_key] = true
		definitions.append(reward_definition)
	era_reward_ir.erase("ok")
	catalog.native_extensions = era_reward_ir

	# Family effects are authored independently from traits and compiled into
	# the same immutable EffectDefinition table. The first official catalog is
	# compiled from family_official_buffs.json; an empty override remains a
	# valid no-op for tests.
	var family_effect_catalog: Resource = family_effect_catalog_override
	if family_effect_catalog == null:
		family_effect_catalog = FamilyEffectCatalogScript.load_default()
	var family_effect_ir: Dictionary = {}
	if family_effect_catalog != null:
		family_effect_ir = family_effect_catalog.compile_native_catalog(
			technology_ids)
		if not bool(family_effect_ir.get("ok", false)):
			return _reject("effect_catalog_family_effect_unavailable")
		var family_definitions: Array = family_effect_ir.get("definitions", [])
		for definition in family_definitions:
			var family_key := String(definition.key)
			if definition_seen.has(family_key):
				return _reject("effect_catalog_family_effect_key_duplicate")
			definition_seen[family_key] = true
			definitions.append(definition)
		family_effect_ir.erase("ok")
		family_effect_ir.erase("definitions")
		for extension_key in family_effect_ir:
			catalog.native_extensions[extension_key] = family_effect_ir[extension_key]

	var economy_catalog := EconomyCatalogScript.compile_native_catalog(
		family_effect_catalog)
	# 标签词典（设计文档 §1 / §27）必须建在**理念效果编译之前**：卡面写的
	# `target_selector_tag` 要在 to_effect_definition() 之后、入表之前解析成
	# `param[1]` 的 1-based id（L5-14）。空表等于「没有标签」，原生侧据此
	# 跳过整张谓词表。
	var tag_list: Array[Dictionary] = []
	var tag_ids := {}
	if bool(economy_catalog.get("ok", false)):
		var tag_dictionary: Dictionary = TargetTagDictionaryScript.build(economy_catalog)
		if not bool(tag_dictionary.get("ok", false)):
			return _reject("effect_catalog_target_tag_dictionary_invalid:%s" % String(
				tag_dictionary.get("reason", "")))
		# `target_tags` is Array[Dictionary]; a plain Array raises at runtime and
		# the exception silently aborts build() (a SCRIPT ERROR does not propagate
		# as an error, it just returns null). The dictionary layer is deliberately
		# untyped so callers can build it cheaply, so the conversion happens once
		# here — the single place that crosses the typed boundary.
		for tag in tag_dictionary.get("tags", []):
			tag_list.append(tag)
		tag_ids = TargetTagDictionaryScript.tag_id_map(tag_list)
	if bool(economy_catalog.get("ok", false)):
		var trait_catalog = FamilyTraitCatalogScript.load_default()
		if trait_catalog != null:
			var trait_columns: Dictionary = trait_catalog.compile_native_columns(
				economy_catalog, family_effect_ir.get(
					"family_effect_keys", PackedStringArray()) if family_effect_catalog != null \
					else PackedStringArray(), family_effect_ir.get(
					"family_effect_source_kinds", PackedInt32Array()) \
					if family_effect_catalog != null else PackedInt32Array())
			if bool(trait_columns.get("ok", false)):
				var keys: PackedStringArray = trait_columns.get(
					"family_trait_modifier_definition_keys", PackedStringArray())
				var targets: PackedInt32Array = trait_columns.get(
					"family_trait_modifier_targets", PackedInt32Array())
				for i in range(keys.size()):
					if String(keys[i]).is_empty() or (i < targets.size() and int(targets[i]) != 0):
						continue
					var program_key := "family.modifier.%s" % String(keys[i])
					if definition_seen.has(program_key):
						continue
					definition_seen[program_key] = true
					definitions.append(_family_definition(String(keys[i])))
	# X5 rewrites name tag synonyms that do not exist in the base dictionary.
	# Materialize them before either IdeologyCatalog.compile_native_catalog()
	# call below can embed the dictionary size, and append only (ids are contract).
	if bool(economy_catalog.get("ok", false)):
		var rewrite_tags_error := _append_ideology_rewrite_tags(
			tag_list, tag_ids)
		if not rewrite_tags_error.is_empty():
			return _reject(rewrite_tags_error)

	# Precompile person programs from existing Modifier definitions. The native
	# PERSON_COMMIT producer currently activates the gameplay.generic.bonus
	# program; PersonStore still owns person state and these rows keep stable
	# definition keys out of the native evaluation loop.
	var modifier_catalog_resource: Resource = ModifierCatalogScript.load_default()
	var modifier_catalog: Dictionary = modifier_catalog_resource.compile_native_catalog() \
		if modifier_catalog_resource != null else {"ok": false}
	if family_effect_catalog != null:
		var family_domain_validation: Dictionary = \
			family_effect_catalog.validate_domain_bindings(
				economy_catalog, modifier_catalog)
		if not bool(family_domain_validation.get("ok", false)):
			return _reject("effect_catalog_family_domain_binding_invalid:%s" % String(
				family_domain_validation.get("reason", "")))
	if bool(modifier_catalog.get("ok", false)):
		var modifier_keys: PackedStringArray = modifier_catalog.get(
			"definition_keys", PackedStringArray())
		var modifier_domains: PackedInt32Array = modifier_catalog.get(
			"definition_domains", PackedInt32Array())
		for i in range(modifier_keys.size()):
			if i >= modifier_domains.size() or int(modifier_domains[i]) not in [2, 3]:
				continue
			var person_program := "person.modifier.%s" % String(modifier_keys[i])
			if definition_seen.has(person_program):
				continue
			definition_seen[person_program] = true
			definitions.append(_person_definition(String(modifier_keys[i]), int(modifier_domains[i])))
		# TriggerRuntime hands typed Modifier actions to EffectRuntime. One
		# executable command row per existing Modifier definition keeps stable
		# definition keys in the cold catalog and avoids runtime string lookup.
		for i in range(modifier_keys.size()):
			if i >= modifier_domains.size():
				continue
			var trigger_modifier_key := String(modifier_keys[i])
			if trigger_modifier_key.is_empty() or int(modifier_domains[i]) < 0 \
					or int(modifier_domains[i]) >= 4:
				continue
			var trigger_program := "trigger.modifier.%s" % trigger_modifier_key
			if definition_seen.has(trigger_program):
				continue
			definition_seen[trigger_program] = true
			definitions.append(_trigger_modifier_definition(
				trigger_modifier_key, int(modifier_domains[i])))
	for economy_row in _trigger_economy_command_rows():
		var economy_program := "trigger.economy.%s" % String(economy_row.command_key)
		if definition_seen.has(economy_program):
			continue
		definition_seen[economy_program] = true
		definitions.append(_trigger_economy_definition(
			String(economy_row.command_key), int(economy_row.opcode)))
	if not definition_seen.has("person.modifier"):
		definitions.append(_person_definition(""))
	# Ideology owns progression, but its authored command templates must be
	# compiled by EffectRuntime so domain mutation remains ACK-gated there.
	var ideology_catalog: Resource = IdeologyCatalogScript.load_default()
	var ideology_country_catalog := EconomyCatalogScript.compile_native_catalog()
	if ideology_catalog != null and bool(ideology_country_catalog.get("ok", false)):
		var ideology_ir: Dictionary = ideology_catalog.compile_native_catalog(
			ideology_country_catalog, ideology_country_catalog)
		if not bool(ideology_ir.get("ok", false)):
			return _reject("effect_catalog_ideology_command_unavailable:%s" % String(
				ideology_ir.get("reason", "")))
		# `metric_keys` becomes the dense id table every native condition reads.
		# A route with no scalar row would compile to an id that is never
		# published, so enforce the pairing where both tables are available.
		for route_key in ideology_ir.get("route_keys", PackedStringArray()):
			var route_metric := "ideology.scalar.route_count.%s" % String(route_key)
			if not catalog.metric_keys.has(route_metric):
				return _reject("effect_catalog_ideology_route_scalar_missing:%s"
					% String(route_key))
		definitions.append(_ideology_command_definition(ideology_ir))
	# Ideology declarative programs. A card effect row whose definition_key
	# matches one of these keys is owned by the reconciliation path (conditions,
	# target selector, lifecycle) instead of the one-shot command batch above.
	var ideology_effects: Resource = ideology_effect_catalog_override
	if ideology_effects == null:
		ideology_effects = IdeologyEffectCatalogScript.load_default()
	if ideology_effects != null:
		for effect in ideology_effects.effects:
			if effect == null or not effect is IdeologyEffectDefinitionScript:
				continue
			# Re-run the card's own rulebook rather than re-deriving it here.
			# IdeologyCatalog also validates, but only when the economy side
			# compiled; a second, weaker copy of those rules in this file is how
			# the DISTANCE_N ceiling stayed wrong for two rounds. One rulebook,
			# called from every gate.
			var card_error: String = effect.validate()
			if not card_error.is_empty():
				return _reject("effect_catalog_%s" % card_error)
			var program: Resource = effect.to_effect_definition()
			# L3-9 override layer. Applied BEFORE the tag resolution and the
			# duplicate-key short-circuit, for the same reason the tag name is:
			# an override targeting a program that never reaches the table must
			# still be reported. `IdeologyEffectCatalog.validate()` has already
			# rejected unknown targets and duplicate rows, so this loop only has
			# to translate.
			var override_error: String = ideology_effects.apply_overrides(
				program, effect.definition_key)
			if not override_error.is_empty():
				return _reject("effect_catalog_%s" % override_error)
			# L5-14: resolve the authored tag *name* into the 1-based dictionary
			# index that param[1] has always meant. Done before the duplicate-key
			# short-circuit below on purpose: a misspelled tag must fail the build
			# even on a card whose program key never reaches the table, otherwise
			# the first card to claim a key hides every later card's typo.
			var tag_names := PackedStringArray()
			if not effect.target_selector_tags.is_empty():
				tag_names = effect.target_selector_tags
			elif effect.target_selector_tag != &"":
				tag_names = PackedStringArray([String(effect.target_selector_tag)])
			var tag_error: String = _apply_selector_tags(
				program, tag_names, tag_list, tag_ids)
			if not tag_error.is_empty():
				return _reject(tag_error)
			var program_key := String(program.key)
			if program_key.is_empty() or definition_seen.has(program_key):
				continue
			definition_seen[program_key] = true
			definitions.append(program)
	definitions.sort_custom(func(a, b) -> bool: return String(a.key) < String(b.key))
	catalog.definitions = definitions
	# Published last so a rejection above leaves the catalog free of a tag table
	# whose ids no compiled program refers to.
	catalog.target_tags = tag_list
	return catalog


## Collect every distinct TAG rewrite replacement and append its union to the
## shared dictionary. Returns "" on success or a fully-qualified rejection.
##
## The scan is driven by the default ideology catalog, not by the compiled
## catalog, because compilation resolves override targets and route membership.
## It deliberately tolerates a missing catalog (bare effect tests) and does not
## mutate anything it cannot validate.
static func _append_ideology_rewrite_tags(tag_list: Array, tag_ids: Dictionary) -> String:
	if tag_list.is_empty() or tag_ids.is_empty():
		return ""
	var ideology_catalog: Resource = IdeologyCatalogScript.load_default()
	if ideology_catalog == null or not ideology_catalog is IdeologyCatalogScript:
		return ""
	var expressions := PackedStringArray()
	for synergy in ideology_catalog.synergies:
		if synergy == null or not synergy is IdeologySynergyDefinitionScript:
			continue
		for override in synergy.overrides:
			if override == null or not override is IdeologyEffectParameterScript:
				continue
			if int(override.field) != IdeologyEffectParameterScript.Field.TAG:
				continue
			var expression: String = override.tag_union_name()
			if not expression.is_empty() and not expressions.has(expression):
				expressions.append(expression)
	if expressions.is_empty():
		return ""
	for expression in expressions:
		if tag_ids.has(expression):
			continue
		var members := PackedStringArray(expression.split("|", false))
		for member in members:
			if not tag_ids.has(member):
				return "effect_catalog_target_selector_tag_unknown:%s" % member
		var union_error := _materialize_tag_union(members, tag_list, tag_ids)
		if not union_error.is_empty():
			return union_error
		if not tag_ids.has(expression):
			return "effect_catalog_target_tag_union_invalid:%s" % expression
	return ""


## Append a deterministic union tag for the requested member names. Names already
## present need no work; every missing name must be a real atom/composite in the
## dictionary, so a typo fails here rather than becoming a never-matching row.
static func _materialize_tag_union(names: PackedStringArray, tag_list: Array,
		tag_ids: Dictionary) -> String:
	# Canonicalize the FULL member list, not only the names that happen to be
	# missing. `coast|delta` needs a synthetic OR even when both atoms exist;
	# otherwise the rewrite names an expression that no dictionary id owns.
	var canonical := PackedStringArray()
	for name in names:
		if not canonical.has(name):
			canonical.append(name)
	canonical.sort()
	if canonical.is_empty():
		return "effect_catalog_target_tag_union_invalid"
	var combined_name := "|".join(canonical)
	if tag_ids.has(combined_name):
		return ""
	# Every member is validated by union(): only names already in the dictionary
	# can be members. A replacement like `a|b` is materialized as one synthetic
	# entry so downstream cards still reference one stable id.
	var merged: Dictionary = TargetTagDictionaryScript.union(canonical, tag_list)
	if not bool(merged.get("ok", false)):
		return "effect_catalog_target_tag_union_invalid:%s" % String(
			merged.get("reason", ""))
	var composite := String(merged.get("name", ""))
	if composite.is_empty():
		return "effect_catalog_target_tag_union_invalid"
	if not tag_ids.has(composite):
		if tag_list.size() >= TargetTagDictionaryScript.MAX_TAGS:
			return "effect_catalog_target_tag_table_over_capacity:%d" % (
				tag_list.size() + 1)
		tag_list.append({"name": composite, "rows": merged["rows"]})
		tag_ids[composite] = tag_list.size()
	return ""


## Resolve a TAG rewrite expression to the id of its concrete dictionary entry.
## Single names use the existing tag; `a|b` uses the sorted synthetic union
## appended above. The caller has already validated every member.
static func resolve_rewrite_tag_id(expression: String, tag_ids: Dictionary) -> int:
	var canonical := PackedStringArray()
	for part in expression.split("|", false):
		var name := String(part).strip_edges()
		if not name.is_empty() and not canonical.has(name):
			canonical.append(name)
	canonical.sort()
	if canonical.is_empty():
		return 0
	var name := "|".join(canonical)
	return int(tag_ids.get(name, 0))


## A null return here used to be silent, which made a broken catalog
## indistinguishable from a missing one. Every rejection now names itself.
static func _reject(reason: String) -> Resource:
	push_error("[effect-catalog] %s" % reason)
	return null


## Resolve a card's authored tag name into the raw 1-based id stored in
## `target_selector_param[1]`, in place on `program`.
##
## Returns "" on success, or a fully-qualified rejection reason. Split out of
## the compile loop so the id contract can be tested without a card file: the
## interesting cases (unknown name, empty dictionary, param array shorter than
## two slots) are all cheap to stage here and expensive to stage in .tres.
static func _apply_selector_tag(program: Resource, tag_name: StringName,
		tag_ids: Dictionary) -> String:
	if tag_name == &"":
		return ""
	var expression := String(tag_name)
	var members := PackedStringArray(expression.split("|", false))
	for index in range(members.size()):
		members[index] = members[index].strip_edges()
	if members.size() > 1:
		var canonical := PackedStringArray()
		for member in members:
			if member.is_empty():
				continue
			if not canonical.has(member):
				canonical.append(member)
		canonical.sort()
		expression = "|".join(canonical)
	var resolved := int(tag_ids.get(expression, 0))
	if resolved <= 0:
		# Distinguish "no dictionary at all" from "typo": when the economy
		# catalog failed to compile, every name looks unknown and the error
		# would send the next reader hunting for a bad tag.
		var reason := "effect_catalog_target_selector_tag_unknown" \
			if not tag_ids.is_empty() \
			else "effect_catalog_target_selector_tag_no_dictionary"
		return "%s:%s:%s" % [reason, String(program.key), expression]
	return _write_selector_tag_id(program, resolved)


## The multi-name form of the above: fold N tag names into one synthetic tag
## and point `param[1]` at it.
##
## This is what makes a 3+-tag AND authorable at all. The dictionary ships a
## fixed menu of *pairwise* composites (`build()` pre-bakes scale × sector,
## market × landform, ...), so without this a card wanting "边地的粮作农业地块"
## would need a hand-written dictionary entry. Here the card just lists the
## three names and the compiler assembles the clause product.
##
## `tag_list` / `tag_ids` are the build's own tables and are mutated: a new
## synthetic tag is **appended**, because tag ids are array indexes — inserting
## would shift every id below it and silently retarget cards that never changed.
static func _apply_selector_tags(program: Resource, names: PackedStringArray,
		tag_list: Array, tag_ids: Dictionary) -> String:
	if names.is_empty():
		return ""
	var selector_kind := int(program.target_selector_kind)
	if selector_kind <= 0 or selector_kind > EffectCatalogScript.POD_MAX_SELECTOR_KIND:
		return ""
	if names.size() == 1:
		var union_members := PackedStringArray()
		for part in String(names[0]).split("|", false):
			var member := String(part).strip_edges()
			if not member.is_empty() and not union_members.has(member):
				union_members.append(member)
		union_members.sort()
		if union_members.size() > 1:
			if tag_ids.is_empty():
				return "effect_catalog_target_selector_tag_no_dictionary:%s:%s" % [
					String(program.key), String(names[0])]
			for member in union_members:
				if int(tag_ids.get(member, 0)) <= 0:
					return "effect_catalog_target_selector_tag_unknown:%s:%s" % [
						String(program.key), member]
			var union_error := _materialize_tag_union(
				union_members, tag_list, tag_ids)
			if not union_error.is_empty():
				return "%s:%s" % [union_error, String(program.key)]
			var resolved := int(tag_ids.get("|".join(union_members), 0))
			if resolved <= 0:
				return "effect_catalog_target_tag_union_invalid:%s" % String(
					program.key)
			return _write_selector_tag_id(program, resolved)
		return _apply_selector_tag(program, StringName(names[0]), tag_ids)
	if tag_ids.is_empty():
		return "effect_catalog_target_selector_tag_no_dictionary:%s:%s" % [
			String(program.key), "&".join(names)]
	# Check membership before folding so an unknown name reports the same
	# `tag_unknown` invariant the single-name path reports, rather than a
	# budget/duplicate reason that points the reader at the wrong thing.
	var selector_names := PackedStringArray()
	for name in names:
		var members := PackedStringArray()
		for part in String(name).split("|", false):
			var member := String(part).strip_edges()
			if not member.is_empty() and not members.has(member):
				members.append(member)
		members.sort()
		for member in members:
			if int(tag_ids.get(member, 0)) <= 0:
				return "effect_catalog_target_selector_tag_unknown:%s:%s" % [
					String(program.key), member]
		if members.size() > 1:
			var union_error := _materialize_tag_union(members, tag_list, tag_ids)
			if not union_error.is_empty():
				return "%s:%s" % [union_error, String(program.key)]
		else:
			members = PackedStringArray([String(name)])
		var resolved_name := "|".join(members)
		if int(tag_ids.get(resolved_name, 0)) <= 0:
			return "effect_catalog_target_selector_tag_unknown:%s:%s" % [
				String(program.key), String(name)]
		selector_names.append(resolved_name)
	var merged: Dictionary = TargetTagDictionaryScript.intersection(
		selector_names, tag_list)
	if not bool(merged.get("ok", false)):
		return "effect_catalog_target_selector_intersection:%s:%s" % [
			String(program.key), String(merged.get("reason", ""))]
	var composite := String(merged["name"])
	var resolved := int(tag_ids.get(composite, 0))
	if resolved <= 0:
		if tag_list.size() >= TargetTagDictionaryScript.MAX_TAGS:
			return "effect_catalog_target_tag_table_over_capacity:%s:%d" % [
				String(program.key), tag_list.size() + 1]
		tag_list.append({"name": composite, "rows": merged["rows"]})
		resolved = tag_list.size()
		tag_ids[composite] = resolved
	return _write_selector_tag_id(program, resolved)


## Single writer for `param[1]`, shared by both forms. Keeping it in one place
## is the point: `param[0]` is the cell cap and must survive untouched, and a
## second copy of this resize dance is how it stops surviving.
static func _write_selector_tag_id(program: Resource, resolved: int) -> String:
	var params: PackedInt32Array = program.target_selector_param
	if params.size() < 2:
		# param[0] is the cell cap and stays 0 (= take the runtime default).
		params.resize(2)
	params[1] = resolved
	program.target_selector_param = params
	return ""


static func _technology_definition(recipe_id: String, recipe_version: int,
		technology_id: String, modifier_key: String, technology_index: int,
		domain_index: int) -> Resource:
	var definition := EffectDefinitionScript.new()
	definition.key = StringName(recipe_id)
	definition.version = recipe_version
	definition.cadence_days = 3650
	var constant := EffectInstructionScript.new()
	constant.op = 1 # CONST
	constant.value_q16 = Q16_ONE
	var emit := EffectInstructionScript.new()
	emit.op = 11 # EMIT_COMMAND
	emit.arg0 = 0
	var adopted_value := EffectInstructionScript.new()
	adopted_value.op = 1 # CONST
	adopted_value.value_q16 = Q16_ONE
	var emit_adopted := EffectInstructionScript.new()
	emit_adopted.op = 11 # EMIT_COMMAND
	emit_adopted.arg0 = 0 if modifier_key.is_empty() else 1
	var end := EffectInstructionScript.new()
	end.op = 12 # END
	var instructions: Array[Resource] = [constant]
	if not modifier_key.is_empty():
		instructions.append(emit)
	instructions.append(adopted_value)
	instructions.append(emit_adopted)
	instructions.append(end)
	definition.instructions = instructions
	var adopted := _command(5, 4, 13, &"technology.adopted", technology_id)
	adopted.value_mode = 0 # VALUE_CONSTANT
	adopted.value_q16 = Q16_ONE
	adopted.payload_i0 = technology_index
	adopted.payload_i1 = domain_index
	adopted.payload_i2 = 1 # technology adoption event recipe version
	var commands: Array[Resource] = []
	if not modifier_key.is_empty():
		commands.append(_command(1, 1, 1, &"technology.modifier", modifier_key))
	commands.append(adopted)
	definition.commands = commands
	return definition


static func _family_definition(modifier_key: String) -> Resource:
	var definition := EffectDefinitionScript.new()
	definition.key = StringName("family.modifier.%s" % modifier_key)
	definition.version = 1
	definition.cadence_days = 30
	var read := EffectInstructionScript.new()
	read.op = 2 # READ_METRIC
	read.arg0 = 0
	var emit := EffectInstructionScript.new()
	emit.op = 11
	emit.arg0 = 0
	var end := EffectInstructionScript.new()
	end.op = 12
	definition.instructions = [read, emit, end]
	definition.commands = [_command(1, 2, 1, &"family.modifier", modifier_key)]
	return definition


static func _person_definition(modifier_key: String = "", domain: int = 3) -> Resource:
	var definition := EffectDefinitionScript.new()
	definition.key = StringName("person.modifier" if modifier_key.is_empty() else
		"person.modifier.%s" % modifier_key)
	definition.version = 1
	definition.cadence_days = 3650
	var constant := EffectInstructionScript.new()
	constant.op = 1
	constant.value_q16 = Q16_ONE
	var emit := EffectInstructionScript.new()
	emit.op = 11
	emit.arg0 = 0
	var end := EffectInstructionScript.new()
	end.op = 12
	definition.instructions = [constant, emit, end]
	definition.commands = [_command(1, domain, 1, &"person.modifier", modifier_key)]
	return definition


static func _trigger_modifier_definition(modifier_key: String, domain: int) -> Resource:
	var definition := EffectDefinitionScript.new()
	definition.key = StringName("trigger.modifier.%s" % modifier_key)
	definition.version = 1
	definition.cadence_days = 3650
	var end := EffectInstructionScript.new()
	end.op = 12 # END; Trigger handoff emits the typed command directly.
	definition.instructions = [end]
	definition.commands = [_command(1, domain, 1, &"trigger.modifier", modifier_key)]
	return definition


static func _trigger_economy_command_rows() -> Array[Dictionary]:
	return [
		{"command_key": "family.free_building", "opcode": 14},
		{"command_key": "family.population_reward", "opcode": 15},
		{"command_key": "family.absorb_anonymous", "opcode": 21},
		{"command_key": "family.purchase_discount", "opcode": 22},
		{"command_key": "family.set_split_policy", "opcode": 23},
	]


static func _trigger_economy_definition(command_key: String, opcode: int) -> Resource:
	var definition := EffectDefinitionScript.new()
	definition.key = StringName("trigger.economy.%s" % command_key)
	definition.version = 1
	definition.cadence_days = 3650
	var end := EffectInstructionScript.new()
	end.op = 12
	definition.instructions = [end]
	definition.commands = [_command(3, 2, opcode, StringName(command_key), "")]
	return definition


static func _trigger_country_signal_definition(signal_id: String,
		signal_index: int, command_key: StringName = &"breakthrough.discover") -> Resource:
	var definition := EffectDefinitionScript.new()
	definition.key = StringName("trigger.country.%s" % signal_id)
	definition.version = 1
	definition.cadence_days = 3650
	var end := EffectInstructionScript.new()
	end.op = 12 # External Trigger ingress emits the typed command directly.
	definition.instructions = [end]
	var command := _command(2, 1, 14, command_key, signal_id)
	command.value_mode = 0
	command.value_q16 = 4 # ResearchSignalDefinition.ObservationMode.TRIGGER_OUTPUT
	command.payload_i0 = signal_index << 32
	definition.commands = [command]
	return definition


static func _ideology_command_definition(ideology_ir: Dictionary) -> Resource:
	var definition := EffectDefinitionScript.new()
	definition.key = &"ideology.command"
	definition.version = 1
	definition.cadence_days = 3650
	var end := EffectInstructionScript.new()
	end.op = 12 # External ideology ingress owns firing; this program is a template registry.
	definition.instructions = [end]
	# Ideology transitions submit persistent, one-shot, and reverse-CSR synergy
	# templates through the same external `ideology.command` program. All three
	# prefixes must therefore register matching Effect command definitions.
	for prefix in ["persistent", "on_enter", "synergy_effect"]:
		var actions: PackedInt32Array = ideology_ir.get("%s_actions" % prefix, PackedInt32Array())
		var domains: PackedInt32Array = ideology_ir.get("%s_domains" % prefix, PackedInt32Array())
		var opcodes: PackedInt32Array = ideology_ir.get("%s_opcodes" % prefix, PackedInt32Array())
		var values: PackedInt64Array = ideology_ir.get("%s_values_q16" % prefix, PackedInt64Array())
		var durations: PackedInt32Array = ideology_ir.get("%s_duration_days" % prefix, PackedInt32Array())
		var stacks: PackedInt32Array = ideology_ir.get("%s_stacks" % prefix, PackedInt32Array())
		var keys: PackedStringArray = ideology_ir.get("%s_command_keys" % prefix, PackedStringArray())
		var definitions: PackedStringArray = ideology_ir.get("%s_definition_keys" % prefix, PackedStringArray())
		var i0: PackedInt64Array = ideology_ir.get("%s_payload_i0" % prefix, PackedInt64Array())
		var i1: PackedInt64Array = ideology_ir.get("%s_payload_i1" % prefix, PackedInt64Array())
		var i2: PackedInt64Array = ideology_ir.get("%s_payload_i2" % prefix, PackedInt64Array())
		var i3: PackedInt64Array = ideology_ir.get("%s_payload_i3" % prefix, PackedInt64Array())
		for i in actions.size():
			if i >= domains.size() or i >= opcodes.size() or i >= values.size() \
					or i >= durations.size() or i >= stacks.size() or i >= keys.size() \
					or i >= definitions.size():
				return EffectDefinitionScript.new() # configure will reject the empty key.
			var command := EffectCommandScript.new()
			command.action = actions[i]
			command.domain = domains[i]
			command.opcode = opcodes[i]
			command.target_resolver = 1
			command.value_mode = 0
			command.value_q16 = values[i]
			command.duration_days = durations[i]
			command.stacks = stacks[i]
			command.command_key = StringName(keys[i])
			command.definition_key = StringName(definitions[i])
			command.payload_i0 = i0[i] if i < i0.size() else 0
			command.payload_i1 = i1[i] if i < i1.size() else 0
			command.payload_i2 = i2[i] if i < i2.size() else 0
			command.payload_i3 = i3[i] if i < i3.size() else 0
			definition.commands.append(command)
	return definition


static func _command(action: int, domain: int, opcode: int,
		command_key: StringName, definition_key: String) -> Resource:
	var command := EffectCommandScript.new()
	command.action = action
	command.domain = domain
	command.opcode = opcode
	command.target_resolver = 1 # TARGET_INSTANCE
	command.value_mode = 1 # VALUE_STACK_TOP
	command.duration_days = -1
	command.stacks = 1
	command.command_key = command_key
	command.definition_key = StringName(definition_key)
	return command
