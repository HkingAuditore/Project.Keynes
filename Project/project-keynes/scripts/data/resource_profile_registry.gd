# resource_profile_registry.gd
# Single-point accessor for all natural-resource ResourceProfile definitions.
# Lazy-loaded on first access, cached in a static ordered Array.
#
# 顺序即权威：`_PROFILE_PATHS` 的下标 = C++ run_natural_resource_pass 的资源索引。
# 新增一种资源的 SOP：
#   1) 在 component_ids.gd / map_data.gd / component_schema.gd 加对应 reserve + extra_change 字段；
#   2) 跑 tools/codegen/gen_cpp_bind_table.py 重新生成 C++ bind table；
#   3) 新建 data/resources/<res>.tres（reserve_component 指向该字段）；
#   4) 在本文件 _PROFILE_PATHS 追加路径；
#   5) 重 build GDExtension。
#
# Consumers: MapGenerator（初始储量 bootstrap + 每日 pass knobs / fallback），
# NaturalResourceDailySystem（间接，经 generator helper）。

class_name ResourceProfileRegistry

# 显式 preload，保证 ResourceProfile 类在本脚本解析前已被 Godot 加载。
const _ResourceProfileScript = preload("res://scripts/data/resource_profile.gd")

# 一个战略地图格约代表广东省量级面积。Profile 中的数量系数以基础区域为标定单位，
# 所有初始储量、最低矿床和自然增减量统一按此面积倍率换算；增长/衰减率不缩放。
const CELL_AREA_RESOURCE_SCALE: float = 100.0

const _PROFILE_PATHS: Array = [
	"res://data/resources/timber.tres",
	"res://data/resources/stone.tres",
	"res://data/resources/fertile_soil.tres",
	"res://data/resources/arable_land.tres",
	"res://data/resources/paddy_land.tres",
	"res://data/resources/plantation_land.tres",
	"res://data/resources/pasture.tres",
	"res://data/resources/coal.tres",
	"res://data/resources/oil.tres",
	"res://data/resources/natural_gas.tres",
	"res://data/resources/copper_ore.tres",
	"res://data/resources/iron_ore.tres",
	"res://data/resources/gold_ore.tres",
	"res://data/resources/silver_ore.tres",
	"res://data/resources/salt.tres",
	"res://data/resources/saltpeter.tres",
	"res://data/resources/rare_earth.tres",
	"res://data/resources/clay.tres",
	"res://data/resources/wild_game.tres",
	"res://data/resources/marine_fish.tres",
	"res://data/resources/bauxite.tres",
	"res://data/resources/limestone.tres",
	"res://data/resources/silica_sand.tres",
	"res://data/resources/phosphate_rock.tres",
	"res://data/resources/tin_ore.tres",
	"res://data/resources/lead_ore.tres",
	"res://data/resources/zinc_ore.tres",
	"res://data/resources/manganese_ore.tres",
	"res://data/resources/sulfur.tres",
	"res://data/resources/flint.tres",
	"res://data/resources/freshwater_fish.tres",
]

static var _ordered: Array = []        # Array[ResourceProfile]，按 _PROFILE_PATHS 顺序
static var _loaded: bool = false


# Idempotent bulk loader. 加载失败的条目跳过并 push_warning，不崩溃。
static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_ordered.clear()
	for path in _PROFILE_PATHS:
		var res := ResourceLoader.load(path, "Resource") as ResourceProfile
		if res == null:
			push_warning("ResourceProfileRegistry: failed to load %s" % path)
			continue
		if float(res.temp_lo) < 0.0 or float(res.temp_hi) > 1.0 \
				or float(res.temp_hi) <= float(res.temp_lo):
			push_error("ResourceProfileRegistry: %s uses invalid temperature range [%s,%s]; expected normalized [0,1]" % [
				path, str(res.temp_lo), str(res.temp_hi)])
			continue
		if float(res.init_target_coverage) + float(res.init_micro_coverage) > 1.000001:
			push_error("ResourceProfileRegistry: %s core + micro coverage exceeds 1.0" % path)
			continue
		if float(res.init_micro_coverage) > 0.0 \
				and float(res.init_micro_reserve_share) <= 0.0 \
				and float(res.init_micro_min_reserve) <= 0.0:
			push_error("ResourceProfileRegistry: %s configures zero-reserve micro deposits" % path)
			continue
		_ordered.append(res)


# 有序资源列表（下标 = C++ pass 资源索引）。
static func ordered() -> Array:
	ensure_loaded()
	return _ordered


static func count() -> int:
	ensure_loaded()
	return _ordered.size()

## Deposits remain present in MapData regardless of this result. This helper is
## for inspectors/map overlays only; extraction is independently gated by the
## extractor building's `technology_tags` in NativeEconomyRuntime.
static func discovery_visible(p: ResourceProfile,
		unlocked_technology_ids: PackedStringArray) -> bool:
	if p == null:
		return false
	for tag in p.discovery_technology_tags:
		var stable_id := String(tag)
		if stable_id.begins_with("tech.") and not unlocked_technology_ids.has(stable_id):
			return false
	return true

static func habitat_code(p: ResourceProfile) -> int:
	if p == null:
		return -1
	var habitat := String(p.habitat_mode)
	if habitat == "legacy":
		habitat = "land" if p.land_only else "any"
	# Transitional aliases for hand-authored profiles from the first habitat revision.
	if habitat == "marine_access": habitat = "marine_water"
	if habitat == "freshwater_access": habitat = "freshwater"
	return int({"any": 0, "land": 1, "marine_water": 2,
		"freshwater": 3, "coastal_land": 4,
		"coastal_or_marine": 5}.get(habitat, -1))


static func habitat_available(p: ResourceProfile, mask: int) -> bool:
	match habitat_code(p):
		0: return true
		1: return (mask & 1) != 0
		2: return (mask & 2) != 0
		3: return (mask & 4) != 0
		4: return (mask & 8) != 0
		5: return (mask & (2 | 8)) != 0
	return false


# 某 profile 储量字段对应的 MapData 属性名（map_field，如 "res_timber_reserve_arr"）。
# 经 component_schema 查表，避免 .tres 重复维护。
static func reserve_map_field(p: ResourceProfile) -> String:
	if p == null:
		return ""
	var e: Dictionary = DCComponentSchema.find_by_name(p.reserve_component)
	return String(e.get("map_field", "")) if not e.is_empty() else ""


## Stable normalization shared by the Inspector and player map overlay.
## It is profile-derived, so the color of a deposit does not jump when an
## unrelated cell becomes the current world maximum.
static func reference_reserve(p: ResourceProfile) -> float:
	if p == null:
		return 1.0
	var initial_peak := float(p.init_base)
	initial_peak += maxf(float(p.init_temp), 0.0)
	initial_peak += maxf(float(p.init_moisture), 0.0)
	initial_peak += maxf(float(p.init_elevation), 0.0)
	initial_peak += maxf(float(p.init_river), 0.0)
	initial_peak += maxf(float(p.init_volcano), 0.0)
	initial_peak += maxf(float(p.init_ocean_current), 0.0)
	initial_peak += maxf(float(p.init_upwelling), 0.0)
	initial_peak += maxf(float(p.init_estuary), 0.0)
	initial_peak += maxf(float(p.init_noise), 0.0)
	initial_peak += maxf(float(p.init_climate_fit), 0.0)
	initial_peak += maxf(float(p.init_province) * 0.90, 0.0)
	initial_peak += maxf(float(p.init_belt) * 0.56, 0.0)
	initial_peak += _max_positive_weight(p.init_landform_weights)
	initial_peak += _max_positive_weight(p.init_vegetation_weights)
	initial_peak *= maxf(float(p.init_reserve_scale), 0.0)
	# `init_min_reserve` is applied after ranking but before the shared cell-area
	# multiplier in MapGenerator. Keep the reference in exactly the same units;
	# multiplying the suitability peak first made coverage-guaranteed resources
	# (for example arable land) saturate the overlay at 1.0.
	initial_peak = maxf(initial_peak, float(p.init_floor_reserve))
	initial_peak = maxf(initial_peak, float(p.init_min_reserve))
	initial_peak *= CELL_AREA_RESOURCE_SCALE
	if float(p.init_target_coverage) > 0.0:
		var normalized_mean := float(p.init_target_mean_reserve) * CELL_AREA_RESOURCE_SCALE
		if float(p.init_target_reserve_density) > 0.0:
			normalized_mean = float(p.init_target_reserve_density) * \
				CELL_AREA_RESOURCE_SCALE / float(p.init_target_coverage)
		initial_peak = maxf(initial_peak, normalized_mean)

	var runtime_peak := 0.0
	if float(p.ecology_capacity) > 0.0:
		runtime_peak = float(p.ecology_capacity) * CELL_AREA_RESOURCE_SCALE
	elif float(p.decay_self) > 0.000001:
		var production := float(p.gen_base) + float(p.gen_self) - float(p.decay_base)
		production += maxf(float(p.gen_temp) - float(p.decay_temp), 0.0)
		production += maxf(float(p.gen_moisture) - float(p.decay_moisture), 0.0)
		runtime_peak = maxf(production, 0.0) * CELL_AREA_RESOURCE_SCALE / float(p.decay_self)
	return maxf(maxf(initial_peak, runtime_peak), 1.0)


## Semantic icon registration for profiles that do not yet carry a Texture2D.
## UI consumers render these keys through the project's Font Awesome system.
static func icon_key(p: ResourceProfile) -> StringName:
	if p == null:
		return &"system.unknown"
	var id := String(p.id)
	return {
		"timber": &"resource.wood",
		"stone": &"resource.rock",
		"fertile_soil": &"resource.fertile_soil",
		"arable_land": &"resource.arable_land",
		"paddy_land": &"resource.paddy_land",
		"plantation_land": &"resource.plantation_land",
		"pasture": &"resource.pasture",
		"coal": &"resource.coal",
		"oil": &"resource.oil",
		"natural_gas": &"resource.natural_gas",
		"copper_ore": &"resource.copper",
		"iron_ore": &"resource.iron",
		"gold_ore": &"resource.gold",
		"silver_ore": &"resource.silver",
		"salt": &"resource.salt_deposit",
		"saltpeter": &"resource.saltpeter",
		"rare_earth": &"resource.rare_earth",
		"clay": &"resource.clay",
		"wild_game": &"resource.animal",
		"marine_fish": &"resource.marine_fish",
		"bauxite": &"resource.bauxite",
		"limestone": &"resource.limestone",
		"silica_sand": &"resource.silica_sand",
		"phosphate_rock": &"resource.phosphate_rock",
		"tin_ore": &"resource.tin",
		"lead_ore": &"resource.lead",
		"zinc_ore": &"resource.zinc",
		"manganese_ore": &"resource.manganese",
		"sulfur": &"resource.sulfur",
		"flint": &"resource.flint",
		"freshwater_fish": &"resource.freshwater_fish",
	}.get(id, &"system.unknown") as StringName


static func _max_positive_weight(weights: Dictionary) -> float:
	var result := 0.0
	for raw in weights.values():
		result = maxf(result, float(raw))
	return result


# 某 profile 储量字段对应的 C++ slot 名（cpp_name，如 "cell_res_timber_reserve"）。
static func reserve_cpp_name(p: ResourceProfile) -> String:
	if p == null:
		return ""
	var e: Dictionary = DCComponentSchema.find_by_name(p.reserve_component)
	return String(e.get("cpp_name", "")) if not e.is_empty() else ""


# 某 profile 对应的额外变化 C++ slot 名（如 "cell_res_timber_extra_change"）。
# 命名从 reserve_component 派生，避免每个 .tres 重复维护。
static func extra_change_cpp_name(p: ResourceProfile) -> String:
	if p == null:
		return ""
	var extra_name := StringName(String(p.reserve_component).replace("_reserve", "_extra_change"))
	var e: Dictionary = DCComponentSchema.find_by_name(extra_name)
	return String(e.get("cpp_name", "")) if not e.is_empty() else ""


# 某 profile 对应的额外变化 MapData 字段名（如 "res_timber_extra_change_arr"）。
static func extra_change_map_field(p: ResourceProfile) -> String:
	if p == null:
		return ""
	var extra_name := StringName(String(p.reserve_component).replace("_reserve", "_extra_change"))
	var e: Dictionary = DCComponentSchema.find_by_name(extra_name)
	return String(e.get("map_field", "")) if not e.is_empty() else ""


# 组装 DCWorldExt.run_natural_resource_pass 的 knobs（不含 n_cells，由调用方补）。
# 所有平行数组按资源索引对齐；schema 缺失（cpp_name 为空）的资源会被整体跳过。
static func build_pass_knobs() -> Dictionary:
	ensure_loaded()
	var quantity_scale := CELL_AREA_RESOURCE_SCALE
	var resource_ids := PackedStringArray()
	var reserve_slots := PackedStringArray()
	var extra_change_slots := PackedStringArray()
	var habitat_modes := PackedInt32Array()
	var temp_lo := PackedFloat32Array()
	var temp_hi := PackedFloat32Array()
	var temperature_signals := PackedInt32Array()
	var moisture_signals := PackedInt32Array()
	var gen_base := PackedFloat32Array()
	var gen_temp := PackedFloat32Array()
	var gen_moisture := PackedFloat32Array()
	var gen_self := PackedFloat32Array()
	var decay_base := PackedFloat32Array()
	var decay_temp := PackedFloat32Array()
	var decay_moisture := PackedFloat32Array()
	var decay_self := PackedFloat32Array()
	var climate_temp_opt := PackedFloat32Array()
	var climate_temp_tol := PackedFloat32Array()
	var climate_moisture_opt := PackedFloat32Array()
	var climate_moisture_tol := PackedFloat32Array()
	var runtime_climate_fit_weight := PackedFloat32Array()
	var decay_stress := PackedFloat32Array()
	var ecology_capacity := PackedFloat32Array()
	var ecology_growth_rate := PackedFloat32Array()
	var ecology_immigration := PackedFloat32Array()
	var ecology_stress_mortality_rate := PackedFloat32Array()
	for p in _ordered:
		var cpp_name: String = reserve_cpp_name(p)
		var extra_cpp_name: String = extra_change_cpp_name(p)
		if cpp_name == "" or extra_cpp_name == "":
			push_warning("ResourceProfileRegistry: resource '%s' has incomplete schema entry for %s; skipped" % [
				String(p.id), String(p.reserve_component)])
			continue
		resource_ids.append(String(p.id))
		reserve_slots.append(cpp_name)
		extra_change_slots.append(extra_cpp_name)
		habitat_modes.append(habitat_code(p))
		temp_lo.append(p.temp_lo)
		temp_hi.append(p.temp_hi)
		temperature_signals.append(1 if String(p.runtime_temperature_signal) == "mean_30d" else 0)
		moisture_signals.append(1 if String(p.runtime_moisture_signal) == "plant_available_water" else 0)
		gen_base.append(p.gen_base * quantity_scale)
		gen_temp.append(p.gen_temp * quantity_scale)
		gen_moisture.append(p.gen_moisture * quantity_scale)
		gen_self.append(p.gen_self * quantity_scale)
		decay_base.append(p.decay_base * quantity_scale)
		decay_temp.append(p.decay_temp * quantity_scale)
		decay_moisture.append(p.decay_moisture * quantity_scale)
		decay_self.append(p.decay_self)
		climate_temp_opt.append(p.climate_temp_opt)
		climate_temp_tol.append(p.climate_temp_tol)
		climate_moisture_opt.append(p.climate_moisture_opt)
		climate_moisture_tol.append(p.climate_moisture_tol)
		runtime_climate_fit_weight.append(p.runtime_climate_fit_weight)
		decay_stress.append(p.decay_stress * quantity_scale)
		ecology_capacity.append(p.ecology_capacity * quantity_scale)
		ecology_growth_rate.append(p.ecology_growth_rate)
		ecology_immigration.append(p.ecology_immigration * quantity_scale)
		ecology_stress_mortality_rate.append(p.ecology_stress_mortality_rate)
	return {
		"resource_count": reserve_slots.size(),
		"resource_ids": resource_ids,
		"reserve_slots": reserve_slots,
		"extra_change_slots": extra_change_slots,
		"habitat_modes": habitat_modes,
		"habitat_mask_slot": "cell_resource_habitat_mask",
		"temp_lo": temp_lo,
		"temp_hi": temp_hi,
		"temperature_signals": temperature_signals,
		"moisture_signals": moisture_signals,
		"gen_base": gen_base,
		"gen_temp": gen_temp,
		"gen_moisture": gen_moisture,
		"gen_self": gen_self,
		"decay_base": decay_base,
		"decay_temp": decay_temp,
		"decay_moisture": decay_moisture,
		"decay_self": decay_self,
		"climate_temp_opt": climate_temp_opt,
		"climate_temp_tol": climate_temp_tol,
		"climate_moisture_opt": climate_moisture_opt,
		"climate_moisture_tol": climate_moisture_tol,
		"runtime_climate_fit_weight": runtime_climate_fit_weight,
		"decay_stress": decay_stress,
		"ecology_capacity": ecology_capacity,
		"ecology_growth_rate": ecology_growth_rate,
		"ecology_immigration": ecology_immigration,
		"ecology_stress_mortality_rate": ecology_stress_mortality_rate,
	}
