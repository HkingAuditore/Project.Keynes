extends "res://scripts/simulation/generator_context.gd"
class_name DCTerrainGenerator
const TerrainBioPublication = preload("res://scripts/geography/map_generation/terrain_bio_publication.gd")
const TerrainClassification = preload("res://scripts/geography/map_generation/terrain_classification.gd")
const BioSummary = preload("res://scripts/geography/map_generation/bio_occupancy_summary.gd")
const BioOccupancyGuaranteeScript = preload("res://scripts/geography/map_generation/bio_occupancy_guarantee.gd")

func _init(generator) -> void:
	_generator = generator

## Assembles native and bundled maps without taking ownership of generation.
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
	var frame_gate = _generator._loading_frames if _generator != null else null
	if frame_gate != null and frame_gate.canceled:
		return null
	var map := MapData.new(cfg.width, cfg.height)
	var slice_start := Time.get_ticks_usec()
	var tree := Engine.get_main_loop() as SceneTree
	for i in range(n):
		if tree != null and Time.get_ticks_usec()-slice_start >= UITokens.LOADING_MAIN_SLICE_USEC:
			await (frame_gate.next_frame() if frame_gate != null else tree.process_frame)
			if frame_gate != null and frame_gate.canceled:
				return null
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
	if native_generation_array_ok(res, "neighbor_indices", n * 6, TYPE_PACKED_INT32_ARRAY) and map.cell_count() == n:
		await map.build_indices_cooperative(frame_gate, res["neighbor_indices"])
		if frame_gate != null and frame_gate.canceled:
			return null
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
	return TerrainClassification._alt_penalty_height(self, height_norm)


func _alt_penalty(elevation: float, sea_level: float = -1.0) -> float:
	return TerrainClassification._alt_penalty(self, elevation, sea_level)

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
	return TerrainClassification._derived_snow_cover(self, temp_now, land_h, terrain, cover)


func _bootstrap_sea_ice_fraction(map: MapData, cfg: MapConfig) -> void:
	TerrainClassification._bootstrap_sea_ice_fraction(self, map, cfg)


# ─── 地形决策（v8 阈值定调） ────────────────────────────────────────────
#
# 决策树先按 elevation 分类（OCEAN/COAST/MOUNTAIN/SNOW/TUNDRA），剩下陆地按
# (temperature, moisture) 在 Whittaker 风格的二维空间里选择 biome；HILL 属于 landform 轴。
#
# v8 的 ridge boost + slope_gate 让中海拔 cell 也能升级 MOUNTAIN，所以
# 生成期 permanent_only=true 时 MOUNTAIN 阈值更保守，丘陵/低地/平原则由 landform 派生。


func _decide_terrain(elevation: float, temperature: float, moisture: float, cfg: MapConfig, permanent_only: bool = false) -> TerrainType.TERRAIN:
	return TerrainClassification._decide_terrain(self, elevation, temperature, moisture, cfg, permanent_only)

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
	return TerrainClassification._derive_landform(self, cell, cfg)

# 给定 (terrain, landform, temperature, moisture)，输出真正的植被身份。
# 关键：当 terrain == HILL / MOUNTAIN 时，不再"植被=丘陵"，而是按 (temp, moist)
# 在 Whittaker 风格的二维空间里选择具体植被（含 ALPINE_* 高山特殊分类）。

func _derive_vegetation(cell: HexCell, landform: int, temperature: float) -> int:
	return TerrainClassification._derive_vegetation(self, cell, landform, temperature)

# Whittaker 风格的(temperature, moisture)→vegetation 决策
# 用于 _derive_vegetation 内部"无明确植被身份的 terrain"（HILL/PLAIN/MOUNTAIN）

func _whittaker_vegetation(temperature: float, moisture: float, landform: int) -> int:
	return TerrainClassification._whittaker_vegetation(self, temperature, moisture, landform)

# 覆盖物（cover）派生：永久冰 → GLACIER / 海冰 → SEA_ICE / 季节雪盖 → SNOW
# 苔原下层默认 PERMAFROST（永久冻土）

func _derive_cover(cell: HexCell, snow_cover: float) -> int:
	return TerrainClassification._derive_cover(self, cell, snow_cover)

# 单 cell 同步三轴。生成期间用 snow_cover=0（默认夏季）；refresh_seasonal 内传当季 snow_cover。

func _sync_axes_for_cell(cell: HexCell, cfg: MapConfig, snow_cover: float, temperature_override: float = -1.0) -> void:
	TerrainClassification._sync_axes_for_cell(self, cell, cfg, snow_cover, temperature_override)

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
	return TerrainBioPublication._bio_occupancy_base_knobs(self, map_ref)



func _bio_occupancy_daily_knobs(map_ref: MapData) -> Dictionary:
	return TerrainBioPublication._bio_occupancy_daily_knobs(self, map_ref)



func _bio_reserve_column(map_ref: MapData, resource_id: String, n: int,
		empty: PackedFloat32Array) -> PackedFloat32Array:
	return TerrainBioPublication._bio_reserve_column(self, map_ref, resource_id, n, empty)



func _publish_bio_occupancy_to_runtime(map_ref: MapData) -> void:
	TerrainBioPublication._publish_bio_occupancy_to_runtime(self, map_ref)


func _seed_bio_occupancy(map_ref: MapData) -> void:
	TerrainBioPublication._seed_bio_occupancy(self, map_ref)


## 生态播种诊断的「表头 + 每物种」段；两条路径（整段 native / 逐段 GDScript）
## 共用同一份打印，保证日志逐字相同。

func _log_bio_occupancy_seed_summary(knobs: Dictionary, seed_res: Dictionary,
		landmass_count: int, province_count: int) -> void:
	TerrainBioPublication._log_bio_occupancy_seed_summary(self, knobs, seed_res, landmass_count, province_count)



func _log_bio_occupancy_seed(knobs: Dictionary, seed_res: Dictionary, landmass_count: int,
		province_count: int) -> void:
	TerrainBioPublication._log_bio_occupancy_seed(self, knobs, seed_res, landmass_count, province_count)


## 融合 pass 返回的 landmass 摘要直接打印（聚合在 C++ 里做完）。

func _log_bio_occupancy_seed_native(report: Dictionary, knobs: Dictionary) -> void:
	TerrainBioPublication._log_bio_occupancy_seed_native(self, report, knobs)


## `_log_bio_occupancy_seed()` 的 landmass 聚合段（旧链路 / A/B 探针参考实现）。
## 融合 pass 在 C++ 里跑同一段逻辑（world_ext_boot_facade.cpp
## boot_bio_landmass_summary），顺序与去重规则逐行对齐。

func _bio_landmass_summary_gdscript(occupancy: PackedInt32Array,
		landmass: PackedInt32Array, knobs: Dictionary,
		out_landmass: PackedInt32Array, out_classes: PackedStringArray,
		out_foods: PackedStringArray) -> void:
	TerrainBioPublication._bio_landmass_summary_gdscript(self, occupancy, landmass, knobs, out_landmass, out_classes, out_foods)


func run_bio_occupancy_pass_native(map_ref, run_diffusion: bool = false,
		day_index: int = 0, slice_enabled: bool = false,
		bio_slice_cells: int = 2048) -> Dictionary:
	return TerrainBioPublication.run_bio_occupancy_pass_native(self, map_ref, run_diffusion, day_index, slice_enabled, bio_slice_cells)

# Phase 14：永久性地标 — 一旦设定不被季节 / biome 重决策覆盖。
# terrain-overhaul：CHAPARRAL/MOOR/FLOODPLAIN/MESA 为特征 pass 专属地形（分类器无法
# 复现），须永久固定，否则季节重判会退回基础气候地形。与 C++ pk_is_permanent_landform 同源。
