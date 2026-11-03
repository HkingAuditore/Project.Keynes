class_name NarrativeCondition
extends Resource

enum Op {
	ALWAYS_TRUE = 0,
	TEMP_GTE = 1,
	TEMP_LTE = 2,
	MOISTURE_GTE = 3,
	MOISTURE_LTE = 4,
	PRECIP_GTE = 5,
	PRECIP_LTE = 6,
	SNOW_GTE = 7,
	ELEVATION_GTE = 8,
	ELEVATION_LTE = 9,
	HAS_RIVER = 10,
	IS_COASTAL = 11,
	OCEAN_CURRENT_SPEED_GTE = 12,
	OCEAN_UPWELLING_GTE = 13,
	TERRAIN_IN = 14,
	LANDFORM_IN = 15,
	VEGETATION_IN = 16,
	POPULATION_GTE = 17,
	POPULATION_LTE = 18,
	SATISFACTION_GTE = 19,
	SATISFACTION_LTE = 20,
	HAS_BUILDING_TYPE = 21,
	BUILDING_COUNT_GTE = 22,
	MARKET_GOOD_SHORTAGE = 23,
	MARKET_GOOD_STOCK_GTE = 24,
	MARKET_GOOD_STOCK_LTE = 25,
	MARKET_GOOD_PRICE_RATIO_GTE = 26,
	HAS_NATURAL_RESOURCE = 27,
	HAS_TECHNOLOGY = 28,
	LACKS_TECHNOLOGY = 29,
	TREASURY_CASH_GTE = 30,
	TREASURY_CASH_LTE = 31,
	ERA_GTE = 32,
	ERA_LTE = 33,
	HAS_STORY_FLAG = 34,
	LACKS_STORY_FLAG = 35,
}

@export var op: int = Op.ALWAYS_TRUE
@export var target_key: StringName = &""
@export var int_value: int = 0
@export var float_value: float = 0.0
@export var bool_value: bool = true
@export var int_list: PackedInt32Array = PackedInt32Array()
@export var string_list: PackedStringArray = PackedStringArray()
@export var negated: bool = false

func evaluate(ctx: Dictionary) -> bool:
	var raw_result: bool = _evaluate_raw(ctx)
	return not raw_result if negated else raw_result

func _evaluate_raw(ctx: Dictionary) -> bool:
	match op:
		Op.ALWAYS_TRUE:
			return true
		Op.TEMP_GTE:
			return _read_float(ctx, ["temperature_c", "temperature", "temp_c", "temp"], 20.0) >= float_value
		Op.TEMP_LTE:
			return _read_float(ctx, ["temperature_c", "temperature", "temp_c", "temp"], 20.0) <= float_value
		Op.MOISTURE_GTE:
			return _read_float(ctx, ["moisture", "soil_moisture"], 0.5) >= float_value
		Op.MOISTURE_LTE:
			return _read_float(ctx, ["moisture", "soil_moisture"], 0.5) <= float_value
		Op.PRECIP_GTE:
			return _read_float(ctx, ["precipitation", "precip", "rainfall"], 0.0) >= float_value
		Op.PRECIP_LTE:
			return _read_float(ctx, ["precipitation", "precip", "rainfall"], 0.0) <= float_value
		Op.SNOW_GTE:
			return _read_float(ctx, ["snow_cover", "snow", "snow_depth"], 0.0) >= float_value
		Op.ELEVATION_GTE:
			return _read_float(ctx, ["elevation", "height", "altitude"], 0.0) >= float_value
		Op.ELEVATION_LTE:
			return _read_float(ctx, ["elevation", "height", "altitude"], 0.0) <= float_value
		Op.HAS_RIVER:
			return _read_bool(ctx, ["has_river", "is_river", "river"], false) == bool_value
		Op.IS_COASTAL:
			return _read_bool(ctx, ["is_coastal", "coastal", "has_coast"], false) == bool_value
		Op.OCEAN_CURRENT_SPEED_GTE:
			return _read_float(ctx, ["ocean_current_speed", "current_speed"], 0.0) >= float_value
		Op.OCEAN_UPWELLING_GTE:
			return _read_float(ctx, ["ocean_upwelling", "upwelling"], 0.0) >= float_value
		Op.TERRAIN_IN:
			var t_id: int = _read_int(ctx, ["terrain", "terrain_type", "terrain_id"], -1)
			var t_name: String = _read_string(ctx, ["terrain_name", "terrain_key"], "")
			return _match_enum_or_name(t_id, t_name)
		Op.LANDFORM_IN:
			var lf_id: int = _read_int(ctx, ["landform", "landform_type", "landform_id"], -1)
			var lf_name: String = _read_string(ctx, ["landform_name", "landform_key"], "")
			return _match_enum_or_name(lf_id, lf_name)
		Op.VEGETATION_IN:
			var veg_id: int = _read_int(ctx, ["vegetation", "vegetation_type", "vegetation_id"], -1)
			var veg_name: String = _read_string(ctx, ["vegetation_name", "vegetation_key"], "")
			return _match_enum_or_name(veg_id, veg_name)
		Op.POPULATION_GTE:
			return _read_int(ctx, ["population", "total_population", "pop"], 0) >= int_value
		Op.POPULATION_LTE:
			return _read_int(ctx, ["population", "total_population", "pop"], 0) <= int_value
		Op.SATISFACTION_GTE:
			return _read_satisfaction_norm(ctx) >= _normalized_satisfaction_threshold()
		Op.SATISFACTION_LTE:
			return _read_satisfaction_norm(ctx) <= _normalized_satisfaction_threshold()
		Op.HAS_BUILDING_TYPE:
			var min_b: int = maxi(1, int_value)
			if target_key == &"":
				return _read_total_building_count(ctx) >= min_b
			return _read_building_type_count(ctx, target_key) >= min_b
		Op.BUILDING_COUNT_GTE:
			return _read_total_building_count(ctx) >= int_value
		Op.MARKET_GOOD_SHORTAGE:
			return _check_market_good_shortage(ctx, target_key)
		Op.MARKET_GOOD_STOCK_GTE:
			return _read_market_good_stock(ctx, target_key) >= int_value
		Op.MARKET_GOOD_STOCK_LTE:
			return _read_market_good_stock(ctx, target_key) <= int_value
		Op.MARKET_GOOD_PRICE_RATIO_GTE:
			return _read_market_good_price_ratio(ctx, target_key) >= float_value
		Op.HAS_NATURAL_RESOURCE:
			var min_res: int = maxi(1, int_value)
			return _read_natural_resource_reserve(ctx, target_key) >= min_res
		Op.HAS_TECHNOLOGY:
			return _has_key_in_collection(ctx, ["technology_ids", "technologies", "unlocked_technologies", "completed_technologies", "techs"], target_key)
		Op.LACKS_TECHNOLOGY:
			return not _has_key_in_collection(ctx, ["technology_ids", "technologies", "unlocked_technologies", "completed_technologies", "techs"], target_key)
		Op.TREASURY_CASH_GTE:
			return _read_int(ctx, ["treasury_cash", "country_cash", "cash", "treasury"], 0) >= int_value
		Op.TREASURY_CASH_LTE:
			return _read_int(ctx, ["treasury_cash", "country_cash", "cash", "treasury"], 0) <= int_value
		Op.ERA_GTE:
			return _read_int(ctx, ["era_index", "era", "current_era"], 0) >= int_value
		Op.ERA_LTE:
			return _read_int(ctx, ["era_index", "era", "current_era"], 0) <= int_value
		Op.HAS_STORY_FLAG:
			return _has_story_flag(ctx, target_key)
		Op.LACKS_STORY_FLAG:
			return not _has_story_flag(ctx, target_key)
		_:
			return false

func _match_enum_or_name(enum_id: int, name_val: String) -> bool:
	if not int_list.is_empty() and enum_id in int_list:
		return true
	if not string_list.is_empty() and not name_val.is_empty():
		var lower_name: String = name_val.to_lower()
		for item in string_list:
			if item.to_lower() == lower_name:
				return true
	if int_list.is_empty() and string_list.is_empty() and target_key != &"":
		return name_val.to_lower() == String(target_key).to_lower()
	return false

func _normalized_satisfaction_threshold() -> float:
	var raw_t: float = float_value
	if is_zero_approx(raw_t) and int_value > 0:
		raw_t = float(int_value)
	if raw_t > 100.0:
		return raw_t / 65536.0
	if raw_t > 1.0001:
		return raw_t / 100.0
	return raw_t

static func _read_satisfaction_norm(ctx: Dictionary) -> float:
	if ctx.has("satisfaction_norm"):
		return float(ctx["satisfaction_norm"])
	if ctx.has("satisfaction_q16"):
		return float(ctx["satisfaction_q16"]) / 65536.0
	var raw_val: float = _read_float(ctx, ["satisfaction", "avg_satisfaction"], 0.5)
	if raw_val > 100.0:
		return raw_val / 65536.0
	if raw_val > 1.0001:
		return raw_val / 100.0
	return raw_val

static func _read_building_type_count(ctx: Dictionary, btype: StringName) -> int:
	var key_str: String = String(btype)
	for dict_key in ["building_counts_by_type", "building_counts_by_id", "building_counts", "buildings_by_type", "buildings"]:
		if not ctx.has(dict_key):
			continue
		var container: Variant = ctx[dict_key]
		if container is Dictionary:
			var d: Dictionary = container
			if d.has(btype):
				return _extract_count(d[btype])
			if d.has(key_str):
				return _extract_count(d[key_str])
		elif container is Array or container is PackedStringArray:
			var count: int = 0
			for elem in container:
				if elem is Dictionary:
					var ed: Dictionary = elem
					var elem_type: String = String(ed.get("building_type", ed.get("type_id", ed.get("id", ""))))
					if elem_type == key_str:
						count += int(ed.get("count", 1))
				elif String(elem) == key_str:
					count += 1
			return count
	return 0

static func _read_total_building_count(ctx: Dictionary) -> int:
	for k in ["building_count", "total_buildings"]:
		if ctx.has(k):
			return int(ctx[k])
	for dict_key in ["building_counts_by_type", "building_counts_by_id", "building_counts", "buildings_by_type", "buildings"]:
		if not ctx.has(dict_key):
			continue
		var container: Variant = ctx[dict_key]
		if container is Dictionary:
			var d: Dictionary = container
			var total: int = 0
			for v in d.values():
				total += _extract_count(v)
			return total
		elif container is Array or container is PackedStringArray:
			return container.size()
	return 0

static func _check_market_good_shortage(ctx: Dictionary, good_id: StringName) -> bool:
	var key_str: String = String(good_id)
	if good_id == &"" or key_str.is_empty():
		if _read_bool(ctx, ["has_any_shortage", "market_shortage"], false):
			return true
		for col_key in ["shortage_good_ids", "shortage_goods", "good_shortages", "shortages"]:
			if not ctx.has(col_key):
				continue
			var col: Variant = ctx[col_key]
			if col is Array or col is PackedStringArray:
				if col.size() > 0:
					return true
			elif col is Dictionary:
				var d: Dictionary = col
				for v in d.values():
					if _is_truthy_or_positive(v):
						return true
		for mg_key in ["market_goods", "goods"]:
			if ctx.has(mg_key) and ctx[mg_key] is Dictionary:
				var mg: Dictionary = ctx[mg_key]
				for entry in mg.values():
					if entry is Dictionary and _good_entry_has_shortage(entry):
						return true
		return false

	for col_key in ["shortage_good_ids", "shortage_goods", "good_shortages", "shortages"]:
		if not ctx.has(col_key):
			continue
		var col: Variant = ctx[col_key]
		if col is Array or col is PackedStringArray:
			for item in col:
				if String(item) == key_str:
					return true
		elif col is Dictionary:
			var d: Dictionary = col
			if d.has(good_id) and _is_truthy_or_positive(d[good_id]):
				return true
			if d.has(key_str) and _is_truthy_or_positive(d[key_str]):
				return true
	for mg_key in ["market_goods", "goods"]:
		if ctx.has(mg_key) and ctx[mg_key] is Dictionary:
			var mg: Dictionary = ctx[mg_key]
			var entry: Variant = mg.get(good_id, mg.get(key_str, null))
			if entry is Dictionary and _good_entry_has_shortage(entry):
				return true
	return false

static func _good_entry_has_shortage(entry: Dictionary) -> bool:
	if bool(entry.get("shortage", entry.get("has_shortage", false))):
		return true
	if float(entry.get("unmet_demand", entry.get("deficit", 0.0))) > 0.0:
		return true
	return false

static func _read_market_good_stock(ctx: Dictionary, good_id: StringName) -> int:
	var key_str: String = String(good_id)
	if key_str.is_empty() and ctx.has("total_market_stock"):
		return int(ctx["total_market_stock"])
	for dict_key in ["market_stocks_by_id", "market_stocks", "good_stocks", "stocks", "treasury_goods_by_id", "country_goods", "treasury_goods"]:
		if ctx.has(dict_key) and ctx[dict_key] is Dictionary:
			var d: Dictionary = ctx[dict_key]
			if d.has(good_id):
				return _extract_count(d[good_id])
			if d.has(key_str):
				return _extract_count(d[key_str])
	for mg_key in ["market_goods", "goods"]:
		if ctx.has(mg_key) and ctx[mg_key] is Dictionary:
			var mg: Dictionary = ctx[mg_key]
			var entry: Variant = mg.get(good_id, mg.get(key_str, null))
			if entry is Dictionary:
				var ed: Dictionary = entry
				return int(ed.get("stock", ed.get("quantity", ed.get("inventory", 0))))
			elif entry is int or entry is float:
				return int(entry)
	return 0

static func _read_market_good_price_ratio(ctx: Dictionary, good_id: StringName) -> float:
	var key_str: String = String(good_id)
	for dict_key in ["market_price_ratios_by_id", "market_price_ratio_by_id", "price_ratios_by_id", "market_price_ratios", "good_price_ratios", "price_ratios"]:
		if ctx.has(dict_key) and ctx[dict_key] is Dictionary:
			var d: Dictionary = ctx[dict_key]
			if key_str.is_empty():
				var max_r: float = 1.0
				for v in d.values():
					max_r = maxf(max_r, float(v))
				return max_r
			if d.has(good_id):
				return float(d[good_id])
			if d.has(key_str):
				return float(d[key_str])
	for mg_key in ["market_goods", "goods"]:
		if ctx.has(mg_key) and ctx[mg_key] is Dictionary:
			var mg: Dictionary = ctx[mg_key]
			if key_str.is_empty():
				var max_r: float = 1.0
				for entry in mg.values():
					if entry is Dictionary:
						max_r = maxf(max_r, _extract_price_ratio(entry))
				return max_r
			var entry: Variant = mg.get(good_id, mg.get(key_str, null))
			if entry is Dictionary:
				return _extract_price_ratio(entry)
	if key_str.is_empty() and ctx.has("max_price_ratio"):
		return float(ctx["max_price_ratio"])
	return 1.0

static func _extract_price_ratio(entry: Dictionary) -> float:
	if entry.has("price_ratio"):
		return float(entry["price_ratio"])
	var price: float = float(entry.get("price", 0.0))
	var base_price: float = float(entry.get("base_price", 0.0))
	if base_price > 0.0001:
		return price / base_price
	return 1.0

static func _read_natural_resource_reserve(ctx: Dictionary, res_id: StringName) -> int:
	var key_str: String = String(res_id)
	for dict_key in ["natural_resources_by_id", "natural_resources", "resources", "resource_reserves"]:
		if not ctx.has(dict_key):
			continue
		var col: Variant = ctx[dict_key]
		if col is Dictionary:
			var d: Dictionary = col
			if key_str.is_empty():
				var max_res: int = 0
				for v in d.values():
					max_res = maxi(max_res, _extract_count(v))
				return max_res
			if d.has(res_id):
				return _extract_count(d[res_id])
			if d.has(key_str):
				return _extract_count(d[key_str])
		elif col is Array or col is PackedStringArray:
			for item in col:
				if key_str.is_empty() or String(item) == key_str:
					return 1
	var single_id: String = _read_string(ctx, ["resource_id", "natural_resource"], "")
	if not single_id.is_empty() and (key_str.is_empty() or single_id == key_str):
		return _read_int(ctx, ["resource_reserve", "reserve"], 1)
	return 0

static func _has_story_flag(ctx: Dictionary, flag_key: StringName) -> bool:
	return _has_key_in_collection(ctx, ["story_flags", "story_flag_ids", "active_story_flags", "flags", "cell_story_flags", "country_story_flags"], flag_key)

static func _has_key_in_collection(ctx: Dictionary, dict_keys: Array, key: StringName) -> bool:
	var key_str: String = String(key)
	if key_str.is_empty():
		return false
	for dk in dict_keys:
		if not ctx.has(dk):
			continue
		var col: Variant = ctx[dk]
		if col is Dictionary:
			var d: Dictionary = col
			if d.has(key) and _is_truthy_or_positive(d[key]):
				return true
			if d.has(key_str) and _is_truthy_or_positive(d[key_str]):
				return true
		elif col is Array or col is PackedStringArray:
			for item in col:
				if String(item) == key_str:
					return true
	return false

static func _extract_count(v: Variant) -> int:
	if v is int or v is float:
		return int(v)
	if v is bool:
		return 1 if v else 0
	if v is Dictionary:
		var d: Dictionary = v
		return int(d.get("count", d.get("reserve", d.get("amount", d.get("quantity", 1)))))
	return 0

static func _is_truthy_or_positive(v: Variant) -> bool:
	if v is bool:
		return v
	if v is int:
		return v != 0
	if v is float:
		return absf(v) > 0.00001
	if v is String or v is StringName:
		return not String(v).is_empty()
	if v is Dictionary:
		return not (v as Dictionary).is_empty()
	return v != null

static func _read_float(ctx: Dictionary, keys: Array, default_val: float) -> float:
	for k in keys:
		if ctx.has(k) and ctx[k] != null:
			return float(ctx[k])
	return default_val

static func _read_int(ctx: Dictionary, keys: Array, default_val: int) -> int:
	for k in keys:
		if ctx.has(k) and ctx[k] != null:
			return int(ctx[k])
	return default_val

static func _read_bool(ctx: Dictionary, keys: Array, default_val: bool) -> bool:
	for k in keys:
		if ctx.has(k) and ctx[k] != null:
			return bool(ctx[k])
	return default_val

static func _read_string(ctx: Dictionary, keys: Array, default_val: String) -> String:
	for k in keys:
		if ctx.has(k) and ctx[k] != null:
			return String(ctx[k])
	return default_val

static func parse_op(raw_op: Variant) -> int:
	if raw_op is int or raw_op is float:
		return int(raw_op)
	if raw_op is String or raw_op is StringName:
		var name_upper: String = String(raw_op).strip_edges().to_upper()
		if Op.has(name_upper):
			return int(Op[name_upper])
	return Op.ALWAYS_TRUE

func to_dict() -> Dictionary:
	var ints: Array = []
	for v in int_list:
		ints.append(int(v))
	var strs: Array = []
	for s in string_list:
		strs.append(String(s))
	return {
		"op": op,
		"target_key": String(target_key),
		"int_value": int_value,
		"float_value": float_value,
		"bool_value": bool_value,
		"int_list": ints,
		"string_list": strs,
		"negated": negated,
	}

static func from_dict(d: Dictionary) -> NarrativeCondition:
	var cond := NarrativeCondition.new()
	if d.is_empty():
		return cond
	cond.op = parse_op(d.get("op", Op.ALWAYS_TRUE))
	cond.target_key = StringName(String(d.get("target_key", "")))
	cond.int_value = int(d.get("int_value", 0))
	cond.float_value = float(d.get("float_value", 0.0))
	cond.bool_value = bool(d.get("bool_value", true))
	cond.negated = bool(d.get("negated", false))

	var raw_ints: Variant = d.get("int_list", [])
	var parsed_ints := PackedInt32Array()
	if raw_ints is PackedInt32Array:
		parsed_ints = raw_ints.duplicate()
	elif raw_ints is Array:
		for item in raw_ints:
			parsed_ints.append(int(item))
	cond.int_list = parsed_ints

	var raw_strs: Variant = d.get("string_list", [])
	var parsed_strs := PackedStringArray()
	if raw_strs is PackedStringArray:
		parsed_strs = raw_strs.duplicate()
	elif raw_strs is Array:
		for item in raw_strs:
			parsed_strs.append(String(item))
	cond.string_list = parsed_strs
	return cond
