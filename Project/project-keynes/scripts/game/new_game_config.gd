class_name NewGameConfig
extends RefCounted

const SCHEMA_VERSION := 3
const LEGACY_SCHEMA_VERSION := 2
const MIN_SEED := 1
const MAX_SEED := 2147483647
const MIN_FOREIGN_COUNT := 0
const MAX_FOREIGN_COUNT := 12
const DEFAULT_FOREIGN_COUNT := 5
const CUSTOM_LAND_LAYOUT := "custom"
const DEFAULT_LAND_LAYOUT := "two"
const SIZE_PRESETS := {
	"small": Vector2i(40, 28),
	"standard": Vector2i(60, 40),
	"large": Vector2i(100, 64),
}
## Player-facing land-layout presets. Numeric knobs must keep continents
## separable: continent_size 0.9 plus two cores merges into one Pangaea.
const LAND_LAYOUT_PRESETS := [
	{
		"id": "single",
		"label": "单个大陆",
		"hint": "一块大型陆地，周围只有少量岛屿。",
		"num_continents": 1,
		"continent_size": 0.78,
		"sea_level": 0.44,
		"continent_spacing": 40,
		"island_amount": 28,
	},
	{
		"id": "two",
		"label": "两个大陆",
		"hint": "两块被海洋隔开的主陆，适合对峙与跨海接触。",
		"num_continents": 2,
		"continent_size": 0.50,
		"sea_level": 0.50,
		"continent_spacing": 92,
		"island_amount": 38,
	},
	{
		"id": "multiple",
		"label": "多个大陆",
		"hint": "三四块分散的陆地，中间是开阔大洋。",
		"num_continents": 4,
		"continent_size": 0.40,
		"sea_level": 0.52,
		"continent_spacing": 88,
		"island_amount": 46,
	},
	{
		"id": "archipelago",
		"label": "群岛",
		"hint": "许多小岛与破碎陆核，海洋占主导。",
		"num_continents": 6,
		"continent_size": 0.28,
		"sea_level": 0.56,
		"continent_spacing": 70,
		"island_amount": 92,
	},
	{
		"id": CUSTOM_LAND_LAYOUT,
		"label": "自定义",
		"hint": "使用高级地图设置中的大陆数量、规模、海平面与分散度。",
	},
]

var country: Dictionary = {
	"name": "新国家",
	"foreign_count": DEFAULT_FOREIGN_COUNT,
}
var base: Dictionary = {
	"map_width": 60,
	"map_height": 40,
	"initial_seed": 1,
	"land_layout": DEFAULT_LAND_LAYOUT,
	"sea_level": 0.50,
	"num_continents": 2,
	"continent_size": 0.50,
	"river_count": 8,
}
var world_controls: Dictionary = {}
var climate: Dictionary = {}
var research: Dictionary = {
	"starting_country_cash": 2500000000000,
	"procurement_budget_per_day": 10000000,
	"domain_weights_bp": PackedInt32Array([2500, 2500, 2500, 2500]),
	"auto_purchase_enabled": true,
}


static func create_default() -> NewGameConfig:
	var config := NewGameConfig.new()
	config.base.initial_seed = random_seed()
	config.apply_land_layout(DEFAULT_LAND_LAYOUT)
	return config


static func random_seed() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return rng.randi_range(MIN_SEED, MAX_SEED)


static func land_layout_by_id(layout_id: String) -> Dictionary:
	for preset in LAND_LAYOUT_PRESETS:
		if String((preset as Dictionary).get("id", "")) == layout_id:
			return preset
	return {}


static func land_layout_index(layout_id: String) -> int:
	for index in range(LAND_LAYOUT_PRESETS.size()):
		if String((LAND_LAYOUT_PRESETS[index] as Dictionary).get("id", "")) == layout_id:
			return index
	return LAND_LAYOUT_PRESETS.size() - 1


func apply_land_layout(layout_id: String) -> bool:
	var preset := land_layout_by_id(layout_id)
	if preset.is_empty():
		return false
	base.land_layout = String(preset.get("id", CUSTOM_LAND_LAYOUT))
	if String(preset.get("id", "")) == CUSTOM_LAND_LAYOUT:
		return true
	base.num_continents = int(preset.get("num_continents", 2))
	base.continent_size = float(preset.get("continent_size", 0.50))
	base.sea_level = float(preset.get("sea_level", 0.50))
	world_controls["continent_spacing"] = int(preset.get("continent_spacing", 55))
	world_controls["island_amount"] = int(preset.get("island_amount", 50))
	climate.clear()
	return true


func validate() -> Dictionary:
	var normalized_name := String(country.get("name", "")).strip_edges()
	if normalized_name.is_empty():
		return _error("country_name_empty", "国家名称不能为空。")
	if normalized_name.length() > 32:
		return _error("country_name_too_long", "国家名称不能超过 32 个字符。")
	for index in range(normalized_name.length()):
		var codepoint := normalized_name.unicode_at(index)
		if codepoint < 32 or codepoint == 127:
			return _error("country_name_control_character", "国家名称不能包含控制字符。")
	country.name = normalized_name
	var foreign_count := int(country.get("foreign_count", DEFAULT_FOREIGN_COUNT))
	if foreign_count < MIN_FOREIGN_COUNT or foreign_count > MAX_FOREIGN_COUNT:
		return _error("foreign_count_out_of_range",
			"外国数量必须在 %d 到 %d 之间。" % [MIN_FOREIGN_COUNT, MAX_FOREIGN_COUNT])
	country.foreign_count = foreign_count

	var seed := int(base.get("initial_seed", 0))
	if seed < MIN_SEED or seed > MAX_SEED:
		return _error("seed_out_of_range", "地图种子必须在 1 到 2147483647 之间。")
	var width := int(base.get("map_width", 0))
	var height := int(base.get("map_height", 0))
	var max_width := DCFeatureFlags.max_map_width()
	var max_height := DCFeatureFlags.max_map_height()
	if width < 10 or width > max_width or height < 8 or height > max_height:
		return _error("map_size_out_of_range",
			"地图尺寸必须在 10..%d x 8..%d 范围内。" % [max_width, max_height])
	base.map_width = width
	base.map_height = height
	base.initial_seed = seed
	base.sea_level = clampf(float(base.get("sea_level", 0.50)), 0.1, 0.8)
	base.num_continents = clampi(int(base.get("num_continents", 2)), 1, 8)
	base.continent_size = clampf(float(base.get("continent_size", 0.50)), 0.2, 0.9)
	base.river_count = clampi(int(base.get("river_count", 8)), 0, 30)
	var layout_id := String(base.get("land_layout", ""))
	if layout_id.is_empty() or land_layout_by_id(layout_id).is_empty():
		layout_id = CUSTOM_LAND_LAYOUT
	base.land_layout = layout_id
	var starting_cash := int(research.get("starting_country_cash", -1))
	var procurement_budget := int(research.get("procurement_budget_per_day", -1))
	var weights: PackedInt32Array = research.get("domain_weights_bp", PackedInt32Array())
	if starting_cash < 0 or procurement_budget < 0 or weights.size() != 4:
		return _error("research_policy_invalid", "科研财政配置无效。")
	var weight_total := 0
	for weight in weights:
		if weight < 0 or weight > 10000:
			return _error("research_policy_invalid", "科研权重必须位于 0..100%。")
		weight_total += weight
	if weight_total != 10000:
		return _error("research_weight_total_invalid", "科研权重总和必须为 100%。")
	research.starting_country_cash = starting_cash
	research.procurement_budget_per_day = procurement_budget
	research.domain_weights_bp = weights
	research.auto_purchase_enabled = bool(research.get("auto_purchase_enabled", true))
	return {"ok": true, "code": "ok", "message": ""}


func to_dictionary() -> Dictionary:
	if climate.is_empty() and not world_controls.is_empty():
		climate = derive_climate(world_controls)
	return {
		"schema": "NewGameConfig",
		"version": SCHEMA_VERSION,
		"country": country.duplicate(true),
		"base": base.duplicate(true),
		"world_controls": world_controls.duplicate(true),
		"climate": climate.duplicate(true),
		"research": research.duplicate(true),
	}


static func derive_climate(controls: Dictionary) -> Dictionary:
	var wetness := _pct(controls, "wetness", 55.0)
	var lake_density := _pct(controls, "lake_density", 45.0)
	var river_density := _pct(controls, "river_density", 55.0)
	var volcano_amount := _pct(controls, "volcano_amount", 40.0)
	var climate := {
		"moisture_land_base": _mix(0.08, 0.30, wetness),
		"moisture_precip_gain": _mix(2.0, 4.8, wetness),
		"moisture_continental_dry": _mix(0.045, 0.012, wetness),
		# [zonal-envelope] 越湿→ITCZ/风暴路径增雨越强、极地抑雨越弱（保持单调）
		"moisture_itcz_wet_strength": _mix(0.6, 1.2, wetness),
		"moisture_stormtrack_wet_strength": _mix(0.3, 0.7, wetness),
		"moisture_polar_dry_strength": _mix(0.5, 0.25, wetness),
		"moisture_tropical_evap_boost": _mix(0.6, 1.4, wetness),
		"hydro_lake_min_cells": _mixi(16, 4, lake_density),
		"hydro_lake_min_depth": _mix(0.030, 0.010, lake_density),
		"hydro_lake_min_volume": _mix(0.50, 0.10, lake_density),
		"river_channel_init_cells": _mixi(30, 7, river_density),
		"max_volcanoes": _mixi(0, 18, volcano_amount),
		"volcano_min_dist": _mixi(14, 3, volcano_amount),
	}
	if controls.has("continent_spacing") or controls.has("island_amount"):
		var continent_spacing := _pct(controls, "continent_spacing", 55.0)
		var island_amount := _pct(controls, "island_amount", 50.0)
		var coast_for_islands := _pct(controls, "coast_roughness", 50.0)
		var offshore_strength: float = clampf((island_amount + coast_for_islands) * 0.5, 0.0, 1.0)
		climate["main_separation_factor"] = _mix(0.62, 1.12, continent_spacing)
		climate["satellites_per_main"] = _mixi(0, 7, island_amount)
		climate["satellite_radius_min"] = _mix(0.26, 0.12, island_amount)
		climate["satellite_radius_max"] = _mix(0.48, 0.28, island_amount)
		climate["satellite_separation_factor"] = _mix(0.30, 0.80, continent_spacing)
		climate["offshore_amp"] = _mix(0.20, 0.70, offshore_strength)
	if controls.has("coast_roughness"):
		var coast_roughness := _pct(controls, "coast_roughness", 50.0)
		climate["continent_warp_amp"] = _mix(0.04, 0.30, coast_roughness)
		climate["meso_weight"] = _mix(0.12, 0.48, coast_roughness)
	if controls.has("relief_amount"):
		climate["macro_relief_weight"] = _mix(0.08, 0.45, _pct(controls, "relief_amount", 55.0))
	if controls.has("mountain_amount"):
		var mountain_amount := _pct(controls, "mountain_amount", 60.0)
		climate["ridge_boost_amp"] = _mix(0.25, 1.15, mountain_amount)
		climate["spl_uplift_rate"] = _mix(0.04, 0.18, mountain_amount)
		climate["orographic_boost"] = _mix(0.35, 2.2, mountain_amount)
	if controls.has("valley_amount"):
		var valley_amount := _pct(controls, "valley_amount", 45.0)
		climate["spl_iters"] = _mixi(0, 30, valley_amount)
		climate["spl_erodibility"] = _mix(0.35, 2.60, valley_amount)
	if controls.has("coastal_wetness"):
		var coastal_wetness := _pct(controls, "coastal_wetness", 55.0)
		climate["moisture_coastal_floor"] = _mix(0.25, 0.62, coastal_wetness)
		climate["coastal_moisture_boost"] = _mix(0.05, 0.38, coastal_wetness)
	if controls.has("rain_shadow"):
		var rain_shadow := _pct(controls, "rain_shadow", 50.0)
		climate["rain_shadow_threshold"] = _mix(0.22, 0.06, rain_shadow)
		climate["rain_shadow_factor"] = _mix(0.88, 0.28, rain_shadow)
		climate["rain_shadow_lookback"] = _mixi(1, 5, rain_shadow)
	if controls.has("lake_size"):
		var lake_size := _pct(controls, "lake_size", 55.0)
		climate["lake_seed_freq"] = _mix(0.090, 0.035, lake_size)
		climate["lake_seed_depth"] = _mix(0.05, 0.16, lake_size)
		climate["lake_seed_min_interior"] = 0.12
	if controls.has("lake_density"):
		climate["lake_seed_threshold"] = _mix(0.72, 0.48, _pct(controls, "lake_density", 45.0))
	if controls.has("short_rivers"):
		climate["hydro_river_min_length"] = _mixi(10, 3, _pct(controls, "short_rivers", 50.0))
	if controls.has("volcano_amount"):
		climate["volcano_min_land_h"] = _mix(0.78, 0.52, volcano_amount)
	return climate


static func from_dictionary(value: Dictionary) -> Dictionary:
	if String(value.get("schema", "")) != "NewGameConfig":
		return _error("config_schema_invalid", "新游戏配置格式无效。")
	var source_version := int(value.get("version", -1))
	if source_version != SCHEMA_VERSION and source_version != LEGACY_SCHEMA_VERSION:
		return _error("config_version_incompatible", "新游戏配置版本不兼容。")
	var config := NewGameConfig.new()
	config.country = (value.get("country", {}) as Dictionary).duplicate(true)
	if source_version == LEGACY_SCHEMA_VERSION:
		config.country.foreign_count = 0
	config.base = (value.get("base", {}) as Dictionary).duplicate(true)
	config.world_controls = (value.get("world_controls", {}) as Dictionary).duplicate(true)
	config.climate = (value.get("climate", {}) as Dictionary).duplicate(true)
	config.research = (value.get("research", {}) as Dictionary).duplicate(true)
	var validation := config.validate()
	if not bool(validation.get("ok", false)):
		return validation
	return {
		"ok": true,
		"code": "ok",
		"message": "",
		"config": config,
		"migrated_from_version": source_version if source_version != SCHEMA_VERSION else 0,
	}


static func _pct(controls: Dictionary, name: String, default_value: float) -> float:
	return clampf(float(controls.get(name, default_value)) / 100.0, 0.0, 1.0)


static func _mix(a: float, b: float, t: float) -> float:
	return lerpf(a, b, clampf(t, 0.0, 1.0))


static func _mixi(a: int, b: int, t: float) -> int:
	return int(round(_mix(float(a), float(b), t)))


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
