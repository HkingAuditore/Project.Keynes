extends "res://scripts/simulation/generator_context.gd"

## 生成请求、生成前检查与 PKMAP 读取；所有可变状态仍归 MapGenerator。
## 通过基类弱引用访问宿主，不保存请求、报告或装配器的副本。
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
		# terrain-overhaul Phase 1 侵蚀
		"erosion_droplet_factor",
		"erosion_max_lifetime",
		"erosion_capacity",
		"erosion_deposit_rate",
		"erosion_erode_rate",
		"erosion_evaporation",
		"erosion_gravity",
		"erosion_min_slope",
		"erosion_thermal_iters",
		"erosion_thermal_talus",
		"erosion_thermal_rate",
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
	var map: MapData = await _generator._terrain_generator.assemble_native_result(final_res, cfg)
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
	var map: MapData = await _generator._terrain_generator.assemble_native_result(final_res, cfg)
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


# Fast-tick perf opt (A)：weather_refresh_stride 跳日时复用的活跃 fronts 快照。
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
	_generator._loading_epoch += 1
	_generator._loading_frames.cancel()
	_generator._loading_frames = _generator.LoadingFrameGateScript.new()
	var epoch = _generator._loading_epoch
	# ── 诊断上下文：任何一次 generate() 失败都要能回答"失败在哪一步/为什么" ──
	_generator.last_generation_error = {}
	_generator._mapgen_stage = "preparing"
	_generator._mapgen_started_usec = Time.get_ticks_usec()
	_generator._last_cfg = cfg
	cfg.validate()
	_generator._abort_all_climate_passes("generate_restart")
	_generator.bake_progress.emit("preparing", 0.03)
	await _generator._yield_generation_frame()
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)
	_generator._mapgen_stage = "loading_catalog"
	await LoadingCatalogCache.prepare(_generator._ensure_generation_world_ext(), _generator._loading_frames)
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)

	var effective_seed: int = cfg.seed if cfg.seed != 0 else randi()
	_generator._rng = RandomNumberGenerator.new()
	_generator._rng.seed = effective_seed
	_generator._init_noise(effective_seed)
	_generator._ensure_daily_pass_modules()

	_generator._last_cfg = cfg
	_generator._last_hex_size = hex_size
	_generator._last_seed = effective_seed
	_generator._runtime_input_generation = 0
	_generator._runtime_climate_trace_pending.clear()
	_generator._runtime_climate_reference_last_day = -1
	_generator._runtime_climate_reference_last_hash = 0
	_generator._runtime_climate_reference_failures = 0
	_generator._runtime_climate_reference_last_error = ""
	_generator._runtime_climate_catalog_hash = 0
	_generator._runtime_climate_catalog_map_id = 0
	_generator._runtime_climate_topology_generation = 1
	_generator._runtime_climate_topology_map_id = 0
	_generator._runtime_climate_neighbor_offsets = PackedInt32Array()
	_generator._runtime_climate_neighbor_offsets_map_id = 0
	_generator._last_climate_breakdown.clear()
	_generator._current_season = -1
	_generator._weather_stage_b_call_index = -1
	_generator._native_daily_last_weather_embed_day = -1000000
	# 阶段 2：新一代地图的纬度/海拔变了，静态 wind baseline 缓存必须失效重算。
	_generator._native_wind_baseline_cache = PackedFloat32Array()
	_generator._native_wind_baseline_cache_map = null
	_generator._native_daily_ema_all_initialized_cache_map = null
	_generator._native_daily_ema_all_initialized_cache_size = 0
	_generator._native_daily_ema_all_initialized_cache_true = false
	_generator._enum_atlas_biome_dirty = false
	_generator._enum_atlas_cover_dirty = false
	_generator._enum_atlas_vegetation_dirty = false
	_generator._last_enum_atlas_upload_breakdown = {}
	_generator._season_stage4_deltas.clear()
	_generator._pending_season_refresh = false
	_generator._season_refresh_in_progress = false
	_generator._last_season_refresh_breakdown = {}
	_generator._scatter_sync_snap_landform = PackedByteArray()
	_generator._scatter_sync_snap_vegetation = PackedByteArray()
	_generator._scatter_sync_snap_cover = PackedByteArray()
	_generator._pending_detail_scatter_change_sets.clear()
	_generator._detail_scatter_change_generation = 0
	_generator._last_detail_scatter_sync = {}
	# X2-精简版：reset 时清掉 SoA-slots 缓存标志，避免新世界生成跨用上个世界的 stale fresh。
	_generator._season_round_slots_fresh = false
	_generator._season_round_slots_skip_count = 0
	_generator._season_round_slots_refresh_count = 0

	var t_total := Time.get_ticks_msec()
	# dots-total-cpp（2026-06-18）：地图生成已 100% C++（base + post_base，逐字段 A/B
	# parity PASS）。GDScript 生成 fallback（_generate_cells / 后处理）已删除——native
	# 失败即硬中止，绝不静默降级。失败的常见原因：DLL 未 rebuild / DCWorldExt 未注册 /
	# native_generation_mode != ACTIVE。
	_generator._mapgen_stage = "native_base"
	var map: MapData = await _generator._generate_cells_native_base(cfg, effective_seed)
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)
	if map == null:
		# 这里以前只 push_error 一段通用中文再 return {}，上层只能拿到
		# "map_generator_failed"——安卓上完全无法定位。现在把 _generate_cells_native_base
		# 已经写好的 _native_generation_base_report（含 rc/path/fallback_reason 等）
		# 连同 preflight 一起固化成结构化失败记录，并给出可读摘要。
		var native_reason := String(_generator._native_generation_base_report.get(
			"fallback_reason", _generator._native_generation_base_report.get("reason", "")))
		var native_path := String(_generator._native_generation_base_report.get("path", ""))
		var stage := "native_base" if native_path != "pkmap" else "pkmap"
		if _generator._native_generation_base_report.has("post_base"):
			stage = "native_post_base"
		var summary := "C++ 地图生成失败"
		if not native_reason.is_empty():
			summary += "（%s）" % native_reason
		summary += "。地图生成已无 GDScript 回退，本次中止。"
		var hint := "安卓：原生库可能缺失或过旧——用 gdext\\build_android.bat 重建 arm64 后重新导出 APK；" \
			+ "Windows：重建 dots_ext DLL 并重启编辑器。自查：adb logcat 过滤 [mapgen]。"
		push_error("[generate] %s reason=%s path=%s" % [summary, native_reason, native_path])
		return _generator._fail_generation(stage, native_reason if not native_reason.is_empty() \
			else "native_generation_returned_null", summary, hint)
	print("MapGenerator v7: per-cell %dms (%d cells, path=%s)" % [
		Time.get_ticks_msec() - t_total,
		map.cell_count(),
		String(_generator._native_generation_base_report.get("path", "gdext_base")),
	])
	_generator.bake_progress.emit("continents", 0.28)
	await _generator._yield_generation_frame()
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)

	# Milestone 1：landform / vegetation / cover 三轴在 native post_base 结果里已就绪
	# （DCTerrainGenerator.assemble_native_result 装配时写入），无需再 _sync_axes_for_map。
	# 在玩法层 baking 之前快照"年均"基线，给 Phase 2 季节刷新做参考
	_generator._terrain_generator.snapshot_base_state(map)

	# Phase 12 / Emergent Climate Coupling：base_terrain 定型后，为每个海洋 cell 初始化
	# 连续的 sea_ice_fraction（以 summer 温度为参考的平衡值），超过 terrain 阈值的同时设置 SEA_ICE。
	# 这取代了旧的 _apply_sea_ice_pass（已删除）——从 generate 开始就已经是"连续覆盖率"语义。
	_generator._bootstrap_sea_ice_fraction(map, cfg)
	# 海冰基线可能改写了部分 cell.terrain → 重新同步轴
	_generator._sync_axes_for_map(map, cfg)
	_generator.bake_progress.emit("climate", 0.40)
	await _generator._yield_generation_frame()
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)

	var t_bake := Time.get_ticks_msec()
	_generator._baker = MapBaker.new()
	_generator._baker.set_loading_frame_gate(_generator._loading_frames)
	# 转发 baker.stage_progress → generator.bake_progress（main.gd 已订阅）。
	if _generator._baker.has_signal("stage_progress") and not _generator._baker.stage_progress.is_connected(_generator._on_baker_stage_progress):
		_generator._baker.stage_progress.connect(_generator._on_baker_stage_progress)
	if _generator._world_clock_ref != null and _generator._baker.has_method("set_world_clock_ref"):
		_generator._baker.set_world_clock_ref(_generator._world_clock_ref)
	var bake_ext = _generator._ensure_generation_world_ext()
	if bake_ext != null and _generator._baker.has_method("set_world_ext"):
		_generator._baker.set_world_ext(bake_ext)
	# Physical Wind & Ocean Circulation：把 ClimateProfile 注入 cfg，让 MapBaker
	# 在 bake_world 内部检测 physical_circulation_enabled 等开关。生成阶段先注入一次；
	# OceanCurrentsJob 注册时还会重复注入一次，保持 cfg.climate_profile 始终为
	# 当前激活的 profile。
	if cfg != null:
		cfg.climate_profile = _generator._c()
	# [fix cell-indirect 2026-06-16] cell.index 必须在 bake_world 之前赋值。
	# bake_world 内部 _bake_height_biome_moisture 会按 cell.index 建 CSR，并把
	# cell.index fan-out 到 map_index_atlas.g/b。原 _build_indices() 在 bake 之后
	# (下方 ~L1205)才跑，会导致 bake 期间 cell.index 全是默认 -1 → CSR 全跳过、
	# map_index_atlas 写哨兵(0xFFFF) → shader 解码全 -1。这里提前建一次索引
	# (幂等：下方 _build_indices / init_soa_from_bake 会按同一 _cells 顺序再建，
	# cell.index 与 SoA terrain_arr 排布严格一致)。此刻 has_soa() 仍为 false，
	# 物理环流 defer 分支(MapBaker._bake_initial_physical_circulation)行为不变。
	_generator._loading_profile_step("await map.build_indices_cooperative()")
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)
	await map.build_indices_cooperative(_generator._loading_frames)
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)
	await _generator._yield_generation_frame()
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)
	# [snow-dyn-valid-fix 2026-06-16] 温度 Bootstrap 必须在 bake_world 之前执行。
	# 原因：bake_world 内部 rebake_dynamic_cell_atlas_only / bake_cell_luts 会把
	# cell.temperature 烘进动态 atlas/LUT 的 R 通道。若此刻温度仍是默认 0.0，首帧
	# atlas 全图 temp=0；旧 shader 靠 dyn_valid=step(0.02,dyn_temp) 兜底回退到
	# derived_temp，但该哨兵会把真实极寒格(温度=0)误判为"未初始化"→ 整格动态状态
	# (含雪盖)被清零。前移后 atlas 从第 0 帧即带真实纬度温度，dyn_valid 不再需要
	# （shader 端已同步移除）。
	# 依赖：cfg / cell.elevation / base_moisture / terrain / landform / vegetation /
	# cover 均在 _generate_cells（bake 前）就绪；不依赖 bake 产物。下方 bake 后的
	# _compute_ocean_currents / _compute_terrain_perturbed_wind 均不读 cell.temperature，
	# 故前移对它们 bit-for-bit 无影响。
	#
	# 初始 current_state（认为是夏季中段，等 main.gd 推第一次 season_changed 再更新）
	# Bootstrap: 同时把温度写入 HexCell backing field，确保 init_soa_from_bake()
	# 的 SoA 镜像（temp_arr / temp_30d_arr / temp_365d_arr / thermal_energy_arr）
	# 开局就是正确的纬度温度，而不是默认 0.0。
	for cell: HexCell in map.all_cells():
		var _boot_ny: float = _generator._cube_row_norm(cell, cfg)
		var _boot_temp: float = _generator._compute_temperature(_boot_ny, cell.elevation)
		# ── current_state 字典（UI / legacy 消费者用） ──
		cell.current_state = {
			"season": 1,
			"temperature": _boot_temp,
			"moisture": cell.base_moisture,
			"snow_cover": 0.0,
			"biome": int(cell.terrain),
			"landform": int(cell.landform),

			"vegetation": int(cell.vegetation),
			"cover": int(cell.cover),
			# Milestone 3：天气初始为 CLEAR，等 main.gd 推第一次 day_changed 才有真实天气
			"weather": int(WeatherType.WT.CLEAR),
			"weather_intensity": 0.0,
		}
		# ── 温度 Bootstrap：直写 backing field，跳过 facade（生成期 _facade_enabled=false）─
		cell._temperature_backing = _boot_temp
		cell._temp_baseline_backing = _boot_temp
		cell._temp_30d_mean_backing = _boot_temp
		cell._temp_365d_mean_backing = _boot_temp
		cell._temp_dev_from_annual_backing = 0.0
		cell._ema_initialized = true
	_generator._mapgen_stage = "bake"
	var world: WorldData = await _generator._baker.bake_world(map, cfg, hex_size, effective_seed)
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)
	if world == null:
		# bake_world 返回空后续全部会空引用崩溃（world.world_bounds 等）；
		# 在这里显式中止并给出可读原因，避免"闪退式"失败无法取证。
		return _generator._fail_generation("bake", "bake_world_returned_null",
			"地表烘焙（bake_world）返回空世界，本次生成中止。",
			"检查 bake 原生 pass（run_bake_geometry_fields_pass / run_physical_solve_pass）日志里的 fallback reason。")
	_generator._mapgen_stage = "soa"
	if _generator._baker.has_method("prewarm_dynamic_axis_caches"):
		_generator._baker.prewarm_dynamic_axis_caches(map, world)
	_generator._last_world = world
	print("MapGenerator v7: bake %dms" % (Time.get_ticks_msec() - t_bake))
	_generator.bake_progress.emit("ecology", 0.90)
	await _generator._yield_generation_frame()
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)

	# 任务 7：在 bake 后新增一个轻量级 pass，把 MapBaker 烤好的 per-pixel 洋流场
	# 折返为 per-cell HexCell.ocean_current。这是逻辑层的洋流字段——渲染层从这里
	# 开始读取（任务 8），未来的 AI / 鱼群 / 航运也从这里读取。不改动 height /
	# temperature / moisture / vegetation 生成（需求显式非目标）。
	_generator._compute_ocean_currents(map, world, hex_size)

	# 地形扰动风场（六边形尺度）：在洋流计算之后，借用已经定型的 cell.terrain /
	# cell.elevation + 邻居拓扑，对 WindBelt.wind_at 给出的"纬度风基线"做局地
	# 修正——海陆摩擦衰减、山脉上风阻挡（降速 + 旁侧绕流）、山脊伯努利加速、
	# 海岸热力风加速。结果写入 cell.wind_vector，仅给 Data Overlay 与未来局地
	# 玩法系统读；天气锋面 advection / 洋流 Ekman 偏转**仍读** WorldData.
	# wind_field_buffer，保留地球级纬向稳定形态。
	_generator._compute_terrain_perturbed_wind(map)

	# Milestone 3：天气子系统初始化（与 generator 同 seed，复盘可重现）
	_generator._weather_system = WeatherSystem.new()
	_generator._weather_system.init(effective_seed, world.world_bounds, hex_size)
	# Systemic Ocean Currents：按配置启用台风尾迹扰动（默认关闭）
	_generator._weather_system.configure_cyclone_wake(cfg.enable_cyclone_wake, cfg.CYCLONE_WAKE_DAYS)
	# Emergent Climate Coupling：把 emergent_weather_coupling 开关与雨影/迎风坡
	# 参数一次性下推到 WeatherSystem，后续每日 tick 内部消费。
	var cp_ec = _generator._c()
	if cp_ec != null:
		_generator._weather_system.configure_emergent_coupling(
			bool(cp_ec.emergent_weather_coupling),
			float(cp_ec.rain_shadow_threshold),
			float(cp_ec.rain_shadow_factor),
			float(cp_ec.orographic_boost)
		)
		# v11 地形扰动风：让 weather front advect / spawn 优先用 cell.wind_vector
		_generator._weather_system.configure_terrain_wind(bool(cp_ec.weather_advect_use_wind_vector))
		# Ocean current → weather spawn bias：寒流海岸抑制 RAIN/STORM/MONSOON 生成、
		# 暖流海岸促进。0 = legacy 行为；详见 weather_system._spawn_emergent_front。
		if _generator._weather_system.has_method("configure_ocean_spawn_bias"):
			_generator._weather_system.configure_ocean_spawn_bias(float(cp_ec.ocean_weather_spawn_bias))
		if _generator._weather_system.has_method("configure_weather_field"):
			_generator._weather_system.configure_weather_field(
				bool(cp_ec.weather_field_enabled),
				clampi(int(cp_ec.weather_field_advect_steps), 0, 8),
				float(cp_ec.weather_field_diffusion),
				float(cp_ec.weather_condensation_gain),
				float(cp_ec.weather_precip_decay),
				float(cp_ec.weather_orographic_lift_gain),
				float(cp_ec.weather_convergence_gain),
				float(cp_ec.weather_ocean_evap_gain),
				mini(int(cp_ec.weather_component_summary_limit), 12),
				int(cp_ec.weather_convergence_refresh_stride),
				float(cp_ec.weather_precip_carryover_max),
				float(cp_ec.weather_vapor_precip_sink),
				float(cp_ec.snowpack_accum_gain),
				float(cp_ec.snowpack_melt_temp_gain),
				float(cp_ec.snowpack_melt_sun_gain),
				float(cp_ec.snowpack_cover_low),
				float(cp_ec.snowpack_cover_full),
				int(cp_ec.snow_accum_days_req) if cp_ec.get("snow_accum_days_req") != null else 2,
				float(cp_ec.weather_temp_anomaly_cap),
				float(cp_ec.snowline_temp_threshold) if cp_ec.get("snowline_temp_threshold") != null else 0.24,
				float(cp_ec.snowline_band) if cp_ec.get("snowline_band") != null else 0.22,
				float(cp_ec.weather_vapor_relax_rate) if cp_ec.get("weather_vapor_relax_rate") != null else 0.08,
				float(cp_ec.weather_orographic_lift_cap) if cp_ec.get("weather_orographic_lift_cap") != null else 0.35,
				float(cp_ec.weather_wet_terrain_precip_damping) if cp_ec.get("weather_wet_terrain_precip_damping") != null else 0.28,
				float(cp_ec.weather_lake_precip_damping) if cp_ec.get("weather_lake_precip_damping") != null else 0.35,
				float(cp_ec.weather_lake_evap_scale) if cp_ec.get("weather_lake_evap_scale") != null else 0.35,
				float(cp_ec.weather_extreme_precip_soft_cap) if cp_ec.get("weather_extreme_precip_soft_cap") != null else 0.16,
				float(cp_ec.weather_extreme_precip_softness) if cp_ec.get("weather_extreme_precip_softness") != null else 0.20,
				float(cp_ec.weather_land_evapotranspiration_gain) if cp_ec.get("weather_land_evapotranspiration_gain") != null else 0.70,
				float(cp_ec.weather_precip_rh_threshold) if cp_ec.get("weather_precip_rh_threshold") != null else 0.70,
				float(cp_ec.weather_ocean_precip_suppression) if cp_ec.get("weather_ocean_precip_suppression") != null else 0.95,
				float(cp_ec.weather_frontogenesis_gain) if cp_ec.get("weather_frontogenesis_gain") != null else 0.42,
				float(cp_ec.weather_rain_shadow_drying) if cp_ec.get("weather_rain_shadow_drying") != null else 0.35,
				float(cp_ec.weather_vapor_transport_gain) if cp_ec.get("weather_vapor_transport_gain") != null else 0.75
			)

	# ─── Daily-Sim SoA Refactor 阶段 2：构建邻居索引 SoA ──────────────────
	# 此时所有 cell 已入库、terrain 已定型（包括河流、火山、湖泊、海冰首日
	# 状态等慢层常量），fast-tick 路径需要的稳定邻居拓扑已就绪。一次性预
	# 计算 _cell_array / _cell_index / _neighbor_indices，之后 fast-tick
	# 热路径直接通过 idx*6+dir 查表，不再走 6 次字典 lookup。
	# regenerate 路径：MapData 实例随每次 generate() 调用整体替换，本次构建
	# 的索引随旧 MapData 一起被丢弃，无需手动 invalidate。
	if not map.has_indices():
		await map.build_indices_cooperative(_generator._loading_frames)
		if epoch != _generator._loading_epoch:
			return _generator._generation_superseded(_generator._mapgen_stage)

	# ─── Climate-Weather 2ms Budget 阶段 A.1：构建 SoA 镜像 ─────────────
	# 一次性把 25 个热字段从 HexCell 同步到 SoA 数组。后续 climate / weather
	# sub-pass 在阶段 A.3+ 切到 SoA 路径后将直接读写这些数组，避免每次取
	# Variant / 字典 lookup。本调用是幂等的 — bake_world / 加载存档 / regenerate
	# 都可以安全调用一次。
	# PR-2.2 DEPRECATED：本函数仅生成期/加载期调用，运行期已全部走 world.write_*_indexed。
	# PR-2.3 HexCell facade 化完成 + 加载/regenerate 路径改为 _alloc_soa + 一次性
	# write_f32_indexed 全字段后可彻底删除（master 手册 §3.10.3）。
	# 任务 3（dots-completion）：改用语义化别名 init_soa_from_bake()，明确"仅 bake 时调用"。
	_generator._loading_profile_step("await map.init_soa_from_bake_cooperative()")
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)
	await map.init_soa_from_bake_cooperative(_generator._loading_frames)
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)
	await _generator._yield_generation_frame()
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)
	_generator._loading_profile_step("_generate_static_research_signals(map)")
	_generator._generate_static_research_signals(map)
	await _generator._yield_generation_frame()
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)
	# Natural resources are bootstrapped in _setup_sus after the deferred
	# physical circulation solve has published per-cell currents/upwelling.
	# This keeps fisheries from silently sampling zero-valued ocean drivers.
	var env_pixel_size: Vector2i = Vector2i.ZERO
	if world != null and "derived_size" in world:
		env_pixel_size = world.derived_size
	_generator._loading_profile_step("ensure_environment_runtime(map, env_pixel_size)")
	_generator.ensure_environment_runtime(map, env_pixel_size)
	await _generator._yield_generation_frame()
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)
	# B1-A：SoA 就位后立即 bake 每 cell 的常量 LUT（归一化纬度 + 年均温度）。
	# Pass A 运行期内层仅需数组索引，不再调用 _cube_row_norm / pow / cos。
	_generator._loading_profile_step("map.bake_lat_temp_year_lut(_generator)")
	map.bake_lat_temp_year_lut(_generator)
	# 季节 round-start knob 几何缓存预热（perf-2026-06）：row_indices + rain-shadow
	# jitter 各跑 n_cells 次 HexCell 解引用共 ~3ms，是 season_refresh B+ round-start
	# tick 的全部峰值。两者是地图几何/固定噪声种子的纯函数，此处地图已完全烘焙
	# （_build_indices / SoA / lat LUT 就绪），一次性预建缓存把这 ~3ms 从首个季节
	# SUS tick 挪到生成期（本就数秒级，开销不可见），让运行期 round-start 命中缓存
	# 降到 ~0.01ms。失败（cfg/warp 未就绪）静默回退到 round 内惰性构建，行为不变。
	if map != null and map.has_indices():
		_generator._loading_profile_step("_ensure_season_knob_geometry_cache(map, map.cell_count())")
		await _generator._prepare_season_geometry_cooperative(map, map.cell_count())
		if epoch != _generator._loading_epoch:
			return _generator._generation_superseded(_generator._mapgen_stage)
	_generator.bake_progress.emit("simulation", 0.96)
	await _generator._yield_generation_frame()
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)
	# ─── SUS 注册（任务 4：接入点 ① + ③）─────────────────────────────────
	# 此时 baker.bake_world 已经一次性烘完了 ocean currents + upwelling 完整版，
	# per-cell 也已经被 _compute_ocean_currents 回填。SUS 从这里开始接管"逐日
	# 增量重烘"——每个完整 round 在 ocean_currents_period_ticks 天内分
	# ocean_currents_slice_count 个切片完成，commit 时再一次性原子替换 4 件
	# 产物（ocean_current_buffer / ocean_upwelling_buffer / vector_atlas_tex /
	# upwelling_tex）并回填 per-cell。
	_generator._mapgen_stage = "sus"
	await _generator._setup_sus(map, world, cfg, hex_size)
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)
	_generator.bake_progress.emit("done", 1.0)
	await _generator._yield_generation_frame()
	if epoch != _generator._loading_epoch:
		return _generator._generation_superseded(_generator._mapgen_stage)

	return {"map": map, "world_data": world, "seed": effective_seed}

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
	# ACTIVE owns Economy scheduling in the native graph, so the legacy SUS job
	# has no report to offer (it is intentionally policy-gated). Prefer the
	# graph's compact native result, while retaining the legacy report for OFF /
	# SHADOW and older DLLs that do not expose the graph accessor.
	if _generator._runtime_graph_active and _generator._data_core_world_ext is DCWorldExt:
		var graph_report: Dictionary = _generator._data_core_world_ext.get_runtime_graph_last_economy_report()
		if not graph_report.is_empty():
			return graph_report
	return _generator._economy_daily_job.last_perf_report() \
		if _generator._economy_daily_job != null and _generator._economy_daily_job.has_method("last_perf_report") \
		else {}



func get_runtime_perf_snapshot(detail_level: int = 0) -> Dictionary:
	if _generator._data_core_world_ext == null:
		return {}
	var snapshot: Dictionary = _generator._data_core_world_ext.get_runtime_perf_snapshot(detail_level)
	snapshot["country_territory_sync_ms"] = _generator._runtime_graph_country_territory_sync_ms
	snapshot["event_dispatch_ms"] = _generator._runtime_graph_country_event_dispatch_ms
	# P1：环境帧发布者的 GDScript 侧账本（C++ 侧看不到谁在打包）。
	snapshot["environment_publish_callsite_mask"] = _generator._environment_publish_callsite_mask
	snapshot["environment_publish_count"] = _generator._environment_publish_count
	snapshot["environment_publish_suppressed"] = _generator._environment_publish_suppressed
	snapshot["environment_publish_orphan_day"] = _generator._environment_publish_orphan_day
	snapshot["environment_publisher_callsite"] = _generator._worker_environment_publisher_callsite
	snapshot["environment_frames_ahead"] = maxi(0,
		int(snapshot.get("simulation_environment_day", 0)) \
		- int(snapshot.get("simulation_committed_day", 0)))
	return snapshot


