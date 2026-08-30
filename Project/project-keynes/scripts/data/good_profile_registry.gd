# good_profile_registry.gd
# Single-point accessor for GoodProfile definitions. Stable IDs are sorted at
# load time; file names and discovery order are never persisted as identity.

class_name GoodProfileRegistry

const _GoodProfileScript = preload("res://scripts/data/good_profile.gd")

const _PROFILE_DIR := "res://data/goods"

static var _ordered: Array = [] # Array[GoodProfile]
static var _by_id: Dictionary = {}
static var _loaded: bool = false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_ordered.clear()
	_by_id.clear()
	# [pk-export-remap] 见 economy_catalog.gd::_load_resources() 同名注释——导出
	# 包里 DirAccess 看到的是带 .remap 后缀的目录项，用 ResourceLoader.list_directory()
	# 才能拿到 x.tres 逻辑名。
	var paths := PackedStringArray()
	for file_name in ResourceLoader.list_directory(_PROFILE_DIR):
		if file_name.get_extension().to_lower() == "tres":
			paths.append("%s/%s" % [_PROFILE_DIR, file_name])
	paths.sort()
	for path in paths:
		var res = ResourceLoader.load(path, "Resource")
		if res == null:
			push_warning("GoodProfileRegistry: failed to load %s" % path)
			continue
		var id_value := StringName(String(res.get("id")))
		if String(id_value) == "":
			push_warning("GoodProfileRegistry: %s has empty id; skipped" % path)
			continue
		_ordered.append(res)
		_by_id[id_value] = res
	_ordered.sort_custom(func(a, b) -> bool: return String(a.id) < String(b.id))


static func ordered() -> Array:
	ensure_loaded()
	return _ordered


static func count() -> int:
	ensure_loaded()
	return _ordered.size()


static func profile_by_id(id_value):
	ensure_loaded()
	var id_key := StringName(String(id_value))
	return _by_id.get(id_key, null)


static func icon_key(id_or_profile) -> StringName:
	var stable_id := String(id_or_profile.id) if id_or_profile is GoodProfile else String(id_or_profile)
	return IconCatalog.good_semantic(stable_id)


static func compile_native_columns() -> Dictionary:
	ensure_loaded()
	var ids := PackedStringArray()
	var default_prices := PackedInt32Array()
	var initial_stock := PackedInt64Array()
	var max_prices := PackedInt32Array()
	var adjust_q16 := PackedInt32Array()
	var demand_elasticity := PackedInt32Array()
	var household_wealth_elasticity_q16 := PackedInt32Array()
	var household_savings_threshold_months_q16 := PackedInt32Array()
	var demand_ema_alpha := PackedInt32Array()
	var inventory_target_ratios_q16 := PackedInt32Array()
	var compatibility_target_inventory_days_q16 := PackedInt32Array()
	var inventory_weight := PackedInt32Array()
	var shortage_weight := PackedInt32Array()
	var excess_demand_weight := PackedInt32Array()
	var cost_anchor_weight := PackedInt32Array()
	var inactive_reversion_weight := PackedInt32Array()
	var business_demand_ema_alpha := PackedInt32Array()
	var supply_ema_alpha := PackedInt32Array()
	var cost_ema_alpha := PackedInt32Array()
	var max_price_rise := PackedInt32Array()
	var max_price_fall := PackedInt32Array()
	var merchant_buy_factor := PackedInt32Array()
	var trade_enabled := PackedInt32Array()
	var transport_load_per_unit_q16 := PackedInt32Array()
	var category_ids := PackedStringArray()
	var substitution_category_offsets := PackedInt32Array([0])
	var substitution_category_ids := PackedStringArray()
	var production_quality_levels := PackedInt32Array()
	var production_efficiencies_q16 := PackedInt32Array()
	var storage_modes := PackedInt32Array()
	var monetary_issue_values := PackedInt64Array()
	var technology_tag_offsets := PackedInt32Array([0])
	var technology_tags := PackedStringArray()
	var semantic_tag_offsets := PackedInt32Array([0])
	var semantic_tags := PackedStringArray()
	for p in _ordered:
		if p.has_meta(&"obsolete_max_price"):
			return {"ok": false, "reason": "obsolete max_price in good: %s" % p.get("id")}
		if p.has_meta(&"obsolete_min_price"):
			return {"ok": false, "reason": "obsolete min_price in good: %s" % p.get("id")}
		var stable_id := String(p.get("id"))
		var category_id := String(p.get("category_id"))
		var configured_substitution_categories: PackedStringArray = p.get(
			"substitution_category_ids")
		var storage_mode := String(p.get("storage_mode"))
		var issue_value := int(p.get("monetary_issue_value"))
		var quality_level := int(p.get("production_quality_level"))
		var production_efficiency := int(p.get("production_efficiency_q16"))
		if category_id == "" or storage_mode not in ["stock", "cycle_flow"]:
			return {"ok": false, "reason": "invalid good metadata: %s" % stable_id}
		var normalized_categories := PackedStringArray()
		var seen_categories := {}
		if configured_substitution_categories.is_empty():
			normalized_categories.append(category_id)
		else:
			for configured_category in configured_substitution_categories:
				var normalized_category := String(configured_category).strip_edges()
				if normalized_category == "" or seen_categories.has(normalized_category):
					return {"ok": false, "reason": "invalid good substitution categories: %s" % stable_id}
				seen_categories[normalized_category] = true
				normalized_categories.append(normalized_category)
		if not normalized_categories.has(category_id):
			return {"ok": false, "reason": "primary good category missing from substitution roles: %s" % stable_id}
		normalized_categories.sort()
		if quality_level < 0 or production_efficiency <= 0 or production_efficiency > 262144:
			return {"ok": false, "reason": "invalid production substitute metadata: %s" % stable_id}
		if storage_mode == "cycle_flow" and stable_id != "electricity":
			return {"ok": false, "reason": "only electricity may use cycle_flow: %s" % stable_id}
		if issue_value < 0 or (issue_value > 0 and stable_id not in ["gold", "silver"]):
			return {"ok": false, "reason": "invalid monetary issue good: %s" % stable_id}
		ids.append(stable_id)
		category_ids.append(category_id)
		substitution_category_ids.append_array(normalized_categories)
		substitution_category_offsets.append(substitution_category_ids.size())
		production_quality_levels.append(quality_level)
		production_efficiencies_q16.append(production_efficiency)
		storage_modes.append(1 if storage_mode == "cycle_flow" else 0)
		monetary_issue_values.append(issue_value)
		var tags: PackedStringArray = p.get("technology_tags")
		for tag in tags:
			if String(tag).strip_edges() == "":
				return {"ok": false, "reason": "empty good technology tag: %s" % stable_id}
			technology_tags.append(String(tag))
		technology_tag_offsets.append(technology_tags.size())
		var normalized_semantic_tags := PackedStringArray()
		for tag in p.get("semantic_tags") as PackedStringArray:
			var normalized := String(tag).strip_edges()
			if normalized.is_empty() or normalized_semantic_tags.has(normalized):
				return {"ok": false, "reason": "invalid good semantic tag: %s" % stable_id}
			normalized_semantic_tags.append(normalized)
		normalized_semantic_tags.sort()
		semantic_tags.append_array(normalized_semantic_tags)
		semantic_tag_offsets.append(semantic_tags.size())
		default_prices.append(int(p.get("default_price")))
		initial_stock.append(int(p.get("initial_stock")))
		max_prices.append(int(p.get("reference_max_price")))
		adjust_q16.append(int(p.get("price_adjust_q16")))
		demand_elasticity.append(int(p.get("demand_price_elasticity_q16")))
		var wealth_elasticity := int(p.get("household_wealth_elasticity_q16"))
		var savings_threshold := int(p.get("household_savings_threshold_months_q16"))
		if wealth_elasticity < -65536 or wealth_elasticity > 131072 \
				or savings_threshold < 0 or savings_threshold > 7864320:
			return {"ok": false, "reason": "invalid household wealth metadata: %s" % stable_id}
		household_wealth_elasticity_q16.append(wealth_elasticity)
		household_savings_threshold_months_q16.append(savings_threshold)
		demand_ema_alpha.append(int(p.get("demand_ema_alpha_q16")))
		var inventory_target_ratio := int(p.get("inventory_target_ratio_q16"))
		if inventory_target_ratio < 0 or inventory_target_ratio > 262144:
			return {"ok": false, "reason": "invalid inventory target ratio: %s" % stable_id}
		inventory_target_ratios_q16.append(inventory_target_ratio)
		# Keep the legacy absolute-days column so a stale DLL fails soft during
		# editor hot reload instead of aborting economy/population bootstrap.
		compatibility_target_inventory_days_q16.append(
			3932160 * inventory_target_ratio / 65536)
		inventory_weight.append(int(p.get("inventory_weight_q16")))
		shortage_weight.append(int(p.get("shortage_weight_q16")))
		excess_demand_weight.append(int(p.get("excess_demand_weight_q16")))
		cost_anchor_weight.append(int(p.get("cost_anchor_weight_q16")))
		# Price V4 uses a meaningful idle half-life even for legacy profiles that
		# serialized the old 512 default.
		inactive_reversion_weight.append(maxi(8192,
			int(p.get("inactive_reversion_weight_q16"))))
		business_demand_ema_alpha.append(int(p.get("business_demand_ema_alpha_q16")))
		supply_ema_alpha.append(int(p.get("supply_ema_alpha_q16")))
		cost_ema_alpha.append(int(p.get("cost_ema_alpha_q16")))
		max_price_rise.append(int(p.get("max_price_rise_q16")))
		max_price_fall.append(int(p.get("max_price_fall_q16")))
		merchant_buy_factor.append(int(p.get("merchant_buy_price_factor_q16")))
		var load := int(p.get("transport_load_per_unit_q16"))
		if load <= 0:
			return {"ok": false, "reason": "invalid transport load: %s" % stable_id}
		trade_enabled.append(1 if storage_mode == "stock" and bool(p.get("trade_enabled")) else 0)
		transport_load_per_unit_q16.append(load)
	return {
		"ok": true,
		"good_ids": ids,
		"good_category_ids": category_ids,
		"good_substitution_category_offsets": substitution_category_offsets,
		"good_substitution_category_ids": substitution_category_ids,
		"good_production_quality_levels": production_quality_levels,
		"good_production_efficiency_q16": production_efficiencies_q16,
		"good_storage_modes": storage_modes,
		"good_monetary_issue_values": monetary_issue_values,
		"good_technology_tag_offsets": technology_tag_offsets,
		"good_technology_tags": technology_tags,
		"good_semantic_tag_offsets": semantic_tag_offsets,
		"good_semantic_tags": semantic_tags,
		"good_default_price": default_prices,
		"good_initial_stock": initial_stock,
		"good_reference_max_price": max_prices,
		"good_price_adjust_q16": adjust_q16,
		"good_demand_price_elasticity_q16": demand_elasticity,
		"good_household_wealth_elasticity_q16": household_wealth_elasticity_q16,
		"good_household_savings_threshold_months_q16": household_savings_threshold_months_q16,
		"good_demand_ema_alpha_q16": demand_ema_alpha,
		"good_inventory_target_ratios_q16": inventory_target_ratios_q16,
		"good_target_inventory_days_q16": compatibility_target_inventory_days_q16,
		"good_inventory_weight_q16": inventory_weight,
		"good_shortage_weight_q16": shortage_weight,
		"good_excess_demand_weight_q16": excess_demand_weight,
		"good_cost_anchor_weight_q16": cost_anchor_weight,
		"good_inactive_reversion_weight_q16": inactive_reversion_weight,
		"good_business_demand_ema_alpha_q16": business_demand_ema_alpha,
		"good_supply_ema_alpha_q16": supply_ema_alpha,
		"good_cost_ema_alpha_q16": cost_ema_alpha,
		"good_max_price_rise_q16": max_price_rise,
		"good_max_price_fall_q16": max_price_fall,
		"good_merchant_buy_factor_q16": merchant_buy_factor,
		"good_trade_enabled": trade_enabled,
		"good_transport_load_per_unit_q16": transport_load_per_unit_q16,
	}
