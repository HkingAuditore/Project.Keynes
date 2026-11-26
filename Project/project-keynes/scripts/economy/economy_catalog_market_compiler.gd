extends RefCounted

## Compiles occupation, household, market and compatibility columns.

const PROFESSION_DIR := "res://data/economy/professions"
const ETHNICITY_DIR := "res://data/economy/ethnicities"
const PLAN_DIR := "res://data/economy/consumption_plans"
const NEED_DIR := "res://data/economy/needs"
const CURVE_DIR := "res://data/economy/environment_curves"
const TerrainTypeScript = preload("res://scripts/geography/terrain_type.gd")
const LandformTypeScript = preload("res://scripts/geography/landform_type.gd")
const Q16_ONE := 65536
const SATISFACTION_DIMENSION_COUNT := 8
const SATISFACTION_TIER_COUNT := 4
const SATISFACTION_MODEL_VERSION := 2
const SIGNAL_IDS := {
	"temperature": 0,
	"moisture": 1,
	"snow_cover": 2,
	"weather_intensity": 3,
}
const CatalogIO = preload("res://scripts/economy/economy_catalog_io.gd")


static func compile(context) -> Dictionary:
	var professions := await CatalogIO._load_resources_impl(PROFESSION_DIR, context)
	var ethnicities := await CatalogIO._load_resources_impl(ETHNICITY_DIR, context)
	var plans := await CatalogIO._load_resources_impl(PLAN_DIR, context)
	var needs := await CatalogIO._load_resources_impl(NEED_DIR, context)
	var curves := await CatalogIO._load_resources_impl(CURVE_DIR, context)
	if professions.is_empty() or ethnicities.is_empty() or plans.is_empty() or needs.is_empty():
		return {"ok": false, "reason": "market v2 catalog is incomplete"}

	if context != null:
		context.stage("goods_columns")
	var good_columns: Dictionary = GoodProfileRegistry.compile_native_columns()
	if not bool(good_columns.get("ok", false)):
		return good_columns
	good_columns.erase("ok")
	var good_ids: PackedStringArray = good_columns.good_ids
	var good_index := CatalogIO._index_ids(good_ids)
	if good_ids.is_empty():
		return {"ok": false, "reason": "good catalog is empty"}

	var need_ids := PackedStringArray()
	var need_living_cost_weights := PackedInt32Array()
	var need_satisfaction_tiers := PackedInt32Array()
	var need_satisfaction_weights := PackedInt32Array()
	var need_semantic_tag_offsets := PackedInt32Array([0])
	var need_semantic_tags := PackedStringArray()
	for need in needs:
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
	var need_index := CatalogIO._index_ids(need_ids)

	var curve_ids := PackedStringArray()
	var curve_signal_ids := PackedInt32Array()
	var curve_values := PackedInt32Array()
	for curve in curves:
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		var curve_id := String(curve.id)
		var signal_name := String(curve.signal_id)
		if not SIGNAL_IDS.has(signal_name) or curve.values_q16.size() != 17:
			return {"ok": false, "reason": "invalid environment curve: %s" % curve_id}
		curve_ids.append(curve_id)
		curve_signal_ids.append(int(SIGNAL_IDS[signal_name]))
		for value in curve.values_q16:
			curve_values.append(maxi(0, int(value)))
	var curve_index := CatalogIO._index_ids(curve_ids)

	var plan_ids := PackedStringArray()
	var plan_index := {}
	for i in range(plans.size()):
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
			need_env_curve_ids.append(CatalogIO._optional_index(curve_index, String(plan.quantity_env_curve_ids[n])))
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
			variant_env_curve_ids.append(CatalogIO._optional_index(
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
	var profession_entry_savings_days := PackedInt32Array()
	var profession_startup_capital_days := PackedInt32Array()
	var profession_state_service_only := PackedInt32Array()
	var profession_state_supplied_need_offsets := PackedInt32Array([0])
	var profession_state_supplied_need_ids := PackedInt32Array()
	var profession_technology_tag_offsets := PackedInt32Array([0])
	var profession_technology_tags := PackedStringArray()
	var profession_semantic_tag_offsets := PackedInt32Array([0])
	var profession_semantic_tags := PackedStringArray()
	# Per-profession spending basket, used by Ideology's material support model:
	# one Q16 need-share row per profession, normalized to 65536. Derived from the
	# profession's own consumption plan so an industrial household and a scholar
	# household can react differently to the same consumption-cost card without
	# measuring live market purchases.
	var profession_need_weight_q16 := PackedInt32Array()
	var profession_index := {}
	for i in range(professions.size()):
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		var stable_id := String(professions[i].id)
		if stable_id == "" or profession_index.has(stable_id) \
				or not plan_index.has(String(professions[i].default_consumption_plan_id)):
			return {"ok": false, "reason": "invalid profession: %s" % stable_id}
		profession_ids.append(stable_id)
		profession_class_ids.append(String(professions[i].profession_class_id))
		if int(professions[i].entry_savings_days) < 0:
			return {"ok": false, "reason": "invalid profession entry savings: %s" % stable_id}
		profession_entry_savings_days.append(int(professions[i].entry_savings_days))
		if int(professions[i].startup_capital_days) < 0:
			return {"ok": false, "reason": "invalid profession startup capital days: %s" % stable_id}
		profession_startup_capital_days.append(int(professions[i].startup_capital_days))
		# Military v1: state-service professions may only fill state-building
		# roles, and their listed needs are supplied in kind by Military.
		var state_service_only := bool(professions[i].state_service_only)
		profession_state_service_only.append(1 if state_service_only else 0)
		var supplied_seen := {}
		for need_id in professions[i].state_supplied_need_ids:
			var supplied_need := String(need_id).strip_edges()
			if not state_service_only:
				return {"ok": false, "reason":
					"state_supplied_need_without_state_service: %s" % stable_id}
			if not need_index.has(supplied_need) or supplied_seen.has(supplied_need):
				return {"ok": false, "reason":
					"invalid state supplied need: %s / %s" % [stable_id, supplied_need]}
			supplied_seen[supplied_need] = true
			profession_state_supplied_need_ids.append(int(need_index[supplied_need]))
		profession_state_supplied_need_offsets.append(
			profession_state_supplied_need_ids.size())
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
		var basket := PackedInt64Array()
		basket.resize(need_ids.size())
		basket.fill(0)
		var plan = plans[int(plan_index[String(professions[i].default_consumption_plan_id)])]
		for k in range(plan.need_ids.size()):
			var basket_need := String(plan.need_ids[k])
			if not need_index.has(basket_need):
				return {"ok": false, "reason":
					"plan references missing need: %s / %s" % [stable_id, basket_need]}
			var basket_need_index := int(need_index[basket_need])
			var quantity := maxi(0, int(plan.base_qty_per_person[k]))
			# Living-cost weight is the only catalog-level price proxy, so it is
			# what turns physical quantities into a spending share. Without it a
			# "3 units of clothing" and "550 units of grain" would be compared as
			# if they cost the same.
			basket[basket_need_index] += quantity * maxi(1, int(
				need_living_cost_weights[basket_need_index]))
		var basket_total := 0
		for quantity in basket:
			basket_total += quantity
		for need_slot in range(basket.size()):
			profession_need_weight_q16.append(0 if basket_total <= 0 else int(
				basket[need_slot] * Q16_ONE / basket_total))

	var ethnicity_ids := PackedStringArray()
	var ethnicity_culture_group_ids := PackedStringArray()
	var ethnicity_need_factor := PackedInt32Array()
	for ethnicity in ethnicities:
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
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
		"satisfaction_model_version": SATISFACTION_MODEL_VERSION,
		"profession_ids": profession_ids,
		"profession_class_ids": profession_class_ids,
		"profession_entry_savings_days": profession_entry_savings_days,
		"profession_startup_capital_days": profession_startup_capital_days,
		"profession_state_service_only": profession_state_service_only,
		"profession_state_supplied_need_offsets":
			profession_state_supplied_need_offsets,
		"profession_state_supplied_need_ids": profession_state_supplied_need_ids,
		"profession_technology_tag_offsets": profession_technology_tag_offsets,
		"profession_technology_tags": profession_technology_tags,
		"profession_semantic_tag_offsets": profession_semantic_tag_offsets,
		"profession_semantic_tags": profession_semantic_tags,
		"profession_need_weight_q16": profession_need_weight_q16,
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
		if context != null:
			await context.checkpoint("economy")
			if context.canceled:
				return {"ok": false, "reason": "loading_canceled"}
		catalog[key] = good_columns[key]
	# Military v1 columns are newer than every compat hash. Strip them from all
	# of the historical hash inputs so an unchanged pre-military catalog keeps
	# its old compat hashes and existing economy saves stay loadable.
	const MILITARY_V1_COLUMNS := [
		"profession_state_service_only",
		"profession_state_supplied_need_offsets",
		"profession_state_supplied_need_ids",
	]
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
	for compat_columns in [market_v10_columns, market_v10_v8_columns,
			market_v10_v7_columns, market_v10_v6_columns, market_v8_columns,
			market_v7_columns, market_v6_columns]:
		for key in MILITARY_V1_COLUMNS:
			compat_columns.erase(key)
	var market_compat_hash_v6 := await CatalogIO._catalog_hash_impl(market_v6_columns, context)
	catalog["market_catalog_hash"] = await CatalogIO._catalog_hash_impl(catalog, context)
	catalog["market_catalog_compat_hash_v8"] = await CatalogIO._catalog_hash_impl(market_v8_columns, context)
	return {
		"ok": true,
		"profession_ids": profession_ids,
		"profession_state_service_only": profession_state_service_only,
		"profession_technology_tag_offsets": profession_technology_tag_offsets,
		"profession_technology_tags": profession_technology_tags,
		"profession_index": profession_index,
		"good_columns": good_columns,
		"good_index": good_index,
		"catalog": catalog,
		"market_v10_columns": market_v10_columns,
		"market_v10_v8_columns": market_v10_v8_columns,
		"market_v10_v7_columns": market_v10_v7_columns,
		"market_v10_v6_columns": market_v10_v6_columns,
		"market_v7_columns": market_v7_columns,
		"market_compat_hash_v6": market_compat_hash_v6,
	}
