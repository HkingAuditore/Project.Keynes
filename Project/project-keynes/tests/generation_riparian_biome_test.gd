extends SceneTree

# Headless:
#   godot --headless --path Project/project-keynes \
#     --script res://tests/generation_riparian_biome_test.gd --quit

const WATER_TERRAINS := [0, 1, 18, 19, 20, 21]
const OCEAN_TERRAINS := [0, 1, 19, 20, 21]
const ARID_TERRAINS := [7, 24, 25, 26, 30]
const DQ := [1, 1, 0, -1, -1, 0]
const DR := [0, -1, -1, 0, 1, 1]

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("[generation-riparian-biome] checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var defaults := ClimateProfile.new()
	# [zonal-envelope] 默认值 0.22→0.30（加深副热带干带，见 climate_profile.gd 注释）。
	_expect("ClimateProfile dry strength defaults to 0.30",
		is_equal_approx(defaults.moisture_subtropical_dry_strength, 0.30))
	_expect("ClimateProfile rain shadow default stays locally dry without dominating coasts",
		is_equal_approx(defaults.rain_shadow_factor, 0.65))
	_expect("ClimateProfile badlands land safety cap is disabled by default",
		is_equal_approx(defaults.badlands_max_land_ratio, 1.0))
	_expect("ClimateProfile badlands arid safety cap is disabled by default",
		is_equal_approx(defaults.badlands_max_arid_ratio, 1.0))
	_expect("ClimateProfile badlands patch safety cap is disabled by default",
		defaults.badlands_max_patch_cells == 0)
	if not ClassDB.class_exists("DCWorldExt"):
		print("[generation-riparian-biome] SKIP DCWorldExt missing")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("DCWorldExt instantiated", ext != null)
	if ext == null:
		return
	_expect("full generation pass exported", ext.has_method("run_native_world_generate_full_pass"))
	if not ext.has_method("run_native_world_generate_full_pass"):
		return

	var cfg := _base_cfg()
	var balanced := _generate(ext, cfg, 0.22)
	var harsh := _generate(ext, cfg, 0.32)
	var no_riparian_cfg: Dictionary = cfg.duplicate(true)
	no_riparian_cfg["river_riparian_floor"] = 0.0
	no_riparian_cfg["river_riparian_gain"] = 0.0
	var no_riparian := _generate(ext, no_riparian_cfg, 0.22)
	if balanced.is_empty() or harsh.is_empty() or no_riparian.is_empty():
		return

	var balanced_stats := _stats(balanced)
	var harsh_stats := _stats(harsh)
	var no_riparian_stats := _stats(no_riparian)
	print("[generation-riparian-biome] balanced=%s" % balanced_stats)
	print("[generation-riparian-biome] harsh=%s" % harsh_stats)
	print("[generation-riparian-biome] no_riparian=%s" % no_riparian_stats)

	_expect("balanced dry strength does not increase arid land",
		int(balanced_stats.arid_land) <= int(harsh_stats.arid_land))
	_expect("balanced generation retains natural arid land",
		int(balanced_stats.arid_land) > 0)
	_expect("coastal highlands exist in the fixed-seed sample",
		int(balanced_stats.coastal_highland) > 0)
	_expect("coastal highlands are not broadly classified as arid",
		float(balanced_stats.coastal_highland_arid) \
			/ float(maxi(1, int(balanced_stats.coastal_highland))) < 0.25)
	_expect("river channels are never arid", int(balanced_stats.river_arid) == 0)
	_expect("riparian feedback does not increase adjacent arid land",
		int(balanced_stats.adjacent_arid) <= int(no_riparian_stats.adjacent_arid))
	_expect("ecology source count is positive",
		int(balanced.get("river_ecology_source_count", 0)) > 0)
	_expect("ecology source count is independent of narrower visual flow",
		int(balanced.get("river_ecology_source_count", 0)) >= int(balanced_stats.visual_big_rivers))
	_expect("all generated tributaries contribute to riparian ecology",
		int(balanced.get("river_ecology_source_count", 0)) == int(balanced_stats.river_cells))
	_expect("riparian moisture touched land",
		int(balanced.get("riparian_moist_touched", 0)) > 0)
	_expect("river-neighbor arid share stays below one quarter",
		int(balanced_stats.adjacent) > 0 \
		and float(balanced_stats.adjacent_arid) / float(balanced_stats.adjacent) < 0.25)
	_expect("final climate redecide evaluated ordinary land",
		int(balanced.get("final_climate_redecide_evaluated", 0)) > 0)
	_expect("final climate redecide consumed late moisture changes",
		int(balanced.get("final_climate_redecide_touched", 0)) > 0)


func _base_cfg() -> Dictionary:
	return {
		"width": 100,
		"height": 64,
		"num_continents": 3,
		"sea_level": 0.42,
		"continent_size": 0.9,
		"river_count": 8,
		"water_dist_max": 8,
		"water_big_river_flow_min": 0.55,
		"lake_moist_floor": 0.55,
		"lake_moist_scale": 2.5,
		"river_riparian_floor": 0.36,
		"river_riparian_gain": 0.12,
		"river_riparian_scale": 2.0,
		"swamp_water_band": 2,
	}


func _generate(ext: Object, cfg: Dictionary, dry_strength: float) -> Dictionary:
	var profile := {
		"native_generation_mode": 2,
		"moisture_subtropical_dry_strength": dry_strength,
	}
	var result: Dictionary = ext.call(
		"run_native_world_generate_full_pass", 20260731, cfg, profile)
	_expect("generation succeeds dry=%.2f riparian=%.2f" % [
		dry_strength, float(cfg.get("river_riparian_gain", 0.0))],
		int(result.get("rc", -1)) == 0 and not bool(result.get("fallback", true)))
	return result if int(result.get("rc", -1)) == 0 else {}


func _stats(result: Dictionary) -> Dictionary:
	var width := int(result.get("width", 0))
	var height := int(result.get("height", 0))
	var terrain: PackedByteArray = result.get("terrain_arr", PackedByteArray())
	var river: PackedByteArray = result.get("has_river_arr", PackedByteArray())
	var flow: PackedFloat32Array = result.get("river_flow_arr", PackedFloat32Array())
	var elevation: PackedFloat32Array = result.get("elevation_arr", PackedFloat32Array())
	var q_arr: PackedInt32Array = result.get("q_arr", PackedInt32Array())
	var r_arr: PackedInt32Array = result.get("r_arr", PackedInt32Array())
	var dist_ocean := _ocean_distances(terrain, q_arr, r_arr, width, height)
	var land := 0
	var arid_land := 0
	var river_arid := 0
	var adjacent := 0
	var adjacent_arid := 0
	var visual_big_rivers := 0
	var river_cells := 0
	var coastal_highland := 0
	var coastal_highland_arid := 0
	for i in range(terrain.size()):
		var t := int(terrain[i])
		if _is_water(t):
			continue
		land += 1
		if _is_arid(t):
			arid_land += 1
		if i < elevation.size() and i < dist_ocean.size() \
				and elevation[i] >= 0.55 and dist_ocean[i] > 0 and dist_ocean[i] <= 8:
			coastal_highland += 1
			if _is_arid(t):
				coastal_highland_arid += 1
		if river[i] != 0:
			river_cells += 1
			if _is_arid(t):
				river_arid += 1
			if flow[i] >= 0.55:
				visual_big_rivers += 1
			continue
		var near_river := false
		for d in range(6):
			var ni := _index_for_qr(q_arr[i] + DQ[d], r_arr[i] + DR[d], width, height)
			if ni >= 0 and river[ni] != 0:
				near_river = true
				break
		if near_river:
			adjacent += 1
			if _is_arid(t):
				adjacent_arid += 1
	return {
		"land": land,
		"arid_land": arid_land,
		"river_arid": river_arid,
		"adjacent": adjacent,
		"adjacent_arid": adjacent_arid,
		"visual_big_rivers": visual_big_rivers,
		"river_cells": river_cells,
		"coastal_highland": coastal_highland,
		"coastal_highland_arid": coastal_highland_arid,
		"final_redecide": int(result.get("final_climate_redecide_touched", -1)),
	}


func _ocean_distances(
		terrain: PackedByteArray,
		q_arr: PackedInt32Array,
		r_arr: PackedInt32Array,
		width: int,
		height: int) -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(terrain.size())
	dist.fill(-1)
	var queue := PackedInt32Array()
	for i in range(terrain.size()):
		if int(terrain[i]) in OCEAN_TERRAINS:
			dist[i] = 0
			queue.append(i)
	var cursor := 0
	while cursor < queue.size():
		var i := queue[cursor]
		cursor += 1
		for d in range(6):
			var ni := _index_for_qr(q_arr[i] + DQ[d], r_arr[i] + DR[d], width, height)
			if ni < 0 or dist[ni] >= 0:
				continue
			dist[ni] = dist[i] + 1
			queue.append(ni)
	return dist


func _index_for_qr(q: int, r: int, width: int, height: int) -> int:
	if r < 0 or r >= height:
		return -1
	var col: int = q + (r >> 1)
	col = posmod(col, width)
	return r * width + col


func _is_water(terrain: int) -> bool:
	return terrain in WATER_TERRAINS


func _is_arid(terrain: int) -> bool:
	return terrain in ARID_TERRAINS


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	push_error("[generation-riparian-biome] FAIL: %s" % label)
