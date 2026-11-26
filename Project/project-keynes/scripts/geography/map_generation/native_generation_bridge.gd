extends "res://scripts/simulation/generator_context.gd"
const GenerationSequence = preload("res://scripts/geography/map_generation/native_generation_sequence.gd")

## 生成请求、生成前检查与 PKMAP 读取；所有可变状态仍归 MapGenerator。
## 通过基类弱引用访问宿主，不保存请求、报告或装配器的副本。
const RuntimeDiagnostics = preload("res://scripts/game/runtime_economy_diagnostics.gd")
const NativeWorld = preload("res://scripts/data_core/native_world.gd")
const NativeLoadingTasks = preload("res://scripts/geography/native_loading_tasks.gd")
const PkmapIOScript = preload("res://scripts/geography/pkmap_io.gd")
const TerrainGeneratorScript = preload("res://scripts/geography/map_generation/terrain_gen.gd")


func ensure_world_ext() -> RefCounted:
	if _generator._data_core_world_ext != null:
		return _generator._data_core_world_ext
	if not ClassDB.class_exists("DCWorldExt"):
		return null
	var ext_obj: Object = NativeWorld.create()
	if ext_obj == null or not (ext_obj is RefCounted):
		return null
	_generator._data_core_world_ext = ext_obj
	_generator._data_core_world_ext.set_diag_logs_enabled(PKLog.enabled)
	return _generator._data_core_world_ext

func native_generation_cfg_dict(cfg: MapConfig) -> Dictionary:
	if cfg == null:
		return {}
	return {
		"width": int(cfg.width),
		"height": int(cfg.height),
		"num_continents": int(cfg.num_continents),
		"sea_level": float(cfg.sea_level),
		"continent_size": float(cfg.continent_size),
		"river_count": int(cfg.river_count),
		"seed": int(cfg.seed),
		"enable_ocean_heat_transport": bool(cfg.enable_ocean_heat_transport),
		# water-bodies systemic（post_base 统一距水场 + 气候回灌 + 生态强化）：
		#   默认值与 world_ext.cpp 内 getd/geti 默认对齐；保守、可一键回退（置 0/负即关闭对应项）。
		"water_dist_max": 8,                  # 距水场 BFS 半径截断（格）
		"water_big_river_flow_min": 0.55,     # 河岸湿度流量加成达到上限的生态流量标尺
		"lake_moist_floor": 0.55,             # 湖滨增湿带湿度地板（× exp 衰减）
		"lake_moist_scale": 2.5,              # 湖滨增湿衰减尺度（格）
		"river_riparian_floor": 0.36,         # 所有成形河流的一环湿度下限（大河最高约 +0.06）
		"river_riparian_gain": 0.12,          # 河谷 riparian 增湿增量（× exp 衰减）
		"river_riparian_scale": 2.0,          # 河谷增湿衰减尺度（格）
		"swamp_water_band": 2,                # 湿地沿湖/大河成带的距水格宽（0=仅 1 格邻接）
	}

func native_generation_profile_dict() -> Dictionary:
	var cp: ClimateProfile = _generator._c()
	if cp == null:
		return {"native_generation_mode": 0}
	# Generation and runtime vegetation use the same profile LUT.  The arrays
	# are scratch inputs to the native pass; they are not persisted as slots.
	_generator._ensure_vegdyn_lut()
	var keys := [
		"native_generation_mode",
		"continent_warp_amp",
		"dist_field_weight",
		"noise_weight",
		"ridge_boost_amp",
		"meso_weight",
		"macro_relief_weight",
		"offshore_amp",
		"edge_falloff_start",
		"edge_falloff_end",
		"edge_falloff_depth",
		# 复刻 GDScript 生成：湖泊种子 + 坑洼平滑 knob（native base pass 用）
		"lake_seed_freq",
		"lake_seed_threshold",
		"lake_seed_depth",
		"lake_seed_min_interior",
		"pit_fill_max_iters",
		"main_radius_min",
		"main_radius_max",
		"satellite_radius_min",
		"satellite_radius_max",
		"satellites_per_main",
		"main_placement_min",
		"main_placement_max",
		"satellite_placement_min",
		"satellite_placement_max",
		"main_separation_factor",
		"satellite_separation_factor",
		"coastal_moisture_boost",
		"orographic_boost",
		"rain_shadow_threshold",
		"rain_shadow_factor",
		"rain_shadow_lookback",
		"river_flow_percentile",
		"river_channel_init_cells",
		"river_headwater_init_cells",
		"river_headwater_min_land_h",
		"hydro_river_min_length",
		"hydro_lake_min_cells",
		"hydro_lake_min_depth",
		"hydro_lake_min_volume",
		"veg_forest_donor",
		"veg_swamp_donor",
		"veg_grassland_donor",
		"veg_desert_donor",
		"veg_jungle_donor",
		"veg_taiga_donor",
		"veg_savanna_donor",
		"veg_oasis_donor",
		"veg_delta_donor",
		"veg_salt_flat_donor",
		"veg_feedback_elev_decay",
		"max_volcanoes",
		"volcano_min_dist",
		"volcano_min_land_h",
		# terrain-overhaul Phase 0 板块构造
		"tectonic_blend",
		"tectonic_plate_count",
		"tectonic_continental_fraction",
		"tectonic_continental_base",
		"tectonic_oceanic_base",
		"tectonic_uplift_amp",
		"tectonic_ridge_width",
		"tectonic_drift_speed",
		"tectonic_lloyd_iters",
		# Stream-Power 河流侵蚀 (Cordonnier 2016)
		"spl_iters",
		"spl_erodibility",
		"spl_area_exp",
		"spl_uplift_rate",
		# terrain-ridge-uplift 2026-11-18：脊抬升 / 坡面扩散 / §5' 脊线残差
		"spl_ridge_uplift",
		"spl_hillslope_diffusion",
		"spl_ridge_prestamp_frac",
		"ridge_residual_frac",
		# terrain-overhaul Phase 3 统一气候场
		"moisture_wind_evap",
		"moisture_rainout_base",
		"moisture_orographic_gain",
		"moisture_continental_dry",
		"moisture_land_base",
		"moisture_precip_gain",
		"moisture_humidity_cap",
		"moisture_smooth",
		"moisture_noise_amp",
		"moisture_subtropical_dry_strength",
		"moisture_subtropical_dry_center",
		"moisture_subtropical_dry_width",
		# [zonal-envelope 2026-08-01] 行星尺度纬带降水包络
		"moisture_itcz_wet_strength",
		"moisture_itcz_center",
		"moisture_itcz_width",
		"moisture_stormtrack_wet_strength",
		"moisture_stormtrack_center",
		"moisture_stormtrack_width",
		"moisture_polar_dry_strength",
		"moisture_tropical_evap_boost",
		"moisture_itcz_recycle_strength",
		"moisture_itcz_convergence",
		"moisture_coastal_floor",
		"moisture_coastal_scale",
		"coastal_temp_moderation",
		"coastal_temp_scale",
		"plant_water_balance_weight",
		"plant_soil_buffer_weight",
		"plant_drought_penalty",
		"vegetation_min_suitability",
		"vegetation_tie_epsilon",
		"vegetation_none_hysteresis",
		# terrain-overhaul Phase 5 特征点缀
		"salt_flat_min_dist_ocean",
		"chaparral_max_dist_ocean",
		"plateau_min_land_h",
		"plateau_max_relief",
		"plateau_min_cells",
		"mountain_min_land_h",
		"mountain_min_relief",
		"relief_thresh_scale_exp",
		"peak_min_land_h",
		"peak_min_prominence",
		"peak_land_cells_per_peak",
		"rift_min_wall",
		"rift_min_axis",
		"rift_min_length_cells",
		"badlands_min_relief",
		"badlands_min_rugged_neighbors",
		"badlands_max_land_ratio",
		"badlands_max_arid_ratio",
		"badlands_max_patch_cells",
		"canyon_min_wall",
		"canyon_min_axis",
	]
	var out: Dictionary = {}
	for k in keys:
		if cp.get(k) != null:
			out[k] = cp.get(k)
	out["veg_ideal_temp"] = _generator._gdext_vegdyn_ideal_temp_cached
	out["veg_ideal_moist"] = _generator._gdext_vegdyn_ideal_moist_cached
	out["veg_temp_tol"] = _generator._gdext_vegdyn_temp_tol_cached
	out["veg_moist_tol"] = _generator._gdext_vegdyn_moist_tol_cached
	return out

func generation_preflight() -> Dictionary:
	var issues: Array = []
	var env: Dictionary = _generator._mapgen_env()
	var cp: ClimateProfile = _generator._c()
	var native_mode := -1
	if cp != null and cp.get("native_generation_mode") != null:
		native_mode = int(cp.get("native_generation_mode"))
	var ext_loaded := ClassDB.class_exists("DCWorldExt")
	var ext: RefCounted = null
	var missing: PackedStringArray = PackedStringArray()
	if not ext_loaded:
		issues.append({
			"code": "extension_not_loaded",
			"message": "GDExtension 未加载：ClassDB 里找不到 DCWorldExt。地图生成 100% 在 C++ 且无 GDScript 回退，"
				+ "原生库缺失 / 版本过旧 / ABI 不匹配都会导致创建地图直接失败。"
				+ ("安卓：请重建 gdext Android arm64（gdext\\build_android.bat）后重新导出 APK。" if env["platform"] == "android" else "")
		})
	else:
		ext = ensure_world_ext()
		if ext == null:
			issues.append({
				"code": "world_ext_uninstantiable",
				"message": "DCWorldExt 已注册但无法实例化（NativeWorld.create 返回空或类型不符）。",
			})
	if native_mode != 2:
		issues.append({
			"code": "native_generation_mode_inactive",
			"message": "ClimateProfile.native_generation_mode=%d，不是 ACTIVE(2)；地图生成只保留 C++ 单路径。" % native_mode,
		})
	var bound := false
	if ext != null:
		bound = bool(ext.is_bound())
	return {
		"ok": issues.is_empty(),
		"issues": issues,
		"extension_loaded": ext_loaded,
		"world_ext_available": ext != null,
		"world_ext_bound": bound,
		"native_mode": native_mode,
		"native_mode_active": native_mode == 2,
		"required_methods": _generator.MAPGEN_REQUIRED_NATIVE_METHODS.duplicate(),
		"missing_methods": missing,
		"env": env,
	}

func native_smoke(w: int = 16, h: int = 12) -> Dictionary:
	var ext := ensure_world_ext()
	if ext == null:
		return {"ok": false, "reason": "world_ext_or_method_unavailable"}
	var cfg := MapConfig.make(w, h)
	cfg.seed = 12345
	var cfg_dict := native_generation_cfg_dict(cfg)
	var profile_dict := native_generation_profile_dict()
	var t0 := Time.get_ticks_usec()
	var res: Dictionary = ext.run_native_world_generate_base_pass(cfg.seed, cfg_dict, profile_dict)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var n := int(res.get("n_cells", 0))
	var ok := int(res.get("rc", -1)) == 0 and not bool(res.get("fallback", true)) and n == w * h
	var out := {
		"ok": ok,
		"grid": "%dx%d" % [w, h],
		"elapsed_ms": ms,
		"n_cells": n,
		"expected_cells": w * h,
		"rc": int(res.get("rc", -1)),
		"fallback": bool(res.get("fallback", true)),
		"reason": String(res.get("fallback_reason", res.get("reason", ""))),
		"native_algorithm": String(res.get("native_algorithm", "")),
	}
	if not ok:
		out["report"] = _generator._mapgen_sanitize_report(res)
	return out

func generate_cells_from_pkmap(cfg: MapConfig, seed: int) -> MapData:
	var path := String(cfg.pkmap_path).strip_edges()
	if path.is_empty():
		push_error("[native_generation/pkmap] pkmap_path 为空；中止，不回退程序生成")
		_generator._native_generation_base_report = {
			"rc": -1,
			"path": "pkmap",
			"fallback": false,
			"fallback_reason": "pkmap_path_empty",
		}
		return null
	var loaded: Dictionary = PkmapIOScript.read_pkmap(path)
	if not bool(loaded.get("ok", false)):
		push_error("[native_generation/pkmap] 读包失败 code=%s message=%s；中止，不回退程序生成" % [
			String(loaded.get("code", "unknown")),
			String(loaded.get("message", "")),
		])
		_generator._native_generation_base_report = {
			"rc": -1,
			"path": "pkmap",
			"fallback": false,
			"fallback_reason": String(loaded.get("code", "pkmap_read_failed")),
		}
		return null
	var header: Dictionary = loaded.get("header", {})
	var width := int(loaded.get("width", 0))
	var height := int(loaded.get("height", 0))
	var n := int(loaded.get("n_cells", width * height))
	if n != width * height or n != int(cfg.width) * int(cfg.height):
		push_error("[native_generation/pkmap] 尺寸不匹配 n=%d header=%dx%d cfg=%dx%d；中止" % [
			n, width, height, int(cfg.width), int(cfg.height),
		])
		_generator._native_generation_base_report = {
			"rc": -1,
			"path": "pkmap",
			"fallback": false,
			"fallback_reason": "size_mismatch",
		}
		return null
	var payload: Dictionary = loaded.get("payload", {})
	var final_res: Dictionary = PkmapIOScript.native_result_from_payload(payload, header)
	if _generator._terrain_generator == null:
		_generator._terrain_generator = TerrainGeneratorScript.new(_generator)
	var frame_gate = _generator._loading_frames
	var map: MapData = await _generator._terrain_generator.assemble_native_result(final_res, cfg)
	if frame_gate.canceled:
		return null
	if map == null:
		push_error("[native_generation/pkmap] assemble_native_result 失败；中止，不回退程序生成")
		_generator._native_generation_base_report = {
			"rc": -1,
			"path": "pkmap",
			"fallback": false,
			"fallback_reason": "assemble_failed",
		}
		return null
	var ext := ensure_world_ext()
	if ext == null:
		push_error("[native_generation/pkmap] 缺 restuff_generation_river_cache（DLL 未 rebuild?）；中止")
		_generator._native_generation_base_report = {
			"rc": -1,
			"path": "pkmap",
			"fallback": false,
			"fallback_reason": "missing_restuff_generation_river_cache",
		}
		return null
	var restuff_in := final_res.duplicate(true)
	restuff_in["width"] = width
	restuff_in["height"] = height
	restuff_in["n_cells"] = n
	var restuff: Dictionary = ext.restuff_generation_river_cache(restuff_in)
	if int(restuff.get("rc", -1)) != 0 or not bool(restuff.get("ok", false)):
		push_error("[native_generation/pkmap] restuff 失败 reason=%s；中止" % String(restuff.get("reason", "")))
		_generator._native_generation_base_report = {
			"rc": -1,
			"path": "pkmap",
			"fallback": false,
			"fallback_reason": String(restuff.get("reason", "restuff_failed")),
		}
		return null
	_generator._native_generation_base_report = {
		"rc": 0,
		"path": "pkmap",
		"fallback": false,
		"n_cells": n,
		"pkmap_path": path,
		"seed": seed,
	}
	print("[native_generation/pkmap] path=pkmap n=%d file=%s restuff=ok" % [n, path])
	return map

func generate_cells_native_base(cfg: MapConfig, seed: int) -> MapData:
	if OS.get_environment("PK_FORCE_MAPGEN_FAIL") == "1":
		# 测试钩子（问题 3/3 验证用）：强制原生返回 null，走与真实失败完全相同的
		# 诊断链路（_native_generation_base_report → _fail_generation → UI/日志）。
		# 只在显式设置环境变量时生效，正常玩家环境恒为空字符串。
		_generator._native_generation_base_report = {
			"rc": -7,
			"path": "forced",
			"fallback": true,
			"fallback_reason": "forced_by_env_PK_FORCE_MAPGEN_FAIL",
			"stage": "native_base",
			"detail": "PK_FORCE_MAPGEN_FAIL=1 injected a synthetic native failure",
			"seed": seed,
			"grid": "%dx%d" % [int(cfg.width), int(cfg.height)] if cfg != null else "?",
		}
		push_warning("[native_generation] PK_FORCE_MAPGEN_FAIL=1 → 注入合成原生失败（测试钩子）")
		return null
	if cfg != null and String(cfg.map_source) == "pkmap":
		return await generate_cells_from_pkmap(cfg, seed)
	var cp: ClimateProfile = _generator._c()
	if not _generator._native_mode_is_active(cp, "native_generation_mode"):
		_generator._native_generation_base_report = {
			"rc": -1,
			"path": "gdscript",
			"fallback_reason": "native_generation_mode_not_active",
		}
		return null
	var ext := ensure_world_ext()
	if ext == null:
		_generator._native_generation_base_report = {
			"rc": -1,
			"path": "gdscript",
			"fallback_reason": "missing_run_native_world_generate_base_pass",
		}
		return null

	var cfg_dict := native_generation_cfg_dict(cfg)
	var profile_dict := native_generation_profile_dict()
	var expected_n: int = int(cfg.width) * int(cfg.height)

	# dots-total-cpp step4（2026-06-25）：base + post_base 融合单次调用——base 的 10×n_cells
	# SoA bundle 留在 C++ 内直接喂 post_base，消除原先 base 结果 C++→GDScript 校验→再回
	# post_base 的 round-trip。full_pass 缺失（DLL 未 rebuild）时回退旧两次调用路径。
	var res: Dictionary
	var final_res: Dictionary
	var n: int
	final_res = await NativeLoadingTasks.compute(ext,"generate", {"seed":seed,"cfg":cfg_dict,"profile":profile_dict}, _generator._loading_frames)
	if bool(final_res.get("canceled", false)):
		return null
	_generator._native_generation_base_report = final_res.duplicate(true)
	if int(final_res.get("rc", -1)) != 0 or bool(final_res.get("fallback", true)):
		var reason_f := String(final_res.get("fallback_reason", final_res.get("reason", "unknown")))
		var stage_f := "post_base" if bool(final_res.get("fused_base_post", false)) else "base"
		push_warning("[native_generation/full] %s 失败 (%s)；GDScript 生成已移除，中止生成" % [stage_f, reason_f])
		return null
	n = int(final_res.get("n_cells", 0))
	if n <= 0 or n != expected_n:
		push_warning("[native_generation/full] bad n_cells=%d expected=%d; 中止" % [n, expected_n])
		return null
	# 合成 base 诊断 dict，供下方 base-path 打印零改动复用（值来自 full_pass 合并键）。
	res = {
		"native_algorithm": final_res.get("native_algorithm", "unknown"),
		"native_ms": final_res.get("base_native_ms", final_res.get("native_ms", 0.0)),
		"water_count": final_res.get("base_water_count", 0),
		"land_count": final_res.get("base_land_count", 0),
		"n_cells": n,
	}
	if _generator._terrain_generator == null:
		_generator._terrain_generator = TerrainGeneratorScript.new(_generator)
	var frame_gate = _generator._loading_frames
	var map: MapData = await _generator._terrain_generator.assemble_native_result(final_res, cfg)
	if frame_gate.canceled:
		return null
	if map == null:
		push_warning("[native_generation] final result invalid（装配失败）；中止生成")
		return null
	print("[native_generation/base] path=gdext algorithm=%s n=%d native_ms=%.3f water=%d land=%d"
		% [
			String(res.get("native_algorithm", "unknown")),
			n,
			float(res.get("native_ms", res.get("elapsed_ms", 0.0))),
			int(res.get("water_count", 0)),
			int(res.get("land_count", 0)),
		])
	print("[native_generation/post_base] path=gdext algorithm=%s n=%d native_ms=%.3f lakes=%d rivers=%d volcanoes=%d"
		% [
			String(final_res.get("native_algorithm", "unknown")),
			int(final_res.get("n_cells", 0)),
			float(final_res.get("native_ms", final_res.get("elapsed_ms", 0.0))),
			int(final_res.get("lake_count", 0)),
			int(final_res.get("river_count", 0)),
			int(final_res.get("volcano_count", 0)),
		])
	print("[native_generation/vegetation] native_ms=%.3f candidates=%d none=%d score=[%.3f,%.3f,%.3f] plant_water_land=%d river_adjacent_desert=%d coastal_highland_desert=%d terrain_weight=[%.3f,%.3f]"
		% [
			float(final_res.get("vegetation_native_ms", 0.0)),
			int(final_res.get("vegetation_candidate_count", 0)),
			int(final_res.get("vegetation_none_count", 0)),
			float(final_res.get("vegetation_score_min", 0.0)),
			float(final_res.get("vegetation_score_mean", 0.0)),
			float(final_res.get("vegetation_score_max", 0.0)),
			int(final_res.get("plant_water_nonzero_land_count", 0)),
			int(final_res.get("river_adjacent_desert_count", 0)),
			int(final_res.get("coastal_highland_desert_count", 0)),
			float(final_res.get("terrain_soft_weight_min", 0.0)),
			float(final_res.get("terrain_soft_weight_max", 0.0)),
		])
	# 生成 QA 度量（地形改造回归基线）：单格水体应 →0，biome 熵/河流占比应随改造上升。
	var qa: Dictionary = final_res.get("qa_metrics", {})
	if not qa.is_empty():
		print("[native_generation/qa] single_water=%d tiny<=3=%d small<=5=%d bodies=%d largest=%d | land_below_sea=%.1f%% | terr_distinct=%d entropy=%.3fbit | river_ratio=%.3f%%"
			% [
				int(qa.get("single_tile_water", 0)),
				int(qa.get("tiny_water_le3", 0)),
				int(qa.get("small_water_le5", 0)),
				int(qa.get("water_bodies", 0)),
				int(qa.get("largest_water_body", 0)),
				100.0 * float(qa.get("land_below_sealevel_ratio", 0.0)),
				int(qa.get("terrain_distinct", 0)),
				float(qa.get("terrain_entropy_bits", 0.0)),
				100.0 * float(qa.get("river_ratio", 0.0)),
			])
	return map

func _c() -> ClimateProfile:
	if _generator.climate_profile == null:
		var loaded := ResourceLoader.load("res://data/world/earth_like.tres", "Resource") as ClimateProfile
		if loaded == null:
			push_warning("MapGenerator: earth_like.tres missing; using in-memory defaults")
			loaded = ClimateProfile.new()
		_generator.climate_profile = loaded
	# Web：关掉分帧/线程化的 async climate round。
	# 浏览器里它要 spawn 一条 pthread，池子打满后 pthread_create 直接失败，
	# 于是"等一轮算完"退化成等超时——实测加载期 refresh_climate_loading 因此
	# 卡了 63 秒。同步 round 在 2400 cell 上是毫秒级，web 上更划算。
	if OS.has_feature("web") and _generator.climate_profile != null:
		if "use_climate_round_async" in _generator.climate_profile and bool(_generator.climate_profile.use_climate_round_async):
			_generator.climate_profile.use_climate_round_async = false
			print("[climate] web build: async climate round disabled (pthread pool exhaustion -> 63s load stall)")
	return _generator.climate_profile



func _calendar_days_per_year() -> int:
	if _generator._world_clock_ref != null and _generator._world_clock_ref.has_method("days_per_year"):
		return clampi(int(_generator._world_clock_ref.days_per_year()), 1, 3660)
	var cp = _generator._c()
	if cp != null and cp.get("orbital_days_per_year") != null:
		return clampi(int(cp.get("orbital_days_per_year")), 1, 3660)
	return 365


func _sync_data_core_runtime_terrain_mirror(map: MapData, reason: String) -> Dictionary:
	var diag: Dictionary = {
		"terrain_mismatch": 0,
		"is_water_mismatch": 0,
		"terrain_written": false,
		"is_water_written": false,
		"skipped": false,
	}
	if not _generator._dc_terrain_mirror_dirty:
		diag["skipped"] = true
		return diag
	if map == null or _generator._data_core_world == null or not _generator._data_core_world.is_bound():
		return diag
	if not _generator._data_core_world.has_method("view_u8") or not _generator._data_core_world.has_method("write_u8_dense"):
		return diag
	var n: int = mini(map.cell_count(), map.terrain_arr.size())
	if n <= 0:
		return diag

	var terrain_mismatch: int = 0
	var cid_terrain: int = _generator._data_core_world.component_id(DCComponentIds.CELL_TERRAIN)
	if cid_terrain >= 0:
		var dc_terrain: PackedByteArray = _generator._data_core_world.view_u8(cid_terrain)
		for i in range(mini(n, dc_terrain.size())):
			if int(dc_terrain[i]) != int(map.terrain_arr[i]):
				terrain_mismatch += 1
		if terrain_mismatch > 0:
			_generator._data_core_world.write_u8_dense(cid_terrain, map.terrain_arr)
			diag["terrain_written"] = true

	var is_water_mismatch: int = 0
	var water_n: int = mini(map.cell_count(), map.is_water_arr.size())
	var cid_is_water: int = _generator._data_core_world.component_id(DCComponentIds.CELL_IS_WATER)
	if cid_is_water >= 0 and water_n > 0:
		var dc_is_water: PackedByteArray = _generator._data_core_world.view_u8(cid_is_water)
		for i in range(mini(water_n, dc_is_water.size())):
			if int(dc_is_water[i]) != int(map.is_water_arr[i]):
				is_water_mismatch += 1
		if is_water_mismatch > 0:
			_generator._data_core_world.write_u8_dense(cid_is_water, map.is_water_arr)
			diag["is_water_written"] = true

	diag["terrain_mismatch"] = terrain_mismatch
	diag["is_water_mismatch"] = is_water_mismatch
	_generator._dc_terrain_mirror_dirty = false
	if (terrain_mismatch > 0 or is_water_mismatch > 0) \
			and _generator._dc_terrain_mirror_sync_log_count < _generator._DC_TERRAIN_MIRROR_SYNC_INITIAL_LOGS:
		_generator._dc_terrain_mirror_sync_log_count += 1
		print("[dc/terrain_mirror_sync] reason=%s terrain_mis=%d isw_mis=%d terrain_written=%s isw_written=%s" % [
			reason, terrain_mismatch, is_water_mismatch,
			str(bool(diag["terrain_written"])), str(bool(diag["is_water_written"])),
		])
	return diag



func _climate_views_from_world(cp: ClimateProfile) -> Dictionary:
	if cp == null:
		return {}
	if _generator._data_core_world == null or not _generator._data_core_world.is_bound():
		return {}
	if _generator._refresh_climate_daily_job == null or not _generator._refresh_climate_daily_job.data_core_ready():
		return {}
	# ── Path-C kill-switch（Phase 3a Step 2.0 hotfix · 2026-05-12）─────────
	# 当 DCWorldExt（C++ co-processor）已 bind 但其 run_climate_pass_a 仍处于
	# stub/fallback 阶段时，DCWorldExt::bind_map_data 内部对 map.<f32> 字段做的
	# `set()` 推回会把 PackedFloat32Array 的 refcount 顶到 ≥3，导致 GDScript
	# climate Pass 内 `arr[i] = v` 触发 CoW 写到一份临时 storage 上，函数退出
	# 即销毁，map.temp_arr 永远是初值（→ 渲染层"温度全蓝"）。详见
	# docs/architecture/current-state.md 第三行的 "GDScript 端整体赋值后必须
	# bind_map_data" 反向对偶。
	#
	# 折中策略（路 C）：DCWorldExt 已 bind 时，climate Pass 暂时回退到 legacy
	# 直读直写 map.<arr> 路径——绕开 view，避免 refcount 抬升 + CoW 自杀。
	# C++ Pass-A 真正接管（run_climate_pass_a 返回 ≥0）后，整套 GDScript Pass
	# 不再读写 cell-level 数组，此 kill-switch 自动失效（届时该函数返回的 view
	# dict 也不会再被使用）。
	if _generator._data_core_world_ext != null:
		return {}
	var w = _generator._data_core_world
	var j = _generator._refresh_climate_daily_job
	# 25 个 cell-level view（key 命名 = SoA 字段后缀，方便读 sub-pass 时一一对照）
	return {
		"temp": w.view_f32(w.component_id(DCComponentIds.CELL_TEMP)),
		"temp_baseline": w.view_f32(w.component_id(DCComponentIds.CELL_TEMP_BASELINE)),
		"temp_30d": w.view_f32(w.component_id(DCComponentIds.CELL_TEMP_30D)),
		"temp_365d": w.view_f32(w.component_id(DCComponentIds.CELL_TEMP_365D)),
		"temp_anomaly": w.view_f32(w.component_id(DCComponentIds.CELL_TEMP_ANOMALY)),
		"moisture": w.view_f32(w.component_id(DCComponentIds.CELL_MOISTURE)),
		"sea_ice_frac": w.view_f32(w.component_id(DCComponentIds.CELL_SEA_ICE_FRAC)),
		"elevation": w.view_f32(w.component_id(DCComponentIds.CELL_ELEVATION)),
		"base_moisture": w.view_f32(w.component_id(DCComponentIds.CELL_BASE_MOISTURE)),
		"ocean_current_x": w.view_f32(w.component_id(DCComponentIds.CELL_OCEAN_CURRENT_X)),
		"ocean_current_y": w.view_f32(w.component_id(DCComponentIds.CELL_OCEAN_CURRENT_Y)),
		"wind_x": w.view_f32(w.component_id(DCComponentIds.CELL_WIND_X)),
		"wind_y": w.view_f32(w.component_id(DCComponentIds.CELL_WIND_Y)),
		"pos_x": w.view_f32(w.component_id(DCComponentIds.CELL_POS_X)),
		"pos_y": w.view_f32(w.component_id(DCComponentIds.CELL_POS_Y)),
		"lat_norm": w.view_f32(w.component_id(DCComponentIds.CELL_LAT_NORM)),
		"temp_baseline_year": w.view_f32(w.component_id(DCComponentIds.CELL_TEMP_BASELINE_YEAR)),
		"terrain": w.view_u8(w.component_id(DCComponentIds.CELL_TERRAIN)),
		"landform": w.view_u8(w.component_id(DCComponentIds.CELL_LANDFORM)),
		"vegetation": w.view_u8(w.component_id(DCComponentIds.CELL_VEGETATION)),
		"cover": w.view_u8(w.component_id(DCComponentIds.CELL_COVER)),
		"is_water": w.view_u8(w.component_id(DCComponentIds.CELL_IS_WATER)),
		"climate_dirty_mask": w.view_u8(w.component_id(DCComponentIds.CELL_CLIMATE_DIRTY)),
		"weather_dirty_mask": w.view_u8(w.component_id(DCComponentIds.CELL_WEATHER_DIRTY)),
		# Phase 3a Step 2.1.a：climate Pass-A SoA 化新增 2 个 view
		"ema_initialized": w.view_u8(w.component_id(DCComponentIds.CELL_EMA_INITIALIZED)),
		"temp_season_offset": w.view_f32(w.component_id(DCComponentIds.CELL_TEMP_SEASON_OFFSET)),
		"insolation_now": w.view_f32(w.component_id(DCComponentIds.CELL_INSOLATION_NOW)),
		"insolation_dev": w.view_f32(w.component_id(DCComponentIds.CELL_INSOLATION_DEV)),
		"day_length": w.view_f32(w.component_id(DCComponentIds.CELL_DAY_LENGTH)),
		"heat_input": w.view_f32(w.component_id(DCComponentIds.CELL_HEAT_INPUT)),
		"thermal_energy": w.view_f32(w.component_id(DCComponentIds.CELL_THERMAL_ENERGY)),
		"snowpack": w.view_f32(w.component_id(DCComponentIds.CELL_SNOWPACK)),
		"water_balance_30d": w.view_f32(w.component_id(DCComponentIds.CELL_WATER_BALANCE_30D)),
	}


# 活跃天气前沿的显示快照。
# 正常日 refresh_daily 结束时写入；跳日分支直接返回此快照，保持 renderer 显示
# 不抖动，同时完全跳过 transpiration / albedo / vegetation / weather→map 反馈
# 以及 baker 的增量重烘。

func _validate_gdext_method_signature(method_name: String, expected_arg_count: int) -> bool:
	if _generator._data_core_world_ext == null:
		print("[gdext sig] %s: ext is null → false" % method_name)
		return false
	var ml: Array = _generator._data_core_world_ext.get_method_list()
	# 在所有 method 里找匹配名字的（不止 1 个：godot-cpp 可能把 setter / getter 同名注册）。
	var matches: Array = []
	for m: Dictionary in ml:
		if String(m.get("name", "")) == method_name:
			matches.append(m)
	if matches.is_empty():
		print("[gdext sig] %s: NOT FOUND in get_method_list() (total entries=%d) → false" % [method_name, ml.size()])
		push_warning("[gdext sig] %s not found in DCWorldExt; gdext .dll is STALE or method removed." % method_name)
		return false
	# 全部 match 都 dump 一次，无脑诊断
	for i in range(matches.size()):
		var m: Dictionary = matches[i]
		var args: Array = m.get("args", [])
		var arg_names: PackedStringArray = PackedStringArray()
		for a in args:
			arg_names.append(String(a.get("name", "<noname>")))
		print("[gdext sig] %s match[%d]: args.size()=%d names=[%s] flags=%d id=%d" % [
			method_name, i, args.size(), ", ".join(arg_names),
			int(m.get("flags", 0)), int(m.get("id", -1)),
		])
	# 只要任意一个 match 的 args.size() == expected → 通过
	for m: Dictionary in matches:
		var args: Array = m.get("args", [])
		if args.size() == expected_arg_count:
			print("[gdext sig] %s: probe PASS (found match with %d args)" % [method_name, expected_arg_count])
			return true
	push_warning("[gdext sig] %s: NONE of %d matches has expected_arg_count=%d. gdext .dll likely STALE; REBUILD: 'cd gdext && scons platform=windows target=template_release dev_build=no -j8'." % [method_name, matches.size(), expected_arg_count])
	return false

func _capture_trace(message: String) -> void:
	if _generator._capture_trace_left <= 0:
		return
	_generator._capture_trace_left -= 1
	print("[capture] " + message)
## Runtime-graph 路径不走 CountryDailySystem，必须自己把 country commit
## 转成 country_committed，否则国界/视野不会跟着 CLAIM 刷新。
## -1 = 尚未对齐过 watermark（首次只采纳，不重放 bootstrap）。

func _ensure_row_tables(cfg: MapConfig, season: int) -> void:
	if cfg == null:
		return
	var H: int = cfg.height
	if _generator._row_tables_season == season and _generator._row_tables_height == H \
			and _generator._row_lat_temp.size() == H:
		return
	_generator._row_lat_temp.resize(H)
	_generator._row_season_off.resize(H)
	var inv: float = 1.0 / float(maxi(H - 1, 1))
	for r in range(H):
		var ny: float = float(r) * inv
		var lat_signed: float = (ny - 0.5) * 2.0
		_generator._row_lat_temp[r] = _generator.DCClimateMath.lat_temp_bell(lat_signed)
		_generator._row_season_off[r] = _generator._season_temp_offset(ny, season)
	_generator._row_tables_season = season
	_generator._row_tables_height = H

# ─── 公开接口 ────────────────────────────────────────────────────────────


func _ensure_daily_pass_modules() -> void:
	if _generator._climate_pass_a_module == null:
		_generator._climate_pass_a_module = DCClimatePassA.new(_generator)
	if _generator._climate_pass_b_module == null:
		_generator._climate_pass_b_module = DCClimatePassB.new(_generator)
	if _generator._ocean_water_pass_module == null:
		_generator._ocean_water_pass_module = DCOceanWaterPass.new(_generator)
	if _generator._ocean_land_pass_module == null:
		_generator._ocean_land_pass_module = DCOceanLandPass.new(_generator)
	if _generator._sea_ice_daily_pass_module == null:
		_generator._sea_ice_daily_pass_module = DCSeaIceDailyPass.new(_generator)
	if _generator._transpiration_pass_module == null:
		_generator._transpiration_pass_module = DCTranspirationPass.new(_generator)



func generate(cfg: MapConfig, hex_size: float) -> Dictionary:
	return await GenerationSequence.generate(self, cfg, hex_size)

# ─── SUS 接入点（任务 4） ────────────────────────────────────────────────


func _runtime_build_topology(context: String) -> bool:
	if _generator._sus == null:
		push_error("[map_generator] DCSystemScheduler unavailable while building topology (%s)" % context)
		return false
	var ok: bool = bool(_generator._sus.build_topology())
	if not ok:
		push_error("[map_generator] DCSystemScheduler.build_topology() failed (%s)" % context)
	return ok



func get_economy_perf_report() -> Dictionary:
	return RuntimeDiagnostics.get_economy_perf_report(_generator)


func get_economy_probe_report() -> Dictionary:
	return RuntimeDiagnostics.get_economy_probe_report(_generator)


func get_runtime_perf_snapshot(detail_level: int = 0) -> Dictionary:
	return RuntimeDiagnostics.get_runtime_perf_snapshot(_generator, detail_level)
