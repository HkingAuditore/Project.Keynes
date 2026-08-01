extends SceneTree

# [zonal-envelope 2026-08-01] 临时探针：生成多 seed 世界，打印纬带湿度统计 + 植被/地形分布。
# Headless:
#   godot --headless --path Project/project-keynes \
#     --script res://tests/_tmp_zonal_probe.gd --quit

const FOREST := [5, 7, 8, 12, 14, 15, 24, 25]      # TAIGA..MONSOON 森林系
const GRASSLAND := [9, 10, 13]                      # 温带草原/干草原/稀树草原
const DESERT := [1, 16, 17]                         # 极地荒漠/沙漠灌木/极旱沙漠
const WATER_TERRAINS := [0, 1, 18, 19, 20, 21]
const ARID_TERRAINS := [7, 24, 25, 26, 30]


func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[zonal-probe] SKIP DCWorldExt missing")
		quit(1)
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null or not ext.has_method("run_native_world_generate_full_pass"):
		print("[zonal-probe] SKIP full pass missing")
		quit(1)
		return
	var cfg := {
		"width": 100, "height": 64, "num_continents": 3,
		"sea_level": 0.42, "continent_size": 0.9,
		"river_count": 8, "water_dist_max": 8,
		"water_big_river_flow_min": 0.55,
		"lake_moist_floor": 0.55, "lake_moist_scale": 2.5,
		"river_riparian_floor": 0.36, "river_riparian_gain": 0.12,
		"river_riparian_scale": 2.0, "swamp_water_band": 2,
	}
	var args := {}
	for raw in OS.get_cmdline_user_args():
		var item := str(raw)
		var split := item.find("=")
		if split > 0:
			args[item.substr(0, split)] = item.substr(split + 1)
	var profile := {"native_generation_mode": 2}
	# 旋钮覆盖探针：dry=副热带干带强度 dryw=干带宽（其余走 C++ 默认）
	if args.has("dry"):
		profile["moisture_subtropical_dry_strength"] = float(args["dry"])
	if args.has("dryw"):
		profile["moisture_subtropical_dry_width"] = float(args["dryw"])
	if args.has("dryc"):
		profile["moisture_subtropical_dry_center"] = float(args["dryc"])
	print("[zonal-probe] overrides=%s" % str(profile))
	if args.has("w") and args.has("h"):
		# 自定义尺度单测（如匹配用户 60x40 录制图）：w=60 h=40
		var custom_cfg: Dictionary = cfg.duplicate(true)
		custom_cfg["width"] = int(args["w"])
		custom_cfg["height"] = int(args["h"])
		for seed in [20260801, 42, 777]:
			var rc_: Dictionary = ext.call("run_native_world_generate_full_pass", seed, custom_cfg, profile)
			if int(rc_.get("rc", -1)) != 0 or bool(rc_.get("fallback", true)):
				print("[zonal-probe] CUSTOM seed=%d FAILED" % seed)
				continue
			_report(seed, rc_, 0)
		quit(0)
		return
	for seed in [20260801, 42, 777]:
		var t0 := Time.get_ticks_msec()
		var r: Dictionary = ext.call("run_native_world_generate_full_pass", seed, cfg, profile)
		var ms := Time.get_ticks_msec() - t0
		if int(r.get("rc", -1)) != 0 or bool(r.get("fallback", true)):
			print("[zonal-probe] seed=%d FAILED rc=%s reason=%s" % [
				seed, str(r.get("rc", "?")), str(r.get("fallback_reason", "?"))])
			continue
		_report(seed, r, ms)
	# 参考尺度复验（150×100 = 15000 格，scale-fix 基准）
	var big_cfg: Dictionary = cfg.duplicate(true)
	big_cfg["width"] = 150
	big_cfg["height"] = 100
	for seed in [20260801, 42]:
		var t1 := Time.get_ticks_msec()
		var rb: Dictionary = ext.call("run_native_world_generate_full_pass", seed, big_cfg, profile)
		var msb := Time.get_ticks_msec() - t1
		if int(rb.get("rc", -1)) != 0 or bool(rb.get("fallback", true)):
			print("[zonal-probe] BIG seed=%d FAILED" % seed)
			continue
		_report(seed, rb, msb)
	quit(0)


func _report(seed: int, r: Dictionary, ms: int) -> void:
	var h := int(r.get("height", 0))
	var bm: PackedFloat32Array = r.get("base_moisture_arr", PackedFloat32Array())
	var terr: PackedByteArray = r.get("terrain_arr", PackedByteArray())
	var veg: PackedByteArray = r.get("vegetation_arr", PackedByteArray())
	var n := terr.size()
	var bands := ["eq<0.2", "subtrop", "midlat", "polar"]
	var bsum := [0.0, 0.0, 0.0, 0.0]
	var bcnt := [0, 0, 0, 0]
	var bmin := [1.0, 1.0, 1.0, 1.0]
	var land := 0
	var forest := 0
	var grass := 0
	var desert := 0
	var arid_terr := 0
	var eq_land := 0
	var eq_forest := 0
	var eq_grass := 0
	var bm_sorted := PackedFloat32Array()
	for i in range(n):
		if int(terr[i]) in WATER_TERRAINS:
			continue
		land += 1
		var row := i / int(r.get("width", 1))
		var eqd: float = absf(float(row) / float(h) * 2.0 - 1.0)
		var b := 0 if eqd < 0.2 else (1 if eqd < 0.45 else (2 if eqd < 0.7 else 3))
		var m := bm[i] if i < bm.size() else 0.0
		bsum[b] += m
		bcnt[b] += 1
		if m < bmin[b]:
			bmin[b] = m
		bm_sorted.append(m)
		var v := int(veg[i]) if i < veg.size() else 0
		if v in FOREST:
			forest += 1
		elif v in GRASSLAND:
			grass += 1
		elif v in DESERT:
			desert += 1
		if int(terr[i]) in ARID_TERRAINS:
			arid_terr += 1
		if eqd < 0.15:
			eq_land += 1
			if v in FOREST:
				eq_forest += 1
			elif v in GRASSLAND:
				eq_grass += 1
	bm_sorted.sort()
	var p10 := bm_sorted[int(bm_sorted.size() * 0.1)] if bm_sorted.size() > 0 else 0.0
	var p50 := bm_sorted[int(bm_sorted.size() * 0.5)] if bm_sorted.size() > 0 else 0.0
	print("[zonal-probe] seed=%d land=%d gen=%dms" % [seed, land, ms])
	print("  cpp_zonal mean eq=%.3f sub=%.3f mid=%.3f pol=%.3f min_sub=%.3f" % [
		float(r.get("zonal_moist_mean_eq", -1.0)), float(r.get("zonal_moist_mean_subtrop", -1.0)),
		float(r.get("zonal_moist_mean_midlat", -1.0)), float(r.get("zonal_moist_mean_polar", -1.0)),
		float(r.get("zonal_moist_min_subtrop", -1.0))])
	for b in range(4):
		print("  gd_band %-8s n=%4d mean=%.3f min=%.3f" % [
			bands[b], bcnt[b], bsum[b] / maxf(1.0, float(bcnt[b])), bmin[b]])
	print("  bm p10=%.3f p50=%.3f | forest=%.1f%% grass=%.1f%% desert=%.1f%% arid_terr=%.1f%%" % [
		p10, p50, 100.0 * forest / land, 100.0 * grass / land,
		100.0 * desert / land, 100.0 * arid_terr / land])
	print("  equator(eq<0.15) land=%d forest=%.1f%% grass=%.1f%%" % [
		eq_land, 100.0 * eq_forest / maxi(1, eq_land), 100.0 * eq_grass / maxi(1, eq_land)])
