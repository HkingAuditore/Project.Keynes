extends "res://scripts/simulation/generator_context.gd"
class_name DCTerrainGenerator

## 校验原生生成结果，装配 HexCell，并保存地形、地貌与植被的生成基线。
## 不持有生成状态；可用 DCTerrainGenerator.new(null) 独立装配结果。

func _init(generator) -> void:
	_generator = generator

## Native result assembly boundary used by MapGenerator.generate().
func assemble_native_result(res: Dictionary, cfg: MapConfig) -> MapData:
	var n: int = int(res.get("n_cells", 0))
	if cfg == null or n <= 0 or n != int(cfg.width) * int(cfg.height):
		return null
	var required := {
		"q_arr": TYPE_PACKED_INT32_ARRAY,
		"r_arr": TYPE_PACKED_INT32_ARRAY,
		"elevation_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"moisture_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"base_moisture_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"temp_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"terrain_arr": TYPE_PACKED_BYTE_ARRAY,
		"landform_arr": TYPE_PACKED_BYTE_ARRAY,
		"vegetation_arr": TYPE_PACKED_BYTE_ARRAY,
		"cover_arr": TYPE_PACKED_BYTE_ARRAY,
		"vegetation_vitality_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"soil_moisture_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"water_balance_30d_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"plant_available_water_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"vegetation_growth_pressure_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"vegetation_heat_stress_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"vegetation_drought_stress_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"vegetation_cold_stress_arr": TYPE_PACKED_FLOAT32_ARRAY,
		"vegetation_regen_score_arr": TYPE_PACKED_FLOAT32_ARRAY,
	}
	for key in required.keys():
		if not native_generation_array_ok(res, key, n, int(required[key])):
			push_warning("[native_generation/assemble] bad array %s" % key)
			return null

	var q_arr: PackedInt32Array = res["q_arr"]
	var r_arr: PackedInt32Array = res["r_arr"]
	var elevation_arr: PackedFloat32Array = res["elevation_arr"]
	var moisture_arr: PackedFloat32Array = res["moisture_arr"]
	var base_moisture_arr: PackedFloat32Array = res["base_moisture_arr"]
	var temp_arr: PackedFloat32Array = res["temp_arr"]
	var temp_baseline_arr: PackedFloat32Array = res["temp_baseline_arr"] if res.has("temp_baseline_arr") else temp_arr
	var temp_30d_arr: PackedFloat32Array = res["temp_30d_arr"] if res.has("temp_30d_arr") else temp_arr
	var temp_365d_arr: PackedFloat32Array = res["temp_365d_arr"] if res.has("temp_365d_arr") else temp_arr
	var terrain_arr: PackedByteArray = res["terrain_arr"]
	var base_terrain_arr: PackedByteArray = res["base_terrain_arr"] if res.has("base_terrain_arr") else terrain_arr
	var landform_arr: PackedByteArray = res["landform_arr"]
	var base_landform_arr: PackedByteArray = res["base_landform_arr"] if res.has("base_landform_arr") else landform_arr
	var vegetation_arr: PackedByteArray = res["vegetation_arr"]
	var base_vegetation_arr: PackedByteArray = res["base_vegetation_arr"] if res.has("base_vegetation_arr") else vegetation_arr
	var cover_arr: PackedByteArray = res["cover_arr"]
	var has_river_arr: PackedByteArray = res["has_river_arr"] if res.has("has_river_arr") else PackedByteArray()
	var river_flow_arr: PackedFloat32Array = res["river_flow_arr"] if res.has("river_flow_arr") else PackedFloat32Array()
	var river_downstream_arr: PackedInt32Array = res["river_downstream_arr"] if res.has("river_downstream_arr") else PackedInt32Array()
	var hydro_parent_arr: PackedInt32Array = res["hydro_parent_arr"] if res.has("hydro_parent_arr") else PackedInt32Array()
	var has_volcano_arr: PackedByteArray = res["has_volcano_arr"] if res.has("has_volcano_arr") else PackedByteArray()
	var is_lake_seed_arr: PackedByteArray = res["is_lake_seed_arr"] if res.has("is_lake_seed_arr") else PackedByteArray()
	var water_depth_arr: PackedFloat32Array = res["water_depth_arr"] if res.has("water_depth_arr") else PackedFloat32Array()
	var map := MapData.new(cfg.width, cfg.height)
	var slice_start := Time.get_ticks_usec()
	var tree := Engine.get_main_loop() as SceneTree
	for i in range(n):
		if tree != null and Time.get_ticks_usec()-slice_start >= UITokens.LOADING_MAIN_SLICE_USEC:
			await tree.process_frame
			slice_start = Time.get_ticks_usec()
		var cell := HexCell.new(int(q_arr[i]), int(r_arr[i]))
		cell.elevation = float(elevation_arr[i])
		cell.moisture = float(moisture_arr[i])
		cell.base_moisture = float(base_moisture_arr[i])
		cell.apply_terrain(int(terrain_arr[i]))
		cell.base_terrain = int(base_terrain_arr[i]) if base_terrain_arr.size() == n else int(terrain_arr[i])
		cell.landform = int(landform_arr[i])
		cell.base_landform = int(base_landform_arr[i]) if base_landform_arr.size() == n else int(landform_arr[i])
		cell.vegetation = int(vegetation_arr[i])
		cell.base_vegetation = int(base_vegetation_arr[i]) if base_vegetation_arr.size() == n else int(vegetation_arr[i])
		cell.cover = int(cover_arr[i])
		cell.has_river = has_river_arr.size() == n and int(has_river_arr[i]) != 0
		cell.river_flow = float(river_flow_arr[i]) if river_flow_arr.size() == n else (1.0 if cell.has_river else 0.0)
		if river_downstream_arr.size() == n:
			var downstream_idx: int = int(river_downstream_arr[i])
			if downstream_idx >= 0 and downstream_idx < n:
				cell.river_downstream = Vector3i(int(q_arr[downstream_idx]), int(r_arr[downstream_idx]), -int(q_arr[downstream_idx]) - int(r_arr[downstream_idx]))
				cell.has_river_downstream = true
		cell.has_volcano = has_volcano_arr.size() == n and int(has_volcano_arr[i]) != 0
		cell.is_lake_seed = is_lake_seed_arr.size() == n and int(is_lake_seed_arr[i]) != 0
		cell.water_depth = float(water_depth_arr[i]) if water_depth_arr.size() == n else 0.0
		cell._temperature_backing = float(temp_arr[i])
		cell._temp_baseline_backing = float(temp_baseline_arr[i])
		cell._temp_30d_mean_backing = float(temp_30d_arr[i])
		cell._temp_365d_mean_backing = float(temp_365d_arr[i])
		cell._temp_dev_from_annual_backing = 0.0
		cell._ema_initialized = true
		cell.current_state = {
			"season": 1,
			"temperature": float(temp_arr[i]),
			"moisture": cell.base_moisture,
			"snow_cover": 0.0,
			"biome": int(cell.terrain),
			"landform": int(cell.landform),
			"vegetation": int(cell.vegetation),
			"cover": int(cell.cover),
			"weather": int(WeatherType.WT.CLEAR),
			"weather_intensity": 0.0,
		}
		map.set_cell(cell)
	map.set_pending_generation_ecology({
		"vegetation_vitality_arr": res["vegetation_vitality_arr"],
		"soil_moisture_arr": res["soil_moisture_arr"],
		"water_balance_30d_arr": res["water_balance_30d_arr"],
		"plant_available_water_arr": res["plant_available_water_arr"],
		"vegetation_growth_pressure_arr": res["vegetation_growth_pressure_arr"],
		"vegetation_heat_stress_arr": res["vegetation_heat_stress_arr"],
		"vegetation_drought_stress_arr": res["vegetation_drought_stress_arr"],
		"vegetation_cold_stress_arr": res["vegetation_cold_stress_arr"],
		"vegetation_regen_score_arr": res["vegetation_regen_score_arr"],
	})
	if hydro_parent_arr.size() == n:
		map.hydro_parent_arr = hydro_parent_arr.duplicate()
	return map


static func native_generation_array_ok(res: Dictionary, key: String, n: int, type_id: int) -> bool:
	var value = res.get(key, null)
	return typeof(value) == type_id and value.size() == n

func describe() -> String:
	return "DCTerrainGenerator(generator=%s)" % ("present" if _generator != null else "(null)")


# 把当前 cell.terrain 作为"年均基线"保存。
# base_moisture 已在 _generate_cells 内、雨影 / 河岸生态之前快照。
# refresh_seasonal 每次从这两个基线出发应用季节扰动，避免跨季累积漂移。
# Milestone 1：同时快照 base_landform / base_vegetation 三轴基线
func snapshot_base_state(map: MapData) -> void:
	for cell: HexCell in map.all_cells():
		cell.base_terrain = cell.terrain
		cell.base_landform = cell.landform
		cell.base_vegetation = cell.vegetation

func _mapgen_env() -> Dictionary:
	var ver: Dictionary = Engine.get_version_info()
	var platform := "desktop"
	if OS.has_feature("android"):
		platform = "android"
	elif OS.has_feature("web"):
		platform = "web"
	elif OS.has_feature("ios"):
		platform = "ios"
	return {
		"os": OS.get_name(),
		"arch": Engine.get_architecture_name(),
		"platform": platform,
		"engine": String(ver.get("string", "unknown")),
		"editor": OS.has_feature("editor"),
		"debug_build": OS.is_debug_build(),
	}


## 把 native 返回字典里的大 PackedArray 折叠成 "<type len=n>"。
## 必须做：_native_generation_base_report 里带 10+ 个 n_cells 数组，
## 直接 JSON.stringify 会产出几 MB 文本，安卓上会卡死加载页。

func _mapgen_sanitize_report(src: Dictionary, depth: int = 2) -> Dictionary:
	var out: Dictionary = {}
	for key in src.keys():
		var value = src[key]
		if value is PackedInt32Array or value is PackedInt64Array \
				or value is PackedFloat32Array or value is PackedFloat64Array \
				or value is PackedByteArray or value is PackedStringArray \
				or value is PackedVector2Array or value is PackedVector3Array:
			out[key] = "<%s len=%d>" % [type_string(typeof(value)), value.size()]
		elif value is Array:
			out[key] = "<Array len=%d>" % value.size()
		elif value is Dictionary:
			out[key] = _generator._mapgen_sanitize_report(value, depth - 1) if depth > 0 \
				else "<Dictionary keys=%d>" % value.size()
		elif value is Object:
			out[key] = "<%s>" % ("null" if value == null else value.get_class())
		else:
			out[key] = value
	return out


## 生成前自检：GDExtension 是否加载、native_generation_mode 是否 ACTIVE、
## DCWorldExt 是否可实例化、生成必需的原生方法是否齐全。
## 返回 {ok, issues[{code,message}], extension_loaded, world_ext_available,
##       world_ext_bound, native_mode, native_mode_active, missing_methods, env}
## 纯只读、无副作用，可随时随地调用（含 --mapgen-selfcheck）。

func _fail_generation(stage: String, reason: String, summary: String, hint: String = "") -> Dictionary:
	var cfg = _generator._last_cfg
	var map_size := "?"
	if cfg != null:
		map_size = "%dx%d" % [int(cfg.width), int(cfg.height)]
	var elapsed_ms := 0.0
	if _generator._mapgen_started_usec > 0:
		elapsed_ms = float(Time.get_ticks_usec() - _generator._mapgen_started_usec) / 1000.0
	_generator.last_generation_error = {
		"stage": stage,
		"reason": reason,
		"summary": summary,
		"hint": hint,
		# 原始字典保留引用（不复制，避免 n_cells 级数组二次分配）；
		# native_report 是它的"去大数组"版本，专供展示/落盘/JSON。
		"native_report_raw": _generator._native_generation_base_report,
		"native_report": _generator._mapgen_sanitize_report(_generator._native_generation_base_report),
		"preflight": _generator.generation_preflight(),
		"env": _generator._mapgen_env(),
		"map_size": map_size,
		"seed": _generator._last_seed,
		"elapsed_ms": elapsed_ms,
		"timestamp": Time.get_datetime_string_from_system(true),
		"superseded": reason == "generation_superseded",
	}
	# 单行摘要：安卓上用 `adb logcat -s godot:* | findstr "[mapgen][fatal]"` 一条过滤到。
	print("[mapgen][fatal] stage=%s reason=%s platform=%s/%s map=%s seed=%d elapsed=%.0fms extensions=%s native_mode=%d"
		% [
			stage, reason, String(_generator.last_generation_error["env"]["platform"]),
			String(_generator.last_generation_error["env"]["arch"]), map_size, _generator._last_seed, elapsed_ms,
			str(_generator.last_generation_error["preflight"].get("extension_loaded", false)),
			int(_generator.last_generation_error["preflight"].get("native_mode", -1)),
		])
	return {}


## 生成被新的 generate() 取代（_loading_epoch 变化）：不是真失败，
## 但要留痕，且让上层不要弹"生成失败"面板去盖住新一轮进度。

func _generation_superseded(stage: String) -> Dictionary:
	_generator.last_generation_error = {
		"stage": stage,
		"reason": "generation_superseded",
		"summary": "本次生成已被新的生成请求取代，已安全中止（不是错误）。",
		"hint": "",
		"native_report_raw": _generator._native_generation_base_report,
		"native_report": _generator._mapgen_sanitize_report(_generator._native_generation_base_report),
		"preflight": {"ok": true, "issues": []},
		"env": _generator._mapgen_env(),
		"map_size": "%dx%d" % [int(_generator._last_cfg.width), int(_generator._last_cfg.height)] if _generator._last_cfg != null else "?",
		"seed": _generator._last_seed,
		"elapsed_ms": 0.0,
		"timestamp": Time.get_datetime_string_from_system(true),
		"superseded": true,
	}
	return {}


## 失败详情纯文本（多行）。UI 的"复制详情"、日志文件、测试断言都用这一段。

func last_generation_error_text() -> String:
	if _generator.last_generation_error.is_empty():
		return ""
	var e = _generator.last_generation_error
	var lines: PackedStringArray = PackedStringArray()
	lines.append("=== 地图生成失败 / mapgen fatal ===")
	lines.append("时间 timestamp : %s" % String(e.get("timestamp", "")))
	lines.append("阶段 stage     : %s" % String(e.get("stage", "?")))
	lines.append("原因 reason    : %s" % String(e.get("reason", "?")))
	lines.append("摘要 summary   : %s" % String(e.get("summary", "")))
	var hint := String(e.get("hint", ""))
	if not hint.is_empty():
		lines.append("排查 hint      : %s" % hint)
	lines.append("地图/种子      : %s  seed=%d  耗时=%.0fms" % [
		String(e.get("map_size", "?")), int(e.get("seed", 0)), float(e.get("elapsed_ms", 0.0)),
	])
	var env: Dictionary = e.get("env", {})
	lines.append("平台/架构      : os=%s arch=%s platform=%s engine=%s debug=%s" % [
		String(env.get("os", "?")), String(env.get("arch", "?")), String(env.get("platform", "?")),
		String(env.get("engine", "?")), str(env.get("debug_build", false)),
	])
	var pf: Dictionary = e.get("preflight", {})
	lines.append("自检 preflight : ok=%s extension_loaded=%s world_ext=%s bound=%s native_mode=%d" % [
		str(pf.get("ok", false)), str(pf.get("extension_loaded", false)),
		str(pf.get("world_ext_available", false)), str(pf.get("world_ext_bound", false)),
		int(pf.get("native_mode", -1)),
	])
	for item in (pf.get("issues", []) as Array):
		if item is Dictionary:
			lines.append("  ! [%s] %s" % [String(item.get("code", "")), String(item.get("message", ""))])
	var miss: PackedStringArray = pf.get("missing_methods", PackedStringArray())
	if not miss.is_empty():
		lines.append("  缺失原生方法: %s" % ", ".join(miss))
	lines.append("")
	lines.append("--- native_generation_base_report (大数组已折叠) ---")
	lines.append(JSON.stringify(e.get("native_report", {}), "  ", true))
	return "".join(lines)


## 原始 native report（未折叠）。测试/诊断面板需要真数组时用这个。

func run_mapgen_selfcheck(include_native_smoke: bool = true) -> Dictionary:
	var out = _generator.generation_preflight()
	out["check"] = "mapgen_selfcheck"
	out["timestamp"] = Time.get_datetime_string_from_system(true)
	# 关键：preflight 只能证明"方法存在"，native_smoke 才能证明"内核真能跑"。
	out["native_smoke"] = _generator._mapgen_native_smoke() if include_native_smoke \
		else {"ok": false, "reason": "skipped"}
	out["preflight_ok"] = bool(out.get("ok", false))
	var smoke_ok := bool(out["native_smoke"].get("ok", false)) if include_native_smoke else true
	out["ok"] = out["preflight_ok"] and smoke_ok
	print("[mapgen][selfcheck] %s" % JSON.stringify(out, "", true))
	return out




# native generation ACTIVE 路径：C++ 负责 base SoA + post-base 湖泊/河流/
# 生态/地标后处理；GDScript 只发送请求、校验 PackedArray 并装配 HexCell。

func _init_noise(seed_val: int) -> void:
	# 域扭曲：低频。原生成大陆轮廓用；现仅供 rain-shadow jitter C++ 桥消费。
	_generator._height_warp = FastNoiseLite.new()
	_generator._height_warp.noise_type            = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_generator._height_warp.seed                  = seed_val + 13
	_generator._height_warp.frequency             = 0.025
	_generator._height_warp.fractal_type          = FastNoiseLite.FRACTAL_FBM
	_generator._height_warp.fractal_octaves       = 3


# ─── 温度（cos bell 曲线） ───────────────────────────────────────────────

# 海拔→温度递减率（双段式，2026-05-18 雪线修正）。
# 旧：alt_penalty = elev * 0.5 —— 海拔 0.85 山头只比平原冷 0.425（≈30 个纬度），
#    赤道高山 temp 仍 ≈ 0.575，无法触发雪线分支。
# 新：低海拔段保持 ×0.55（保护平原/丘陵的纬度气候带不被压扁），
# 0.55→0.40 降低海拔线性降温，使中海拔 4-6 月积雪自然融化，季节温差超越海拔效应。
# AMP 0.30→0.22 等比缩放高山额外扣减。
# 2026-07-08：输入改为海平面以上的 land_h，避免 sea_level 本身被当成海拔惩罚，
# 否则海平面附近陆地也会被按 elevation≈sea_level 过度扣温。
# CPU/GPU/C++ SAME_SOURCE：三路径一致。

func _alt_penalty_height(height_norm: float) -> float:
	var h: float = clampf(height_norm, 0.0, 1.0)
	var lin: float = h * _generator.ALT_PEN_LINEAR
	var hi: float = smoothstep(_generator.ALT_PEN_HIGH_LO, _generator.ALT_PEN_HIGH_HI, h) * _generator.ALT_PEN_HIGH_AMP
	return lin + hi


func _alt_penalty(elevation: float, sea_level: float = -1.0) -> float:
	var sea: float = sea_level
	if sea < 0.0 and _generator._last_cfg != null:
		sea = float(_generator._last_cfg.sea_level)
	if sea >= 0.0:
		return _generator._alt_penalty_height(_generator._temperature_height_for_penalty(elevation, sea))
	return _generator._alt_penalty_height(elevation)

# 雪盖派生：与 shader compute_snow_factor 同公式（去掉 fbm jitter，CPU 端用确定性版本）。
# 2026-05-19：把雪线从"高山地形开关"改回连续海拔/温度权重。
#   - 低温段放宽到 temp<0.52，但以薄雪为主，解决丘陵/温带冬季永远无雪。
#   - 高山段用 temp 0.72→0.28 和 land_h 0.22→0.90 的双 smoothstep，
#     让暖季高山雪盖退成斑驳，而不是只要进 MOUNTAIN 就终年全白。
# 输入 land_h 由 caller 用 sea_level 归一化后传入，避免在此重复算。
# 2026-05-19 Plan-C 调参：cold_snow 雪线带从 [0.26, 0.52]×0.50 收窄到 [0.30, 0.48]×0.55。
# 配合 season_temp_amp 0.20→0.32 的振幅放大，让中高纬地块在春秋出现真正的雪线过渡态，
# 而不是终年同色。SAME_SOURCE 锚点：
#   - shader: shaders/include/snow_cover.gdshaderinc::apply_snow_cover (cold_lo/cold_hi)
#   - 本文件 fast-path 复刻：行 ~5781（_apply_climate_daily_pass_fast 内）

func _derived_snow_cover(temp_now: float, land_h: float, terrain: int, cover: int) -> float:
	# 2026-05-19 Plan-C 二次调参（日志诊断后）：
	# 现象：season_temp_amp=0.32 + 雪线带 [0.30, 0.48] 宽度仅 0.18 → 季节振幅(0.64)
	# 是过渡带 3.6 倍 → 单 cell 只在春秋很短的窗口里看到"半雪"，其余时间全有/全无。
	# 修复：把雪线带拉宽到 [0.20, 0.60]（0.40），中纬冬季满白、春秋稳定过渡、
	#       夏季中高纬挂薄雪、赤道全年无雪。amount 上提 0.55→0.70 强化对比。
	var snow_cover: float = 0.0
	if terrain == TerrainType.TERRAIN.SNOW:
		snow_cover = (1.0 - smoothstep(0.22, 0.62, temp_now)) * 0.80
	var cold_snow: float = (1.0 - smoothstep(0.20, 0.60, temp_now)) * 0.70
	var altitude_w: float = smoothstep(0.22, 0.90, land_h)
	var alpine_temp_w: float = 1.0 - smoothstep(0.20, 0.85, temp_now)
	var alpine_snow: float = altitude_w * alpine_temp_w * 0.92
	snow_cover = max(snow_cover, max(cold_snow, alpine_snow))
	if cover == CoverType.CV.GLACIER and snow_cover < 0.80:
		snow_cover = 0.80
	return snow_cover


func _bootstrap_sea_ice_fraction(map: MapData, cfg: MapConfig) -> void:
	# generate() 里的一次性初始化：为每个海洋 cell 按年基线温度给出 sea_ice_fraction 平衡值。
	# 目的：让 refresh_climate_daily 首次运行前就有合理的初值，而不是全 0（否则高纬该冻的地方
	# 需要几十天才爬到 ice_terrain_threshold，视觉上出现"开局一片无冰"的假象）。
	# 不使用固定 summer/winter 相位；季节性由后续 daily temperature pass 连续注入。
	#
	# 平衡值取法（与 _apply_sea_ice_daily_pass 的阈值语义一致）：
	#   temp < form_threshold  →  fraction = smoothstep 向 1 走
	#   temp > melt_threshold  →  fraction = 0
	#   之间                   →  线性过渡
	# 然后再按 sea_ice_terrain_threshold 翻转 terrain。
	var cp = _generator._c()
	if cp == null:
		return
	var t_form: float = float(cp.sea_ice_form_threshold)
	var t_melt: float = float(cp.sea_ice_melt_threshold)
	var thr_terrain: float = float(cp.sea_ice_terrain_threshold)
	var solar_gate_enabled: bool = _generator._sea_ice_solar_gate_enabled(cp)
	var freeze_insol_low: float = float(cp.sea_ice_freeze_insol_low)
	var freeze_insol_high: float = float(cp.sea_ice_freeze_insol_high)
	for cell: HexCell in map.all_cells():
		if not _generator._is_water(cell.terrain):
			cell.sea_ice_fraction = 0.0
			continue
		if cell.terrain == TerrainType.TERRAIN.LAKE:
			cell.sea_ice_fraction = 0.0
			continue
		var ny: float = _generator._cube_row_norm(cell, cfg)
		var temp_year: float = _generator._compute_temperature(ny, cell.elevation)
		var temp_ref: float = clampf(temp_year, 0.0, 1.0)
		var polar_w: float = absf(ny * 2.0 - 1.0)
		var frac: float = 0.0
		if temp_ref < t_form:
			# 冷：按离阈距离给个饱和度
			frac = clampf((t_form - temp_ref) / maxf(t_form, 0.001), 0.0, 1.0)
			# 用更宽的 smoothstep，避免接近阈值的低浓度冰在开局就变成满冰带。
			frac = smoothstep(0.10, 0.85, frac)
		elif temp_ref > t_melt:
			frac = 0.0
		else:
			# 迟滞带：线性从 form→melt 对应 1→0
			var span: float = maxf(t_melt - t_form, 0.001)
			frac = clampf((t_melt - temp_ref) / span, 0.0, 1.0) * 0.35
		if solar_gate_enabled:
			var annual_insol: float = _generator._insolation_annual_mean(ny)
			frac *= _generator._sea_ice_freeze_gate(annual_insol, freeze_insol_low, freeze_insol_high)
		var stable_polar_pack: bool = polar_w >= 0.78 and temp_ref < t_form * 0.85
		if not stable_polar_pack and frac >= thr_terrain:
			frac = maxf(0.0, thr_terrain - 0.08)
		cell.sea_ice_fraction = frac
		# 生成期只把稳定极地多年冰落成 terrain；过渡冰由 daily pass 自行生长/消退。
		if stable_polar_pack and frac >= thr_terrain and cell.terrain != TerrainType.TERRAIN.SEA_ICE:
			_generator._set_cell_runtime_terrain(map, cell, TerrainType.TERRAIN.SEA_ICE)


# ─── 地形决策（v8 阈值定调） ────────────────────────────────────────────
#
# 决策树先按 elevation 分类（OCEAN/COAST/MOUNTAIN/SNOW/TUNDRA），剩下陆地按
# (temperature, moisture) 在 Whittaker 风格的二维空间里选择 biome；HILL 属于 landform 轴。
#
# v8 的 ridge boost + slope_gate 让中海拔 cell 也能升级 MOUNTAIN，所以
# 生成期 permanent_only=true 时 MOUNTAIN 阈值更保守，丘陵/低地/平原则由 landform 派生。


func _decide_terrain(elevation: float, temperature: float, moisture: float, cfg: MapConfig, permanent_only: bool = false) -> TerrainType.TERRAIN:
	if elevation < cfg.sea_level - 0.06:
		return TerrainType.TERRAIN.OCEAN
	if elevation < cfg.sea_level:
		return TerrainType.TERRAIN.COAST

	var land_height: float = (elevation - cfg.sea_level) / (1.0 - cfg.sea_level)

	# ─── 海拔/极地优先（不论温度湿度）───────────────────────────────────
	# v10.6：三档 SNOW 判定
	# 2026-05-18 雪线修正 #2：alt_penalty 加深后温度被多扣 ~0.24，
	# 中纬丘陵 (land_h≈0.4~0.5) 大量误判 COLD_SNOW。阈值跟着抬：
	#   COLD_SNOW_LINE 0.40→0.55（只允许中山以上冷雪）
	#   cold-snow 温度门槛 0.13→0.08（更冷才换 SNOW）
	#   极地低温门槛 0.06→0.03（低海拔不被 alt_pen 误伤）
	#
	# 2026-05-18 雪线修正 #3 / 季节性高山雪：
	# permanent_only=true 仅在 bake 阶段（snapshot_base_state 之前）使用，
	# 用更严苛阈值决定哪些 cell 被永久锁死为 SNOW（base_terrain=SNOW，
	# refresh_seasonal/refresh_climate_daily 会跳过 _decide_terrain 永久维持）。
	# 其它 fast-tick 路径仍传 false，温度（含 season_offset）正常驱动雪/岩切换。
	#
	# 调参目标：
	#   - 赤道高山顶不再只凭高度永久雪；由雪盖曲线决定季节性退缩。
	#   - 中纬高山（land_h≈0.55~0.82, 年均温<0.08）→ bake 进 MOUNTAIN，
	#     fast tick 冬季 temp_now<0.08 时翻 SNOW，夏季回 MOUNTAIN
	#   - 极地低海拔（temp<0.03）→ bake 进 TUNDRA/PLAIN，季节性翻雪
	var snow_line: float = 0.85 if permanent_only else 0.82
	var snow_line_temp: float = 0.26 if permanent_only else 0.34
	var cold_snow_line: float = 0.70 if permanent_only else 0.55
	var cold_snow_temp: float = 0.05 if permanent_only else 0.08
	# 极地永久雪：bake 时关闭（温度<0 等价于不触发），fast-tick 仍按 0.03 兜底。
	var polar_temp: float = -1.0 if permanent_only else 0.03
	if land_height > snow_line and temperature < snow_line_temp:
		return TerrainType.TERRAIN.SNOW
	if land_height > cold_snow_line and temperature < cold_snow_temp:
		return TerrainType.TERRAIN.SNOW
	if temperature < polar_temp:
		return TerrainType.TERRAIN.SNOW
	var mountain_line: float = 0.72 if permanent_only else 0.70
	if land_height > mountain_line:
		return TerrainType.TERRAIN.MOUNTAIN
	if temperature < 0.20:
		return TerrainType.TERRAIN.TUNDRA

	# [climate-zone-fix P1] 与 C++ pk_decide_terrain_ex 同源：湿端阈值按世界湿度天花板
	# 旧单一"热带(>0.55)"拆成真热带与亚热带/暖温带；连续雨林只占湿尾。
	# (0.55–0.66)，让 FOREST 地形在亚热带可达，修复 SUBTROPICAL_FOREST 死分支。
	# [zonal-envelope 2026-08-01] 与 C++ 完全重新同步（此前 GDScript 已漂移：温带 FOREST
	# 真热带门为 0.80（≈33°回归线外缘），温带 FOREST 湿门 0.42、
	# 温带 GRASSLAND 0.28，并保留凉带 STEPPE/TUNDRA 限制。
	if temperature > 0.80:                         # 真热带（赤道带，0–33°）
		if moisture > 0.64:
			return TerrainType.TERRAIN.JUNGLE     # 连续湿润热带森林（C++ 同步）
		if moisture > 0.32:
			return TerrainType.TERRAIN.SAVANNA    # 稀树草原
		# [zonal-envelope 二轮] 热带草系干端 0.20→0.24，干端转真荒漠（C++ 同步）。
		if moisture > 0.24:
			return TerrainType.TERRAIN.STEPPE
		return TerrainType.TERRAIN.DESERT         # 热带沙漠

	if temperature > 0.55:                         # 亚热带 / 暖温带（33–51°，湿端→亚热带常绿林）
		if moisture > 0.40:
			return TerrainType.TERRAIN.FOREST     # → _derive_vegetation 派生 SUBTROPICAL_FOREST（0.36→0.40）
		if moisture > 0.24:
			return TerrainType.TERRAIN.GRASSLAND
		if moisture > 0.16:
			return TerrainType.TERRAIN.STEPPE
		return TerrainType.TERRAIN.DESERT

	if temperature > 0.38:                         # 温带（51–62°）
		if moisture > 0.42:
			return TerrainType.TERRAIN.FOREST     # 温带阔叶林（配合风暴路径湿带）
		if moisture > 0.28:
			return TerrainType.TERRAIN.GRASSLAND  # 温带草地（0.32→0.28 收窄草原漏斗）
		if moisture > 0.16:
			return TerrainType.TERRAIN.STEPPE
		return TerrainType.TERRAIN.DESERT

	# 凉温带 / 北方带（0.20–0.38，62–77°）
	if moisture > 0.45:
		return TerrainType.TERRAIN.TAIGA
	# [water-tuning 2026-06-26] STEPPE 限暖凉温带（t>0.30），更冷回落针叶林/苔原/寒漠
	if temperature > 0.30:
		if moisture > 0.22:
			return TerrainType.TERRAIN.STEPPE
		return TerrainType.TERRAIN.COLD_DESERT
	# 冷凉温带 / 亚极地（0.20–0.30）
	if moisture > 0.28:
		return TerrainType.TERRAIN.TAIGA
	if moisture > 0.16:
		return TerrainType.TERRAIN.TUNDRA
	return TerrainType.TERRAIN.COLD_DESERT

# ─── Milestone 1：三轴派生（landform / vegetation / cover） ──────────────────
#
# 设计选择：
#   原计划"重写 _apply_*_pass 让 vegetation/cover 成为工作源"风险过高（9 个 pass
#   × 数百分支需要逐一验证）。改为更安全的"terrain 在生成期间仍是工作源，
#   三轴在每个生成阶段末尾从 terrain + 上下文派生"。
#
# 收益等价：
#   1) UI 与新代码读 cell.landform / vegetation / cover 是真正的独立轴
#   2) HILL 上不再"压制"植被—— vegetation 看到 cell.terrain == HILL 时
#      会按 (temp, moist) 重新走 Whittaker 决策（_decide_vegetation_for_landform
#      内部分支），输出真实植被
#   3) Phase 8 生态评分切到 vegetation_history（粒度更细）
#   4) M2~M4 的 baker 双通道、Weather 注入、强耦合反馈都基于这套接口扩展

# 三个 enum 是 int，用 LandformType.LF.* 等访问。
# 这些 derive 函数都是 const 函数（无 side effect，仅读 cell 现成属性 + cfg）。


func _derive_landform(cell: HexCell, cfg: MapConfig) -> int:
	# 火山地标优先（has_volcano flag 在生成中后期由 _apply_volcano_pass 写入）
	if cell.has_volcano:
		return LandformType.LF.VOLCANO
	# 水体走 cell.terrain，因为 LAKE / OCEAN / COAST 由水体连通分量算法决定，
	# 不是简单的"低于海平面"
	var t: int = int(cell.terrain)
	if t == TerrainType.TERRAIN.LAKE:
		return LandformType.LF.LAKE
	# OCEAN / COAST / REEF / KELP / SEA_ICE 都是海洋系；按海拔分深 / 中 / 浅
	var marine: bool = (t == TerrainType.TERRAIN.OCEAN \
			or t == TerrainType.TERRAIN.COAST \
			or t == TerrainType.TERRAIN.REEF \
			or t == TerrainType.TERRAIN.KELP \
			or t == TerrainType.TERRAIN.SEA_ICE)
	if marine:
		var sea: float = cfg.sea_level
		if cell.elevation < sea * 0.55:
			return LandformType.LF.DEEP_OCEAN
		if cell.elevation < sea * 0.92:
			return LandformType.LF.OCEAN
		return LandformType.LF.COAST
	# 特殊永久地标
	if t == TerrainType.TERRAIN.DELTA:
		return LandformType.LF.DELTA
	if t == TerrainType.TERRAIN.BADLANDS:
		return LandformType.LF.BADLANDS
	if t == TerrainType.TERRAIN.SALT_FLAT:
		return LandformType.LF.SALT_FLAT
	if t == TerrainType.TERRAIN.FLOODPLAIN:
		return LandformType.LF.PLAIN
	if t == TerrainType.TERRAIN.MESA:
		return LandformType.LF.PLATEAU
	# 陆地：按 land_h 分段（与原 _decide_terrain 阈值一致）
	var land_h: float = (cell.elevation - cfg.sea_level) / maxf(1.0 - cfg.sea_level, 0.001)
	if land_h > 0.92:
		return LandformType.LF.PEAK
	if land_h > 0.70:
		return LandformType.LF.MOUNTAIN
	if land_h > 0.22:
		return LandformType.LF.HILL
	if land_h > 0.05:
		return LandformType.LF.LOWLAND
	return LandformType.LF.PLAIN

# 给定 (terrain, landform, temperature, moisture)，输出真正的植被身份。
# 关键：当 terrain == HILL / MOUNTAIN 时，不再"植被=丘陵"，而是按 (temp, moist)
# 在 Whittaker 风格的二维空间里选择具体植被（含 ALPINE_* 高山特殊分类）。

func _derive_vegetation(cell: HexCell, landform: int, temperature: float) -> int:
	var t: int = int(cell.terrain)
	# 海水 / 湖水 / 海冰：水面无陆生植被
	if t == TerrainType.TERRAIN.OCEAN \
			or t == TerrainType.TERRAIN.LAKE or t == TerrainType.TERRAIN.SEA_ICE:
		return VegetationType.VEG.NONE
	# COAST：暖凉浅海软底育海草床(SEAGRASS)，过冷/过热裸沙底为 NONE。
	# [zonal-envelope] 上缘 0.74→0.82：真热带边界收窄到 0.80 后热带浅海也允许海草床。
	if t == TerrainType.TERRAIN.COAST:
		if temperature > 0.42 and temperature < 0.82:
			return VegetationType.VEG.SEAGRASS
		return VegetationType.VEG.NONE
	# 海洋特殊植被
	if t == TerrainType.TERRAIN.REEF:
		return VegetationType.VEG.CORAL_REEF
	if t == TerrainType.TERRAIN.KELP:
		return VegetationType.VEG.KELP_FOREST
	# 永久冰川 / 雪面：植被几乎不存在
	if t == TerrainType.TERRAIN.GLACIER:
		return VegetationType.VEG.NONE
	if t == TerrainType.TERRAIN.SNOW:
		# 雪面下面如果是高山地形，植被身份是"高山苔原"被雪覆盖（cover 单独标 SNOW）
		if landform == LandformType.LF.HILL or landform == LandformType.LF.MOUNTAIN:
			return VegetationType.VEG.ALPINE_TUNDRA
		if landform == LandformType.LF.PEAK:
			return VegetationType.VEG.NONE
		return VegetationType.VEG.POLAR_DESERT
	# 高山判定（HILL/MOUNTAIN/PEAK）：植被走"高山植被"分支
	var is_alpine: bool = (landform == LandformType.LF.MOUNTAIN \
			or landform == LandformType.LF.PEAK)
	# PEAK 几乎无植被
	if landform == LandformType.LF.PEAK:
		return VegetationType.VEG.NONE
	# 永久地标植被映射
	if t == TerrainType.TERRAIN.DELTA:
		return VegetationType.VEG.MARSH if temperature < 0.55 else VegetationType.VEG.MANGROVE
	if t == TerrainType.TERRAIN.OASIS:
		return VegetationType.VEG.OASIS_VEG
	if t == TerrainType.TERRAIN.SALT_FLAT:
		return VegetationType.VEG.NONE
	if t == TerrainType.TERRAIN.BADLANDS:
		return VegetationType.VEG.DESERT_SCRUB
	# ── terrain-overhaul 新增地形 → 植被映射（与 C++ pk_derive_vegetation 同源）──
	if t == TerrainType.TERRAIN.COLD_DESERT:
		return VegetationType.VEG.XERIC_DESERT if cell.moisture < 0.08 else VegetationType.VEG.DESERT_SCRUB
	if t == TerrainType.TERRAIN.CHAPARRAL:
		return VegetationType.VEG.MEDITERRANEAN_SHRUB
	if t == TerrainType.TERRAIN.MOOR:
		return VegetationType.VEG.PEAT_BOG
	if t == TerrainType.TERRAIN.FLOODPLAIN:
		if temperature > 0.55:
			return VegetationType.VEG.MONSOON_FOREST if cell.moisture > 0.60 else VegetationType.VEG.SAVANNA
		return VegetationType.VEG.MARSH if cell.moisture > 0.70 else VegetationType.VEG.TEMPERATE_GRASSLAND
	if t == TerrainType.TERRAIN.MESA:
		return VegetationType.VEG.DESERT_SCRUB
	if t == TerrainType.TERRAIN.SWAMP:
		# 冷区沼泽积累泥炭 → PEAT_BOG，否则常规沼泽。
		return VegetationType.VEG.PEAT_BOG if temperature < 0.34 else VegetationType.VEG.SWAMP
	if t == TerrainType.TERRAIN.MANGROVE:
		return VegetationType.VEG.MANGROVE
	if t == TerrainType.TERRAIN.SHRUBLAND:
		return VegetationType.VEG.MEDITERRANEAN_SHRUB
	# 寒带 / 苔原 / 北方
	if t == TerrainType.TERRAIN.TUNDRA:
		if is_alpine:
			return VegetationType.VEG.ALPINE_TUNDRA
		return VegetationType.VEG.TUNDRA
	if t == TerrainType.TERRAIN.TAIGA:
		if is_alpine:
			return VegetationType.VEG.TEMPERATE_CONIFER
		return VegetationType.VEG.TAIGA
	# 山地无明确植被身份 → 走 Whittaker 决策（HILL 也走这里以避免"植被=丘陵"）
	if t == TerrainType.TERRAIN.HILL or t == TerrainType.TERRAIN.MOUNTAIN \
			or t == TerrainType.TERRAIN.PLAIN:
		return _generator._whittaker_vegetation(temperature, cell.moisture, landform)
	# Phase 10 Whittaker 命中：FOREST/JUNGLE/SAVANNA/GRASSLAND/STEPPE/DESERT
	var is_hilly: bool = (landform == LandformType.LF.HILL)
	match t:
		TerrainType.TERRAIN.FOREST:
			if is_alpine:
				return VegetationType.VEG.TEMPERATE_CONIFER
			# 暖湿丘陵迎风坡 → 云雾林（[climate-zone-fix P1] 湿门 0.70→0.52 适配湿度天花板）
			if is_hilly and temperature > 0.50 and cell.moisture > 0.52:
				return VegetationType.VEG.CLOUD_FOREST
			# [climate-zone-fix P1] temp>0.55→SUBTROPICAL_FOREST 现可达(亚热带 0.55–0.66 带 FOREST 地形)
			if temperature > 0.55:
				return VegetationType.VEG.SUBTROPICAL_FOREST
			return VegetationType.VEG.TEMPERATE_DECIDUOUS
		TerrainType.TERRAIN.JUNGLE:
			# 热带高地云雾林 → 极湿雨林 → 季风半落叶 → 季雨林
			# 连续雨林只占湿尾，季风林承接中间湿度带。
			if (is_alpine or is_hilly) and cell.moisture > 0.60:
				return VegetationType.VEG.CLOUD_FOREST
			if cell.moisture > 0.66:
				return VegetationType.VEG.TROPICAL_RAINFOREST
			if cell.moisture > 0.50:
				return VegetationType.VEG.MONSOON_FOREST
			return VegetationType.VEG.TROPICAL_DRY_FOREST
		TerrainType.TERRAIN.SAVANNA:
			if is_alpine:
				return VegetationType.VEG.ALPINE_MEADOW if cell.moisture > 0.45 else VegetationType.VEG.BOREAL_SHRUB
			# Keep SAVANNA's wet edge aligned with _decide_terrain's JUNGLE boundary.
			# SAVANNA 湿端季风林门与 JUNGLE 0.64 边界同步（C++ 同步）。
			return VegetationType.VEG.MONSOON_FOREST if cell.moisture > 0.64 else VegetationType.VEG.SAVANNA
		TerrainType.TERRAIN.GRASSLAND:
			if is_alpine:
				return VegetationType.VEG.ALPINE_MEADOW
			return VegetationType.VEG.TEMPERATE_GRASSLAND
		TerrainType.TERRAIN.STEPPE:
			if is_alpine:
				if temperature < 0.28:
					return VegetationType.VEG.ALPINE_TUNDRA
				return VegetationType.VEG.ALPINE_MEADOW if cell.moisture > 0.32 else VegetationType.VEG.BOREAL_SHRUB
			return VegetationType.VEG.TEMPERATE_STEPPE
		TerrainType.TERRAIN.DESERT:
			# 极旱 → XERIC_DESERT；普通 → DESERT_SCRUB
			if cell.moisture < 0.10:
				return VegetationType.VEG.XERIC_DESERT
			return VegetationType.VEG.DESERT_SCRUB
		_:
			return _generator._whittaker_vegetation(temperature, cell.moisture, landform)

# Whittaker 风格的(temperature, moisture)→vegetation 决策
# 用于 _derive_vegetation 内部"无明确植被身份的 terrain"（HILL/PLAIN/MOUNTAIN）

func _whittaker_vegetation(temperature: float, moisture: float, landform: int) -> int:
	var is_alpine: bool = (landform == LandformType.LF.MOUNTAIN \
			or landform == LandformType.LF.PEAK)
	var is_hilly: bool = (landform == LandformType.LF.HILL)
	# 寒带
	if temperature < 0.06:
		return VegetationType.VEG.POLAR_DESERT
	if temperature < 0.20:
		if is_alpine:
			return VegetationType.VEG.ALPINE_TUNDRA
		return VegetationType.VEG.TUNDRA
	# 凉温带
	if temperature < 0.40:
		if moisture > 0.40:
			if is_alpine:
				return VegetationType.VEG.TEMPERATE_CONIFER
			return VegetationType.VEG.TAIGA
		if moisture > 0.20:
			return VegetationType.VEG.BOREAL_SHRUB
		return VegetationType.VEG.ALPINE_TUNDRA if is_alpine else VegetationType.VEG.TEMPERATE_STEPPE
	# 暖温带
	if temperature < 0.55:
		# 温带森林湿门 0.42 / 草门 0.26，与 C++ pk_whittaker_vegetation 同步。
		if moisture > 0.42:
			if is_alpine:
				return VegetationType.VEG.TEMPERATE_CONIFER
			if is_hilly:
				return VegetationType.VEG.TEMPERATE_DECIDUOUS
			return VegetationType.VEG.TEMPERATE_DECIDUOUS
		if moisture > 0.26:
			if is_alpine:
				return VegetationType.VEG.ALPINE_MEADOW
			return VegetationType.VEG.TEMPERATE_GRASSLAND
		return VegetationType.VEG.BOREAL_SHRUB if is_alpine else VegetationType.VEG.TEMPERATE_STEPPE
	# [climate-zone-fix P1] 亚热带拆出 SUBTROPICAL_FOREST；真热带湿端阈值下移适配天花板。
	# [zonal-envelope] 亚热带上缘 0.66→0.80（≈33°），SUBTROP 湿门 0.36→0.40，与 C++ 同步。
	if temperature < 0.80:           # 亚热带（33–51°）
		if moisture > 0.40:
			return VegetationType.VEG.SUBTROPICAL_FOREST
		if moisture > 0.22:
			return VegetationType.VEG.TEMPERATE_GRASSLAND
		if moisture < 0.12:
			return VegetationType.VEG.DESERT_SCRUB   # 副热带旱坡
		return VegetationType.VEG.TEMPERATE_STEPPE
	# 真热带（0–33°）
	# 连续雨林湿门 0.64，与 JUNGLE 地形边界对齐（C++ 同步）。
	if moisture > 0.64:
		return VegetationType.VEG.TROPICAL_RAINFOREST
	if moisture > 0.42:
		return VegetationType.VEG.MONSOON_FOREST
	if moisture > 0.34:
		return VegetationType.VEG.TROPICAL_DRY_FOREST
	# [zonal-envelope 二轮] SAVANNA 下限 0.20→0.24（C++ 同步）。
	if moisture > 0.24:
		return VegetationType.VEG.SAVANNA
	if moisture < 0.10:
		return VegetationType.VEG.XERIC_DESERT
	return VegetationType.VEG.DESERT_SCRUB

# 覆盖物（cover）派生：永久冰 → GLACIER / 海冰 → SEA_ICE / 季节雪盖 → SNOW
# 苔原下层默认 PERMAFROST（永久冻土）

func _derive_cover(cell: HexCell, snow_cover: float) -> int:
	var t: int = int(cell.terrain)
	if t == TerrainType.TERRAIN.GLACIER:
		return CoverType.CV.GLACIER
	if t == TerrainType.TERRAIN.SEA_ICE:
		return CoverType.CV.SEA_ICE
	if t == TerrainType.TERRAIN.SNOW:
		return CoverType.CV.SNOW
	# 季节性雪盖（陆地，由 refresh_seasonal 算出 snow_cover ∈ [0, 1]）
	if snow_cover > 0.5 and not _generator._is_water(t):
		return CoverType.CV.SNOW
	# 苔原默认下层永冻土（这是地理事实，不是季节性）
	if t == TerrainType.TERRAIN.TUNDRA:
		return CoverType.CV.PERMAFROST
	return CoverType.CV.NONE

# 单 cell 同步三轴。生成期间用 snow_cover=0（默认夏季）；refresh_seasonal 内传当季 snow_cover。

func _sync_axes_for_cell(cell: HexCell, cfg: MapConfig, snow_cover: float, temperature_override: float = -1.0) -> void:
	var landform = _generator._derive_landform(cell, cfg)
	var prev_landform: int = int(cell.landform)
	if not _generator._is_water(cell.terrain) and (
			prev_landform == LandformType.LF.PEAK
			or prev_landform == LandformType.LF.VOLCANO
			or prev_landform == LandformType.LF.PLATEAU
			or prev_landform == LandformType.LF.RIFT_VALLEY
			or prev_landform == LandformType.LF.CANYON):
		landform = prev_landform
	var ny: float = _generator._cube_row_norm(cell, cfg)
	var temp: float = temperature_override if temperature_override >= 0.0 else _generator._compute_temperature(ny, cell.elevation)
	cell.landform = landform
	# 保留合理的演替滞后；明显跨生态带的残留则在 terrain 重分类后立即纠正。
	var needs_reconcile := VegetationType.needs_biome_reconciliation(
		int(cell.terrain), int(cell.vegetation))
	if _generator._is_water(cell.terrain) \
			or int(cell.vegetation) == int(VegetationType.VEG.NONE) \
			or needs_reconcile:
		cell.vegetation = _generator._derive_vegetation(cell, landform, temp)
	cell.cover = _generator._derive_cover(cell, snow_cover)

# 全图同步（生成结束后调用一次，snow_cover=0）

func _compute_ocean_currents(map: MapData, world: WorldData, hex_size: float) -> void:
	var t0 := Time.get_ticks_msec()
	# Physical Wind & Ocean Circulation：物理化路径下，cell.ocean_current /
	# cell.upwelling_strength 已由 MapBaker 的 hex 求解器（PhysicalCirculationSolver.psi_to_ocean_current
	# / solve_upwelling）直接写入；此时再从像素 buffer 反向采样会**降级精度**
	# （hex 求解 → RG8 量化 → 双线性回采，三次重采样累积误差），所以直接 return。
	# 旧路径继续按"像素回采到 hex"工作，行为 bit-for-bit 不变。
	var profile: ClimateProfile = _generator._c()
	if profile != null and profile.physical_circulation_enabled:
		# 收尾日志：旧版每天一次；现在 physical-hex 已是常态路径，只在第一次
		# 命中时打一行作为可观测证据，后续静默。
		if not _generator._phys_skip_logged:
			_generator._phys_skip_logged = true
			print("MapGenerator: skip _compute_ocean_currents (physical-hex path writes per-cell directly)")
		return
	var water_count: int = 0
	var has_upwelling: bool = not world.ocean_upwelling_buffer.is_empty()
	for cell: HexCell in map.all_cells():
		if cell == null:
			continue
		if not _generator._is_water(cell.terrain):
			cell.ocean_current = Vector2.ZERO
			cell.upwelling_strength = 0.0
			continue
		var wp: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, hex_size)
		var cur: Vector2 = world.sample_ocean_current(wp)
		# clamp 长度 ≤ 1（sample 出来理论上就在 [-1,1]×[-1,1] 区间，
		# 极少数对角线位置 length 可能 >1，做个安全裁切）。
		if cur.length() > 1.0:
			cur = cur.normalized()
		cell.ocean_current = cur
		# Systemic Ocean Currents：同步回填 upwelling_strength ∈ [-1, 1]
		cell.upwelling_strength = world.sample_upwelling(wp) if has_upwelling else 0.0
		water_count += 1
	print("MapGenerator v7: ocean currents for %d water cells in %dms"
			% [water_count, Time.get_ticks_msec() - t0])

# ─── 地形扰动风场（六边形尺度） ────────────────────────────────────────────
# 给每个 cell 计算"被地形修改过的实际盛行风向 + 风速"，写入 cell.wind_vector。
# 仅在 bake 后跑一次（per-game）。语义参见 HexCell.wind_vector 注释——
# 不影响 WorldData.wind_field_buffer，也不参与天气 / 洋流物理。
#
# 算法（season_phase=2.0 = 北半球夏至基线，与 wind_field_buffer 同源；
# 后续若想要季节切换可再扩展）：
#   ① 基础风：dir = WindBelt.wind_at(ny, 2.0)，speed = WindBelt.wind_speed_at(ny, 2.0)
#   ② 海陆摩擦：陆地 cell speed × 0.65（粗糙度 ~ 海面的 3-5 倍，简化为线性衰减）
#   ③ 山脉上风阻挡：取上风向相邻 cell（用 wind dir 的反方向选最匹配的 hex 邻居）
#      若上风邻居 elevation - 当前 elevation > 0.15：
#        speed × 0.4（背风衰减）
#        方向往两侧旋转 60°，向"左右两侧海拔较低"的那一侧绕（绕山阻力小）
#   ④ 山脊伯努利效应：当前 cell 高于全部 6 邻居 ≥ 0.10 → speed × 1.3
#   ⑤ 海岸热力风：自身陆地、邻居有海洋（白天海风加速）→ speed × 1.15
# 这些系数都是经验值，目的是让 Overlay 显示"风受地形影响"，不必物理精确。

func _compute_terrain_perturbed_wind(map: MapData) -> void:
	if _generator._last_cfg == null:
		return
	# Physical Wind & Ocean Circulation：物理化路径下，cell.wind_vector / wind_speed 已由
	# PhysicalCirculationSolver.solve_wind_field 求出（含纬度基线 + ∇slp 压力梯度风 +
	# 沿海热力环流 + 科氏偏转 + 山地地形偏转），再叠这一遍经验性"地形扰动"会重复且不一致。
	# 物理化开启时直接 return，保留 hex 求解器结果。
	var profile: ClimateProfile = _generator._c()
	if profile != null and profile.physical_circulation_enabled:
		print("MapGenerator: skip _compute_terrain_perturbed_wind (physical-hex solver writes per-cell)")
		return
	var t0 := Time.get_ticks_msec()
	var cfg_local: MapConfig = _generator._last_cfg
	var perturbed_count: int = 0
	# 预存 6 个 cube 方向的二维"屏幕 dir"，用于"风向 → 上风 hex 邻居"匹配。
	# pointy-top + cube_to_world：方向 0 (E) 与屏幕 +x 对齐，1 (NE) 偏右上等。
	# 这里用 cube_to_world(d.x, d.y, 1.0) 得到方向单位向量，避免硬编码。
	var dir_screen: Array = []  # Array[Vector2]
	dir_screen.resize(HexUtils.CUBE_DIRECTIONS.size())
	for i in range(HexUtils.CUBE_DIRECTIONS.size()):
		var d_v3: Vector3i = HexUtils.CUBE_DIRECTIONS[i]
		var v: Vector2 = HexUtils.cube_to_world(d_v3.x, d_v3.y, 1.0)
		var ln: float = v.length()
		dir_screen[i] = v / ln if ln > 0.0001 else Vector2.RIGHT

	for cell: HexCell in map.all_cells():
		if cell == null:
			continue
		var ny: float = _generator._cube_row_norm(cell, cfg_local)
		var base_dir: Vector2 = _generator.WindBeltScript.wind_at(ny, 2.0, 0.0)
		var base_speed: float = _generator.WindBeltScript.wind_speed_at(ny, 2.0)

		# ② 海陆摩擦：陆地 0.65；水面 1.0；海冰按陆地处理（雪面也粗糙）
		var is_water_cell: bool = _generator._is_water(cell.terrain)
		var is_sea_ice: bool = cell.terrain == TerrainType.TERRAIN.SEA_ICE
		var friction: float = 1.0
		if is_sea_ice:
			friction = 0.7
		elif not is_water_cell:
			friction = 0.65
		var spd: float = base_speed * friction
		var dir: Vector2 = base_dir

		# ③/④/⑤ 需要 6 邻居 elevation；按方向 idx 拿（缺失邻居用当前 cell 自身海拔代替）
		var nb_elev: PackedFloat32Array = PackedFloat32Array()
		nb_elev.resize(6)
		var nb_cells: Array = []
		nb_cells.resize(6)
		for k in range(6):
			var dk: Vector3i = HexUtils.CUBE_DIRECTIONS[k]
			var nb: HexCell = map.get_cell_by_cube(
				Vector3i(cell.q + dk.x, cell.r + dk.y, cell.s + dk.z)
			)
			nb_cells[k] = nb
			nb_elev[k] = nb.elevation if nb != null else cell.elevation

		# ③ 山脉上风阻挡：选与"风向反方向"夹角最小的 hex 邻居作为上风邻居
		var upwind_idx: int = 0
		var best_dot: float = -INF
		var minus_dir: Vector2 = -dir.normalized() if dir.length() > 0.0001 else Vector2.LEFT
		for k in range(6):
			var ds: Vector2 = dir_screen[k]
			var dot_k: float = ds.dot(minus_dir)
			if dot_k > best_dot:
				best_dot = dot_k
				upwind_idx = k
		var upwind_elev: float = nb_elev[upwind_idx]
		var elev_diff: float = upwind_elev - cell.elevation
		if elev_diff > 0.15:
			spd *= 0.4
			# 选两个旁侧邻居（左右各一），看哪侧海拔更低就往哪侧绕
			var left_idx: int = (upwind_idx + 5) % 6  # 上风的"左前方"对应的下风方向
			var right_idx: int = (upwind_idx + 1) % 6
			# 实际下风方向 = -upwind_dir；其旁侧 = downwind_idx ±1
			var downwind_idx: int = (upwind_idx + 3) % 6
			var dn_left: int = (downwind_idx + 5) % 6
			var dn_right: int = (downwind_idx + 1) % 6
			# 旁侧 elev 越低，风越倾向往那侧绕
			var bend_sign: float = 0.0
			if nb_elev[dn_left] < nb_elev[dn_right] - 0.02:
				bend_sign = -1.0
			elif nb_elev[dn_right] < nb_elev[dn_left] - 0.02:
				bend_sign = 1.0
			# 旋转 ~50° 模拟绕流
			if bend_sign != 0.0:
				dir = dir.rotated(bend_sign * 0.87)  # ~50°
			# 不重新归一（保留方向语义；速度已被 0.4 衰减）
			# 仅在 left_idx/right_idx 没用到时消耗，规避 GDScript 未使用变量警告
			var _u: int = left_idx + right_idx

		# ④ 山脊加速：当前 cell elevation 高于所有邻居 ≥ 0.10
		var is_ridge: bool = true
		for k in range(6):
			if cell.elevation - nb_elev[k] < 0.10:
				is_ridge = false
				break
		if is_ridge:
			spd *= 1.3

		# ⑤ 海岸热力风：陆地 + 至少一个海洋邻居
		if not is_water_cell:
			var has_sea_neighbor: bool = false
			for k in range(6):
				var nbc: HexCell = nb_cells[k]
				if nbc != null and _generator._is_water(nbc.terrain):
					has_sea_neighbor = true
					break
			if has_sea_neighbor:
				spd *= 1.15

		# 写入：dir 已 normalize（来自 wind_at），最终向量长度 = 速度
		var final_dir: Vector2 = dir
		var ln_d: float = final_dir.length()
		if ln_d > 0.0001:
			final_dir = final_dir / ln_d
		else:
			final_dir = Vector2(1.0, 0.0)
		cell.wind_vector = final_dir * spd
		perturbed_count += 1

	print("MapGenerator: terrain-perturbed wind for %d cells in %dms"
			% [perturbed_count, Time.get_ticks_msec() - t0])


func _generate_static_research_signals(map: MapData) -> void:
	if map == null or _generator._data_core_world_ext == null :
		push_error("[research-signals] native generation pass unavailable")
		return
	var catalog: Dictionary = _generator.TechnologyCatalogScript.compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		push_error("[research-signals] catalog compile failed: %s" % String(catalog.get("reason", "unknown")))
		return
	var ids: PackedStringArray = catalog.get("research_signal_ids", PackedStringArray())
	var dense := PackedInt32Array()
	for key in [
		"landform.freshwater_access", "landform.river_valley", "landform.volcanic",
		"landform.high_plateau", "landform.coastal_estuary", "landform.coast",
		"landform.arid_basin", "landform.marsh", "landform.forest",
		"landform.grassland", "landform.mountain",
		"landform.delta", "landform.floodplain", "landform.monsoon_basin",
		"landform.loess_plain", "landform.steppe_plain", "landform.tundra",
		"landform.conifer_forest", "landform.oasis", "landform.steep_slope",
		"landform.stable_wind_corridor",
	]:
		var index := ids.find(key)
		if index < 0:
			push_error("[research-signals] required catalog id missing: %s" % key)
			return
		dense.append(index)
	var result: Dictionary = _generator._data_core_world_ext.run_research_signal_generation_pass({
		"width": map.width,
		"height": map.height,
		"seed": _generator._last_seed,
		"generation_vegetation": map.vegetation_arr,
		"landform": map.landform_arr,
		"has_river": map.has_river_arr,
		"has_volcano": map.has_volcano_arr,
		"is_water": map.is_water_arr,
		"temperature": map.temp_arr,
		"moisture": map.moisture_arr,
		"elevation": map.elevation_arr,
		"signal_ids": dense,
	})
	if not bool(result.get("ok", false)):
		push_error("[research-signals] native generation failed: %s" % String(result.get("reason", "unknown")))
		return
	var n := map.cell_count()
	var offsets: PackedInt32Array = result.get("cell_signal_offsets", PackedInt32Array())
	var values: PackedInt32Array = result.get("cell_signal_values", PackedInt32Array())
	var signal_ids: PackedInt32Array = result.get("cell_signal_ids", PackedInt32Array())
	var realms: PackedByteArray = result.get("cell_biogeographic_realm", PackedByteArray())
	var generation_vegetation: PackedByteArray = result.get("generation_vegetation", PackedByteArray())
	if offsets.size() != n + 1 or realms.size() != n or generation_vegetation.size() != n \
			or values.size() != signal_ids.size():
		push_error("[research-signals] native output shape invalid")
		return
	map.generation_vegetation_arr = generation_vegetation
	map.cell_biogeographic_realm_arr = realms
	map.cell_research_signal_offsets = offsets
	map.cell_research_signal_ids = signal_ids
	map.cell_research_signal_values = values


## Natural-resource deposits do not exist when the static geography signal pass
## runs. This second native pass appends resource.* facts to the same sorted CSR.

func _append_natural_resource_research_signals(map: MapData) -> void:
	if map == null or _generator._data_core_world_ext == null :
		return
	var catalog: Dictionary = _generator.TechnologyCatalogScript.compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		push_error("[research-signals] resource catalog compile failed")
		return
	var ids: PackedStringArray = catalog.get("research_signal_ids", PackedStringArray())
	var dense := PackedInt32Array()
	var reserves: Array[PackedFloat32Array] = []
	for profile in ResourceProfileRegistry.ordered():
		var signal_index := ids.find("resource.%s" % String(profile.id))
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if signal_index < 0 or field.is_empty():
			push_error("[research-signals] resource signal binding missing: %s" % String(profile.id))
			return
		var values: PackedFloat32Array = map.get(field)
		if values.size() != map.cell_count():
			push_error("[research-signals] resource reserve shape invalid: %s" % String(profile.id))
			return
		dense.append(signal_index)
		reserves.append(values)
	var result: Dictionary = _generator._data_core_world_ext.run_research_signal_generation_pass({
		"mode": "resources",
		"cell_count": map.cell_count(),
		"cell_signal_offsets": map.cell_research_signal_offsets,
		"cell_signal_ids": map.cell_research_signal_ids,
		"cell_signal_values": map.cell_research_signal_values,
		"resource_signal_ids": dense,
		"resource_reserves": reserves,
	})
	if not bool(result.get("ok", false)):
		push_error("[research-signals] native resource merge failed: %s" % String(
			result.get("reason", "unknown")))
		return
	map.cell_research_signal_offsets = result.get("cell_signal_offsets", PackedInt32Array())
	map.cell_research_signal_ids = result.get("cell_signal_ids", PackedInt32Array())
	map.cell_research_signal_values = result.get("cell_signal_values", PackedInt32Array())



func _bio_occupancy_base_knobs(map_ref: MapData) -> Dictionary:
	var build_started_usec := Time.get_ticks_usec()
	if map_ref == null:
		return {"ok": false, "reason": "map_missing"}
	var n := map_ref.cell_count()
	var map_id := int(map_ref.get_instance_id())
	var cache_hit = _generator._bio_occupancy_knob_cache_version == _generator._BIO_OCCUPANCY_KNOB_CACHE_VERSION \
			and _generator._bio_occupancy_knob_cache_map_id == map_id \
			and _generator._bio_occupancy_knob_cache_n == n \
			and not _generator._bio_occupancy_knob_cache.is_empty()
	if not cache_hit:
		var catalog: Dictionary = _generator.ResearchSignalCatalogScript.compile_native_catalog()
		if not bool(catalog.get("ok", false)):
			return {"ok": false, "reason": String(catalog.get("reason", "catalog"))}
		var carrier_ids: PackedStringArray = catalog.get(
			"research_bio_carrier_ids", PackedStringArray())
		var carrier_alts: PackedStringArray = catalog.get(
			"research_bio_carrier_alt_ids", PackedStringArray())
		var unique_ids: Array[String] = []
		var index_of := {}
		for raw_id in carrier_ids:
			var id := String(raw_id)
			if id.is_empty() or index_of.has(id):
				continue
			index_of[id] = unique_ids.size()
			unique_ids.append(id)
		for raw_id in carrier_alts:
			var id := String(raw_id)
			if id.is_empty() or index_of.has(id):
				continue
			index_of[id] = unique_ids.size()
			unique_ids.append(id)
		var primary := PackedInt32Array()
		var alt := PackedInt32Array()
		var carrier_slot_names := PackedStringArray()
		for raw_id in unique_ids:
			var slot_name := ""
			for profile in ResourceProfileRegistry.ordered():
				if String(profile.id) == String(raw_id):
					slot_name = ResourceProfileRegistry.reserve_cpp_name(profile)
					break
			carrier_slot_names.append(slot_name)
		primary.resize(carrier_ids.size())
		alt.resize(carrier_alts.size())
		for i in range(carrier_ids.size()):
			var id := String(carrier_ids[i])
			primary[i] = int(index_of.get(id, -1)) if not id.is_empty() else -1
		for i in range(carrier_alts.size()):
			var id := String(carrier_alts[i])
			alt[i] = int(index_of.get(id, -1)) if not id.is_empty() else -1
		_generator._bio_occupancy_knob_cache = {
			"ok": true,
			"cell_count": n,
			"width": map_ref.width,
			"height": map_ref.height,
			"seed": _generator._last_seed,
			"neighbor_indices": map_ref.neighbor_indices_packed(),
			"species_signal_ids": catalog.get("research_bio_signal_ids", PackedInt32Array()),
			"species_occupancy_bits": catalog.get("research_bio_occupancy_bits", PackedInt32Array()),
			"species_carrier_index": primary,
			"species_carrier_alt_index": alt,
			"species_temp_lo": catalog.get("research_bio_temp_lo", PackedFloat32Array()),
			"species_temp_hi": catalog.get("research_bio_temp_hi", PackedFloat32Array()),
			"species_moist_lo": catalog.get("research_bio_moist_lo", PackedFloat32Array()),
			"species_moist_hi": catalog.get("research_bio_moist_hi", PackedFloat32Array()),
			"species_elev_lo": catalog.get("research_bio_elev_lo", PackedFloat32Array()),
			"species_elev_hi": catalog.get("research_bio_elev_hi", PackedFloat32Array()),
			"species_veg_mask0": catalog.get("research_bio_veg_mask0", PackedInt32Array()),
			"species_veg_mask1": catalog.get("research_bio_veg_mask1", PackedInt32Array()),
			"species_flags": catalog.get("research_bio_flags", PackedInt32Array()),
			"species_max_cost": catalog.get("research_bio_max_cost", PackedInt32Array()),
			"species_fill_keep": catalog.get("research_bio_fill_keep", PackedFloat32Array()),
			"species_origin_policy": catalog.get("research_bio_origin_policy", PackedInt32Array()),
			"species_guild": catalog.get("research_bio_guild", PackedInt32Array()),
			"species_habitat_class": catalog.get("research_bio_habitat_class", PackedInt32Array()),
			"carrier_ids": carrier_ids,
			"carrier_alts": carrier_alts,
			"carrier_unique_ids": unique_ids,
			"carrier_slot_names": carrier_slot_names,
		}
		_generator._bio_occupancy_knob_cache_map_id = map_id
		_generator._bio_occupancy_knob_cache_n = n
		_generator._bio_occupancy_knob_cache_version = _generator._BIO_OCCUPANCY_KNOB_CACHE_VERSION
	var static_knobs: Dictionary = _generator._bio_occupancy_knob_cache
	if _generator._bio_occupancy_native_configured_map_id != map_id \
			and _generator._data_core_world_ext != null :
		var configured: Dictionary = _generator._data_core_world_ext.configure_bio_occupancy(static_knobs)
		if bool(configured.get("ok", false)):
			_generator._bio_occupancy_native_configured_map_id = map_id
	var empty := PackedFloat32Array()
	empty.resize(n)
	var columns: Array = []
	var unique_ids: Array = static_knobs.get("carrier_unique_ids", [])
	for raw_id in unique_ids:
		columns.append(_generator._bio_reserve_column(map_ref, String(raw_id), n, empty))
	var temperature: PackedFloat32Array = map_ref.temp_30d_arr
	if temperature.size() != n:
		temperature = map_ref.temp_arr
	var out: Dictionary = static_knobs.duplicate(false)
	out.merge({
		"cell_count": n,
		"is_water": map_ref.is_water_arr,
		"vegetation": map_ref.vegetation_arr,
		"landform": map_ref.landform_arr,
		"has_river": map_ref.has_river_arr,
		"temperature": temperature,
		"moisture": map_ref.moisture_arr,
		"elevation": map_ref.elevation_arr,
		"carrier_reserves": columns,
		"_knob_cache_hit": cache_hit,
		"_knob_cache_build_ms": (Time.get_ticks_usec() - build_started_usec) / 1000.0,
	})
	return out



func _bio_occupancy_daily_knobs(map_ref: MapData) -> Dictionary:
	if map_ref == null:
		return {"ok": false, "reason": "map_missing"}
	var map_id := int(map_ref.get_instance_id())
	if _generator._bio_occupancy_native_configured_map_id != map_id:
		var configured_knobs = _generator._bio_occupancy_base_knobs(map_ref)
		if not bool(configured_knobs.get("ok", false)):
			return configured_knobs
		if _generator._bio_occupancy_native_configured_map_id != map_id:
			# Native slots may be unavailable in a focused test harness. Preserve
			# the PackedArray A/B path instead of changing gameplay semantics.
			return configured_knobs
	return {
		"ok": true,
		"cell_count": map_ref.cell_count(),
		"seed": _generator._last_seed,
		"use_configured_slots": true,
		"_knob_cache_hit": true,
		"_knob_cache_build_ms": 0.0,
	}



func _bio_reserve_column(map_ref: MapData, resource_id: String, n: int,
		empty: PackedFloat32Array) -> PackedFloat32Array:
	for profile in ResourceProfileRegistry.ordered():
		if String(profile.id) != resource_id:
			continue
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field.is_empty():
			break
		var values: PackedFloat32Array = map_ref.get(field)
		if values.size() == n:
			return values
		break
	return empty



func _publish_bio_occupancy_to_runtime(map_ref: MapData) -> void:
	if map_ref == null:
		return
	var pairs := [
		[&"cell.bio_occupancy_bits", map_ref.bio_occupancy_bits_arr],
		[&"cell.landmass_id", map_ref.landmass_id_arr],
		[&"cell.province_id", map_ref.province_id_arr],
	]
	for pair in pairs:
		var component: StringName = pair[0]
		var values: PackedInt32Array = pair[1]
		if _generator._data_core_world != null and _generator._data_core_world.has_method("component_id") \
				and _generator._data_core_world.has_method("write_i32_range"):
			var cid := int(_generator._data_core_world.component_id(component))
			if cid >= 0:
				_generator._data_core_world.write_i32_range(cid, 0, values)
		if _generator._data_core_world_ext != null :
			var cid_ext := int(_generator._data_core_world_ext.component_id(component))
			if cid_ext >= 0:
				_generator._data_core_world_ext.write_i32_range(cid_ext, 0, values)



func _seed_bio_occupancy(map_ref: MapData) -> void:
	if map_ref == null or _generator._data_core_world_ext == null:
		push_error("[bio-occupancy] native province/seed pass unavailable")
		return
	var knobs = _generator._bio_occupancy_base_knobs(map_ref)
	if not bool(knobs.get("ok", false)):
		push_error("[bio-occupancy] species knobs failed: %s" % String(knobs.get("reason", "unknown")))
		return
	var province_res: Dictionary = {}
	var seed_res: Dictionary = {}
	seed_res = _generator._data_core_world_ext.run_bio_bootstrap_pass(knobs)
	if not bool(seed_res.get("ok", false)):
		push_error("[bio-occupancy] bootstrap pass failed: %s" % String(
			seed_res.get("reason", "unknown")))
		return
	province_res = seed_res
	var n := map_ref.cell_count()
	var landmass: PackedInt32Array = province_res.get("landmass_ids", PackedInt32Array())
	var provinces: PackedInt32Array = province_res.get("province_ids", PackedInt32Array())
	if landmass.size() != n or provinces.size() != n:
		push_error("[bio-occupancy] province output shape invalid")
		return
	map_ref.landmass_id_arr = landmass
	map_ref.province_id_arr = provinces
	knobs["province_ids"] = provinces
	knobs["landmass_ids"] = landmass
	if seed_res.is_empty():
		seed_res = _generator._data_core_world_ext.run_bio_seed_pass(knobs)
		if not bool(seed_res.get("ok", false)):
			push_error("[bio-occupancy] seed pass failed: %s" % String(
				seed_res.get("reason", "unknown")))
			return
	var occupancy: PackedInt32Array = seed_res.get("occupancy_bits", PackedInt32Array())
	if occupancy.size() != n:
		push_error("[bio-occupancy] occupancy output shape invalid")
		return
	map_ref.bio_occupancy_bits_arr = occupancy
	_generator._publish_bio_occupancy_to_runtime(map_ref)
	_generator._log_bio_occupancy_seed(knobs, seed_res, int(province_res.get("landmass_count", 0)),
		int(province_res.get("province_count", 0)))


## 生态播种诊断的「表头 + 每物种」段；两条路径（整段 native / 逐段 GDScript）
## 共用同一份打印，保证日志逐字相同。

func _log_bio_occupancy_seed_summary(knobs: Dictionary, seed_res: Dictionary,
		landmass_count: int, province_count: int) -> void:
	var catalog: Dictionary = _generator.ResearchSignalCatalogScript.compile_native_catalog()
	var ids: PackedStringArray = catalog.get("research_signal_ids", PackedStringArray())
	var signal_ids: PackedInt32Array = knobs.get("species_signal_ids", PackedInt32Array())
	var envelope: PackedInt32Array = seed_res.get("envelope_cell_counts", PackedInt32Array())
	var origin_envelope: PackedInt32Array = seed_res.get("origin_envelope_cell_counts", PackedInt32Array())
	var occupied: PackedInt32Array = seed_res.get("occupied_cell_counts", PackedInt32Array())
	var origins: PackedInt32Array = seed_res.get("origin_landmass_ids", PackedInt32Array())
	var seeded: PackedInt32Array = seed_res.get("seeded_landmass_counts", PackedInt32Array())
	var hearths: PackedInt32Array = seed_res.get("hearth_cell_counts", PackedInt32Array())
	print("[bio-occupancy] seed landmasses=%d provinces=%d species=%d secondary_hearths=%d" % [
		landmass_count, province_count, signal_ids.size(),
		int(seed_res.get("secondary_hearth_count", 0))])
	for i in range(signal_ids.size()):
		var sid := int(signal_ids[i])
		var signal_name := String(ids[sid]) if sid >= 0 and sid < ids.size() else "?"
		var env_n := int(envelope[i]) if i < envelope.size() else 0
		var origin_n := int(origin_envelope[i]) if i < origin_envelope.size() else 0
		var occ_n := int(occupied[i]) if i < occupied.size() else 0
		var origin_id := int(origins[i]) if i < origins.size() else 0
		var seeded_n := int(seeded[i]) if i < seeded.size() else 0
		var hearth_n := int(hearths[i]) if i < hearths.size() else occ_n
		var fill_ratio := (float(occ_n) / float(origin_n)) if origin_n > 0 else 0.0
		print("[bio-occupancy]   %s envelope=%d hearth=%d seeded_landmasses=%d primary_landmass=%d primary_envelope=%d occupied=%d occupied/envelope=%.2f" % [
			signal_name, env_n, hearth_n, seeded_n, origin_id, origin_n, occ_n, fill_ratio])



func _log_bio_occupancy_seed(knobs: Dictionary, seed_res: Dictionary, landmass_count: int,
		province_count: int) -> void:
	_generator._log_bio_occupancy_seed_summary(knobs, seed_res, landmass_count, province_count)
	var landmass_ids := PackedInt32Array()
	var classes_out := PackedStringArray()
	var foods_out := PackedStringArray()
	_generator._bio_landmass_summary_gdscript(
		seed_res.get("occupancy_bits", PackedInt32Array()),
		knobs.get("landmass_ids", PackedInt32Array()),
		knobs, landmass_ids, classes_out, foods_out)
	for i in range(landmass_ids.size()):
		print("[bio-occupancy]   landmass %d classes=%s foods=%s" % [
			int(landmass_ids[i]), String(classes_out[i]), String(foods_out[i])])


## 融合 pass 返回的 landmass 摘要直接打印（聚合在 C++ 里做完）。

func _log_bio_occupancy_seed_native(report: Dictionary, knobs: Dictionary) -> void:
	_generator._log_bio_occupancy_seed_summary(knobs, report,
		int(report.get("bio_log_landmass_count", 0)),
		int(report.get("bio_log_province_count", 0)))
	var landmass_ids: PackedInt32Array = report.get(
		"bio_log_landmass_ids", PackedInt32Array())
	var classes: PackedStringArray = report.get(
		"bio_log_classes", PackedStringArray())
	var foods: PackedStringArray = report.get(
		"bio_log_foods", PackedStringArray())
	if classes.size() != landmass_ids.size() or foods.size() != landmass_ids.size():
		return
	for i in range(landmass_ids.size()):
		print("[bio-occupancy]   landmass %d classes=%s foods=%s" % [
			int(landmass_ids[i]), String(classes[i]), String(foods[i])])


## `_log_bio_occupancy_seed()` 的 landmass 聚合段（旧链路 / A/B 探针参考实现）。
## 融合 pass 在 C++ 里跑同一段逻辑（world_ext_boot_facade.cpp
## boot_bio_landmass_summary），顺序与去重规则逐行对齐。

func _bio_landmass_summary_gdscript(occupancy: PackedInt32Array,
		landmass: PackedInt32Array, knobs: Dictionary,
		out_landmass: PackedInt32Array, out_classes: PackedStringArray,
		out_foods: PackedStringArray) -> void:
	var class_names := PackedStringArray(_generator.BIO_LOG_CLASS_NAMES)
	var food_names: Array = _generator.BIO_LOG_FOOD_NAMES
	var food_bits: PackedInt32Array = _generator._bio_log_food_bits()
	var occ_bits: PackedInt32Array = knobs.get("species_occupancy_bits", PackedInt32Array())
	var habitat_class: PackedInt32Array = knobs.get("species_habitat_class", PackedInt32Array())
	var summaries := {}
	for cell in range(mini(occupancy.size(), landmass.size())):
		var lid := int(landmass[cell])
		if lid <= 0:
			continue
		if not summaries.has(lid):
			summaries[lid] = {"foods": [], "classes": []}
		var foods: Array = summaries[lid].foods
		var classes: Array = summaries[lid].classes
		var bits := int(occupancy[cell])
		if bits == 0:
			continue
		for i in food_bits.size():
			if food_bits[i] >= 0 and (bits & (1 << food_bits[i])) != 0 \
					and not foods.has(food_names[i]):
				foods.append(food_names[i])
		for si in range(mini(occ_bits.size(), habitat_class.size())):
			var bit := int(occ_bits[si])
			var habitat := int(habitat_class[si])
			if bit < 0 or bit >= 32 or (bits & (1 << bit)) == 0 \
					or habitat <= 0 or habitat >= class_names.size():
				continue
			var habitat_name := String(class_names[habitat])
			if not classes.has(habitat_name):
				classes.append(habitat_name)
	out_landmass.resize(summaries.size())
	out_classes.resize(summaries.size())
	out_foods.resize(summaries.size())
	var idx := 0
	for lid in summaries:
		var foods: Array = summaries[lid].foods
		var classes: Array = summaries[lid].classes
		out_landmass[idx] = int(lid)
		out_classes[idx] = ", ".join(classes) if not classes.is_empty() else "none"
		out_foods[idx] = ", ".join(foods) if not foods.is_empty() else "none"
		idx += 1




func run_bio_occupancy_pass_native(map_ref, run_diffusion: bool = false,
		day_index: int = 0, slice_enabled: bool = false,
		bio_slice_cells: int = 2048) -> Dictionary:
	if map_ref == null or _generator._data_core_world_ext == null :
		return {"ok": false, "path": "skip", "reason": "native_unavailable"}
	var knobs = _generator._bio_occupancy_daily_knobs(map_ref)
	if not bool(knobs.get("ok", false)):
		return knobs
	if not bool(knobs.get("use_configured_slots", false)):
		knobs["province_ids"] = map_ref.province_id_arr
		knobs["occupancy_bits"] = map_ref.bio_occupancy_bits_arr
	knobs["run_diffusion"] = run_diffusion
	knobs["day_index"] = day_index
	knobs["slice_enabled"] = slice_enabled
	if _generator._bio_observation_country_handle == 0 and _generator._country_facade != null:
		var start_cell := int(_generator.gameplay_start_report().get("cell", -1))
		if start_cell >= 0:
			_generator._bio_observation_country_handle = int(_generator._country_facade.cell_summary(
				start_cell).get("country_handle", 0))
	if _generator._bio_observation_country_handle != 0:
		knobs["observation_country_handle"] = _generator._bio_observation_country_handle
		knobs["observation_effective_day"] = day_index + 1
	# Keep phase boundaries (persistence/diffusion/merge/publish) preemptible
	# while using a fixed deterministic range per call. The round is frozen by
	# WorldClock until the final publish, so no partial occupancy is visible.
	if slice_enabled:
		knobs["bio_slice_cells"] = clampi(bio_slice_cells, 2048, 32768)
	# The first sliced call captures the full input snapshot.  Subsequent fixed
	# cursor calls reuse native staging and must not refresh/copy MapData again.
	var refresh_inputs = not slice_enabled or not _generator._bio_occupancy_slice_inflight
	if refresh_inputs:
		var refresh_keys := PackedStringArray([
			"cell_bio_occupancy_bits",
			"cell_temp_30d",
			"cell_moisture",
			"cell_vegetation",
		])
		for slot_name in _generator._bio_occupancy_knob_cache.get(
				"carrier_slot_names", PackedStringArray()):
			if not refresh_keys.has(slot_name):
				refresh_keys.append(slot_name)
		_generator._data_core_world_ext.refresh_slots_from_map_keys(refresh_keys)
	var sliced_call := slice_enabled and \
			true
	var res: Dictionary = _generator._data_core_world_ext.run_bio_occupancy_slice(knobs) \
			if sliced_call else _generator._data_core_world_ext.run_bio_occupancy_pass(knobs)
	res["bio_knob_cache_hit"] = bool(knobs.get("_knob_cache_hit", false))
	res["bio_knob_cache_build_ms"] = float(knobs.get("_knob_cache_build_ms", 0.0))
	if slice_enabled and not sliced_call:
		res["path"] = "gdext_one_shot_fallback"
		res["bio_slice_fallback_reason"] = "missing_run_bio_occupancy_slice"
		res["fallback_reason"] = "missing_run_bio_occupancy_slice"
		res["fail_stage"] = "bio_occupancy_daily"
		_generator._bio_occupancy_slice_inflight = false
	if not bool(res.get("ok", false)) and sliced_call:
		# A failed slice never publishes partial staging.  Retry the legacy pass
		# with the same knobs so feature-flag rollback remains lossless.
		var fallback_res: Dictionary = _generator._data_core_world_ext.run_bio_occupancy_pass(knobs)
		fallback_res["path"] = "gdext_one_shot_fallback"
		fallback_res["bio_slice_fallback_reason"] = str(res.get("reason", "slice_failed"))
		fallback_res["fallback_reason"] = str(res.get("reason", "slice_failed"))
		fallback_res["fail_stage"] = str(res.get("fail_stage", "bio_occupancy_slice"))
		res = fallback_res
		_generator._bio_occupancy_slice_inflight = false
	if bool(res.get("ok", false)):
		var slice_done := bool(res.get("done", true))
		_generator._bio_occupancy_slice_inflight = slice_enabled and not slice_done
		if not slice_done:
			return res
		var occupancy: PackedInt32Array = res.get("occupancy_bits", PackedInt32Array())
		if occupancy.size() == map_ref.cell_count():
			map_ref.bio_occupancy_bits_arr = occupancy
			_generator._publish_bio_occupancy_to_runtime(map_ref)
			res["published_to_slot"] = true
		_generator._bio_occupancy_slice_inflight = false
	return res

# Phase 14：永久性地标 — 一旦设定不被季节 / biome 重决策覆盖。
# terrain-overhaul：CHAPARRAL/MOOR/FLOODPLAIN/MESA 为特征 pass 专属地形（分类器无法
# 复现），须永久固定，否则季节重判会退回基础气候地形。与 C++ pk_is_permanent_landform 同源。
