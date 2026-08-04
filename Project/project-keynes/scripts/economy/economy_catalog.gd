class_name EconomyCatalog
extends RefCounted

const PROFESSION_DIR := "res://data/economy/professions"
const ETHNICITY_DIR := "res://data/economy/ethnicities"
const PLAN_DIR := "res://data/economy/consumption_plans"
const NEED_DIR := "res://data/economy/needs"
const CURVE_DIR := "res://data/economy/environment_curves"
const BUILDING_DIR := "res://data/economy/buildings"
const PRODUCTION_CLIMATE_DIR := "res://data/economy/production_climates"
const ResourceRegistryScript = preload("res://scripts/data/resource_profile_registry.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const FamilyTraitCatalogScript = preload("res://scripts/family/family_trait_catalog.gd")
const DEFAULT_SETTLEMENT_PROFILE_PATH := "res://data/economy/default_settlement.tres"
const DEFAULT_FAMILY_SURNAME_PACK_PATH := "res://data/economy/default_family_surnames.tres"
const DEFAULT_PERSON_GIVEN_NAME_PACK_PATH := "res://data/economy/default_person_given_names.tres"
const DEFAULT_FAMILY_TRAIT_CATALOG_PATH := "res://data/economy/default_family_traits.tres"
const Q16_ONE := 65536
## Reserved profession that represents unemployed population buckets. It is a
## legal signature profession (one signature per ethnicity is auto-generated),
## but MUST NEVER be usable as a building owner or employee role -- otherwise the
## unemployed pool could "hire itself". Catalog validation rejects any building
## that references it.
const UNEMPLOYED_PROFESSION_ID := "unemployed"
## Composite satisfaction dimensions, in native `SAT_DIM_*` order: subsistence,
## basic, comfort, luxury, income growth, savings, tax burden, social
## development. The first four are the need tiers, so every need must classify
## into `[0, SATISFACTION_TIER_COUNT)`.
const SATISFACTION_DIMENSION_COUNT := 8
const SATISFACTION_TIER_COUNT := 4
const SATISFACTION_DEVELOPMENT_INPUT_COUNT := 3
const SIGNAL_IDS := {
	"temperature": 0,
	"moisture": 1,
	"snow_cover": 2,
	"weather_intensity": 3,
}

static func compile_native_catalog() -> Dictionary:
	var professions := _load_resources(PROFESSION_DIR)
	var ethnicities := _load_resources(ETHNICITY_DIR)
	var plans := _load_resources(PLAN_DIR)
	var needs := _load_resources(NEED_DIR)
	var curves := _load_resources(CURVE_DIR)
	if professions.is_empty() or ethnicities.is_empty() or plans.is_empty() or needs.is_empty():
		return {"ok": false, "reason": "market v2 catalog is incomplete"}

	var good_columns: Dictionary = GoodProfileRegistry.compile_native_columns()
	if not bool(good_columns.get("ok", false)):
		return good_columns
	good_columns.erase("ok")
	var good_ids: PackedStringArray = good_columns.good_ids
	var good_index := _index_ids(good_ids)
	if good_ids.is_empty():
		return {"ok": false, "reason": "good catalog is empty"}

	var need_ids := PackedStringArray()
	var need_living_cost_weights := PackedInt32Array()
	var need_satisfaction_tiers := PackedInt32Array()
	var need_satisfaction_weights := PackedInt32Array()
	var need_semantic_tag_offsets := PackedInt32Array([0])
	var need_semantic_tags := PackedStringArray()
	for need in needs:
		var living_weight := int(need.living_cost_weight_q16)
		if living_weight < 0 or living_weight > Q16_ONE:
			return {"ok": false, "reason": "invalid living cost weight: %s" % String(need.id)}
		var satisfaction_tier := int(need.satisfaction_tier)
		if satisfaction_tier < 0 or satisfaction_tier >= SATISFACTION_TIER_COUNT:
			return {"ok": false, "reason": "invalid need satisfaction tier: %s" % String(need.id)}
		var satisfaction_weight := int(need.satisfaction_weight_q16)
		if satisfaction_weight < 0 or satisfaction_weight > Q16_ONE:
			return {"ok": false, "reason": "invalid need satisfaction weight: %s" % String(need.id)}
		need_ids.append(String(need.id))
		need_living_cost_weights.append(living_weight)
		need_satisfaction_tiers.append(satisfaction_tier)
		need_satisfaction_weights.append(satisfaction_weight)
		var normalized_tags := PackedStringArray()
		for source_tags in [need.use_tags as PackedStringArray,
				need.semantic_tags as PackedStringArray]:
			for tag in source_tags:
				var normalized := String(tag).strip_edges()
				if normalized.is_empty() or normalized_tags.has(normalized):
					return {"ok": false, "reason": "invalid need semantic tag: %s" % String(need.id)}
				normalized_tags.append(normalized)
		normalized_tags.sort()
		need_semantic_tags.append_array(normalized_tags)
		need_semantic_tag_offsets.append(need_semantic_tags.size())
	if need_ids.size() > 32:
		return {"ok": false, "reason": "global need count exceeds 32"}
	var need_index := _index_ids(need_ids)

	var curve_ids := PackedStringArray()
	var curve_signal_ids := PackedInt32Array()
	var curve_values := PackedInt32Array()
	for curve in curves:
		var curve_id := String(curve.id)
		var signal_name := String(curve.signal_id)
		if not SIGNAL_IDS.has(signal_name) or curve.values_q16.size() != 17:
			return {"ok": false, "reason": "invalid environment curve: %s" % curve_id}
		curve_ids.append(curve_id)
		curve_signal_ids.append(int(SIGNAL_IDS[signal_name]))
		for value in curve.values_q16:
			curve_values.append(maxi(0, int(value)))
	var curve_index := _index_ids(curve_ids)

	var plan_ids := PackedStringArray()
	var plan_index := {}
	for i in range(plans.size()):
		var stable_id := String(plans[i].id)
		if stable_id == "" or plan_index.has(stable_id):
			return {"ok": false, "reason": "invalid or duplicate plan id: %s" % stable_id}
		plan_ids.append(stable_id)
		plan_index[stable_id] = i

	var plan_need_offsets := PackedInt32Array([0])
	var need_stable_ids := PackedInt32Array()
	var need_priorities := PackedInt32Array()
	var need_base_qty := PackedInt64Array()
	var need_wealth_elasticity := PackedInt32Array()
	var need_wealth_min := PackedInt32Array()
	var need_wealth_max := PackedInt32Array()
	var need_price_quantity_elasticity := PackedInt32Array()
	var need_price_quantity_floor := PackedInt32Array()
	var need_env_curve_ids := PackedInt32Array()
	var need_variant_offsets := PackedInt32Array([0])
	var variant_preference := PackedInt32Array()
	var variant_elasticity := PackedInt32Array()
	var variant_env_curve_ids := PackedInt32Array()
	var variant_component_offsets := PackedInt32Array([0])
	var component_good_ids := PackedInt32Array()
	var component_qty := PackedInt64Array()

	for plan in plans:
		var need_count: int = plan.need_ids.size()
		if need_count > 16 or plan.priorities.size() != need_count \
				or plan.base_qty_per_person.size() != need_count \
				or plan.wealth_elasticity_q16.size() != need_count \
				or plan.wealth_min_q16.size() != need_count \
				or plan.wealth_max_q16.size() != need_count \
				or plan.price_quantity_elasticity_q16.size() != need_count \
				or plan.price_quantity_floor_q16.size() != need_count \
				or plan.quantity_env_curve_ids.size() != need_count \
				or plan.need_variant_offsets.size() != need_count + 1 \
				or plan.need_variant_offsets[0] != 0:
			return {"ok": false, "reason": "invalid need columns in plan %s" % String(plan.id)}
		var variant_count: int = plan.variant_ids.size()
		if plan.need_variant_offsets[need_count] != variant_count \
				or plan.variant_preference_q16.size() != variant_count \
				or plan.variant_price_elasticity_q16.size() != variant_count \
				or plan.variant_preference_env_curve_ids.size() != variant_count \
				or plan.variant_component_offsets.size() != variant_count + 1 \
				or plan.variant_component_offsets[0] != 0:
			return {"ok": false, "reason": "invalid variant columns in plan %s" % String(plan.id)}
		if plan.variant_component_offsets[variant_count] != plan.component_good_ids.size() \
				or plan.component_good_ids.size() != plan.component_qty_per_need.size() \
				or plan.component_good_ids.size() > 128:
			return {"ok": false, "reason": "invalid component columns in plan %s" % String(plan.id)}
		var previous_priority := -2147483648
		for n in range(need_count):
			var need_id := String(plan.need_ids[n])
			var priority := int(plan.priorities[n])
			var vb := int(plan.need_variant_offsets[n])
			var ve := int(plan.need_variant_offsets[n + 1])
			if not need_index.has(need_id) or priority < previous_priority or ve <= vb or ve - vb > 8:
				return {"ok": false, "reason": "invalid need entry in plan %s" % String(plan.id)}
			previous_priority = priority
			need_stable_ids.append(int(need_index[need_id]))
			need_priorities.append(priority)
			need_base_qty.append(int(plan.base_qty_per_person[n]))
			need_wealth_elasticity.append(int(plan.wealth_elasticity_q16[n]))
			need_wealth_min.append(int(plan.wealth_min_q16[n]))
			need_wealth_max.append(int(plan.wealth_max_q16[n]))
			var price_quantity_elasticity := int(plan.price_quantity_elasticity_q16[n])
			var price_quantity_floor := int(plan.price_quantity_floor_q16[n])
			if price_quantity_elasticity < 0 or price_quantity_elasticity > Q16_ONE * 4 \
					or price_quantity_floor < 0 or price_quantity_floor > Q16_ONE:
				return {"ok": false, "reason": "invalid price quantity response in plan %s" % String(plan.id)}
			need_price_quantity_elasticity.append(price_quantity_elasticity)
			need_price_quantity_floor.append(price_quantity_floor)
			need_env_curve_ids.append(_optional_index(curve_index, String(plan.quantity_env_curve_ids[n])))
			need_variant_offsets.append(need_variant_offsets[-1] + ve - vb)
		for v in range(variant_count):
			var cb := int(plan.variant_component_offsets[v])
			var ce := int(plan.variant_component_offsets[v + 1])
			if ce <= cb or ce - cb > 4:
				return {"ok": false, "reason": "invalid complement bundle in plan %s" % String(plan.id)}
			variant_preference.append(int(plan.variant_preference_q16[v]))
			variant_elasticity.append(int(plan.variant_price_elasticity_q16[v]))
			variant_env_curve_ids.append(_optional_index(
				curve_index, String(plan.variant_preference_env_curve_ids[v])))
			variant_component_offsets.append(variant_component_offsets[-1] + ce - cb)
			for c in range(cb, ce):
				var good_id := String(plan.component_good_ids[c])
				if not good_index.has(good_id) or int(plan.component_qty_per_need[c]) <= 0:
					return {"ok": false, "reason": "invalid good component in plan %s" % String(plan.id)}
				component_good_ids.append(int(good_index[good_id]))
				component_qty.append(int(plan.component_qty_per_need[c]))
		plan_need_offsets.append(need_stable_ids.size())

	var profession_ids := PackedStringArray()
	var profession_class_ids := PackedStringArray()
	var profession_technology_tag_offsets := PackedInt32Array([0])
	var profession_technology_tags := PackedStringArray()
	var profession_semantic_tag_offsets := PackedInt32Array([0])
	var profession_semantic_tags := PackedStringArray()
	var profession_index := {}
	for i in range(professions.size()):
		var stable_id := String(professions[i].id)
		if stable_id == "" or profession_index.has(stable_id) \
				or not plan_index.has(String(professions[i].default_consumption_plan_id)):
			return {"ok": false, "reason": "invalid profession: %s" % stable_id}
		profession_ids.append(stable_id)
		profession_class_ids.append(String(professions[i].profession_class_id))
		profession_index[stable_id] = i
		for tag in professions[i].technology_tags:
			var normalized := String(tag).strip_edges()
			if normalized == "":
				return {"ok": false, "reason": "empty profession technology tag: %s" % stable_id}
			profession_technology_tags.append(normalized)
		profession_technology_tag_offsets.append(profession_technology_tags.size())
		var normalized_semantic_tags := PackedStringArray()
		for tag in professions[i].semantic_tags:
			var normalized := String(tag).strip_edges()
			if normalized.is_empty() or normalized_semantic_tags.has(normalized):
				return {"ok": false, "reason": "invalid profession semantic tag: %s" % stable_id}
			normalized_semantic_tags.append(normalized)
		normalized_semantic_tags.sort()
		profession_semantic_tags.append_array(normalized_semantic_tags)
		profession_semantic_tag_offsets.append(profession_semantic_tags.size())

	var ethnicity_ids := PackedStringArray()
	var ethnicity_need_factor := PackedInt32Array()
	for ethnicity in ethnicities:
		var stable_id := String(ethnicity.id)
		if stable_id == "" or ethnicity_ids.has(stable_id) \
				or ethnicity.need_modifier_ids.size() != ethnicity.need_quantity_factors_q16.size():
			return {"ok": false, "reason": "invalid ethnicity: %s" % stable_id}
		ethnicity_ids.append(stable_id)
		var factors := PackedInt32Array()
		factors.resize(need_ids.size())
		factors.fill(Q16_ONE)
		for i in range(ethnicity.need_modifier_ids.size()):
			var need_id := String(ethnicity.need_modifier_ids[i])
			if not need_index.has(need_id):
				return {"ok": false, "reason": "ethnicity references missing need: %s" % need_id}
			factors[int(need_index[need_id])] = int(ethnicity.need_quantity_factors_q16[i])
		ethnicity_need_factor.append_array(factors)

	var signature_profession_ids := PackedInt32Array()
	var signature_ethnicity_ids := PackedInt32Array()
	var signature_plan_ids := PackedInt32Array()
	var signature_birth_rate_q32 := PackedInt64Array()
	var signature_death_rate_q32 := PackedInt64Array()
	var signature_satisfaction_birth_weight_q16 := PackedInt64Array()
	var signature_satisfaction_dimension_weights := PackedInt32Array()
	var signature_keys := PackedStringArray()
	for profession_idx in range(professions.size()):
		var profession = professions[profession_idx]
		var dimension_weights: PackedInt32Array = profession.satisfaction_dimension_weights_q16
		if not dimension_weights.is_empty() \
				and dimension_weights.size() != SATISFACTION_DIMENSION_COUNT:
			return {"ok": false, "reason":
				"profession satisfaction weight count mismatch: %s" % String(profession.id)}
		for weight in dimension_weights:
			if int(weight) < 0 or int(weight) > Q16_ONE:
				return {"ok": false, "reason":
					"invalid profession satisfaction weight: %s" % String(profession.id)}
		for ethnicity_idx in range(ethnicities.size()):
			var ethnicity = ethnicities[ethnicity_idx]
			signature_keys.append("%s|%s" % [String(profession.id), String(ethnicity.id)])
			signature_profession_ids.append(profession_idx)
			signature_ethnicity_ids.append(ethnicity_idx)
			signature_plan_ids.append(int(plan_index[String(profession.default_consumption_plan_id)]))
			signature_birth_rate_q32.append((int(profession.birth_rate_q32) * int(ethnicity.birth_rate_factor_q16)) / Q16_ONE)
			signature_death_rate_q32.append((int(profession.death_rate_q32) * int(ethnicity.death_rate_factor_q16)) / Q16_ONE)
			signature_satisfaction_birth_weight_q16.append(int(profession.satisfaction_birth_weight_q16))
			# An unauthored profession emits -1 in every slot; native substitutes
			# the profile-wide default rather than silently weighting nothing.
			if dimension_weights.is_empty():
				for _dimension in range(SATISFACTION_DIMENSION_COUNT):
					signature_satisfaction_dimension_weights.append(-1)
			else:
				signature_satisfaction_dimension_weights.append_array(dimension_weights)

	var catalog := {
		"profession_ids": profession_ids,
		"profession_class_ids": profession_class_ids,
		"profession_technology_tag_offsets": profession_technology_tag_offsets,
		"profession_technology_tags": profession_technology_tags,
		"profession_semantic_tag_offsets": profession_semantic_tag_offsets,
		"profession_semantic_tags": profession_semantic_tags,
		"ethnicity_ids": ethnicity_ids,
		"need_ids": need_ids,
		"need_living_cost_weights_q16": need_living_cost_weights,
		"need_satisfaction_tiers": need_satisfaction_tiers,
		"need_satisfaction_weights_q16": need_satisfaction_weights,
		"need_semantic_tag_offsets": need_semantic_tag_offsets,
		"need_semantic_tags": need_semantic_tags,
		"plan_ids": plan_ids,
		"environment_curve_ids": curve_ids,
		"environment_curve_signal_ids": curve_signal_ids,
		"environment_curve_values_q16": curve_values,
		"plan_need_offsets": plan_need_offsets,
		"need_stable_ids": need_stable_ids,
		"need_priorities": need_priorities,
		"need_base_qty_per_person": need_base_qty,
		"need_wealth_elasticity_q16": need_wealth_elasticity,
		"need_wealth_min_q16": need_wealth_min,
		"need_wealth_max_q16": need_wealth_max,
		"need_price_quantity_elasticity_q16": need_price_quantity_elasticity,
		"need_price_quantity_floor_q16": need_price_quantity_floor,
		"need_quantity_env_curve_ids": need_env_curve_ids,
		"need_variant_offsets": need_variant_offsets,
		"variant_preference_q16": variant_preference,
		"variant_price_elasticity_q16": variant_elasticity,
		"variant_preference_env_curve_ids": variant_env_curve_ids,
		"variant_component_offsets": variant_component_offsets,
		"component_good_ids": component_good_ids,
		"component_qty_per_need": component_qty,
		"ethnicity_need_factor_q16": ethnicity_need_factor,
		"signature_profession_ids": signature_profession_ids,
		"signature_ethnicity_ids": signature_ethnicity_ids,
		"signature_plan_ids": signature_plan_ids,
		"signature_birth_rate_q32": signature_birth_rate_q32,
		"signature_death_rate_q32": signature_death_rate_q32,
		"signature_satisfaction_birth_weight_q16": signature_satisfaction_birth_weight_q16,
		"signature_satisfaction_dimension_weights_q16":
			signature_satisfaction_dimension_weights,
		"satisfaction_dimension_count": SATISFACTION_DIMENSION_COUNT,
		"signature_keys": signature_keys,
	}
	for key in good_columns:
		catalog[key] = good_columns[key]
	var market_v10_columns := catalog.duplicate(true)
	market_v10_columns.erase("good_trade_enabled")
	market_v10_columns.erase("good_transport_load_per_unit_q16")
	var market_v10_v8_columns := market_v10_columns.duplicate(true)
	market_v10_v8_columns.erase("profession_technology_tag_offsets")
	market_v10_v8_columns.erase("profession_technology_tags")
	var market_v10_v7_columns := market_v10_v8_columns.duplicate(true)
	market_v10_v7_columns.erase("need_living_cost_weights_q16")
	var market_v10_v6_columns := market_v10_v7_columns.duplicate(true)
	for key in [
		"good_excess_demand_weight_q16", "good_cost_anchor_weight_q16",
		"good_inactive_reversion_weight_q16", "good_business_demand_ema_alpha_q16",
		"good_supply_ema_alpha_q16", "good_cost_ema_alpha_q16",
	]:
		market_v10_v6_columns.erase(key)
	var market_v8_columns := catalog.duplicate(true)
	market_v8_columns.erase("profession_technology_tag_offsets")
	market_v8_columns.erase("profession_technology_tags")
	var market_v7_columns := market_v8_columns.duplicate(true)
	market_v7_columns.erase("need_living_cost_weights_q16")
	var market_v6_columns := market_v7_columns.duplicate(true)
	for key in [
		"good_excess_demand_weight_q16", "good_cost_anchor_weight_q16",
		"good_inactive_reversion_weight_q16", "good_business_demand_ema_alpha_q16",
		"good_supply_ema_alpha_q16", "good_cost_ema_alpha_q16",
	]:
		market_v6_columns.erase(key)
	var market_compat_hash_v6 := _catalog_hash(market_v6_columns)
	catalog["market_catalog_hash"] = _catalog_hash(catalog)
	catalog["market_catalog_compat_hash_v8"] = _catalog_hash(market_v8_columns)
	var building_columns := _compile_building_columns(
		profession_index, good_index, good_columns.good_storage_modes,
		good_columns.good_substitution_category_offsets,
		good_columns.good_substitution_category_ids,
		good_columns.good_production_quality_levels,
		good_columns.good_production_efficiency_q16)
	if not bool(building_columns.get("ok", false)):
		return building_columns
	building_columns.erase("ok")
	var technology_catalog: Dictionary = TechnologyCatalogScript.compile_native_catalog()
	if not bool(technology_catalog.get("ok", false)):
		return technology_catalog
	var technology_ids: PackedStringArray = technology_catalog.technology_ids
	var technology_set := {}
	for technology_id in technology_ids:
		technology_set[String(technology_id)] = true
	for tag in good_columns.good_technology_tags:
		if String(tag).begins_with("tech."):
			if not technology_set.has(String(tag)):
				return {"ok": false, "reason": "unknown good technology tag: %s" % String(tag)}
	for tag in profession_technology_tags:
		if String(tag).begins_with("tech."):
			if not technology_set.has(String(tag)):
				return {"ok": false, "reason": "unknown profession technology tag: %s" % String(tag)}
	for tag in building_columns.building_technology_tags:
		if String(tag).begins_with("tech."):
			if not technology_set.has(String(tag)):
				return {"ok": false, "reason": "unknown building technology tag: %s" % String(tag)}
	for resource in ResourceRegistryScript.ordered():
		for tag in resource.discovery_technology_tags:
			var normalized := String(tag).strip_edges()
			if normalized == "":
				return {"ok": false, "reason": "empty resource discovery technology tag: %s" % String(resource.id)}
			if normalized.begins_with("tech.") and not technology_set.has(normalized):
				return {"ok": false, "reason": "unknown resource technology tag: %s" % normalized}
	for key in technology_catalog:
		if key != "ok":
			catalog[key] = technology_catalog[key]
	var building_v7_columns := building_columns.duplicate(true)
	for key in [
		"building_upgrade_family_ids", "building_upgrade_family_indices",
		"building_upgrade_tiers", "building_input_required_q16",
		"building_input_category_ids", "building_input_min_quality_levels",
		"building_input_candidate_offsets",
		"building_input_candidate_good_ids", "building_input_candidate_efficiency_q16",
	]:
		building_v7_columns.erase(key)
	building_v7_columns.erase("building_employee_wage_policies")
	building_v7_columns.erase("building_employee_reference_wages_per_day")
	var building_v6_columns := building_v7_columns.duplicate(true)
	for key in [
		"building_target_operating_margin_q16", "building_supply_price_elasticity_q16",
		"building_output_cost_share_offsets", "building_output_cost_shares_q16",
	]:
		building_v6_columns.erase(key)
	catalog["building_catalog_hash"] = _catalog_hash(building_columns)
	var building_v13_columns := building_columns.duplicate(true)
	for key in [
		"building_resource_gen_base", "building_resource_gen_temp",
		"building_resource_gen_moisture", "building_resource_gen_self",
		"building_resource_decay_base", "building_resource_decay_temp",
		"building_resource_decay_moisture", "building_resource_decay_self_q16",
		"building_resource_ecology_capacity", "building_resource_ecology_growth_q16",
		"building_resource_temp_lo_q16", "building_resource_temp_hi_q16",
	]:
		building_v13_columns.erase(key)
	var building_compat_hash_v13 := _catalog_hash(building_v13_columns)
	catalog["market_catalog_compat_hash_v6"] = market_compat_hash_v6
	catalog["market_catalog_compat_hash_v7"] = _catalog_hash(market_v7_columns)
	catalog["building_catalog_compat_hash_v6"] = _catalog_hash(building_v6_columns)
	catalog["building_catalog_compat_hash_v7"] = _catalog_hash(building_v7_columns)
	for key in building_columns:
		catalog[key] = building_columns[key]
	var catalog_v13 := catalog.duplicate(true)
	for key in building_columns:
		if not building_v13_columns.has(key):
			catalog_v13.erase(key)
	catalog_v13["building_catalog_hash"] = building_compat_hash_v13
	catalog["building_catalog_compat_hash_v13"] = building_compat_hash_v13
	catalog["catalog_compat_hash_v13"] = _catalog_hash(catalog_v13)
	var catalog_v10 := catalog.duplicate(true)
	catalog_v10.erase("good_trade_enabled")
	catalog_v10.erase("good_transport_load_per_unit_q16")
	catalog_v10["market_catalog_hash"] = _catalog_hash(market_v10_columns)
	catalog_v10["market_catalog_compat_hash_v8"] = _catalog_hash(market_v10_v8_columns)
	catalog_v10["market_catalog_compat_hash_v7"] = _catalog_hash(market_v10_v7_columns)
	catalog_v10["market_catalog_compat_hash_v6"] = _catalog_hash(market_v10_v6_columns)
	catalog["catalog_compat_hash_v10"] = _catalog_hash(catalog_v10)
	catalog["catalog_hash"] = _catalog_hash(catalog)
	var settlement_profile = load(DEFAULT_SETTLEMENT_PROFILE_PATH)
	if settlement_profile == null or not settlement_profile.has_method("compile_native_columns"):
		return {"ok": false, "reason": "default settlement profile is unavailable"}
	var settlement_columns: Dictionary = settlement_profile.compile_native_columns()
	if not bool(settlement_columns.get("ok", false)):
		return settlement_columns
	for key in settlement_columns:
		if key != "ok":
			catalog[key] = settlement_columns[key]
	var family_pack = load(DEFAULT_FAMILY_SURNAME_PACK_PATH)
	if family_pack == null or not family_pack.has_method("compile_native_columns"):
		return {"ok": false, "reason": "default family surname pack is unavailable"}
	var family_columns: Dictionary = family_pack.compile_native_columns()
	if not bool(family_columns.get("ok", false)):
		return family_columns
	for key in family_columns:
		if key != "ok":
			catalog[key] = family_columns[key]
	var person_pack = load(DEFAULT_PERSON_GIVEN_NAME_PACK_PATH)
	if person_pack == null or not person_pack.has_method("compile_native_columns"):
		return {"ok": false, "reason": "default person given-name pack is unavailable"}
	var person_columns: Dictionary = person_pack.compile_native_columns()
	if not bool(person_columns.get("ok", false)):
		return person_columns
	for key in person_columns:
		if key != "ok":
			catalog[key] = person_columns[key]
	var trait_catalog = load(DEFAULT_FAMILY_TRAIT_CATALOG_PATH)
	if trait_catalog == null or not trait_catalog is FamilyTraitCatalogScript:
		return {"ok": false, "reason": "default family trait catalog is unavailable"}
	var trait_columns: Dictionary = trait_catalog.compile_native_columns(catalog)
	if not bool(trait_columns.get("ok", false)):
		return trait_columns
	for key in trait_columns:
		if key != "ok":
			catalog[key] = trait_columns[key]
	# Family trait semantics participate in the final economy identity. The
	# earlier hash remains useful only for explicit legacy readers.
	catalog["catalog_hash"] = _catalog_hash(catalog)
	catalog["ok"] = true
	return catalog


static func need_display_names() -> Dictionary:
	var names := {}
	for need in _load_resources(NEED_DIR):
		var stable_id := String(need.id)
		if stable_id == "":
			continue
		var display_name := String(need.display_name)
		names[stable_id] = display_name if display_name != "" else stable_id
	return names

static func _compile_building_columns(profession_index: Dictionary,
		good_index: Dictionary, good_storage_modes: PackedInt32Array,
		good_substitution_category_offsets: PackedInt32Array,
		good_substitution_category_ids: PackedStringArray,
		good_quality_levels: PackedInt32Array,
		good_efficiencies_q16: PackedInt32Array) -> Dictionary:
	var profiles := _load_resources(BUILDING_DIR)
	var climate_profiles := _load_resources(PRODUCTION_CLIMATE_DIR)
	var climate_profile_ids := PackedStringArray()
	var climate_temperature_opt_q16 := PackedInt32Array()
	var climate_temperature_tolerance_q16 := PackedInt32Array()
	var climate_water_opt_q16 := PackedInt32Array()
	var climate_water_tolerance_q16 := PackedInt32Array()
	var climate_exposure_q16 := PackedInt32Array()
	var climate_floor_q16 := PackedInt32Array()
	var climate_profile_index := {}
	for climate in climate_profiles:
		var climate_id := String(climate.id).strip_edges()
		if climate_id == "" or climate_profile_index.has(climate_id) \
				or float(climate.temperature_opt) < 0.0 or float(climate.temperature_opt) > 1.0 \
				or float(climate.water_opt) < 0.0 or float(climate.water_opt) > 1.0 \
				or float(climate.temperature_tolerance) <= 0.0 \
				or float(climate.temperature_tolerance) > 1.0 \
				or float(climate.water_tolerance) <= 0.0 \
				or float(climate.water_tolerance) > 1.0 \
				or int(climate.exposure_q16) < 0 or int(climate.exposure_q16) > Q16_ONE \
				or int(climate.floor_q16) < 0 or int(climate.floor_q16) > Q16_ONE:
			return {"ok": false, "reason": "invalid production climate profile: %s" % climate_id}
		climate_profile_index[climate_id] = climate_profile_ids.size()
		climate_profile_ids.append(climate_id)
		climate_temperature_opt_q16.append(roundi(float(climate.temperature_opt) * Q16_ONE))
		climate_temperature_tolerance_q16.append(roundi(float(climate.temperature_tolerance) * Q16_ONE))
		climate_water_opt_q16.append(roundi(float(climate.water_opt) * Q16_ONE))
		climate_water_tolerance_q16.append(roundi(float(climate.water_tolerance) * Q16_ONE))
		climate_exposure_q16.append(int(climate.exposure_q16))
		climate_floor_q16.append(int(climate.floor_q16))
	var good_count := good_quality_levels.size()
	if good_efficiencies_q16.size() != good_count \
			or good_substitution_category_offsets.size() != good_count + 1 \
			or good_substitution_category_offsets[0] != 0 \
			or good_substitution_category_offsets[-1] != good_substitution_category_ids.size():
		return {"ok": false, "reason": "good substitution category columns mismatch"}
	var category_good_indices := {}
	for good_idx in range(good_count):
		var begin := int(good_substitution_category_offsets[good_idx])
		var end := int(good_substitution_category_offsets[good_idx + 1])
		if begin < 0 or end <= begin or end > good_substitution_category_ids.size():
			return {"ok": false, "reason": "good substitution category offsets invalid"}
		for category_edge in range(begin, end):
			var category_id := String(good_substitution_category_ids[category_edge])
			if category_id == "":
				return {"ok": false, "reason": "empty good substitution category"}
			if not category_good_indices.has(category_id):
				category_good_indices[category_id] = PackedInt32Array()
			var members: PackedInt32Array = category_good_indices[category_id]
			members.append(good_idx)
			category_good_indices[category_id] = members
	var used_resource_ids := {}
	for profile in profiles:
		for resource_id in profile.resource_ids:
			used_resource_ids[String(resource_id)] = true
		for resource_id in profile.resource_generation_ids:
			used_resource_ids[String(resource_id)] = true
		for i in range(profile.condition_signals.size()):
			if int(profile.condition_signals[i]) == 10 and i < profile.condition_reference_ids.size():
				used_resource_ids[String(profile.condition_reference_ids[i])] = true
	var resources: Array = ResourceRegistryScript.ordered().duplicate()
	resources.sort_custom(func(a, b) -> bool: return String(a.id) < String(b.id))
	var resource_ids := PackedStringArray()
	var resource_reserve_slots := PackedStringArray()
	var resource_extra_slots := PackedStringArray()
	var resource_index := {}
	var resource_gen_base := PackedInt64Array()
	var resource_gen_temp := PackedInt64Array()
	var resource_gen_moisture := PackedInt64Array()
	var resource_gen_self := PackedInt64Array()
	var resource_decay_base := PackedInt64Array()
	var resource_decay_temp := PackedInt64Array()
	var resource_decay_moisture := PackedInt64Array()
	var resource_decay_self_q16 := PackedInt32Array()
	var resource_ecology_capacity := PackedInt64Array()
	var resource_ecology_growth_q16 := PackedInt32Array()
	var resource_temp_lo_q16 := PackedInt32Array()
	var resource_temp_hi_q16 := PackedInt32Array()
	var resource_semantic_tag_offsets := PackedInt32Array([0])
	var resource_semantic_tags := PackedStringArray()
	for resource in resources:
		var stable_id := String(resource.id)
		if not used_resource_ids.has(stable_id):
			continue
		var reserve_slot: String = ResourceRegistryScript.reserve_cpp_name(resource)
		var extra_slot: String = ResourceRegistryScript.extra_change_cpp_name(resource)
		if stable_id == "" or reserve_slot == "" or extra_slot == "" or resource_index.has(stable_id):
			return {"ok": false, "reason": "invalid building resource: %s" % stable_id}
		resource_index[stable_id] = resource_ids.size()
		resource_ids.append(stable_id)
		resource_reserve_slots.append(reserve_slot)
		resource_extra_slots.append(extra_slot)
		var quantity_scale := ResourceRegistryScript.CELL_AREA_RESOURCE_SCALE * 1000.0
		resource_gen_base.append(roundi(float(resource.gen_base) * quantity_scale))
		resource_gen_temp.append(roundi(float(resource.gen_temp) * quantity_scale))
		resource_gen_moisture.append(roundi(float(resource.gen_moisture) * quantity_scale))
		resource_gen_self.append(roundi(float(resource.gen_self) * quantity_scale))
		resource_decay_base.append(roundi(float(resource.decay_base) * quantity_scale))
		resource_decay_temp.append(roundi(float(resource.decay_temp) * quantity_scale))
		resource_decay_moisture.append(roundi(float(resource.decay_moisture) * quantity_scale))
		resource_decay_self_q16.append(roundi(float(resource.decay_self) * Q16_ONE))
		resource_ecology_capacity.append(roundi(float(resource.ecology_capacity) * quantity_scale))
		resource_ecology_growth_q16.append(roundi(float(resource.ecology_growth_rate) * Q16_ONE))
		resource_temp_lo_q16.append(roundi(float(resource.temp_lo) * Q16_ONE))
		resource_temp_hi_q16.append(roundi(float(resource.temp_hi) * Q16_ONE))
		var normalized_resource_tags := PackedStringArray()
		for tag in resource.semantic_tags:
			var normalized := String(tag).strip_edges()
			if normalized.is_empty() or normalized_resource_tags.has(normalized):
				return {"ok": false, "reason": "invalid resource semantic tag: %s" % stable_id}
			normalized_resource_tags.append(normalized)
		normalized_resource_tags.sort()
		resource_semantic_tags.append_array(normalized_resource_tags)
		resource_semantic_tag_offsets.append(resource_semantic_tags.size())

	var type_ids := PackedStringArray()
	var owner_professions := PackedInt32Array()
	var owner_slots := PackedInt64Array()
	var wages_per_employee_per_day := PackedInt64Array()
	var construction_days := PackedInt32Array()
	var behavior_ids := PackedInt32Array()
	var behavior_versions := PackedInt32Array()
	var target_operating_margins := PackedInt32Array()
	var supply_price_elasticities := PackedInt32Array()
	var building_kinds := PackedInt32Array()
	var building_economic_sectors := PackedInt32Array()
	var building_climate_profile_indices := PackedInt32Array()
	var technology_tag_offsets := PackedInt32Array([0])
	var technology_tags := PackedStringArray()
	var semantic_tag_offsets := PackedInt32Array([0])
	var semantic_tags := PackedStringArray()
	var upgrade_family_set := {}
	for profile in profiles:
		var family_id := String(profile.upgrade_family_id).strip_edges()
		if family_id != "":
			upgrade_family_set[family_id] = true
	var upgrade_family_ids := PackedStringArray(upgrade_family_set.keys())
	upgrade_family_ids.sort()
	var upgrade_family_indices := PackedInt32Array()
	var upgrade_tiers := PackedInt32Array()
	var used_upgrade_tiers := {}
	var employee_offsets := PackedInt32Array([0])
	var employee_professions := PackedInt32Array()
	var employee_slot_counts := PackedInt64Array()
	var employee_wage_policies := PackedInt32Array()
	var employee_reference_wages := PackedInt64Array()
	var construction_offsets := PackedInt32Array([0])
	var construction_goods := PackedInt32Array()
	var construction_quantities := PackedInt64Array()
	var input_offsets := PackedInt32Array([0])
	var input_goods := PackedInt32Array()
	var input_quantities := PackedInt64Array()
	var input_required_q16 := PackedInt32Array()
	var input_category_ids := PackedStringArray()
	var input_min_quality_levels := PackedInt32Array()
	var input_candidate_offsets := PackedInt32Array([0])
	var input_candidate_goods := PackedInt32Array()
	var input_candidate_efficiencies := PackedInt32Array()
	var output_offsets := PackedInt32Array([0])
	var output_goods := PackedInt32Array()
	var output_quantities := PackedInt64Array()
	var output_cost_share_offsets := PackedInt32Array([0])
	var output_cost_shares := PackedInt32Array()
	var production_resource_offsets := PackedInt32Array([0])
	var production_resources := PackedInt32Array()
	var production_resource_quantities := PackedInt64Array()
	var production_resource_modes := PackedInt32Array()
	var production_resource_access_modes := PackedInt32Array()
	var generation_resource_offsets := PackedInt32Array([0])
	var generation_resources := PackedInt32Array()
	var generation_resource_quantities := PackedInt64Array()
	var generation_floor_q16 := PackedInt32Array()
	var condition_offsets := PackedInt32Array([0])
	var condition_opcodes := PackedInt32Array()
	var condition_signals := PackedInt32Array()
	var condition_compares := PackedInt32Array()
	var condition_references := PackedInt32Array()
	var condition_values := PackedInt64Array()

	for profile in profiles:
		var stable_id := String(profile.id)
		var owner_id := String(profile.owner_profession_id)
		if stable_id == "" or type_ids.has(stable_id) or not profession_index.has(owner_id) \
				or owner_id == UNEMPLOYED_PROFESSION_ID \
				or int(profile.owner_slots_per_building) <= 0 or int(profile.construction_days) < 0:
			return {"ok": false, "reason": "invalid building type: %s" % stable_id}
		var building_kind := String(profile.building_kind)
		if building_kind not in ["collector", "industrial", "service"]:
			return {"ok": false, "reason": "invalid building kind: %s" % stable_id}
		building_kinds.append(0 if building_kind == "collector" \
			else (2 if building_kind == "service" else 1))
		var tags_text := ""
		for tag in profile.technology_tags:
			tags_text += " " + String(tag)
		var sector := 2
		if String(profile.upgrade_family_id) == "research_institution" \
				or tags_text.contains("knowledge"):
			sector = 4
		elif building_kind == "collector":
			sector = 1
		elif tags_text.contains("agriculture") or tags_text.contains("food") \
				or stable_id.contains("farm"):
			sector = 0
		elif tags_text.contains("energy") or tags_text.contains("electric") \
				or stable_id.contains("power") or stable_id.contains("fuel"):
			sector = 3
		building_economic_sectors.append(sector)
		var climate_id := String(profile.production_climate_profile_id).strip_edges()
		if climate_id != "" and not climate_profile_index.has(climate_id):
			return {"ok": false, "reason": "missing production climate profile: %s" % climate_id}
		building_climate_profile_indices.append(int(climate_profile_index.get(climate_id, -1)))
		var upgrade_family_id := String(profile.upgrade_family_id).strip_edges()
		var upgrade_tier := int(profile.upgrade_tier)
		if (upgrade_family_id == "" and upgrade_tier != 0) \
				or (upgrade_family_id != "" and upgrade_tier <= 0):
			return {"ok": false, "reason": "invalid building upgrade tier: %s" % stable_id}
		var upgrade_family_idx := upgrade_family_ids.find(upgrade_family_id) \
			if upgrade_family_id != "" else -1
		var upgrade_key := "%d:%d" % [upgrade_family_idx, upgrade_tier]
		if upgrade_family_idx >= 0 and used_upgrade_tiers.has(upgrade_key):
			return {"ok": false, "reason": "duplicate building upgrade tier: %s" % stable_id}
		if upgrade_family_idx >= 0:
			used_upgrade_tiers[upgrade_key] = true
		upgrade_family_indices.append(upgrade_family_idx)
		upgrade_tiers.append(upgrade_tier)
		for tag in profile.technology_tags:
			if String(tag).strip_edges() == "":
				return {"ok": false, "reason": "empty building technology tag: %s" % stable_id}
			technology_tags.append(String(tag))
		technology_tag_offsets.append(technology_tags.size())
		var normalized_building_tags := PackedStringArray()
		for tag in profile.semantic_tags:
			var normalized := String(tag).strip_edges()
			if normalized.is_empty() or normalized_building_tags.has(normalized):
				return {"ok": false, "reason": "invalid building semantic tag: %s" % stable_id}
			normalized_building_tags.append(normalized)
		normalized_building_tags.sort()
		semantic_tags.append_array(normalized_building_tags)
		semantic_tag_offsets.append(semantic_tags.size())
		var wage_policy := String(profile.wage_policy_id)
		var wage_per_employee := int(profile.wage_per_employee_per_day)
		if wage_policy not in ["none", "fixed", "adaptive"]:
			return {"ok": false, "reason": "unsupported building wage policy: %s" % stable_id}
		if wage_per_employee < 0 or (wage_policy == "none" and wage_per_employee != 0):
			return {"ok": false, "reason": "invalid building wage: %s" % stable_id}
		type_ids.append(stable_id)
		owner_professions.append(int(profession_index[owner_id]))
		owner_slots.append(int(profile.owner_slots_per_building))
		wages_per_employee_per_day.append(wage_per_employee if wage_policy != "none" else 0)
		construction_days.append(int(profile.construction_days))
		var behavior_id := String(profile.behavior_id)
		if behavior_id not in ["none", "consume_local_resources", "cultivate_local_resources"]:
			return {"ok": false, "reason": "unsupported building behavior: %s" % stable_id}
		behavior_ids.append(2 if behavior_id == "cultivate_local_resources" else (
			1 if behavior_id == "consume_local_resources" else 0))
		behavior_versions.append(int(profile.behavior_version))
		var target_margin := int(profile.target_operating_margin_q16)
		var supply_elasticity := int(profile.supply_price_elasticity_q16)
		if target_margin < 0 or target_margin > 262144 \
				or supply_elasticity < 0 or supply_elasticity > 262144:
			return {"ok": false, "reason": "invalid building price response: %s" % stable_id}
		target_operating_margins.append(target_margin)
		supply_price_elasticities.append(supply_elasticity)
		var generation_floor := int(profile.resource_generation_floor_q16)
		if generation_floor < 0 or generation_floor > Q16_ONE:
			return {"ok": false, "reason": "invalid building resource generation floor: %s" % stable_id}
		generation_floor_q16.append(generation_floor)

		var role_ids: PackedStringArray = profile.employee_profession_ids
		var role_slots: PackedInt64Array = profile.employee_slots_per_building
		var role_wage_policies: PackedStringArray = profile.employee_wage_policy_ids
		var role_reference_wages: PackedInt64Array = profile.employee_reference_wages_per_day
		if role_ids.size() != role_slots.size():
			return {"ok": false, "reason": "building employee columns mismatch: %s" % stable_id}
		if not role_wage_policies.is_empty() and role_wage_policies.size() != role_ids.size():
			return {"ok": false, "reason": "building role wage policies mismatch: %s" % stable_id}
		if not role_reference_wages.is_empty() and role_reference_wages.size() != role_ids.size():
			return {"ok": false, "reason": "building role reference wages mismatch: %s" % stable_id}
		if not role_ids.is_empty() and role_wage_policies.is_empty() \
				and (wage_policy == "none" or wage_per_employee <= 0):
			return {"ok": false, "reason": "employee building requires wage policy: %s" % stable_id}
		for i in range(role_ids.size()):
			var profession_id := String(role_ids[i])
			var role_policy := String(role_wage_policies[i]) if not role_wage_policies.is_empty() else wage_policy
			var role_reference := int(role_reference_wages[i]) if not role_reference_wages.is_empty() else wage_per_employee
			if not profession_index.has(profession_id) or int(role_slots[i]) <= 0 \
					or profession_id == UNEMPLOYED_PROFESSION_ID \
					or role_policy not in ["none", "fixed", "adaptive"] \
					or role_reference < 0 or (role_policy != "none" and role_reference <= 0):
				return {"ok": false, "reason": "invalid building employee role: %s" % stable_id}
			employee_professions.append(int(profession_index[profession_id]))
			employee_slot_counts.append(int(role_slots[i]))
			employee_wage_policies.append(0 if role_policy == "none" else (1 if role_policy == "fixed" else 2))
			employee_reference_wages.append(role_reference)
		employee_offsets.append(employee_professions.size())

		if profile.construction_good_ids.is_empty():
			return {"ok": false, "reason": "building requires explicit construction goods: %s" % stable_id}
		var error := _append_building_goods(profile.construction_good_ids,
			profile.construction_quantities, good_index, construction_goods,
			construction_quantities)
		if error != "": return {"ok": false, "reason": "%s: %s" % [error, stable_id]}
		construction_offsets.append(construction_goods.size())
		error = _append_building_goods(profile.input_good_ids,
			profile.input_quantities_per_day, good_index, input_goods, input_quantities)
		if error != "": return {"ok": false, "reason": "%s: %s" % [error, stable_id]}
		var configured_required: PackedInt32Array = profile.input_required_q16
		if not configured_required.is_empty() and configured_required.size() != profile.input_good_ids.size():
			return {"ok": false, "reason": "building input required columns mismatch: %s" % stable_id}
		var configured_categories: PackedStringArray = profile.input_category_ids
		var configured_min_levels: PackedInt32Array = profile.input_min_quality_levels
		var explicit_offsets: PackedInt32Array = profile.input_candidate_offsets
		var explicit_good_ids: PackedStringArray = profile.input_candidate_good_ids
		var explicit_efficiencies: PackedInt32Array = profile.input_candidate_efficiency_q16
		if not configured_categories.is_empty() and configured_categories.size() != profile.input_good_ids.size():
			return {"ok": false, "reason": "building input category columns mismatch: %s" % stable_id}
		if not configured_min_levels.is_empty() and configured_min_levels.size() != profile.input_good_ids.size():
			return {"ok": false, "reason": "building input quality columns mismatch: %s" % stable_id}
		var explicit_candidate_error := _validate_explicit_input_candidates(profile, good_index)
		if explicit_candidate_error != "":
			return {"ok": false, "reason": "%s: %s" % [explicit_candidate_error, stable_id]}
		var has_explicit_candidates := explicit_offsets.size() > 1 \
			or not explicit_good_ids.is_empty() or not explicit_efficiencies.is_empty()
		for input_idx in range(profile.input_good_ids.size()):
			var required_q16 := int(configured_required[input_idx]) if not configured_required.is_empty() else Q16_ONE
			var category_id := String(configured_categories[input_idx]) if not configured_categories.is_empty() else ""
			var min_level := int(configured_min_levels[input_idx]) if not configured_min_levels.is_empty() else 0
			if required_q16 < 0 or required_q16 > Q16_ONE:
				return {"ok": false, "reason": "invalid building input required q16: %s" % stable_id}
			if min_level < 0:
				return {"ok": false, "reason": "negative building input quality: %s" % stable_id}
			input_required_q16.append(required_q16)
			input_category_ids.append(category_id)
			input_min_quality_levels.append(min_level)
			var explicit_begin := int(explicit_offsets[input_idx]) if has_explicit_candidates else 0
			var explicit_end := int(explicit_offsets[input_idx + 1]) if has_explicit_candidates else 0
			if explicit_end > explicit_begin:
				var sorted_candidates: Array[Dictionary] = []
				for candidate_idx in range(explicit_begin, explicit_end):
					var candidate_id := String(explicit_good_ids[candidate_idx])
					var efficiency := int(explicit_efficiencies[candidate_idx])
					sorted_candidates.append({"id": candidate_id, "efficiency": efficiency})
				sorted_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
					return String(a.id) < String(b.id))
				for candidate in sorted_candidates:
					input_candidate_goods.append(int(good_index[String(candidate.id)]))
					input_candidate_efficiencies.append(int(candidate.efficiency))
			elif category_id == "":
				input_candidate_goods.append(int(good_index[String(profile.input_good_ids[input_idx])]))
				input_candidate_efficiencies.append(Q16_ONE)
			else:
				var category_members: PackedInt32Array = category_good_indices.get(
					category_id, PackedInt32Array())
				for good_idx in category_members:
					if int(good_quality_levels[good_idx]) >= min_level:
						input_candidate_goods.append(good_idx)
						input_candidate_efficiencies.append(int(good_efficiencies_q16[good_idx]))
				if input_candidate_offsets[-1] == input_candidate_goods.size():
					return {"ok": false, "reason": "building input category has no candidates: %s" % stable_id}
			input_candidate_offsets.append(input_candidate_goods.size())
		input_offsets.append(input_goods.size())
		error = _append_building_goods(profile.output_good_ids,
			profile.output_quantities_per_day, good_index, output_goods, output_quantities)
		if error != "": return {"ok": false, "reason": "%s: %s" % [error, stable_id]}
		output_offsets.append(output_goods.size())
		var configured_cost_shares: PackedInt32Array = profile.output_cost_shares_q16
		if not configured_cost_shares.is_empty():
			if configured_cost_shares.size() != profile.output_good_ids.size():
				return {"ok": false, "reason": "building output cost shares mismatch: %s" % stable_id}
			var share_total := 0
			for share in configured_cost_shares:
				if int(share) < 0:
					return {"ok": false, "reason": "negative building output cost share: %s" % stable_id}
				share_total += int(share)
				output_cost_shares.append(int(share))
			if share_total != Q16_ONE:
				return {"ok": false, "reason": "building output cost shares must sum to Q16: %s" % stable_id}
		output_cost_share_offsets.append(output_cost_shares.size())
		if building_kind == "service":
			if not profile.output_good_ids.is_empty():
				return {"ok": false, "reason": "service building must have no output: %s" % stable_id}
		elif profile.output_good_ids.is_empty():
			return {"ok": false, "reason": "building has no output: %s" % stable_id}
		var produces_cycle_flow := false
		var consumes_cycle_flow := false
		for good_id in profile.output_good_ids:
			produces_cycle_flow = produces_cycle_flow or int(
				good_storage_modes[int(good_index[String(good_id)])]) == 1
		for good_id in profile.input_good_ids:
			consumes_cycle_flow = consumes_cycle_flow or int(
				good_storage_modes[int(good_index[String(good_id)])]) == 1
		if produces_cycle_flow and consumes_cycle_flow:
			return {"ok": false, "reason": "cycle-flow producer consumes cycle flow: %s" % stable_id}

		var prod_ids: PackedStringArray = profile.resource_ids
		var prod_qty: PackedInt64Array = profile.resource_quantities_per_day
		var prod_modes: PackedStringArray = profile.resource_interaction_modes
		var prod_access: PackedStringArray = profile.resource_access_modes
		if prod_ids.size() != prod_qty.size() or prod_ids.size() != prod_modes.size() \
				or prod_ids.size() != prod_access.size():
			return {"ok": false, "reason": "building resource columns mismatch: %s" % stable_id}
		for i in range(prod_ids.size()):
			var resource_id := String(prod_ids[i])
			var interaction_mode := String(prod_modes[i])
			var access_mode := String(prod_access[i])
			if not resource_index.has(resource_id) or int(prod_qty[i]) <= 0 \
					or interaction_mode not in ["extract", "capacity"] \
					or access_mode != "local":
				return {"ok": false, "reason": "invalid building production resource: %s" % stable_id}
			production_resources.append(int(resource_index[resource_id]))
			production_resource_quantities.append(int(prod_qty[i]))
			production_resource_modes.append(0 if interaction_mode == "extract" else 1)
			production_resource_access_modes.append(0)
		production_resource_offsets.append(production_resources.size())
		if owner_id == "merchant":
			# Route B: a merchant may own either a matching bullion collector
			# (gold/silver) or a service "merchant post" (no output/resource).
			var merchant_service_valid: bool = building_kind == "service" \
				and behavior_id == "none" \
				and profile.output_good_ids.is_empty() and prod_ids.is_empty() \
				and profile.resource_generation_ids.is_empty()
			var merchant_bullion_valid: bool = building_kind == "collector" \
				and behavior_id == "consume_local_resources" \
				and profile.output_good_ids.size() == 1 and prod_ids.size() == 1 \
				and String(prod_modes[0]) == "extract" \
				and profile.resource_generation_ids.is_empty()
			if merchant_bullion_valid:
				var bullion_id := String(profile.output_good_ids[0])
				merchant_bullion_valid = (bullion_id == "gold" and String(prod_ids[0]) == "gold_ore") \
					or (bullion_id == "silver" and String(prod_ids[0]) == "silver_ore")
			if not merchant_bullion_valid and not merchant_service_valid:
				return {"ok": false, "reason": "merchant may only own matching bullion collector or service post: %s" % stable_id}
		if building_kind == "collector" and prod_ids.is_empty():
			return {"ok": false, "reason": "collector requires natural resource: %s" % stable_id}
		if building_kind != "collector" and not prod_ids.is_empty():
			return {"ok": false, "reason": "non-collector building cannot consume natural resource: %s" % stable_id}
		if building_kind == "collector" and behavior_id == "none":
			return {"ok": false, "reason": "collector requires resource behavior: %s" % stable_id}
		if building_kind == "industrial" and behavior_id != "none":
			return {"ok": false, "reason": "industrial building cannot use resource behavior: %s" % stable_id}
		if building_kind == "service" and behavior_id != "none":
			return {"ok": false, "reason": "service building cannot use resource behavior: %s" % stable_id}
		var generation_ids: PackedStringArray = profile.resource_generation_ids
		var generation_qty: PackedInt64Array = profile.resource_generation_quantities_per_day
		if generation_ids.size() != generation_qty.size():
			return {"ok": false, "reason": "building resource generation columns mismatch: %s" % stable_id}
		if behavior_id != "cultivate_local_resources" and not generation_ids.is_empty():
			return {"ok": false, "reason": "building resource generation requires cultivation behavior: %s" % stable_id}
		if behavior_id == "cultivate_local_resources" and generation_ids.is_empty():
			return {"ok": false, "reason": "cultivation behavior requires resource generation: %s" % stable_id}
		for i in range(generation_ids.size()):
			var resource_id := String(generation_ids[i])
			if not resource_index.has(resource_id) or int(generation_qty[i]) <= 0:
				return {"ok": false, "reason": "invalid building generated resource: %s" % stable_id}
			generation_resources.append(int(resource_index[resource_id]))
			generation_resource_quantities.append(int(generation_qty[i]))
		generation_resource_offsets.append(generation_resources.size())

		var ops: PackedInt32Array = profile.condition_opcodes
		var signals: PackedInt32Array = profile.condition_signals
		var compares: PackedInt32Array = profile.condition_compares
		var refs: PackedStringArray = profile.condition_reference_ids
		var values: PackedInt64Array = profile.condition_values
		if ops.size() != signals.size() or ops.size() != compares.size() \
				or ops.size() != refs.size() or ops.size() != values.size():
			return {"ok": false, "reason": "building condition columns mismatch: %s" % stable_id}
		var depth := 0
		for i in range(ops.size()):
			var opcode := int(ops[i])
			if opcode == 1:
				depth += 1
			elif opcode == 4:
				if depth < 1: return {"ok": false, "reason": "building condition stack underflow: %s" % stable_id}
			elif opcode == 2 or opcode == 3:
				if depth < 2: return {"ok": false, "reason": "building condition stack underflow: %s" % stable_id}
				depth -= 1
			else:
				return {"ok": false, "reason": "building condition opcode invalid: %s" % stable_id}
			var reference := -1
			if int(signals[i]) == 10:
				var ref_id := String(refs[i])
				if not resource_index.has(ref_id):
					return {"ok": false, "reason": "building condition resource missing: %s" % stable_id}
				reference = int(resource_index[ref_id])
			condition_opcodes.append(opcode)
			condition_signals.append(int(signals[i]))
			condition_compares.append(int(compares[i]))
			condition_references.append(reference)
			condition_values.append(int(values[i]))
		if not ops.is_empty() and depth != 1:
			return {"ok": false, "reason": "building condition postfix invalid: %s" % stable_id}
		condition_offsets.append(condition_opcodes.size())

	return {
		"ok": true,
		"building_type_ids": type_ids,
		"building_kinds": building_kinds,
		"building_economic_sectors": building_economic_sectors,
		"building_production_climate_profile_indices": building_climate_profile_indices,
		"production_climate_profile_ids": climate_profile_ids,
		"production_climate_temperature_opt_q16": climate_temperature_opt_q16,
		"production_climate_temperature_tolerance_q16": climate_temperature_tolerance_q16,
		"production_climate_water_opt_q16": climate_water_opt_q16,
		"production_climate_water_tolerance_q16": climate_water_tolerance_q16,
		"production_climate_exposure_q16": climate_exposure_q16,
		"production_climate_floor_q16": climate_floor_q16,
		"building_technology_tag_offsets": technology_tag_offsets,
		"building_technology_tags": technology_tags,
		"building_semantic_tag_offsets": semantic_tag_offsets,
		"building_semantic_tags": semantic_tags,
		"building_upgrade_family_ids": upgrade_family_ids,
		"building_upgrade_family_indices": upgrade_family_indices,
		"building_upgrade_tiers": upgrade_tiers,
		"building_owner_profession_ids": owner_professions,
		"building_owner_slots": owner_slots,
		"building_wage_per_employee_per_day": wages_per_employee_per_day,
		"building_construction_days": construction_days,
		"building_behavior_ids": behavior_ids,
		"building_behavior_versions": behavior_versions,
		"building_target_operating_margin_q16": target_operating_margins,
		"building_supply_price_elasticity_q16": supply_price_elasticities,
		"building_employee_offsets": employee_offsets,
		"building_employee_profession_ids": employee_professions,
		"building_employee_slots": employee_slot_counts,
		"building_employee_wage_policies": employee_wage_policies,
		"building_employee_reference_wages_per_day": employee_reference_wages,
		"building_construction_offsets": construction_offsets,
		"building_construction_good_ids": construction_goods,
		"building_construction_quantities": construction_quantities,
		"building_input_offsets": input_offsets,
		"building_input_good_ids": input_goods,
		"building_input_quantities": input_quantities,
		"building_input_required_q16": input_required_q16,
		"building_input_category_ids": input_category_ids,
		"building_input_min_quality_levels": input_min_quality_levels,
		"building_input_candidate_offsets": input_candidate_offsets,
		"building_input_candidate_good_ids": input_candidate_goods,
		"building_input_candidate_efficiency_q16": input_candidate_efficiencies,
		"building_output_offsets": output_offsets,
		"building_output_good_ids": output_goods,
		"building_output_quantities": output_quantities,
		"building_output_cost_share_offsets": output_cost_share_offsets,
		"building_output_cost_shares_q16": output_cost_shares,
		"building_resource_ids": resource_ids,
		"building_resource_reserve_slots": resource_reserve_slots,
		"building_resource_extra_slots": resource_extra_slots,
		"building_resource_gen_base": resource_gen_base,
		"building_resource_gen_temp": resource_gen_temp,
		"building_resource_gen_moisture": resource_gen_moisture,
		"building_resource_gen_self": resource_gen_self,
		"building_resource_decay_base": resource_decay_base,
		"building_resource_decay_temp": resource_decay_temp,
		"building_resource_decay_moisture": resource_decay_moisture,
		"building_resource_decay_self_q16": resource_decay_self_q16,
		"building_resource_ecology_capacity": resource_ecology_capacity,
		"building_resource_ecology_growth_q16": resource_ecology_growth_q16,
		"building_resource_temp_lo_q16": resource_temp_lo_q16,
		"building_resource_temp_hi_q16": resource_temp_hi_q16,
		"building_resource_semantic_tag_offsets": resource_semantic_tag_offsets,
		"building_resource_semantic_tags": resource_semantic_tags,
		"building_resource_offsets": production_resource_offsets,
		"building_production_resource_ids": production_resources,
		"building_production_resource_quantities": production_resource_quantities,
		"building_production_resource_modes": production_resource_modes,
		"building_production_resource_access_modes": production_resource_access_modes,
		"building_resource_generation_offsets": generation_resource_offsets,
		"building_resource_generation_ids": generation_resources,
		"building_resource_generation_quantities": generation_resource_quantities,
		"building_resource_generation_floor_q16": generation_floor_q16,
		"building_condition_offsets": condition_offsets,
		"building_condition_opcodes": condition_opcodes,
		"building_condition_signals": condition_signals,
		"building_condition_compares": condition_compares,
		"building_condition_references": condition_references,
		"building_condition_values": condition_values,
	}


static func _validate_explicit_input_candidates(profile: Resource,
		good_index: Dictionary) -> String:
	var offsets: PackedInt32Array = profile.input_candidate_offsets
	var candidate_ids: PackedStringArray = profile.input_candidate_good_ids
	var efficiencies: PackedInt32Array = profile.input_candidate_efficiency_q16
	var has_explicit_candidates := offsets.size() > 1 \
		or not candidate_ids.is_empty() or not efficiencies.is_empty()
	if not has_explicit_candidates:
		return ""
	if offsets.size() != profile.input_good_ids.size() + 1 or offsets[0] != 0 \
			or candidate_ids.size() != efficiencies.size() \
			or offsets[-1] != candidate_ids.size():
		return "building explicit input candidate columns mismatch"
	for offset_idx in range(1, offsets.size()):
		if offsets[offset_idx] < offsets[offset_idx - 1]:
			return "building explicit input candidate offsets invalid"
	var configured_categories: PackedStringArray = profile.input_category_ids
	for input_idx in range(profile.input_good_ids.size()):
		var begin := int(offsets[input_idx])
		var end := int(offsets[input_idx + 1])
		if end <= begin:
			continue
		var category_id := String(configured_categories[input_idx]) \
			if not configured_categories.is_empty() else ""
		if category_id != "":
			return "building input cannot combine category and explicit candidates"
		var preferred_id := String(profile.input_good_ids[input_idx])
		var seen_candidates := {}
		for candidate_idx in range(begin, end):
			var candidate_id := String(candidate_ids[candidate_idx])
			var efficiency := int(efficiencies[candidate_idx])
			if not good_index.has(candidate_id) or seen_candidates.has(candidate_id) \
					or efficiency <= 0 or efficiency > 262144:
				return "invalid building explicit input candidate"
			seen_candidates[candidate_id] = true
		if not seen_candidates.has(preferred_id):
			return "preferred building input missing from explicit candidates"
	return ""

static func _append_building_goods(ids: PackedStringArray, quantities: PackedInt64Array,
		good_index: Dictionary, out_ids: PackedInt32Array,
		out_quantities: PackedInt64Array) -> String:
	if ids.size() != quantities.size():
		return "building good columns mismatch"
	for i in range(ids.size()):
		var stable_id := String(ids[i])
		if not good_index.has(stable_id) or int(quantities[i]) <= 0:
			return "invalid building good"
		out_ids.append(int(good_index[stable_id]))
		out_quantities.append(int(quantities[i]))
	return ""

static func _load_resources(dir_path: String) -> Array:
	# [pk-export-remap] DirAccess.get_files_at() 在导出/打包工程里看到的是 pck
	# 目录项原名（会带 .remap 后缀，如 x.tres.remap），后缀过滤永远命不中，导
	# 致整个目录被判定为空——这不是 web 专属坑，任何导出包（含桌面 exe）都会
	# 中招，只是这之前只跑过编辑器内松散工程没触发。ResourceLoader.list_directory()
	# 在两种场景下都返回逻辑名（x.tres），是 Godot 4.3+ 专门为此提供的 API。
	var paths := PackedStringArray()
	for file_name in ResourceLoader.list_directory(dir_path):
		if file_name.get_extension().to_lower() == "tres":
			paths.append("%s/%s" % [dir_path, file_name])
	paths.sort()
	var out := []
	for path in paths:
		var resource = ResourceLoader.load(path, "Resource")
		if resource != null and String(resource.get("id")) != "":
			out.append(resource)
	out.sort_custom(func(a, b) -> bool: return String(a.id) < String(b.id))
	return out

static func _index_ids(ids: PackedStringArray) -> Dictionary:
	var out := {}
	for i in range(ids.size()):
		if String(ids[i]) == "" or out.has(String(ids[i])):
			return {}
		out[String(ids[i])] = i
	return out

static func _optional_index(index: Dictionary, id_value: String) -> int:
	if id_value == "":
		return -1
	return int(index.get(id_value, -2))

static func _catalog_hash(catalog: Dictionary) -> int:
	var keys := catalog.keys()
	keys.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	var canonical := "economy-catalog-v2\n"
	for key in keys:
		canonical += "%s=%s\n" % [String(key), var_to_str(catalog[key])]
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(canonical.to_utf8_buffer())
	var digest := hashing.finish()
	var value: int = 0
	for i in range(7):
		value = (value << 8) | int(digest[i])
	return maxi(1, value)
