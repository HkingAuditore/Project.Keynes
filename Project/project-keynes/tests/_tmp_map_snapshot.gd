extends SceneTree

# [zonal-envelope 2026-08-01] 临时快照工具：生成 150x100 世界两次（同 seed 确定性 A/B），
# 输出 base_moisture / vegetation 两张 PNG 到 tmp/ 供目视检查纬度格局。
# Headless:
#   godot --headless --path Project/project-keynes \
#     --script res://tests/_tmp_map_snapshot.gd -- seed=20260801 --quit

const WATER_TERRAINS := [0, 1, 18, 19, 20, 21]
const SCALE := 6


func _init() -> void:
	var code := _run()
	quit(code)


func _run() -> int:
	var seed := int(_arguments().get("seed", 20260801))
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[map-snapshot] DCWorldExt unavailable")
		return 3
	var ext: Object = ClassDB.instantiate("DCWorldExt")
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
	var a: Dictionary = ext.call("run_native_world_generate_full_pass", seed, cfg, profile)
	var b: Dictionary = ext.call("run_native_world_generate_full_pass", seed, cfg, profile)
	if int(a.get("rc", -1)) != 0 or int(b.get("rc", -1)) != 0:
		push_error("[map-snapshot] generation failed")
		return 4
	var width := int(a.get("width", 150))
	var height := int(a.get("height", 100))

	# 同 seed 确定性 A/B：全部关键 SoA 字节级一致
	var det_ok := true
	for key in ["base_moisture_arr", "vegetation_arr", "terrain_arr", "temp_arr"]:
		if a.get(key) != b.get(key):
			det_ok = false
			push_error("[map-snapshot] NONDETERMINISTIC field: %s" % key)
	print("[map-snapshot] determinism same-seed A/B: %s" % ("IDENTICAL" if det_ok else "DIVERGED"))

	var terr: PackedByteArray = a.get("terrain_arr")
	var veg: PackedByteArray = a.get("vegetation_arr")
	var bm: PackedFloat32Array = a.get("base_moisture_arr")
	var out_dir := "D:/Godot/ProjectKeynes/Project.Keynes/tmp"
	_save_png(out_dir + "/zonal_fix_base_moisture_%d.png" % seed,
		width, height, terr, bm)
	_save_veg_png(out_dir + "/zonal_fix_vegetation_%d.png" % seed,
		width, height, terr, veg)
	print("[map-snapshot] pngs written to tmp/ (seed=%d)" % seed)
	return 0 if det_ok else 5


func _save_png(path: String, width: int, height: int,
		terr: PackedByteArray, bm: PackedFloat32Array) -> void:
	var img := Image.create(width * SCALE, height * SCALE, false, Image.FORMAT_RGB8)
	for i in range(terr.size()):
		var col := Color.BLACK
		if int(terr[i]) in WATER_TERRAINS:
			col = Color(0.08, 0.16, 0.35)
		else:
			var m: float = bm[i]
			# 干=棕黄，中=绿，湿=深青
			if m < 0.2:
				col = Color(0.75, 0.62, 0.35).lerp(Color(0.55, 0.42, 0.25), m / 0.2)
			elif m < 0.4:
				col = Color(0.75, 0.62, 0.35).lerp(Color(0.35, 0.55, 0.25), (m - 0.2) / 0.2)
			else:
				col = Color(0.35, 0.55, 0.25).lerp(Color(0.05, 0.30, 0.28), minf((m - 0.4) / 0.35, 1.0))
		var x := (i % width) * SCALE
		var y := (i / width) * SCALE
		for dy in range(SCALE):
			for dx in range(SCALE):
				img.set_pixel(x + dx, y + dy, col)
	img.save_png(path)


func _veg_color(v: int) -> Color:
	match v:
		0: return Color(0.45, 0.45, 0.45)      # NONE 裸地
		1: return Color(0.85, 0.85, 0.88)      # POLAR_DESERT
		2, 3: return Color(0.62, 0.68, 0.62)   # TUNDRA 系
		4: return Color(0.55, 0.70, 0.45)      # ALPINE_MEADOW
		5, 8: return Color(0.13, 0.35, 0.22)   # TAIGA/CONIFER 深绿
		6: return Color(0.40, 0.48, 0.30)      # BOREAL_SHRUB
		7: return Color(0.20, 0.50, 0.20)      # TEMPERATE_DECIDUOUS
		9: return Color(0.55, 0.72, 0.30)      # TEMPERATE_GRASSLAND
		10: return Color(0.72, 0.68, 0.38)     # TEMPERATE_STEPPE
		11: return Color(0.48, 0.55, 0.28)     # MEDITERRANEAN_SHRUB
		12: return Color(0.15, 0.45, 0.25)     # SUBTROPICAL_FOREST
		13: return Color(0.78, 0.72, 0.35)     # SAVANNA 金草
		14: return Color(0.02, 0.30, 0.12)     # TROPICAL_RAINFOREST 深雨林
		15: return Color(0.25, 0.48, 0.18)     # TROPICAL_DRY_FOREST
		16, 17: return Color(0.85, 0.70, 0.42) # 荒漠系
		18: return Color(0.30, 0.55, 0.35)     # OASIS
		19: return Color(0.10, 0.40, 0.35)     # MANGROVE
		20, 21, 27: return Color(0.25, 0.45, 0.40) # 湿地系
		24: return Color(0.10, 0.38, 0.30)     # CLOUD_FOREST
		25: return Color(0.08, 0.36, 0.16)     # MONSOON_FOREST
		_: return Color(0.5, 0.5, 0.5)


func _save_veg_png(path: String, width: int, height: int,
		terr: PackedByteArray, veg: PackedByteArray) -> void:
	var img := Image.create(width * SCALE, height * SCALE, false, Image.FORMAT_RGB8)
	for i in range(terr.size()):
		var col := Color(0.08, 0.16, 0.35) if int(terr[i]) in WATER_TERRAINS \
			else _veg_color(int(veg[i]))
		var x := (i % width) * SCALE
		var y := (i / width) * SCALE
		for dy in range(SCALE):
			for dx in range(SCALE):
				img.set_pixel(x + dx, y + dy, col)
	img.save_png(path)


func _arguments() -> Dictionary:
	var out := {}
	for raw in OS.get_cmdline_user_args():
		var item := str(raw)
		var split := item.find("=")
		if split > 0:
			out[item.substr(0, split)] = item.substr(split + 1)
	return out
