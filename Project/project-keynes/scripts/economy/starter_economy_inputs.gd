extends RefCounted

## Reads shared starter site data, inputs, and building availability.

const ResourceProfileRegistry = preload(
	"res://scripts/data/resource_profile_registry.gd")
const BUILDING_DIR := "res://data/economy/buildings"
const CLOTHING_CURVE_PATH := \
	"res://data/economy/environment_curves/cold_clothing_quantity.tres"
const PRODUCTION_CLIMATE_DIR := "res://data/economy/production_climates"
const STARTER_POPULATION := 40
const GOODS_SCALE := 1000
const Q16_ONE := 65536
const RESOURCE_RUNWAY_DAYS := 365
const RENEWABLE_SAFE_HARVEST_Q16 := 0
const RENEWABLE_MIN_RESERVE_Q16 := 22938
const RENEWABLE_GROWTH_DIVISOR := 8
const PRECIOUS_GOOD_IDS := {"gold": true}
const PRECIOUS_RESOURCE_IDS := {"gold_ore": true}
static var _building_profiles: Array = []
static var _resource_profiles: Dictionary = {}
static var _climate_profiles: Dictionary = {}
static var _active_reserve_overlay: Dictionary = {}


static func _starter_output_quantity(raw_quantity: int, climate_q16: int,
		output_efficiency_q16: int) -> int:
	# Native catalog scales goods first, then production applies climate. Soft
	# inputs add productivity above this baseline; opening safety never assumes
	# their stock or funding. Hard inputs remain in the supply-closure constraints.
	var scaled := raw_quantity * output_efficiency_q16 / Q16_ONE
	return scaled * climate_q16 / Q16_ONE

static func _building_profile_by_id(building_id: String):
	_ensure_profiles_loaded()
	for profile in _building_profiles:
		if String(profile.id) == building_id:
			return profile
	return null

static func _starter_initial_goods(starter_route: Dictionary) -> Dictionary:
	var goods := {}
	for good_id in starter_route.get("starter_food_good_ids", PackedStringArray()):
		goods[String(good_id)] = true
	for key in ["starter_clothing_good_id", "starter_input_buffer_good_id"]:
		var good_id := String(starter_route.get(key, ""))
		if not good_id.is_empty():
			goods[good_id] = true
	return goods

static func _starter_buffered_goods(starter_route: Dictionary) -> Dictionary:
	var goods := _starter_initial_goods(starter_route)
	var construction_good := String(starter_route.get("starter_construction_good_id", ""))
	if not construction_good.is_empty():
		goods[construction_good] = true
	return goods

static func _clothing_demand(map: MapData, cell_idx: int) -> int:
	var curve = load(CLOTHING_CURVE_PATH)
	var factor_q16 := Q16_ONE
	if curve != null and curve.values_q16.size() == 17:
		var temperature := clampf(_array_value(map.temp_arr, cell_idx, 0.5), 0.0, 1.0)
		var scaled := temperature * 16.0
		var lower := mini(16, floori(scaled))
		var upper := mini(16, lower + 1)
		var fraction := scaled - lower
		factor_q16 = roundi(lerpf(float(curve.values_q16[lower]),
			float(curve.values_q16[upper]), fraction))
	return maxi(1, STARTER_POPULATION * 2 * factor_q16 / Q16_ONE)

static func _technology_available(profile, completed: Dictionary) -> bool:
	var direct_present := false
	var direct_met := false
	for raw_tag in profile.technology_tags:
		var tag := String(raw_tag)
		if not tag.begins_with("tech."):
			continue
		direct_present = true
		direct_met = direct_met or completed.has(tag)
	if not direct_present or not direct_met:
		return false
	for raw_tag in profile.required_technology_tags:
		var tag := String(raw_tag)
		if tag.begins_with("tech.") and not completed.has(tag):
			return false
	return true

static func _profile_relevant(profile, relevant_goods: Dictionary) -> bool:
	if String(profile.id) == "early_merchant_post":
		return true
	for good_id in profile.output_good_ids:
		if relevant_goods.has(String(good_id)):
			return true
	return false

static func _is_unselected_precious_profile(profile, selected: bool) -> bool:
	if selected:
		return false
	for good_id in profile.output_good_ids:
		if PRECIOUS_GOOD_IDS.has(String(good_id)):
			return true
	for resource_id in profile.resource_ids:
		if PRECIOUS_RESOURCE_IDS.has(String(resource_id)):
			return true
	return false

static func _is_unselected_knowledge_profile(profile, selected: bool) -> bool:
	return not selected and _profile_outputs(profile, "technology_points")

static func _profile_outputs(profile, good_id: String) -> bool:
	return profile.output_good_ids.has(good_id)

static func _useful_count_limit(profile, starter_route: Dictionary, map: MapData,
		cell_idx: int, maximum: int, selected: bool,
		output_efficiency_q16: int = Q16_ONE) -> int:
	if maximum <= 1:
		return maximum
	var output_per_building := 0
	var food_goods: PackedStringArray = starter_route.get(
		"starter_food_good_ids", PackedStringArray())
	for index in range(mini(profile.output_good_ids.size(),
			profile.output_quantities_per_day.size())):
		if food_goods.has(String(profile.output_good_ids[index])):
			output_per_building += _starter_output_quantity(
				int(profile.output_quantities_per_day[index]),
				_production_climate_q16(profile, map, cell_idx), output_efficiency_q16)
	if output_per_building > 0:
		# Leave two buildings above the nominal survival target available to the
		# integer solver; the objective penalizes unused surplus deterministically.
		var largest_food_demand := STARTER_POPULATION * 440
		return mini(maximum, maxi(1 if selected else 0,
			(largest_food_demand * 2 + output_per_building - 1) / output_per_building + 2))
	if _profile_outputs(profile, "clothing"):
		return mini(maximum, 6)
	for good_id in profile.output_good_ids:
		if String(good_id) == "bast_fiber":
			return mini(maximum, 4)
	return mini(maximum, 4 if selected else 2)

static func _resource_building_count_cap(profile, map: MapData, cell_idx: int) -> int:
	if profile.resource_ids.is_empty():
		return -1
	var cap := 0x3fffffff
	for index in range(mini(profile.resource_ids.size(), mini(
			profile.resource_quantities_per_day.size(),
			profile.resource_interaction_modes.size()))):
		var resource_id := String(profile.resource_ids[index])
		var required := float(profile.resource_quantities_per_day[index]) / \
			float(GOODS_SCALE)
		if required <= 0.0:
			return 0
		var reserve := _reserve(map, resource_id, cell_idx)
		if String(profile.resource_interaction_modes[index]) == "capacity":
			cap = mini(cap, floori(reserve / required))
		elif _resource_is_renewable(resource_id):
			if RENEWABLE_SAFE_HARVEST_Q16 > 0:
				cap = mini(cap, floori(_renewable_safe_yield_per_day(
					resource_id, reserve) / required))
			else:
				# Open access has no administrative sustainable-yield gate.
				# The one-day physical stock bound prevents impossible startup
				# extraction; native CPUE determines realized output and profit.
				cap = mini(cap, floori(reserve / required))
		else:
			cap = mini(cap, floori(reserve /
				(required * RESOURCE_RUNWAY_DAYS)))
	return maxi(0, cap)

static func _renewable_safe_yield_per_day(resource_id: String,
		local_reserve: float) -> float:
	var profile = _resource_profiles.get(resource_id)
	if profile == null:
		return 0.0
	var capacity := maxf(0.0, float(profile.ecology_capacity)) * \
		ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE
	var growth := maxf(0.0, float(profile.ecology_growth_rate))
	if capacity <= 0.0 or growth <= 0.0:
		return 0.0
	var reserve_floor := local_reserve * float(RENEWABLE_MIN_RESERVE_Q16) / Q16_ONE
	var yield_biomass := minf(capacity / RENEWABLE_GROWTH_DIVISOR,
		maxf(0.0, local_reserve - reserve_floor))
	return yield_biomass * growth * float(RENEWABLE_SAFE_HARVEST_Q16) / Q16_ONE

static func _resource_is_renewable(resource_id: String) -> bool:
	var profile = _resource_profiles.get(resource_id)
	return profile != null and float(profile.ecology_capacity) > 0.0 \
		and float(profile.ecology_growth_rate) > 0.0

static func _production_climate_q16(profile, map: MapData, cell_idx: int) -> int:
	var climate_id := String(profile.production_climate_profile_id)
	if climate_id.is_empty() or not _climate_profiles.has(climate_id):
		return Q16_ONE
	var climate = _climate_profiles[climate_id]
	var temperature := _array_value(map.temp_arr, cell_idx, 0.5)
	var water := _array_value(map.plant_available_water_arr, cell_idx,
		_array_value(map.moisture_arr, cell_idx, 0.5))
	var temperature_fit := clampf(1.0 - absf(temperature -
		float(climate.temperature_opt)) / maxf(float(climate.temperature_tolerance),
		0.000001), 0.0, 1.0)
	var water_fit := clampf(1.0 - absf(water - float(climate.water_opt)) /
		maxf(float(climate.water_tolerance), 0.000001), 0.0, 1.0)
	var bounded := maxf(float(climate.floor_q16) / Q16_ONE,
		minf(temperature_fit, water_fit))
	var capacity := 1.0 - float(climate.exposure_q16) / Q16_ONE * (1.0 - bounded)
	return clampi(roundi(capacity * Q16_ONE), 0, Q16_ONE)

static func _conditions_met(profile, map: MapData, cell_idx: int) -> bool:
	if profile.condition_opcodes.is_empty():
		return true
	var stack: Array[bool] = []
	for index in range(profile.condition_opcodes.size()):
		match int(profile.condition_opcodes[index]):
			1:
				var actual := _condition_signal(profile, index, map, cell_idx)
				stack.append(_compare_condition(actual,
					int(profile.condition_compares[index]),
					int(profile.condition_values[index])))
			2:
				if stack.size() < 2: return false
				var right_and := bool(stack.pop_back())
				var left_and := bool(stack.pop_back())
				stack.append(left_and and right_and)
			3:
				if stack.size() < 2: return false
				var right_or := bool(stack.pop_back())
				var left_or := bool(stack.pop_back())
				stack.append(left_or or right_or)
			4:
				if stack.is_empty(): return false
				stack.append(not bool(stack.pop_back()))
			_:
				return false
	return stack.size() == 1 and bool(stack[0])

static func _condition_signal(profile, token: int, map: MapData, cell_idx: int) -> int:
	match int(profile.condition_signals[token]):
		0: return roundi(_array_value(map.temp_arr, cell_idx, 0.5) * Q16_ONE)
		1: return roundi(_array_value(map.moisture_arr, cell_idx, 0.5) * Q16_ONE)
		2: return roundi(_array_value(map.snow_cover_arr, cell_idx, 0.0) * Q16_ONE)
		3: return roundi(_array_value(map.weather_intensity_arr, cell_idx, 0.0) * Q16_ONE)
		4: return roundi(_array_value(map.elevation_arr, cell_idx, 0.0) * Q16_ONE)
		5: return int(map.terrain_arr[cell_idx]) if cell_idx < map.terrain_arr.size() else 0
		6: return int(map.landform_arr[cell_idx]) if cell_idx < map.landform_arr.size() else 0
		7: return int(map.vegetation_arr[cell_idx]) if cell_idx < map.vegetation_arr.size() else 0
		8: return int(map.is_water_arr[cell_idx]) if cell_idx < map.is_water_arr.size() else 0
		9: return int(map.has_river_arr[cell_idx]) if cell_idx < map.has_river_arr.size() else 0
		10:
			return roundi(_reserve(map, String(profile.condition_reference_ids[token]),
				cell_idx) * GOODS_SCALE)
	return 0

static func _compare_condition(actual: int, compare: int, expected: int) -> bool:
	match compare:
		0: return actual == expected
		1: return actual != expected
		2: return actual < expected
		3: return actual <= expected
		4: return actual > expected
		5: return actual >= expected
	return false

static func _reserve(map: MapData, resource_id: String, cell_idx: int) -> float:
	var profile = _resource_profiles.get(resource_id)
	if profile == null:
		return 0.0
	var field := ResourceProfileRegistry.reserve_map_field(profile)
	if field.is_empty():
		return 0.0
	var values = map.get(field)
	if not values is PackedFloat32Array or cell_idx < 0 or cell_idx >= values.size():
		return 0.0
	var actual := maxf(0.0, float(values[cell_idx]))
	if _active_reserve_overlay.has(resource_id):
		return maxf(actual, float(_active_reserve_overlay[resource_id]))
	return actual

static func _array_value(values: PackedFloat32Array, index: int,
		fallback: float) -> float:
	return float(values[index]) if index >= 0 and index < values.size() else fallback

static func _primary_building_first(ids: PackedStringArray,
		counts: PackedInt64Array, primary_id: String) -> Dictionary:
	var primary_index := ids.find(primary_id)
	if primary_index <= 0:
		return {"ids": ids, "counts": counts}
	var ordered_ids := PackedStringArray([primary_id])
	var ordered_counts := PackedInt64Array([counts[primary_index]])
	for index in range(ids.size()):
		if index == primary_index:
			continue
		ordered_ids.append(ids[index])
		ordered_counts.append(counts[index])
	return {"ids": ordered_ids, "counts": ordered_counts}

static func _ensure_profiles_loaded() -> void:
	if not _building_profiles.is_empty():
		return
	ResourceProfileRegistry.ensure_loaded()
	for profile in ResourceProfileRegistry.ordered():
		_resource_profiles[String(profile.id)] = profile
	var building_paths := PackedStringArray()
	for file_name in ResourceLoader.list_directory(BUILDING_DIR):
		if file_name.get_extension().to_lower() == "tres":
			building_paths.append("%s/%s" % [BUILDING_DIR, file_name])
	building_paths.sort()
	for path in building_paths:
		var profile = ResourceLoader.load(path, "Resource")
		if profile is BuildingProfile and not String(profile.id).is_empty():
			_building_profiles.append(profile)
	_building_profiles.sort_custom(func(a, b) -> bool:
		return String(a.id) < String(b.id))
	for file_name in ResourceLoader.list_directory(PRODUCTION_CLIMATE_DIR):
		if file_name.get_extension().to_lower() != "tres":
			continue
		var profile = ResourceLoader.load(
			"%s/%s" % [PRODUCTION_CLIMATE_DIR, file_name], "Resource")
		if profile != null and not String(profile.get("id")).is_empty():
			_climate_profiles[String(profile.id)] = profile

static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
