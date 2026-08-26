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

static func compile_native_catalog(
		family_effect_catalog_override: Resource = null,
		family_trait_catalog_override: Resource = null) -> Dictionary:
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
	var variant_class_wealth_elasticity_delta := PackedInt32Array()
	var variant_class_savings_threshold_factor := PackedInt32Array()
	var variant_env_curve_ids := PackedInt32Array()
	var variant_component_offsets := PackedInt32Array([0])
	var component_good_ids := PackedInt32Array()
	var component_qty := PackedInt64Array()

	for plan in plans:
		var need_count: int = plan.need_ids.size()
		if need_count > 20 or plan.priorities.size() != need_count \
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
		var class_wealth_delta: PackedInt32Array = plan.variant_class_wealth_elasticity_delta_q16
		var class_threshold_factor: PackedInt32Array = plan.variant_class_savings_threshold_factor_q16
		# Legacy synthetic resources may omit the new columns. Formal generated
		# content always authors them explicitly.
		if class_wealth_delta.is_empty():
			class_wealth_delta.resize(variant_count)
			class_wealth_delta.fill(0)
		if class_threshold_factor.is_empty():
			class_threshold_factor.resize(variant_count)
			class_threshold_factor.fill(Q16_ONE)
		if plan.need_variant_offsets[need_count] != variant_count \
				or plan.variant_preference_q16.size() != variant_count \
				or plan.variant_price_elasticity_q16.size() != variant_count \
				or class_wealth_delta.size() != variant_count \
				or class_threshold_factor.size() != variant_count \
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
			var wealth_delta := int(class_wealth_delta[v])
			var threshold_factor := int(class_threshold_factor[v])
			if wealth_delta < -65536 or wealth_delta > 131072 \
					or threshold_factor < 0 or threshold_factor > 262144:
				return {"ok": false, "reason": "invalid class wealth response in plan %s" % String(plan.id)}
			variant_class_wealth_elasticity_delta.append(wealth_delta)
			variant_class_savings_threshold_factor.append(threshold_factor)
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
	var ethnicity_culture_group_ids := PackedStringArray()
	var ethnicity_need_factor := PackedInt32Array()
	for ethnicity in ethnicities:
		var stable_id := String(ethnicity.id)
		if stable_id == "" or ethnicity_ids.has(stable_id) \
				or ethnicity.need_modifier_ids.size() != ethnicity.need_quantity_factors_q16.size():
			return {"ok": false, "reason": "invalid ethnicity: %s" % stable_id}
		ethnicity_ids.append(stable_id)
		var culture_group_id := String(ethnicity.culture_group_id).strip_edges()
		if culture_group_id.is_empty():
			return {"ok": false, "reason": "ethnicity_missing_culture_group: %s" % stable_id}
		ethnicity_culture_group_ids.append(culture_group_id)
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
		"ethnicity_culture_group_ids": ethnicity_culture_group_ids,
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
		"variant_class_wealth_elasticity_delta_q16": variant_class_wealth_elasticity_delta,
		"variant_class_savings_threshold_factor_q16": variant_class_savings_threshold_factor,
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
		"modifier_sector_ids": PackedStringArray([
			"agriculture", "extractive", "manufacturing", "energy", "knowledge"]),
		"modifier_terrain_ids": PackedStringArray(
			TerrainTypeScript.TERRAIN.keys().map(func(value):
				return String(value).to_lower())),
		"modifier_landform_ids": PackedStringArray(
			LandformTypeScript.LF.keys().map(func(value):
				return String(value).to_lower())),
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
		good_columns.good_monetary_issue_values,
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
		var technology_id := String(technology_ids[technology_index_value])
		technology_set[technology_id] = true
		technology_index[technology_id] = technology_index_value
		technology_binding_rows[technology_index_value] = []
	var good_tag_offsets: PackedInt32Array = good_columns.good_technology_tag_offsets
	for good_index_value in range(good_columns.good_ids.size()):
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
		var allows_terminal_or_unlock := String(
			building_columns.building_type_ids[building_index_value]) in [
				"glassware_factory", "metal_housewares_factory", "leather_goods_factory"]
		if building_binding_count != (2 if allows_terminal_or_unlock else 1):
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
	var dependency_columns := _compile_building_dependency_columns(
		building_columns, good_columns, building_columns.building_resource_ids,
		building_columns.building_resource_technology_tag_offsets,
		building_columns.building_resource_technology_tags,
		technology_set, technology_index)
	if not bool(dependency_columns.get("ok", false)):
		return dependency_columns
	for technology_index_value in range(technology_ids.size()):
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
		if key != "ok":
			catalog[key] = technology_catalog[key]
	for key in development_catalog:
		if key != "ok":
			catalog[key] = development_catalog[key]
	for key in ["technology_content_binding_offsets", "technology_content_binding_kinds",
			"technology_content_binding_ids", "technology_consumer_flags",
			"building_dependency_branch_offsets", "building_dependency_branch_technologies",
			"building_dependency_branch_technology_offsets",
			"building_dependency_branch_group_offsets", "building_dependency_kinds",
			"building_dependency_ids", "building_dependency_tag_offsets",
			"building_dependency_tags"]:
		catalog[key] = content_binding_summary[key]
	var trigger_catalog_resource: Resource = TriggerCatalogScript.load_default()
	var trigger_catalog: Dictionary = trigger_catalog_resource.compile_native_catalog() \
		if trigger_catalog_resource != null else {"ok": false,
			"reason": "trigger_catalog_missing"}
	if not bool(trigger_catalog.get("ok", false)):
		return trigger_catalog
	catalog["technology_catalog_identity_hash"] = _catalog_hash(technology_catalog)
	catalog["technology_content_binding_hash"] = _catalog_hash(content_binding_summary)
	catalog["technology_trigger_definition_hash"] = _catalog_hash(trigger_catalog)
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
	var carrying_columns := _compile_carrying_columns(catalog, building_columns, good_columns)
	if not bool(carrying_columns.get("ok", false)):
		return carrying_columns
	carrying_columns.erase("ok")
	for key in carrying_columns:
		catalog[key] = carrying_columns[key]
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
	var family_effect_ir: Dictionary = family_effect_catalog.compile_native_catalog(
		catalog.get("technology_ids", PackedStringArray()))
	if not bool(family_effect_ir.get("ok", false)):
		return family_effect_ir
	family_effect_ir.erase("ok")
	family_effect_ir.erase("definitions")
	for key in family_effect_ir:
		catalog[key] = family_effect_ir[key]
	var trait_columns: Dictionary = trait_catalog.compile_native_columns(
		catalog, family_effect_ir.get("family_effect_keys", PackedStringArray()),
		family_effect_ir.get("family_effect_source_kinds", PackedInt32Array()))
	if not bool(trait_columns.get("ok", false)):
		return trait_columns
	for key in trait_columns:
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
	catalog["catalog_compat_hash_v39"] = _catalog_hash(catalog_v39)
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

static func _compile_carrying_columns(catalog: Dictionary, building_columns: Dictionary,
		good_columns: Dictionary) -> Dictionary:
	const FAMILY_SPECS := [
		["staple", "staple_food"],
		["protein", "protein"],
		["produce", "produce"],
		["clothing", "clothing"],
		["housing", "housing"],
		["household", "household_goods"],
		["hygiene", "hygiene"],
		["healthcare", "healthcare"],
		["energy", "home_energy"],
		["transport", "transport"],
		["communication", "communication"],
		["education", "education_culture"],
		["recreation", "recreation"],
		["durables", "durable_goods"],
		["work_tools", "work_equipment"],
		["luxury", "luxury"],
		["status", "status_goods"],
	]
	const PRODUCER_SPECS := [
		["construction", [
			"primitive_construction", "masonry_material", "plant_construction",
			"construction_components", "raw_stone", "lumber"]],
		["mill_tools", ["tools", "tool_metal"]],
		["metals", ["ferrous_stock", "structural_metal", "tool_metal"]],
		["bullion", ["precious_metal"]],
	]
	const SUPPORT_RESOURCE_IDS := [
		"arable_land", "paddy_land", "pasture", "plantation_land",
		"wild_game", "freshwater_fish", "marine_fish",
	]
	var need_ids: PackedStringArray = catalog.get("need_ids", PackedStringArray())
	var need_index := _index_ids(need_ids)
	var family_ids := PackedStringArray()
	var family_need_stable := PackedInt32Array()
	var family_good_offsets := PackedInt32Array([0])
	var family_goods := PackedInt32Array()
	var household_goods := {}
	for spec in FAMILY_SPECS:
		var family_id := String(spec[0])
		var need_id := String(spec[1])
		if not need_index.has(need_id):
			return {"ok": false, "reason": "carrying_need_family_missing:%s" % need_id}
		var need_stable := int(need_index[need_id])
		var goods := _carrying_need_goods(need_stable, catalog)
		family_ids.append(family_id)
		family_need_stable.append(need_stable)
		for good_id in goods:
			household_goods[int(good_id)] = true
			family_goods.append(int(good_id))
		family_good_offsets.append(family_goods.size())
	var category_goods := _carrying_category_goods(
		good_columns.get("good_substitution_category_offsets", PackedInt32Array()),
		good_columns.get("good_substitution_category_ids", PackedStringArray()),
		int((good_columns.get("good_ids", PackedStringArray()) as PackedStringArray).size()))
	if bool(category_goods.get("ok", true)) == false:
		return category_goods
	var used_producer_goods := {}
	for spec in PRODUCER_SPECS:
		var family_id := String(spec[0])
		var categories: Array = spec[1]
		var collected := PackedInt32Array()
		var seen := {}
		for category_id in categories:
			var members: PackedInt32Array = category_goods.get(String(category_id), PackedInt32Array())
			for good_id in members:
				var gid := int(good_id)
				if household_goods.has(gid) or used_producer_goods.has(gid) or seen.has(gid):
					continue
				seen[gid] = true
				collected.append(gid)
		collected.sort()
		for gid in collected:
			used_producer_goods[int(gid)] = true
			family_goods.append(int(gid))
		family_ids.append(family_id)
		family_need_stable.append(-1)
		family_good_offsets.append(family_goods.size())
	var resource_ids: PackedStringArray = building_columns.get(
		"building_resource_ids", PackedStringArray())
	var resource_index := _index_ids(resource_ids)
	var support_resource_ids := PackedInt32Array()
	for resource_id in SUPPORT_RESOURCE_IDS:
		support_resource_ids.append(int(resource_index.get(String(resource_id), -1)))
	var food_need_stables := PackedInt32Array()
	for need_id in ["staple_food", "protein", "produce"]:
		food_need_stables.append(int(need_index[need_id]))
	var survival_food_goods := {}
	for need_stable in food_need_stables:
		for good_id in _carrying_need_goods(int(need_stable), catalog):
			survival_food_goods[int(good_id)] = true
	var fertile_soil_id := int(resource_index.get("fertile_soil", -1))
	var yield_offsets := PackedInt32Array()
	yield_offsets.resize(SUPPORT_RESOURCE_IDS.size() + 1)
	yield_offsets.fill(0)
	var yield_building := PackedInt32Array()
	var yield_resource := PackedInt32Array()
	var yield_secondary := PackedInt32Array()
	var yield_food := PackedInt64Array()
	var yield_qty := PackedInt64Array()
	var yield_secondary_qty := PackedInt64Array()
	var yield_modes := PackedInt32Array()
	var building_type_ids: PackedStringArray = building_columns.get(
		"building_type_ids", PackedStringArray())
	var output_offsets: PackedInt32Array = building_columns.get(
		"building_output_offsets", PackedInt32Array())
	var output_goods: PackedInt32Array = building_columns.get(
		"building_output_good_ids", PackedInt32Array())
	var output_qty: PackedInt64Array = building_columns.get(
		"building_output_quantities", PackedInt64Array())
	var resource_offsets: PackedInt32Array = building_columns.get(
		"building_resource_offsets", PackedInt32Array())
	var production_resources: PackedInt32Array = building_columns.get(
		"building_production_resource_ids", PackedInt32Array())
	var production_qty: PackedInt64Array = building_columns.get(
		"building_production_resource_quantities", PackedInt64Array())
	var production_modes: PackedInt32Array = building_columns.get(
		"building_production_resource_modes", PackedInt32Array())
	if output_offsets.size() != building_type_ids.size() + 1 \
			or resource_offsets.size() != building_type_ids.size() + 1:
		return {"ok": false, "reason": "carrying_food_yield_building_shape_invalid"}
	var rows_by_support: Array = []
	rows_by_support.resize(SUPPORT_RESOURCE_IDS.size())
	for support_idx in range(SUPPORT_RESOURCE_IDS.size()):
		rows_by_support[support_idx] = []
	for type_id in range(building_type_ids.size()):
		var food_output := 0
		for output_idx in range(int(output_offsets[type_id]), int(output_offsets[type_id + 1])):
			if output_idx < 0 or output_idx >= output_goods.size() \
					or output_idx >= output_qty.size():
				return {"ok": false, "reason": "carrying_food_yield_output_invalid"}
			if survival_food_goods.has(int(output_goods[output_idx])):
				food_output += int(output_qty[output_idx])
		if food_output <= 0:
			continue
		var primary_support := -1
		var primary_resource := -1
		var primary_qty := 0
		var primary_mode := 1
		var secondary_resource := -1
		var secondary_qty := 0
		for edge in range(int(resource_offsets[type_id]), int(resource_offsets[type_id + 1])):
			if edge < 0 or edge >= production_resources.size() \
					or edge >= production_qty.size() or edge >= production_modes.size():
				return {"ok": false, "reason": "carrying_food_yield_resource_invalid"}
			var resource_id := int(production_resources[edge])
			if resource_id == fertile_soil_id:
				secondary_resource = resource_id
				secondary_qty = int(production_qty[edge])
				continue
			for support_idx in range(support_resource_ids.size()):
				if int(support_resource_ids[support_idx]) == resource_id and primary_support < 0:
					primary_support = support_idx
					primary_resource = resource_id
					primary_qty = int(production_qty[edge])
					primary_mode = int(production_modes[edge])
		if primary_support < 0 or primary_qty <= 0:
			continue
		rows_by_support[primary_support].append({
			"building": type_id,
			"resource": primary_resource,
			"secondary": secondary_resource,
			"food": food_output,
			"qty": primary_qty,
			"secondary_qty": secondary_qty,
			"mode": primary_mode,
		})
	for support_idx in range(rows_by_support.size()):
		yield_offsets[support_idx] = yield_building.size()
		for row in rows_by_support[support_idx]:
			yield_building.append(int(row.building))
			yield_resource.append(int(row.resource))
			yield_secondary.append(int(row.secondary))
			yield_food.append(int(row.food))
			yield_qty.append(int(row.qty))
			yield_secondary_qty.append(int(row.secondary_qty))
			yield_modes.append(int(row.mode))
	yield_offsets[SUPPORT_RESOURCE_IDS.size()] = yield_building.size()
	return {
		"ok": true,
		"carrying_family_ids": family_ids,
		"carrying_family_need_stable_ids": family_need_stable,
		"carrying_family_good_offsets": family_good_offsets,
		"carrying_family_good_ids": family_goods,
		"carrying_support_resource_ids": support_resource_ids,
		"carrying_food_yield_offsets": yield_offsets,
		"carrying_food_yield_building_type_ids": yield_building,
		"carrying_food_yield_resource_ids": yield_resource,
		"carrying_food_yield_secondary_resource_ids": yield_secondary,
		"carrying_food_yield_food_output": yield_food,
		"carrying_food_yield_resource_qty": yield_qty,
		"carrying_food_yield_secondary_qty": yield_secondary_qty,
		"carrying_food_yield_modes": yield_modes,
	}


static func _carrying_need_goods(need_stable: int, catalog: Dictionary) -> PackedInt32Array:
	var need_stable_ids: PackedInt32Array = catalog.get("need_stable_ids", PackedInt32Array())
	var need_variant_offsets: PackedInt32Array = catalog.get("need_variant_offsets", PackedInt32Array())
	var variant_component_offsets: PackedInt32Array = catalog.get(
		"variant_component_offsets", PackedInt32Array())
	var component_good_ids: PackedInt32Array = catalog.get("component_good_ids", PackedInt32Array())
	var seen := {}
	if need_variant_offsets.size() != need_stable_ids.size() + 1:
		return PackedInt32Array()
	for entry in range(need_stable_ids.size()):
		if int(need_stable_ids[entry]) != need_stable:
			continue
		var variant_begin := int(need_variant_offsets[entry])
		var variant_end := int(need_variant_offsets[entry + 1])
		for variant_id in range(variant_begin, variant_end):
			if variant_id < 0 or variant_id + 1 >= variant_component_offsets.size():
				continue
			var component_begin := int(variant_component_offsets[variant_id])
			var component_end := int(variant_component_offsets[variant_id + 1])
			for component_idx in range(component_begin, component_end):
				if component_idx >= 0 and component_idx < component_good_ids.size():
					seen[int(component_good_ids[component_idx])] = true
	var goods := PackedInt32Array()
	for good_id in seen.keys():
		goods.append(int(good_id))
	goods.sort()
	return goods


static func _carrying_category_goods(offsets: PackedInt32Array, ids: PackedStringArray,
		good_count: int) -> Dictionary:
	var out := {}
	if offsets.size() != good_count + 1 or offsets.is_empty() or int(offsets[0]) != 0 \
			or int(offsets[-1]) != ids.size():
		return {"ok": false, "reason": "carrying_substitution_category_shape_invalid"}
	for good_idx in range(good_count):
		var begin := int(offsets[good_idx])
		var end := int(offsets[good_idx + 1])
		if begin < 0 or end < begin or end > ids.size():
			return {"ok": false, "reason": "carrying_substitution_category_offsets_invalid"}
		for edge in range(begin, end):
			var category_id := String(ids[edge])
			if category_id.is_empty():
				continue
			var members: PackedInt32Array = out.get(category_id, PackedInt32Array())
			members.append(good_idx)
			out[category_id] = members
	out["ok"] = true
	return out


static func _compile_building_columns(profession_index: Dictionary,
		good_index: Dictionary, good_storage_modes: PackedInt32Array,
		good_monetary_issue_values: PackedInt64Array,
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
	var resource_technology_tag_offsets := PackedInt32Array([0])
	var resource_technology_tags := PackedStringArray()
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
		for tag in resource.discovery_technology_tags:
			var normalized_technology_tag := String(tag).strip_edges()
			if normalized_technology_tag.is_empty():
				return {"ok": false, "reason": "resource_technology_binding_empty",
					"id": stable_id}
			resource_technology_tags.append(normalized_technology_tag)
		resource_technology_tag_offsets.append(resource_technology_tags.size())

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
	var required_technology_tag_offsets := PackedInt32Array([0])
	var required_technology_tags := PackedStringArray()
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
	var construction_candidate_offsets := PackedInt32Array([0])
	var construction_candidate_goods := PackedInt32Array()
	var construction_candidate_efficiencies := PackedInt32Array()
	var maintenance_offsets := PackedInt32Array([0])
	var maintenance_goods := PackedInt32Array()
	var maintenance_quantities := PackedInt64Array()
	var maintenance_horizon_days := PackedInt32Array()
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
		var sector_ids := ["agriculture", "extractive", "manufacturing", "energy", "knowledge"]
		var sector_id := String(profile.economic_sector_id).strip_edges()
		var sector := sector_ids.find(sector_id)
		if sector < 0:
			return {"ok": false, "reason": "invalid building economic sector: %s" % stable_id,
				"sector": sector_id}
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
		var required_seen := {}
		for tag in profile.required_technology_tags:
			var required_tag := String(tag).strip_edges()
			if not required_tag.begins_with("tech.") or required_seen.has(required_tag):
				return {"ok": false,
					"reason": "invalid required building technology tag: %s" % stable_id,
					"tag": required_tag}
			required_seen[required_tag] = true
			required_technology_tags.append(required_tag)
		required_technology_tag_offsets.append(required_technology_tags.size())
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

		var zero_cost_construction: bool = allows_zero_cost_construction(profile)
		if profile.construction_good_ids.is_empty() and not zero_cost_construction:
			return {"ok": false, "reason": "building requires explicit construction goods: %s" % stable_id}
		var error := ""
		if not profile.construction_good_ids.is_empty():
			error = _append_building_goods(profile.construction_good_ids,
				profile.construction_quantities, good_index, construction_goods,
				construction_quantities)
		if error != "": return {"ok": false, "reason": "%s: %s" % [error, stable_id]}
		var construction_candidate_error := _append_construction_candidates(
			profile, good_index, construction_candidate_offsets,
			construction_candidate_goods, construction_candidate_efficiencies)
		if construction_candidate_error != "":
			return {"ok": false, "reason": "%s: %s" % [construction_candidate_error, stable_id]}
		construction_offsets.append(construction_goods.size())
		var authored_maintenance_ids: PackedStringArray = profile.maintenance_good_ids
		var authored_maintenance_qty: PackedInt64Array = profile.maintenance_quantities_per_day
		if authored_maintenance_ids.size() != authored_maintenance_qty.size():
			return {"ok": false, "reason": "building maintenance columns mismatch: %s" % stable_id}
		if not authored_maintenance_ids.is_empty():
			for item in range(authored_maintenance_ids.size()):
				var maintenance_id := String(authored_maintenance_ids[item])
				if not good_index.has(maintenance_id) or int(authored_maintenance_qty[item]) <= 0:
					return {"ok": false, "reason": "invalid building maintenance good: %s" % stable_id}
				var maintenance_good := int(good_index[maintenance_id])
				if maintenance_good < 0 or maintenance_good >= good_storage_modes.size() \
						or int(good_storage_modes[maintenance_good]) != 0:
					continue
				if maintenance_good < good_monetary_issue_values.size() \
						and int(good_monetary_issue_values[maintenance_good]) > 0:
					continue
				maintenance_goods.append(maintenance_good)
				maintenance_quantities.append(int(authored_maintenance_qty[item]))
		var horizon := int(profile.maintenance_horizon_days)
		if horizon < 0:
			return {"ok": false, "reason": "invalid building maintenance horizon: %s" % stable_id}
		maintenance_horizon_days.append(horizon)
		maintenance_offsets.append(maintenance_goods.size())
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
		"building_required_technology_tag_offsets": required_technology_tag_offsets,
		"building_required_technology_tags": required_technology_tags,
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
		"building_construction_candidate_offsets": construction_candidate_offsets,
		"building_construction_candidate_good_ids": construction_candidate_goods,
		"building_construction_candidate_efficiency_q16": construction_candidate_efficiencies,
		"building_maintenance_offsets": maintenance_offsets,
		"building_maintenance_good_ids": maintenance_goods,
		"building_maintenance_quantities": maintenance_quantities,
		"building_maintenance_horizon_days": maintenance_horizon_days,
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
		"building_resource_technology_tag_offsets": resource_technology_tag_offsets,
		"building_resource_technology_tags": resource_technology_tags,
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


## Compiles the material/resource prerequisites for every direct building
## technology branch.  A branch is usable only when its own technology and
## required tags are completed, and every dependency group has at least one
## completed discovery/production tag.  Input candidate alternatives share one
## group, so a building is not incorrectly forced to unlock every substitute.
static func _compile_building_dependency_columns(buildings: Dictionary,
		goods: Dictionary, resource_ids: PackedStringArray,
		resource_tag_offsets: PackedInt32Array, resource_tags: PackedStringArray,
		technology_set: Dictionary, technology_index: Dictionary) -> Dictionary:
	var building_ids: PackedStringArray = buildings.building_type_ids
	var direct_offsets: PackedInt32Array = buildings.building_technology_tag_offsets
	var direct_tags: PackedStringArray = buildings.building_technology_tags
	var required_offsets: PackedInt32Array = \
		buildings.building_required_technology_tag_offsets
	var required_tags: PackedStringArray = buildings.building_required_technology_tags
	var dependency_branch_offsets := PackedInt32Array([0])
	var dependency_branch_technology_offsets := PackedInt32Array([0])
	var dependency_branch_technologies := PackedInt32Array()
	var dependency_branch_group_offsets := PackedInt32Array([0])
	var dependency_kinds := PackedByteArray()
	var dependency_ids := PackedInt32Array()
	var dependency_tag_offsets := PackedInt32Array([0])
	var dependency_tags := PackedInt32Array()
	var good_ids: PackedStringArray = goods.good_ids
	var good_tag_offsets: PackedInt32Array = goods.good_technology_tag_offsets
	var good_technology_tags: PackedStringArray = goods.good_technology_tags
	var construction_offsets: PackedInt32Array = buildings.building_construction_offsets
	var construction_goods: PackedInt32Array = buildings.building_construction_good_ids
	var construction_candidate_offsets: PackedInt32Array = buildings.get(
		"building_construction_candidate_offsets", PackedInt32Array())
	var construction_candidate_goods: PackedInt32Array = buildings.get(
		"building_construction_candidate_good_ids", PackedInt32Array())
	var input_offsets: PackedInt32Array = buildings.building_input_offsets
	var input_goods: PackedInt32Array = buildings.building_input_good_ids
	var input_required: PackedInt32Array = buildings.building_input_required_q16
	var input_candidate_offsets: PackedInt32Array = buildings.building_input_candidate_offsets
	var input_candidate_goods: PackedInt32Array = buildings.building_input_candidate_good_ids
	var output_offsets: PackedInt32Array = buildings.building_output_offsets
	var output_goods: PackedInt32Array = buildings.building_output_good_ids
	var resource_offsets: PackedInt32Array = buildings.building_resource_offsets
	var production_resources: PackedInt32Array = buildings.building_production_resource_ids
	var generation_offsets: PackedInt32Array = buildings.building_resource_generation_offsets
	var generation_resources: PackedInt32Array = buildings.building_resource_generation_ids
	var resource_index := {}
	for resource_index_value in range(resource_ids.size()):
		resource_index[String(resource_ids[resource_index_value])] = resource_index_value
	var append_tags := func(raw_tags: Array, building_id: String,
			dependency_kind: int, dependency_id: int) -> Dictionary:
		var seen := {}
		for raw_tag in raw_tags:
			var tag := String(raw_tag).strip_edges()
			if not tag.begins_with("tech.") or seen.has(tag):
				continue
			seen[tag] = true
			if not technology_set.has(tag):
				return {"ok": false, "reason": "unknown_building_dependency_technology",
					"building_id": building_id, "dependency_kind": dependency_kind,
					"dependency_id": dependency_id, "tag": tag}
			dependency_tags.append(int(technology_index[tag]))
		if seen.is_empty():
			return {"ok": false, "reason": "building_dependency_technology_missing",
				"building_id": building_id, "dependency_kind": dependency_kind,
				"dependency_id": dependency_id}
		dependency_tag_offsets.append(dependency_tags.size())
		return {"ok": true}
	var append_good_group := func(building_id: String, dependency_kind: int,
			good_id: int, candidate_ids: Array = []) -> Dictionary:
		var acceptable := []
		var ids_to_scan := candidate_ids if not candidate_ids.is_empty() else [good_id]
		for candidate_id in ids_to_scan:
			var candidate := int(candidate_id)
			if candidate < 0 or candidate >= good_ids.size():
				return {"ok": false, "reason": "building_dependency_good_invalid",
					"building_id": building_id, "dependency_id": candidate}
			for tag_index in range(good_tag_offsets[candidate], good_tag_offsets[candidate + 1]):
				acceptable.append(String(good_technology_tags[tag_index]))
		dependency_kinds.append(dependency_kind)
		dependency_ids.append(good_id)
		return append_tags.call(acceptable, building_id, dependency_kind, good_id)
	var append_resource_group := func(building_id: String, dependency_kind: int,
			resource_id: int) -> Dictionary:
		if resource_id < 0 or resource_id >= resource_ids.size():
			return {"ok": false, "reason": "building_dependency_resource_invalid",
				"building_id": building_id, "dependency_id": resource_id}
		var acceptable := []
		for tag_index in range(resource_tag_offsets[resource_id], resource_tag_offsets[resource_id + 1]):
			acceptable.append(String(resource_tags[tag_index]))
		dependency_kinds.append(dependency_kind)
		dependency_ids.append(resource_id)
		return append_tags.call(acceptable, building_id, dependency_kind, resource_id)
	for building_index in range(building_ids.size()):
		var building_id := String(building_ids[building_index])
		var building_branch_count := 0
		for direct_index in range(direct_offsets[building_index], direct_offsets[building_index + 1]):
			var direct_tag := String(direct_tags[direct_index]).strip_edges()
			if not direct_tag.begins_with("tech."):
				continue
			dependency_branch_technologies.append(int(technology_index[direct_tag]))
			for required_index in range(required_offsets[building_index], required_offsets[building_index + 1]):
				var required_tag := String(required_tags[required_index]).strip_edges()
				dependency_branch_technologies.append(int(technology_index[required_tag]))
			dependency_branch_technology_offsets.append(dependency_branch_technologies.size())
			building_branch_count += 1
			for edge in range(construction_offsets[building_index], construction_offsets[building_index + 1]):
				var candidates := []
				if edge + 1 < construction_candidate_offsets.size():
					for candidate_edge in range(construction_candidate_offsets[edge],
							construction_candidate_offsets[edge + 1]):
						candidates.append(int(construction_candidate_goods[candidate_edge]))
				var result: Dictionary = append_good_group.call(building_id, 1,
					int(construction_goods[edge]), candidates)
				if not bool(result.get("ok", false)):
					return result
			for edge in range(input_offsets[building_index], input_offsets[building_index + 1]):
				# Soft complements are demand sinks, not operational prerequisites.
				# Compiling them into the technology dependency CSR would make an
				# optional recipe input a hidden hard unlock gate.
				if int(input_required[edge]) < 65536:
					continue
				var candidates := []
				if edge + 1 < input_candidate_offsets.size():
					for candidate_edge in range(input_candidate_offsets[edge], input_candidate_offsets[edge + 1]):
						candidates.append(int(input_candidate_goods[candidate_edge]))
				var result: Dictionary = append_good_group.call(building_id, 2,
					int(input_goods[edge]), candidates)
				if not bool(result.get("ok", false)):
					return result
			for edge in range(output_offsets[building_index], output_offsets[building_index + 1]):
				var result: Dictionary = append_good_group.call(building_id, 3,
					int(output_goods[edge]))
				if not bool(result.get("ok", false)):
					return result
			for edge in range(resource_offsets[building_index], resource_offsets[building_index + 1]):
				var result: Dictionary = append_resource_group.call(building_id, 4,
					int(production_resources[edge]))
				if not bool(result.get("ok", false)):
					return result
			for edge in range(generation_offsets[building_index], generation_offsets[building_index + 1]):
				var result: Dictionary = append_resource_group.call(building_id, 5,
					int(generation_resources[edge]))
				if not bool(result.get("ok", false)):
					return result
			dependency_branch_group_offsets.append(dependency_kinds.size())
		dependency_branch_offsets.append(
			dependency_branch_offsets[-1] + building_branch_count)
		if building_branch_count == 0:
			return {"ok": false, "reason": "building_technology_binding_missing",
				"id": building_id}
	return {"ok": true,
		"building_dependency_branch_offsets": dependency_branch_offsets,
		"building_dependency_branch_technologies": dependency_branch_technologies,
		"building_dependency_branch_technology_offsets": dependency_branch_technology_offsets,
		"building_dependency_branch_group_offsets": dependency_branch_group_offsets,
		"building_dependency_kinds": dependency_kinds,
		"building_dependency_ids": dependency_ids,
		"building_dependency_tag_offsets": dependency_tag_offsets,
		"building_dependency_tags": dependency_tags}

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


## Zero-bill lots: merchant-style services, or stone-age construction
## collectors tagged `starter.construction` whose daily inputs are empty or
## all-soft complements. Industrial buildings and later collectors still need
## an explicit bill.
static func allows_zero_cost_construction(profile: Resource) -> bool:
	if profile == null or int(profile.construction_days) != 0 \
			or not profile.construction_good_ids.is_empty():
		return false
	var kind := String(profile.building_kind)
	if kind == "service":
		return true
	if kind != "collector" or not _daily_inputs_are_all_soft(profile):
		return false
	for tag in profile.semantic_tags:
		if String(tag).strip_edges() == "starter.construction":
			return true
	return false


static func _daily_inputs_are_all_soft(profile: Resource) -> bool:
	if profile.input_good_ids.is_empty():
		return true
	var required: PackedInt32Array = profile.input_required_q16
	if required.size() != profile.input_good_ids.size():
		return false
	for required_q16 in required:
		if int(required_q16) >= Q16_ONE:
			return false
	return true


static func _append_construction_candidates(profile: Resource,
		good_index: Dictionary, out_offsets: PackedInt32Array,
		out_goods: PackedInt32Array, out_efficiencies: PackedInt32Array) -> String:
	var groups: PackedStringArray = profile.construction_good_ids
	var explicit_offsets: PackedInt32Array = profile.construction_candidate_offsets
	var explicit_goods: PackedStringArray = profile.construction_candidate_good_ids
	var explicit_efficiencies: PackedInt32Array = profile.construction_candidate_efficiency_q16
	var has_explicit := explicit_offsets.size() > 1 \
		or not explicit_goods.is_empty() or not explicit_efficiencies.is_empty()
	if not has_explicit:
		for good_id in groups:
			var stable_id := String(good_id)
			if not good_index.has(stable_id):
				return "invalid construction good"
			out_goods.append(int(good_index[stable_id]))
			out_efficiencies.append(Q16_ONE)
			out_offsets.append(out_goods.size())
		return ""
	if explicit_offsets.size() != groups.size() + 1 \
		or explicit_offsets.is_empty() or explicit_offsets[0] != 0 \
		or explicit_goods.size() != explicit_efficiencies.size() \
		or explicit_offsets[-1] != explicit_goods.size():
		return "building construction candidate columns mismatch"
	for offset_index in range(1, explicit_offsets.size()):
		if explicit_offsets[offset_index] < explicit_offsets[offset_index - 1]:
			return "building construction candidate offsets invalid"
	for group_index in range(groups.size()):
		var begin := int(explicit_offsets[group_index])
		var end := int(explicit_offsets[group_index + 1])
		if end <= begin:
			return "building construction candidate group is empty"
		var preferred := String(groups[group_index])
		var seen := {}
		var preferred_seen := false
		for candidate_index in range(begin, end):
			var candidate_id := String(explicit_goods[candidate_index])
			var efficiency := int(explicit_efficiencies[candidate_index])
			if not good_index.has(candidate_id) or seen.has(candidate_id) \
					or efficiency <= 0 or efficiency > 4 * Q16_ONE:
				return "invalid construction candidate"
			seen[candidate_id] = true
			preferred_seen = preferred_seen or candidate_id == preferred
			out_goods.append(int(good_index[candidate_id]))
			out_efficiencies.append(efficiency)
		if not preferred_seen:
			return "construction candidate group must include preferred good"
		out_offsets.append(out_goods.size())
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
