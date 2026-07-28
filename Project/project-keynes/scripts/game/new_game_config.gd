class_name NewGameConfig
extends RefCounted

const SCHEMA_VERSION := 2
const MIN_SEED := 1
const MAX_SEED := 2147483647
const SIZE_PRESETS := {
	"small": Vector2i(40, 28),
	"standard": Vector2i(60, 40),
	"large": Vector2i(100, 64),
}

var country: Dictionary = {"name": "新国家"}
var base: Dictionary = {
	"map_width": 60,
	"map_height": 40,
	"initial_seed": 1,
	"sea_level": 0.42,
	"num_continents": 2,
	"continent_size": 0.9,
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
	return config


static func random_seed() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return rng.randi_range(MIN_SEED, MAX_SEED)


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

	var seed := int(base.get("initial_seed", 0))
	if seed < MIN_SEED or seed > MAX_SEED:
		return _error("seed_out_of_range", "地图种子必须在 1 到 2147483647 之间。")
	var width := int(base.get("map_width", 0))
	var height := int(base.get("map_height", 0))
	if width < 10 or width > 500 or height < 8 or height > 400:
		return _error("map_size_out_of_range", "地图尺寸必须在 10..500 x 8..400 范围内。")
	base.map_width = width
	base.map_height = height
	base.initial_seed = seed
	base.sea_level = clampf(float(base.get("sea_level", 0.42)), 0.1, 0.8)
	base.num_continents = clampi(int(base.get("num_continents", 2)), 1, 8)
	base.continent_size = clampf(float(base.get("continent_size", 0.9)), 0.2, 0.9)
	base.river_count = clampi(int(base.get("river_count", 8)), 0, 30)
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
	var wetness := clampf(float(controls.get("wetness", 55)) / 100.0, 0.0, 1.0)
	var lake_density := clampf(float(controls.get("lake_density", 45)) / 100.0, 0.0, 1.0)
	var river_density := clampf(float(controls.get("river_density", 55)) / 100.0, 0.0, 1.0)
	var volcano_amount := clampf(float(controls.get("volcano_amount", 40)) / 100.0, 0.0, 1.0)
	return {
		"moisture_land_base": lerpf(0.08, 0.30, wetness),
		"moisture_precip_gain": lerpf(2.0, 4.8, wetness),
		"moisture_continental_dry": lerpf(0.045, 0.012, wetness),
		"hydro_lake_min_cells": int(round(lerpf(16.0, 4.0, lake_density))),
		"hydro_lake_min_depth": lerpf(0.030, 0.010, lake_density),
		"hydro_lake_min_volume": lerpf(0.50, 0.10, lake_density),
		"river_channel_init_cells": int(round(lerpf(30.0, 7.0, river_density))),
		"max_volcanoes": int(round(lerpf(0.0, 18.0, volcano_amount))),
		"volcano_min_dist": int(round(lerpf(14.0, 3.0, volcano_amount))),
	}


static func from_dictionary(value: Dictionary) -> Dictionary:
	if String(value.get("schema", "")) != "NewGameConfig":
		return _error("config_schema_invalid", "新游戏配置格式无效。")
	if int(value.get("version", -1)) != SCHEMA_VERSION:
		return _error("config_version_incompatible", "新游戏配置版本不兼容。")
	var config := NewGameConfig.new()
	config.country = (value.get("country", {}) as Dictionary).duplicate(true)
	config.base = (value.get("base", {}) as Dictionary).duplicate(true)
	config.world_controls = (value.get("world_controls", {}) as Dictionary).duplicate(true)
	config.climate = (value.get("climate", {}) as Dictionary).duplicate(true)
	config.research = (value.get("research", {}) as Dictionary).duplicate(true)
	var validation := config.validate()
	if not bool(validation.get("ok", false)):
		return validation
	return {"ok": true, "code": "ok", "message": "", "config": config}


static func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
