class_name EconomyCatalog
extends RefCounted

const MarketCompiler = preload("res://scripts/economy/economy_catalog_market_compiler.gd")

const CarryingCompiler = preload("res://scripts/economy/economy_carrying_catalog_compiler.gd")

const PROFESSION_DIR := "res://data/economy/professions"
const ETHNICITY_DIR := "res://data/economy/ethnicities"
const PLAN_DIR := "res://data/economy/consumption_plans"
const NEED_DIR := "res://data/economy/needs"
const CURVE_DIR := "res://data/economy/environment_curves"
const BUILDING_DIR := "res://data/economy/buildings"
const PRODUCTION_CLIMATE_DIR := "res://data/economy/production_climates"
const ResourceRegistryScript = preload("res://scripts/data/resource_profile_registry.gd")
const BuildingColumnsCompilerScript = preload(
	"res://scripts/economy/economy_building_catalog_compiler.gd")
const BuildingPlacementCatalogScript = preload(
	"res://scripts/economy/building_placement_catalog.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")
const DevelopmentAchievementCatalogScript = preload(
	"res://scripts/research/development_achievement_catalog.gd")
const FamilyTraitCatalogScript = preload("res://scripts/family/family_trait_catalog.gd")
const FamilyEffectCatalogScript = preload("res://scripts/family/family_effect_catalog.gd")
const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")
const LandformTypeScript = preload("res://scripts/geography/landform_type.gd")
const DEFAULT_SETTLEMENT_PROFILE_PATH := "res://data/economy/default_settlement.tres"
const DEFAULT_FAMILY_SURNAME_PACK_PATH := "res://data/economy/default_family_surnames.tres"
const DEFAULT_PERSON_GIVEN_NAME_PACK_PATH := "res://data/economy/default_person_given_names.tres"
const DEFAULT_FAMILY_TRAIT_CATALOG_PATH := "res://data/economy/default_family_traits.tres"
const DEFAULT_FAMILY_EFFECT_CATALOG_PATH := "res://data/economy/default_family_effects.tres"
const Q16_ONE := 65536
## Reserved profession that represents unemployed population buckets. It is a
## legal signature profession (one signature per ethnicity is auto-generated),
## but MUST NEVER be usable as a building owner or employee role -- otherwise the
## unemployed pool could "hire itself". Catalog validation rejects any building
## that references it.
const UNEMPLOYED_PROFESSION_ID := "unemployed"
## Composite satisfaction dimensions, in native `SAT_DIM_*` order: subsistence,
## basic, comfort, luxury, income growth, savings, tax burden, social
## development. Needs classify into `[0, SATISFACTION_TIER_COUNT)`.
const SATISFACTION_DIMENSION_COUNT := 8
const SATISFACTION_TIER_COUNT := 4
const SATISFACTION_MODEL_VERSION := 2
## Dense order of `building_economic_sectors`. The compiled column stores this
## index, so the order is a data contract: append only, never reorder. The
## construction workspace groups its catalog pages by these sectors.
## `military` is appended after the five civil sectors on purpose: every native
## sector-keyed array (maintenance horizon, country sector output factors,
## overview buckets) is sized from the civil five, so the appended index stays
## out of those rules instead of silently landing in `knowledge`.
const BUILDING_SECTOR_IDS := [
	"agriculture", "extractive", "manufacturing", "energy", "knowledge",
	"military",
]
## Number of civil sectors. Native sector-keyed columns are sized from this, so
## `military` must never be indexed into them.
const BUILDING_CIVIL_SECTOR_COUNT := 5
## Authoring name -> dense `building_kinds` index. The native runtime
## switches on these four values, so the mapping is a data contract with
## `BuildingType::kind`: append only, never reorder or reuse an index.
## A miss here is a hard error: an unrecognised kind must never fall
## through to `industrial` and become a silent market producer.
const BUILDING_KIND_INDICES := {
	"collector": 0,
	"industrial": 1,
	"service": 2,
	"state": 3,
}
const SATISFACTION_DEVELOPMENT_INPUT_COUNT := 3
const SIGNAL_IDS := {
	"temperature": 0,
	"moisture": 1,
	"snow_cover": 2,
	"weather_intensity": 3,
}

const CatalogIO = preload("res://scripts/economy/economy_catalog_io.gd")
const ConstructionDependencies = preload("res://scripts/economy/economy_catalog_construction_dependencies.gd")


static func compile_native_catalog(
		family_effect_catalog_override: Resource = null,
		family_trait_catalog_override: Resource = null) -> Dictionary:
	return _compile_native_catalog.call(null, family_effect_catalog_override, family_trait_catalog_override)

static func compile_native_catalog_cooperative(context,
		family_effect_catalog_override: Resource = null,
		family_trait_catalog_override: Resource = null) -> Dictionary:
	return await context.dictionary("economy",
		[family_effect_catalog_override, family_trait_catalog_override],
		_compile_native_catalog, [family_effect_catalog_override, family_trait_catalog_override])

static func _compile_native_catalog(context,
		family_effect_catalog_override: Resource,
		family_trait_catalog_override: Resource) -> Dictionary:
	if family_trait_catalog_override == null and family_effect_catalog_override == null:
		var precompiled := LoadingCatalogCache.economy_catalog()
		if not precompiled.is_empty():
			return precompiled
	var market := await MarketCompiler.compile(context)
	if not bool(market.get("ok", false)):
		return market
	var profession_ids: PackedStringArray = market.profession_ids
	var profession_state_service_only: PackedInt32Array = market.profession_state_service_only
	var profession_technology_tag_offsets: PackedInt32Array = market.profession_technology_tag_offsets
	var profession_technology_tags: PackedStringArray = market.profession_technology_tags
	var profession_index: Dictionary = market.profession_index
	var good_columns: Dictionary = market.good_columns
	var good_index: Dictionary = market.good_index
	var catalog: Dictionary = market.catalog
	var market_v10_columns: Dictionary = market.market_v10_columns
	var market_v10_v8_columns: Dictionary = market.market_v10_v8_columns
	var market_v10_v7_columns: Dictionary = market.market_v10_v7_columns
	var market_v10_v6_columns: Dictionary = market.market_v10_v6_columns
	var market_v7_columns: Dictionary = market.market_v7_columns
	var market_compat_hash_v6: int = market.market_compat_hash_v6
	var building_columns := await BuildingColumnsCompilerScript.compile_cooperative(context,
		await CatalogIO._load_resources_impl(BUILDING_DIR, context), await CatalogIO._load_resources_impl(PRODUCTION_CLIMATE_DIR, context),
		profession_index, good_index, good_columns.good_storage_modes,
		good_columns.good_monetary_issue_values,
		good_columns.good_substitution_category_offsets,
		good_columns.good_substitution_category_ids,
		good_columns.good_production_quality_levels,
		good_columns.good_production_efficiency_q16,
		profession_state_service_only)
	if not bool(building_columns.get("ok", false)):
		return building_columns
	building_columns.erase("ok")
	if context != null:
		context.stage("technology_columns")
	var technology_catalog: Dictionary = TechnologyCatalogScript.compile_native_catalog()
	if not bool(technology_catalog.get("ok", false)):
		return technology_catalog
	var development_catalog := DevelopmentAchievementCatalogScript.compile_native_catalog(
		technology_catalog.get("research_signal_ids", PackedStringArray()))
	if not bool(development_catalog.get("ok", false)):
		return development_catalog
	var technology_ids: PackedStringArray = technology_catalog.technology_ids
	var technology_set := {}
	var technology_index := {}
	var technology_binding_rows: Array = []
	technology_binding_rows.resize(technology_ids.size())
	for technology_index_value in range(technology_ids.size()):
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		var technology_id := String(technology_ids[technology_index_value])
		technology_set[technology_id] = true
		technology_index[technology_id] = technology_index_value
		technology_binding_rows[technology_index_value] = []
	var building_type_set := {}
	for building_id in building_columns.building_type_ids:
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		building_type_set[String(building_id)] = true
	for intersection_value in technology_catalog.get("technology_application_intersections", []):
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		var intersection: Dictionary = intersection_value
		for building_value in intersection.get("building_ids", []):
			var building_id := String(building_value)
			if not building_type_set.has(building_id):
				return {"ok": false, "reason": "technology_application_building_missing",
					"id": String(intersection.get("id", "")), "building_id": building_id}
	var good_tag_offsets: PackedInt32Array = good_columns.good_technology_tag_offsets
	for good_index_value in range(good_columns.good_ids.size()):
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		var good_binding_count := 0
		for tag_index in range(good_tag_offsets[good_index_value],
				good_tag_offsets[good_index_value + 1]):
			var tag := String(good_columns.good_technology_tags[tag_index]).strip_edges()
			if not tag.begins_with("tech."):
				continue
			if not technology_set.has(tag):
				return {"ok": false, "reason": "unknown_good_technology_tag",
					"id": String(good_columns.good_ids[good_index_value]), "tag": tag}
			technology_binding_rows[int(technology_index[tag])].append(
				[1, String(good_columns.good_ids[good_index_value])])
			good_binding_count += 1
		if good_binding_count == 0:
			return {"ok": false, "reason": "good_technology_binding_missing",
				"id": String(good_columns.good_ids[good_index_value])}
	for profession_index_value in range(profession_ids.size()):
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		for tag_index in range(profession_technology_tag_offsets[profession_index_value],
				profession_technology_tag_offsets[profession_index_value + 1]):
			var tag := String(profession_technology_tags[tag_index]).strip_edges()
			if tag.begins_with("tech."):
				return {"ok": false, "reason": "profession_technology_binding_forbidden",
					"id": String(profession_ids[profession_index_value]), "tag": tag}
	var building_tag_offsets: PackedInt32Array = \
		building_columns.building_technology_tag_offsets
	var building_required_tag_offsets: PackedInt32Array = \
		building_columns.building_required_technology_tag_offsets
	var building_output_offsets: PackedInt32Array = building_columns.building_output_offsets
	var building_output_good_ids: PackedInt32Array = building_columns.building_output_good_ids
	var production_permit_keys := {}
	for building_index_value in range(building_columns.building_type_ids.size()):
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		var building_binding_count := 0
		var direct_building_technology_ids := PackedStringArray()
		for tag_index in range(building_tag_offsets[building_index_value],
				building_tag_offsets[building_index_value + 1]):
			var tag := String(
				building_columns.building_technology_tags[tag_index]).strip_edges()
			if not tag.begins_with("tech."):
				continue
			if not technology_set.has(tag):
				return {"ok": false, "reason": "unknown_building_technology_tag",
					"id": String(building_columns.building_type_ids[building_index_value]),
					"tag": tag}
			technology_binding_rows[int(technology_index[tag])].append(
				[2, String(building_columns.building_type_ids[building_index_value])])
			direct_building_technology_ids.append(tag)
			building_binding_count += 1
		if building_binding_count == 0:
			return {"ok": false, "reason": "building_technology_binding_missing",
				"id": String(building_columns.building_type_ids[building_index_value])}
		if building_binding_count != 1:
			return {"ok": false, "reason": "building_technology_binding_must_be_single",
				"id": String(building_columns.building_type_ids[building_index_value]),
				"count": building_binding_count}
		for tag_index in range(building_required_tag_offsets[building_index_value],
				building_required_tag_offsets[building_index_value + 1]):
			var required_tag := String(
				building_columns.building_required_technology_tags[tag_index]).strip_edges()
			if not technology_set.has(required_tag):
				return {"ok": false, "reason": "unknown_building_required_technology_tag",
					"id": String(building_columns.building_type_ids[building_index_value]),
					"tag": required_tag}
		for output_index in range(building_output_offsets[building_index_value],
				building_output_offsets[building_index_value + 1]):
			var output_good_id := String(good_columns.good_ids[
				int(building_output_good_ids[output_index])])
			for direct_technology_id in direct_building_technology_ids:
				production_permit_keys["%s|%s" % [
					direct_technology_id, output_good_id]] = true
	for good_index_value in range(good_columns.good_ids.size()):
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		var good_id := String(good_columns.good_ids[good_index_value])
		for tag_index in range(good_tag_offsets[good_index_value],
				good_tag_offsets[good_index_value + 1]):
			var technology_tag := String(
				good_columns.good_technology_tags[tag_index]).strip_edges()
			if not technology_tag.begins_with("tech."):
				continue
			if not production_permit_keys.has("%s|%s" % [technology_tag, good_id]):
				return {"ok": false, "reason": "good_technology_producer_missing",
					"id": good_id, "tag": technology_tag}
	var resource_ids := PackedStringArray()
	var resource_tag_offsets := PackedInt32Array([0])
	var resource_technology_tags := PackedStringArray()
	for resource in ResourceRegistryScript.ordered():
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		resource_ids.append(String(resource.id))
		var resource_binding_count := 0
		for tag in resource.discovery_technology_tags:
			var normalized := String(tag).strip_edges()
			if normalized == "":
				return {"ok": false, "reason": "resource_technology_binding_empty",
					"id": String(resource.id)}
			if not normalized.begins_with("tech."):
				continue
			if not technology_set.has(normalized):
				return {"ok": false, "reason": "unknown_resource_technology_tag",
					"id": String(resource.id), "tag": normalized}
			resource_technology_tags.append(normalized)
			technology_binding_rows[int(technology_index[normalized])].append(
				[3, String(resource.id)])
			resource_binding_count += 1
		if resource_binding_count == 0:
			return {"ok": false, "reason": "resource_technology_binding_missing",
				"id": String(resource.id)}
		resource_tag_offsets.append(resource_technology_tags.size())
	if context != null:
		context.stage("building_dependencies")
	var dependency_columns := ConstructionDependencies._compile_building_dependency_columns(
		building_columns, good_columns, building_columns.building_resource_ids,
		building_columns.building_resource_technology_tag_offsets,
		building_columns.building_resource_technology_tags,
		technology_set, technology_index)
	if not bool(dependency_columns.get("ok", false)):
		return dependency_columns
	for technology_index_value in range(technology_ids.size()):
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		var binding_count: int = technology_binding_rows[technology_index_value].size()
		var technology_id := String(technology_ids[technology_index_value])
		var is_milestone := (int(technology_catalog.technology_flags[technology_index_value]) \
				& TechnologyCatalogScript.FLAG_MILESTONE) != 0
		if is_milestone and binding_count != 0:
			return {"ok": false, "reason": "milestone_content_binding_forbidden",
				"id": technology_id, "count": binding_count}
	var technology_binding_offsets := PackedInt32Array([0])
	var technology_binding_kinds := PackedByteArray()
	var technology_binding_ids := PackedStringArray()
	var technology_consumer_flags := PackedByteArray()
	var modifier_offsets: PackedInt32Array = \
		technology_catalog.technology_modifier_term_offsets
	var recipe_ids: PackedStringArray = technology_catalog.technology_effect_recipe_ids
	for technology_index_value in range(technology_ids.size()):
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		for binding in technology_binding_rows[technology_index_value]:
			technology_binding_kinds.append(int(binding[0]))
			technology_binding_ids.append(String(binding[1]))
		technology_binding_offsets.append(technology_binding_ids.size())
		var consumer_flags := 1 if not technology_binding_rows[technology_index_value].is_empty() else 0
		if modifier_offsets[technology_index_value + 1] > modifier_offsets[technology_index_value]:
			consumer_flags |= 2
		if (int(technology_catalog.technology_flags[technology_index_value]) \
				& TechnologyCatalogScript.FLAG_STARTING) == 0 \
				and not String(recipe_ids[technology_index_value]).is_empty():
			consumer_flags |= 4
		if consumer_flags == 0:
			return {"ok": false, "reason": "technology_consumer_missing",
				"id": String(technology_ids[technology_index_value])}
		technology_consumer_flags.append(consumer_flags)
	var content_binding_summary := {
		"good_ids": good_columns.good_ids,
		"good_technology_tag_offsets": good_tag_offsets,
		"good_technology_tags": good_columns.good_technology_tags,
		"building_type_ids": building_columns.building_type_ids,
		"building_technology_tag_offsets": building_tag_offsets,
		"building_technology_tags": building_columns.building_technology_tags,
		"building_required_technology_tag_offsets": building_required_tag_offsets,
		"building_required_technology_tags": \
			building_columns.building_required_technology_tags,
		"profession_ids": profession_ids,
		"profession_technology_tag_offsets": profession_technology_tag_offsets,
		"profession_technology_tags": profession_technology_tags,
		"resource_ids": resource_ids,
		"resource_technology_tag_offsets": resource_tag_offsets,
		"resource_technology_tags": resource_technology_tags,
		"technology_content_binding_offsets": technology_binding_offsets,
		"technology_content_binding_kinds": technology_binding_kinds,
		"technology_content_binding_ids": technology_binding_ids,
		"technology_consumer_flags": technology_consumer_flags,
		"building_dependency_kinds": dependency_columns.building_dependency_kinds,
		"building_dependency_ids": dependency_columns.building_dependency_ids,
		"building_dependency_branch_offsets": dependency_columns.building_dependency_branch_offsets,
		"building_dependency_branch_technologies": dependency_columns.building_dependency_branch_technologies,
		"building_dependency_branch_technology_offsets": dependency_columns.building_dependency_branch_technology_offsets,
		"building_dependency_branch_group_offsets": dependency_columns.building_dependency_branch_group_offsets,
		"building_dependency_tag_offsets": dependency_columns.building_dependency_tag_offsets,
		"building_dependency_tags": dependency_columns.building_dependency_tags,
	}
	for key in technology_catalog:
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		if key != "ok":
			catalog[key] = technology_catalog[key]
	for key in development_catalog:
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		if key != "ok":
			catalog[key] = development_catalog[key]
	for key in ["technology_content_binding_offsets", "technology_content_binding_kinds",
			"technology_content_binding_ids", "technology_consumer_flags",
			"building_dependency_branch_offsets", "building_dependency_branch_technologies",
			"building_dependency_branch_technology_offsets",
			"building_dependency_branch_group_offsets", "building_dependency_kinds",
			"building_dependency_ids", "building_dependency_tag_offsets",
			"building_dependency_tags",
			# Id spaces the effect catalog needs to turn a stable id into the
			# dense index a metric reads (TargetTagDictionary). They were
			# already compiled here for the technology binding hash, just not
			# published; a second compiler pass to re-derive the same order
			# would be the kind of mirror that drifts.
			"good_ids", "resource_ids"]:
		catalog[key] = content_binding_summary[key]
	var trigger_catalog_resource: Resource = TriggerCatalogScript.load_default()
	var trigger_catalog: Dictionary = trigger_catalog_resource.compile_native_catalog() \
		if trigger_catalog_resource != null else {"ok": false,
			"reason": "trigger_catalog_missing"}
	if not bool(trigger_catalog.get("ok", false)):
		return trigger_catalog
	catalog["technology_catalog_identity_hash"] = await CatalogIO._catalog_hash_impl(technology_catalog, context)
	catalog["technology_content_binding_hash"] = await CatalogIO._catalog_hash_impl(content_binding_summary, context)
	catalog["technology_trigger_definition_hash"] = await CatalogIO._catalog_hash_impl(trigger_catalog, context)
	var building_v7_columns := building_columns.duplicate(true)
	for key in [
		"building_upgrade_family_ids", "building_upgrade_family_indices",
		"building_upgrade_tiers", "building_input_required_q16",
		"building_industry_chain_ids", "building_progression_steps",
		"building_maturity_ranks", "building_maturity_display_names",
		"building_progression_roles", "building_progression_predecessor_offsets",
		"building_progression_predecessor_indices",
		"building_progression_terminal_reasons",
		"building_input_category_ids", "building_input_min_quality_levels",
		"building_input_candidate_offsets",
		"building_input_candidate_good_ids", "building_input_candidate_efficiency_q16",
		# Military v1 addition, newer than every compat hash below.
		"building_state_roles",
	]:
		building_v7_columns.erase(key)
	building_v7_columns.erase("building_employee_wage_policies")
	var building_v6_columns := building_v7_columns.duplicate(true)
	for key in [
		"building_target_operating_margin_q16", "building_supply_price_elasticity_q16",
		"building_output_cost_share_offsets", "building_output_cost_shares_q16",
	]:
		building_v6_columns.erase(key)
	catalog["building_catalog_hash"] = await CatalogIO._catalog_hash_impl(building_columns, context)
	if context != null:
		context.stage("carrying_columns")
	var carrying_columns := CarryingCompiler.compile(catalog, building_columns, good_columns, CatalogIO._index_ids)
	if not bool(carrying_columns.get("ok", false)):
		return carrying_columns
	carrying_columns.erase("ok")
	for key in carrying_columns:
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		catalog[key] = carrying_columns[key]
	var building_v13_columns := building_columns.duplicate(true)
	for key in [
		# Military v1 additions are newer than every compat hash, so the older
		# hash inputs must not see them or an unchanged catalog would hash
		# differently and invalidate existing saves.
		"building_state_roles",
		"building_industry_chain_ids", "building_progression_steps",
		"building_maturity_ranks", "building_maturity_display_names",
		"building_progression_roles", "building_progression_predecessor_offsets",
		"building_progression_predecessor_indices",
		"building_progression_terminal_reasons",
		"building_resource_gen_base", "building_resource_gen_temp",
		"building_resource_gen_moisture", "building_resource_gen_self",
		"building_resource_decay_base", "building_resource_decay_temp",
		"building_resource_decay_moisture", "building_resource_decay_self_q16",
		"building_resource_ecology_capacity", "building_resource_ecology_growth_q16",
		"building_resource_temp_lo_q16", "building_resource_temp_hi_q16",
		"building_resource_climate_temp_opt_q16",
		"building_resource_climate_temp_tol_q16",
		"building_resource_climate_moisture_opt_q16",
		"building_resource_climate_moisture_tol_q16",
		"building_resource_runtime_fit_weight_q16",
		"building_resource_temperature_signal",
		"building_resource_moisture_signal",
	]:
		building_v13_columns.erase(key)
	var building_compat_hash_v13 := await CatalogIO._catalog_hash_impl(building_v13_columns, context)
	catalog["market_catalog_compat_hash_v6"] = market_compat_hash_v6
	catalog["market_catalog_compat_hash_v7"] = await CatalogIO._catalog_hash_impl(market_v7_columns, context)
	catalog["building_catalog_compat_hash_v6"] = await CatalogIO._catalog_hash_impl(building_v6_columns, context)
	catalog["building_catalog_compat_hash_v7"] = await CatalogIO._catalog_hash_impl(building_v7_columns, context)
	for key in building_columns:
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		catalog[key] = building_columns[key]
	var catalog_v13 := catalog.duplicate(true)
	for key in building_columns:
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		if not building_v13_columns.has(key):
			catalog_v13.erase(key)
	catalog_v13["building_catalog_hash"] = building_compat_hash_v13
	catalog["building_catalog_compat_hash_v13"] = building_compat_hash_v13
	catalog["catalog_compat_hash_v13"] = await CatalogIO._catalog_hash_impl(catalog_v13, context)
	var catalog_v10 := catalog.duplicate(true)
	catalog_v10.erase("good_trade_enabled")
	catalog_v10.erase("good_transport_load_per_unit_q16")
	catalog_v10["market_catalog_hash"] = await CatalogIO._catalog_hash_impl(market_v10_columns, context)
	catalog_v10["market_catalog_compat_hash_v8"] = await CatalogIO._catalog_hash_impl(market_v10_v8_columns, context)
	catalog_v10["market_catalog_compat_hash_v7"] = await CatalogIO._catalog_hash_impl(market_v10_v7_columns, context)
	catalog_v10["market_catalog_compat_hash_v6"] = await CatalogIO._catalog_hash_impl(market_v10_v6_columns, context)
	catalog["catalog_compat_hash_v10"] = await CatalogIO._catalog_hash_impl(catalog_v10, context)
	catalog["catalog_hash"] = await CatalogIO._catalog_hash_impl(catalog, context)
	var settlement_profile = load(DEFAULT_SETTLEMENT_PROFILE_PATH)
	if settlement_profile == null or not settlement_profile.has_method("compile_native_columns"):
		return {"ok": false, "reason": "default settlement profile is unavailable"}
	var settlement_columns: Dictionary = settlement_profile.compile_native_columns()
	if not bool(settlement_columns.get("ok", false)):
		return settlement_columns
	for key in settlement_columns:
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		if key != "ok":
			catalog[key] = settlement_columns[key]
	var family_pack = load(DEFAULT_FAMILY_SURNAME_PACK_PATH)
	if family_pack == null or not family_pack.has_method("compile_native_columns"):
		return {"ok": false, "reason": "default family surname pack is unavailable"}
	var family_columns: Dictionary = family_pack.compile_native_columns()
	if not bool(family_columns.get("ok", false)):
		return family_columns
	for key in family_columns:
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		if key != "ok":
			catalog[key] = family_columns[key]
	var person_pack = load(DEFAULT_PERSON_GIVEN_NAME_PACK_PATH)
	if person_pack == null or not person_pack.has_method("compile_native_columns"):
		return {"ok": false, "reason": "default person given-name pack is unavailable"}
	var person_columns: Dictionary = person_pack.compile_native_columns()
	if not bool(person_columns.get("ok", false)):
		return person_columns
	for key in person_columns:
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		if key != "ok":
			catalog[key] = person_columns[key]
	var trait_catalog = family_trait_catalog_override
	if trait_catalog == null:
		trait_catalog = FamilyTraitCatalogScript.load_default()
	if trait_catalog == null or not trait_catalog is FamilyTraitCatalogScript:
		return {"ok": false, "reason": "default family trait catalog is unavailable"}
	var family_effect_catalog = family_effect_catalog_override
	if family_effect_catalog == null:
		family_effect_catalog = FamilyEffectCatalogScript.load_default()
	if family_effect_catalog == null or not family_effect_catalog is FamilyEffectCatalogScript:
		return {"ok": false, "reason": "family effect catalog is unavailable"}
	if context != null:
		context.stage("family_effect_columns")
	var family_effect_ir: Dictionary = family_effect_catalog.compile_native_catalog(
		catalog.get("technology_ids", PackedStringArray()))
	if not bool(family_effect_ir.get("ok", false)):
		return family_effect_ir
	family_effect_ir.erase("ok")
	family_effect_ir.erase("definitions")
	for key in family_effect_ir:
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		catalog[key] = family_effect_ir[key]
	var trait_columns: Dictionary = trait_catalog.compile_native_columns(
		catalog, family_effect_ir.get("family_effect_keys", PackedStringArray()),
		family_effect_ir.get("family_effect_source_kinds", PackedInt32Array()))
	if not bool(trait_columns.get("ok", false)):
		return trait_columns
	for key in trait_columns:
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		if key != "ok":
			catalog[key] = trait_columns[key]
	var family_v39_columns := {
		"family_surname_pack_id": catalog.family_surname_pack_id,
		"family_surname_ids": catalog.family_surname_ids,
		"family_surname_text": catalog.family_surname_text,
		"family_surname_weights": catalog.family_surname_weights,
	}
	var family_v39_hash := hash(family_v39_columns)
	if family_v39_hash == 0:
		family_v39_hash = 1
	var catalog_v39 := catalog.duplicate(true)
	for key in ["ethnicity_culture_group_ids", "family_culture_group_ids",
			"family_culture_group_display_names", "family_culture_group_naming_formats",
			"family_culture_group_separators", "family_culture_group_suffixes",
			"family_surname_culture_group_ids"]:
		catalog_v39.erase(key)
	catalog_v39["family_catalog_hash"] = family_v39_hash
	catalog["family_catalog_compat_hash_v39"] = family_v39_hash
	catalog["catalog_compat_hash_v39"] = await CatalogIO._catalog_hash_impl(catalog_v39, context)
	# Final identity includes family traits and the consumption model version.
	catalog["catalog_hash"] = await CatalogIO._catalog_hash_impl(catalog, context)
	catalog["ok"] = true
	return catalog

static func need_display_names() -> Dictionary:
	return _need_display_names_impl.call(null)

static func _need_display_names_impl(context) -> Dictionary:
	var names := {}
	for need in await CatalogIO._load_resources_impl(NEED_DIR, context):
		if context != null:
			await context.checkpoint("need_displays")
			if context.canceled:
				return {}
		var stable_id := String(need.id)
		if stable_id == "":
			continue
		var display_name := String(need.display_name)
		names[stable_id] = display_name if display_name != "" else stable_id
	return names

static func validate_building_progression_profiles(profiles: Array) -> Dictionary:

		# Explicit kind table. The previous nested ternary ended in a bare
		# `else 1`, so any unrecognised kind - a typo like "state_" or a
		# newly authored kind this runtime does not know - compiled into
		# `industrial` and started bidding for inputs and selling output.
		# Military v1 (design §5.2/§5.3): a state-owned lot carries an authored
		# role; every other kind must leave it at `none`.
		# Military v1 (design §1.4/§1.5): every state lot is unlocked by
		# exactly one technology. The generic binding rule below also rejects
		# a double binding, but it reports a bare count; a state lot is the
		# one kind whose whole purpose is a single gate, so fail with the
		# role named and the offending count attached.

			# Military v1: a state-owned lot is staffed only by state-service
			# professions, and every one of those roles runs "state_payroll".
				# Design §3.2/§3.3: the treasury pays every state role, so the
				# policy must be authored explicitly. The earlier form skipped
				# this check whenever `employee_wage_policy_ids` was empty, which
				# let a state lot fall back to the building-level market wage
				# and compile with a wage the treasury never settles.
			# Employee wages are always discovered from the live labour market.
			# Keep accepting legacy "fixed" content for load compatibility, but
			# never compile it into a fixed native wage policy. `state_payroll`
			# is not a wage amount: the treasury pays the military wage, so the
			# role posts no building contract wage either.

		# Design §7.3: a state lot is a pure treasury cash sink. Its upkeep is
		# settled by the military runtime, so a material maintenance bill here
		# would charge the same building twice - once in goods, once in cash.
		# Reject the authoring outright instead of silently dropping the
		# column, so the double bill can never come back through content.

		# Design §7.3: a state lot neither extracts nor cultivates. The
		# generic collector/cultivation rules below would reject these too,
		# but with a reason that never names the state contract, and the
		# collector rule in particular reads as if a state lot could be
		# fixed by re-tagging its kind.
			# Route B: a merchant may own either a matching bullion collector
			# (gold/silver) or a service "merchant post" (no output/resource).

	return BuildingPlacementCatalogScript.validate_building_progression_profiles(profiles)

static func _validate_explicit_input_candidates(profile: Resource,
		good_index: Dictionary) -> String:
	return BuildingPlacementCatalogScript._validate_explicit_input_candidates(profile, good_index)

## Compiles the material/resource prerequisites for every direct building
## technology branch.  A branch is usable only when its own technology and
## required tags are completed, and every dependency group has at least one
## completed discovery/production tag.  Input candidate alternatives share one
## group, so a building is not incorrectly forced to unlock every substitute.

static func allows_zero_cost_construction(profile: Resource) -> bool:


	return BuildingPlacementCatalogScript.allows_zero_cost_construction(profile)

static func _append_construction_candidates(profile: Resource,
		good_index: Dictionary, category_good_indices: Dictionary,
		good_quality_levels: PackedInt32Array,
		good_efficiencies_q16: PackedInt32Array, out_offsets: PackedInt32Array,
		out_goods: PackedInt32Array, out_efficiencies: PackedInt32Array) -> String:
			# A category group expands to every member whose production quality
			# clears the gate. The preferred good stays in the group so the
			# runtime keeps its cost tie-break and the content-binding summary
			# still sees the authored material.
	return BuildingPlacementCatalogScript._append_construction_candidates(profile,
		good_index, category_good_indices, good_quality_levels, good_efficiencies_q16,
		out_offsets, out_goods, out_efficiencies)

static func _load_resources(dir_path: String) -> Array:
	return CatalogIO._load_resources_impl.call(dir_path, null)

static func _catalog_hash(catalog: Dictionary) -> int:
	return CatalogIO._catalog_hash_impl.call(catalog, null)
