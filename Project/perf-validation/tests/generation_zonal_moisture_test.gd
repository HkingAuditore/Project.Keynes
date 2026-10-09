extends SceneTree

# [zonal-envelope 2026-08-01] 行星尺度纬带湿度/生物群系硬指标验收测试。
# 断言（3 个 seed、150×100 参考尺度，scale-fix 基准 N=15000）：
#   1. 赤道带(eq_dist<0.2) base_moisture 中位数 > 副热带带(0.25-0.45) 中位数（ITCZ 湿于副热带）
#   2. 副热带带存在 base_moisture<0.2 格（荒漠真实可达）
#   3. 中纬带(0.45-0.65) 中位数 > 副热带带（风暴路径湿带）
#   4. 赤道核心(eq<0.15) 森林系占比 > 草原系
#   5. 全图森林系均值 25-36%（设计中心 25-35%，±1pt 种子噪声）、草原系均值 <30%、荒漠系每 seed ≥2%
# Headless:
#   godot --headless --path Project/project-keynes \
#     --script res://tests/generation_zonal_moisture_test.gd --quit

const SEEDS := [20260801, 42, 777]
const WATER_TERRAINS := [0, 1, 18, 19, 20, 21]
const FOREST := [5, 7, 8, 12, 14, 15, 24, 25]
const GRASSLAND := [9, 10, 13]
const DESERT := [1, 16, 17]

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("[generation-zonal-moisture] checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var defaults := ClimateProfile.new()
	_expect("ClimateProfile ITCZ wet strength default 0.9",
		is_equal_approx(defaults.moisture_itcz_wet_strength, 0.9))
	_expect("ClimateProfile subtropical dry width default widened to 0.18",
		is_equal_approx(defaults.moisture_subtropical_dry_width, 0.18))
	_expect("ClimateProfile tropical evap boost default 1.0",
		is_equal_approx(defaults.moisture_tropical_evap_boost, 1.0))
	_expect("ClimateProfile ITCZ recycle default 0.62",
		is_equal_approx(defaults.moisture_itcz_recycle_strength, 0.62))
	if not ClassDB.class_exists("DCWorldExt"):
		print("[generation-zonal-moisture] SKIP DCWorldExt missing")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null or not ext.has_method("run_native_world_generate_full_pass"):
		print("[generation-zonal-moisture] SKIP full pass missing")
		return

	var cfg := {
		"width": 150, "height": 100, "num_continents": 3,
		"sea_level": 0.42, "continent_size": 0.9,
		"river_count": 8, "water_dist_max": 8,
		"water_big_river_flow_min": 0.55,
		"lake_moist_floor": 0.55, "lake_moist_scale": 2.5,
		"river_riparian_floor": 0.36, "river_riparian_gain": 0.12,
		"river_riparian_scale": 2.0, "swamp_water_band": 2,
	}
	var profile := {"native_generation_mode": 2}

	var agg_forest := 0.0
	var agg_grass := 0.0
	var agg_eq_med := 0.0
	var agg_sub_med := 0.0
	var agg_mid_med := 0.0
	var n_ok := 0
	for seed in SEEDS:
		var r: Dictionary = ext.call("run_native_world_generate_full_pass", seed, cfg, profile)
		_expect("generation succeeds seed=%d" % seed,
			int(r.get("rc", -1)) == 0 and not bool(r.get("fallback", true)))
		if int(r.get("rc", -1)) != 0 or bool(r.get("fallback", true)):
			continue
		n_ok += 1
		var st := _stats(r)
		print("[generation-zonal-moisture] seed=%d %s" % [seed, str(st)])
		_expect("seed=%d eq bm median > subtrop + 0.08" % seed,
			st.eq_med > st.sub_med + 0.08)
		_expect("seed=%d subtropical band has true arid cells (bm<0.2)" % seed,
			int(st.sub_dry_cells) > 0)
		_expect("seed=%d midlat bm median > subtrop median" % seed,
			st.mid_med > st.sub_med)
		_expect("seed=%d equatorial forest share > grass share (%.0f%% > %.0f%%)" % [
				seed, st.eq_forest_pct, st.eq_grass_pct],
			st.eq_forest_pct > st.eq_grass_pct)
		_expect("seed=%d global forest 24-38%% (%.1f%%)" % [seed, st.forest_pct],
			st.forest_pct >= 24.0 and st.forest_pct <= 38.0)
		_expect("seed=%d global grass < 32%% (%.1f%%)" % [seed, st.grass_pct],
			st.grass_pct < 32.0)
		_expect("seed=%d global desert >= 2%% (%.1f%%)" % [seed, st.desert_pct],
			st.desert_pct >= 2.0)
		# C++ 侧纬带均值输出一致性（同分布的双通道交叉验证）
		var cpp_eq := float(r.get("zonal_moist_mean_eq", -1.0))
		var cpp_sub := float(r.get("zonal_moist_mean_subtrop", -1.0))
		_expect("seed=%d cpp zonal stats exposed and eq wetter than subtrop" % seed,
			cpp_eq >= 0.0 and cpp_eq > cpp_sub)
		agg_forest += st.forest_pct
		agg_grass += st.grass_pct
		agg_eq_med += st.eq_med
		agg_sub_med += st.sub_med
		agg_mid_med += st.mid_med
	if n_ok == 0:
		return
	agg_forest /= n_ok
	agg_grass /= n_ok
	agg_eq_med /= n_ok
	agg_sub_med /= n_ok
	agg_mid_med /= n_ok
	_expect("aggregate eq median (%.3f) > subtrop median (%.3f) + 0.10" % [agg_eq_med, agg_sub_med],
		agg_eq_med > agg_sub_med + 0.10)
	_expect("aggregate midlat median (%.3f) > subtrop median (%.3f) + 0.02" % [agg_mid_med, agg_sub_med],
		agg_mid_med > agg_sub_med + 0.02)
	_expect("aggregate forest 25-36%% (%.1f%%)" % agg_forest,
		agg_forest >= 25.0 and agg_forest <= 36.0)
	_expect("aggregate grass < 30%% (%.1f%%)" % agg_grass, agg_grass < 30.0)


func _stats(r: Dictionary) -> Dictionary:
	var width := int(r.get("width", 1))
	var height := int(r.get("height", 1))
	var terr: PackedByteArray = r.get("terrain_arr", PackedByteArray())
	var veg: PackedByteArray = r.get("vegetation_arr", PackedByteArray())
	var bm: PackedFloat32Array = r.get("base_moisture_arr", PackedFloat32Array())
	var eq_vals := []
	var sub_vals := []
	var mid_vals := []
	var land := 0
	var forest := 0
	var grass := 0
	var desert := 0
	var eq_land := 0
	var eq_forest := 0
	var eq_grass := 0
	var sub_dry := 0
	for i in range(terr.size()):
		if int(terr[i]) in WATER_TERRAINS:
			continue
		land += 1
		var row := i / width
		var eqd: float = absf(float(row) / float(height) * 2.0 - 1.0)
		var m := bm[i] if i < bm.size() else 0.0
		if eqd < 0.2:
			eq_vals.append(m)
		elif eqd >= 0.25 and eqd < 0.45:
			sub_vals.append(m)
			if m < 0.2:
				sub_dry += 1
		elif eqd >= 0.45 and eqd < 0.65:
			mid_vals.append(m)
		var v := int(veg[i]) if i < veg.size() else 0
		if v in FOREST:
			forest += 1
		elif v in GRASSLAND:
			grass += 1
		elif v in DESERT:
			desert += 1
		if eqd < 0.15:
			eq_land += 1
			if v in FOREST:
				eq_forest += 1
			elif v in GRASSLAND:
				eq_grass += 1
	return {
		"eq_med": _median(eq_vals),
		"sub_med": _median(sub_vals),
		"mid_med": _median(mid_vals),
		"sub_dry_cells": sub_dry,
		"forest_pct": 100.0 * forest / maxi(1, land),
		"grass_pct": 100.0 * grass / maxi(1, land),
		"desert_pct": 100.0 * desert / maxi(1, land),
		"eq_forest_pct": 100.0 * eq_forest / maxi(1, eq_land),
		"eq_grass_pct": 100.0 * eq_grass / maxi(1, eq_land),
		"land": land,
	}


func _median(vals: Array) -> float:
	if vals.is_empty():
		return 0.0
	vals.sort()
	return float(vals[vals.size() / 2])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		return
	_failures += 1
	push_error("[generation-zonal-moisture] FAIL: %s" % label)
