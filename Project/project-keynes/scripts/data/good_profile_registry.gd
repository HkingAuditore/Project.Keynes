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
	var paths := PackedStringArray()
	for file_name in DirAccess.get_files_at(_PROFILE_DIR):
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


static func compile_native_columns() -> Dictionary:
	ensure_loaded()
	var ids := PackedStringArray()
	var default_prices := PackedInt32Array()
	var initial_stock := PackedInt64Array()
	var min_prices := PackedInt32Array()
	var max_prices := PackedInt32Array()
	var adjust_q16 := PackedInt32Array()
	var demand_elasticity := PackedInt32Array()
	var demand_ema_alpha := PackedInt32Array()
	var target_inventory_days := PackedInt32Array()
	var inventory_weight := PackedInt32Array()
	var shortage_weight := PackedInt32Array()
	var max_price_rise := PackedInt32Array()
	var max_price_fall := PackedInt32Array()
	var merchant_buy_factor := PackedInt32Array()
	for p in _ordered:
		ids.append(String(p.get("id")))
		default_prices.append(int(p.get("default_price")))
		initial_stock.append(int(p.get("initial_stock")))
		min_prices.append(int(p.get("min_price")))
		max_prices.append(int(p.get("max_price")))
		adjust_q16.append(int(p.get("price_adjust_q16")))
		demand_elasticity.append(int(p.get("demand_price_elasticity_q16")))
		demand_ema_alpha.append(int(p.get("demand_ema_alpha_q16")))
		target_inventory_days.append(int(p.get("target_inventory_days_q16")))
		inventory_weight.append(int(p.get("inventory_weight_q16")))
		shortage_weight.append(int(p.get("shortage_weight_q16")))
		max_price_rise.append(int(p.get("max_price_rise_q16")))
		max_price_fall.append(int(p.get("max_price_fall_q16")))
		merchant_buy_factor.append(int(p.get("merchant_buy_price_factor_q16")))
	return {
		"good_ids": ids,
		"good_default_price": default_prices,
		"good_initial_stock": initial_stock,
		"good_min_price": min_prices,
		"good_max_price": max_prices,
		"good_price_adjust_q16": adjust_q16,
		"good_demand_price_elasticity_q16": demand_elasticity,
		"good_demand_ema_alpha_q16": demand_ema_alpha,
		"good_target_inventory_days_q16": target_inventory_days,
		"good_inventory_weight_q16": inventory_weight,
		"good_shortage_weight_q16": shortage_weight,
		"good_max_price_rise_q16": max_price_rise,
		"good_max_price_fall_q16": max_price_fall,
		"good_merchant_buy_factor_q16": merchant_buy_factor,
	}
