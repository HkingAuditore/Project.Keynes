extends RefCounted


static func generate(owner: Variant, cfg: MapConfig, hex_size: float) -> Dictionary:
	owner._generator._loading_epoch += 1
	owner._generator._loading_frames.cancel()
	owner._generator._loading_frames = owner._generator.LoadingFrameGateScript.new()
	var epoch = owner._generator._loading_epoch
	# ── 诊断上下文：任何一次 generate() 失败都要能回答"失败在哪一步/为什么" ──
	owner._generator.last_generation_error = {}
	owner._generator._mapgen_stage = "preparing"
	owner._generator._mapgen_started_usec = Time.get_ticks_usec()
	owner._generator._last_cfg = cfg
	cfg.validate()
	owner._generator._abort_all_climate_passes("generate_restart")
	owner._generator.bake_progress.emit("preparing", 0.03)
	await owner._generator._yield_generation_frame()
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)
	owner._generator._mapgen_stage = "loading_catalog"
	await LoadingCatalogCache.prepare(owner._generator._ensure_generation_world_ext(), owner._generator._loading_frames)
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)

	var effective_seed: int = cfg.seed if cfg.seed != 0 else randi()
	owner._generator._rng = RandomNumberGenerator.new()
	owner._generator._rng.seed = effective_seed
	owner._generator._init_noise(effective_seed)
	owner._generator._ensure_daily_pass_modules()

	owner._generator._last_cfg = cfg
	owner._generator._last_hex_size = hex_size
	owner._generator._last_seed = effective_seed
	owner._generator._runtime_input_generation = 0
	owner._generator._runtime_climate_trace_pending.clear()
	owner._generator._runtime_climate_reference_last_day = -1
	owner._generator._runtime_climate_reference_last_hash = 0
	owner._generator._runtime_climate_reference_failures = 0
	owner._generator._runtime_climate_reference_last_error = ""
	owner._generator._runtime_climate_catalog_hash = 0
	owner._generator._runtime_climate_catalog_map_id = 0
	owner._generator._runtime_climate_topology_generation = 1
	owner._generator._runtime_climate_topology_map_id = 0
	owner._generator._runtime_climate_neighbor_offsets = PackedInt32Array()
	owner._generator._runtime_climate_neighbor_offsets_map_id = 0
	owner._generator._last_climate_breakdown.clear()
	owner._generator._current_season = -1
	owner._generator._weather_stage_b_call_index = -1
	# 阶段 2：新一代地图的纬度/海拔变了，静态 wind baseline 缓存必须失效重算。
	owner._generator._native_wind_baseline_cache = PackedFloat32Array()
	owner._generator._native_wind_baseline_cache_map = null
	owner._generator._native_daily_ema_all_initialized_cache_map = null
	owner._generator._native_daily_ema_all_initialized_cache_size = 0
	owner._generator._native_daily_ema_all_initialized_cache_true = false
	owner._generator._enum_atlas_biome_dirty = false
	owner._generator._enum_atlas_cover_dirty = false
	owner._generator._enum_atlas_vegetation_dirty = false
	owner._generator._last_enum_atlas_upload_breakdown = {}
	owner._generator._season_stage4_deltas.clear()
	owner._generator._pending_season_refresh = false
	owner._generator._season_refresh_in_progress = false
	owner._generator._last_season_refresh_breakdown = {}
	owner._generator._scatter_sync_snap_landform = PackedByteArray()
	owner._generator._scatter_sync_snap_vegetation = PackedByteArray()
	owner._generator._scatter_sync_snap_cover = PackedByteArray()
	owner._generator._pending_detail_scatter_change_sets.clear()
	owner._generator._detail_scatter_change_generation = 0
	owner._generator._last_detail_scatter_sync = {}
	# X2-精简版：reset 时清掉 SoA-slots 缓存标志，避免新世界生成跨用上个世界的 stale fresh。
	owner._generator._season_round_slots_fresh = false
	owner._generator._season_round_slots_skip_count = 0
	owner._generator._season_round_slots_refresh_count = 0

	var t_total := Time.get_ticks_msec()
	# dots-total-cpp（2026-06-18）：地图生成已 100% C++（base + post_base，逐字段 A/B
	# parity PASS）。GDScript 生成 fallback（_generate_cells / 后处理）已删除——native
	# 失败即硬中止，绝不静默降级。失败的常见原因：DLL 未 rebuild / DCWorldExt 未注册 /
	# native_generation_mode != ACTIVE。
	owner._generator._mapgen_stage = "native_base"
	var map: MapData = await owner._generator._generate_cells_native_base(cfg, effective_seed)
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)
	if map == null:
		# 这里以前只 push_error 一段通用中文再 return {}，上层只能拿到
		# "map_generator_failed"——安卓上完全无法定位。现在把 _generate_cells_native_base
		# 已经写好的 _native_generation_base_report（含 rc/path/fallback_reason 等）
		# 连同 preflight 一起固化成结构化失败记录，并给出可读摘要。
		var native_reason := String(owner._generator._native_generation_base_report.get(
			"fallback_reason", owner._generator._native_generation_base_report.get("reason", "")))
		var native_path := String(owner._generator._native_generation_base_report.get("path", ""))
		var stage := "native_base" if native_path != "pkmap" else "pkmap"
		if owner._generator._native_generation_base_report.has("post_base"):
			stage = "native_post_base"
		var summary := "C++ 地图生成失败"
		if not native_reason.is_empty():
			summary += "（%s）" % native_reason
		summary += "。地图生成已无 GDScript 回退，本次中止。"
		var hint := "安卓：原生库可能缺失或过旧——用 gdext\\build_android.bat 重建 arm64 后重新导出 APK；" \
			+ "Windows：重建 dots_ext DLL 并重启编辑器。自查：adb logcat 过滤 [mapgen]。"
		push_error("[generate] %s reason=%s path=%s" % [summary, native_reason, native_path])
		return owner._generator._fail_generation(stage, native_reason if not native_reason.is_empty() \
			else "native_generation_returned_null", summary, hint)
	print("MapGenerator v7: per-cell %dms (%d cells, path=%s)" % [
		Time.get_ticks_msec() - t_total,
		map.cell_count(),
		String(owner._generator._native_generation_base_report.get("path", "gdext_base")),
	])
	owner._generator.bake_progress.emit("continents", 0.28)
	await owner._generator._yield_generation_frame()
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)

	# Milestone 1：landform / vegetation / cover 三轴在 native post_base 结果里已就绪
	# （DCTerrainGenerator.assemble_native_result 装配时写入），无需再 _sync_axes_for_map。
	# 在玩法层 baking 之前快照"年均"基线，给 Phase 2 季节刷新做参考
	owner._generator._terrain_generator.snapshot_base_state(map)

	# Phase 12 / Emergent Climate Coupling：base_terrain 定型后，为每个海洋 cell 初始化
	# 连续的 sea_ice_fraction（以 summer 温度为参考的平衡值），超过 terrain 阈值的同时设置 SEA_ICE。
	# 这取代了旧的 _apply_sea_ice_pass（已删除）——从 generate 开始就已经是"连续覆盖率"语义。
	owner._generator._bootstrap_sea_ice_fraction(map, cfg)
	# 海冰基线可能改写了部分 cell.terrain → 重新同步轴
	owner._generator._sync_axes_for_map(map, cfg)
	owner._generator.bake_progress.emit("climate", 0.40)
	await owner._generator._yield_generation_frame()
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)

	var t_bake := Time.get_ticks_msec()
	owner._generator._baker = MapBaker.new()
	owner._generator._baker.set_loading_frame_gate(owner._generator._loading_frames)
	# 转发 baker.stage_progress → generator.bake_progress（main.gd 已订阅）。
	if owner._generator._baker.has_signal("stage_progress") and not owner._generator._baker.stage_progress.is_connected(owner._generator._on_baker_stage_progress):
		owner._generator._baker.stage_progress.connect(owner._generator._on_baker_stage_progress)
	if owner._generator._world_clock_ref != null and owner._generator._baker.has_method("set_world_clock_ref"):
		owner._generator._baker.set_world_clock_ref(owner._generator._world_clock_ref)
	var bake_ext = owner._generator._ensure_generation_world_ext()
	if bake_ext != null and owner._generator._baker.has_method("set_world_ext"):
		owner._generator._baker.set_world_ext(bake_ext)
	# Physical Wind & Ocean Circulation：把 ClimateProfile 注入 cfg，让 MapBaker
	# 在 bake_world 内部检测 physical_circulation_enabled 等开关。生成阶段先注入一次；
	# OceanCurrentsJob 注册时还会重复注入一次，保持 cfg.climate_profile 始终为
	# 当前激活的 profile。
	if cfg != null:
		cfg.climate_profile = owner._generator._c()
	# Map baking writes cell indices into its lookup textures. Generated maps
	# already have them; older or authored maps build them here before baking.
	owner._generator._loading_profile_step("build_map_indices")
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)
	await map.build_indices_cooperative(owner._generator._loading_frames)
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)
	await owner._generator._yield_generation_frame()
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)
	owner._generator._loading_profile_step("initial_climate_and_map_bake")
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
		var _boot_ny: float = owner._generator._cube_row_norm(cell, cfg)
		var _boot_temp: float = owner._generator._compute_temperature(_boot_ny, cell.elevation)
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
	owner._generator._mapgen_stage = "bake"
	var world: WorldData = await owner._generator._baker.bake_world(map, cfg, hex_size, effective_seed)
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)
	if world == null:
		# bake_world 返回空后续全部会空引用崩溃（world.world_bounds 等）；
		# 在这里显式中止并给出可读原因，避免"闪退式"失败无法取证。
		return owner._generator._fail_generation("bake", "bake_world_returned_null",
			"地表烘焙（bake_world）返回空世界，本次生成中止。",
			"检查 bake 原生 pass（run_bake_geometry_fields_pass / run_physical_solve_pass）日志里的 fallback reason。")
	owner._generator._mapgen_stage = "soa"
	if owner._generator._baker.has_method("prewarm_dynamic_axis_caches"):
		owner._generator._baker.prewarm_dynamic_axis_caches(map, world)
	owner._generator._last_world = world
	print("MapGenerator v7: bake %dms" % (Time.get_ticks_msec() - t_bake))
	owner._generator.bake_progress.emit("ecology", 0.90)
	await owner._generator._yield_generation_frame()
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)

	# 任务 7：在 bake 后新增一个轻量级 pass，把 MapBaker 烤好的 per-pixel 洋流场
	# 折返为 per-cell HexCell.ocean_current。这是逻辑层的洋流字段——渲染层从这里
	# 开始读取（任务 8），未来的 AI / 鱼群 / 航运也从这里读取。不改动 height /
	# temperature / moisture / vegetation 生成（需求显式非目标）。
	owner._generator._compute_ocean_currents(map, world, hex_size)

	# 地形扰动风场（六边形尺度）：在洋流计算之后，借用已经定型的 cell.terrain /
	# cell.elevation + 邻居拓扑，对 WindBelt.wind_at 给出的"纬度风基线"做局地
	# 修正——海陆摩擦衰减、山脉上风阻挡（降速 + 旁侧绕流）、山脊伯努利加速、
	# 海岸热力风加速。结果写入 cell.wind_vector，仅给 Data Overlay 与未来局地
	# 玩法系统读；天气锋面 advection / 洋流 Ekman 偏转**仍读** WorldData.
	# wind_field_buffer，保留地球级纬向稳定形态。
	owner._generator._compute_terrain_perturbed_wind(map)

	# Milestone 3：天气子系统初始化（与 generator 同 seed，复盘可重现）
	owner._generator._weather_system = WeatherSystem.new()
	owner._generator._weather_system.init(effective_seed, world.world_bounds, hex_size)
	# Systemic Ocean Currents：按配置启用台风尾迹扰动（默认关闭）
	owner._generator._weather_system.configure_cyclone_wake(cfg.enable_cyclone_wake, cfg.CYCLONE_WAKE_DAYS)
	# Emergent Climate Coupling：把 emergent_weather_coupling 开关与雨影/迎风坡
	# 参数一次性下推到 WeatherSystem，后续每日 tick 内部消费。
	var cp_ec = owner._generator._c()
	if cp_ec != null:
		owner._generator._weather_system.configure_emergent_coupling(
			bool(cp_ec.emergent_weather_coupling),
			float(cp_ec.rain_shadow_threshold),
			float(cp_ec.rain_shadow_factor),
			float(cp_ec.orographic_boost)
		)
		# v11 地形扰动风：让 weather front advect / spawn 优先用 cell.wind_vector
		owner._generator._weather_system.configure_terrain_wind(bool(cp_ec.weather_advect_use_wind_vector))
		# Ocean current → weather spawn bias：寒流海岸抑制 RAIN/STORM/MONSOON 生成、
		# 暖流海岸促进。0 = legacy 行为；详见 weather_system._spawn_emergent_front。
		if owner._generator._weather_system.has_method("configure_ocean_spawn_bias"):
			owner._generator._weather_system.configure_ocean_spawn_bias(float(cp_ec.ocean_weather_spawn_bias))
		if owner._generator._weather_system.has_method("configure_weather_field"):
			owner._generator._weather_system.configure_weather_field(
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
		await map.build_indices_cooperative(owner._generator._loading_frames)
		if epoch != owner._generator._loading_epoch:
			return owner._generator._generation_superseded(owner._generator._mapgen_stage)

	# ─── Climate-Weather 2ms Budget 阶段 A.1：构建 SoA 镜像 ─────────────
	# 一次性把 25 个热字段从 HexCell 同步到 SoA 数组。后续 climate / weather
	# sub-pass 在阶段 A.3+ 切到 SoA 路径后将直接读写这些数组，避免每次取
	# Variant / 字典 lookup。本调用是幂等的 — bake_world / 加载存档 / regenerate
	# 都可以安全调用一次。
	# PR-2.2 DEPRECATED：本函数仅生成期/加载期调用，运行期已全部走 world.write_*_indexed。
	# PR-2.3 HexCell facade 化完成 + 加载/regenerate 路径改为 _alloc_soa + 一次性
	# write_f32_indexed 全字段后可彻底删除（master 手册 §3.10.3）。
	# 任务 3（dots-completion）：改用语义化别名 init_soa_from_bake()，明确"仅 bake 时调用"。
	owner._generator._loading_profile_step("await map.init_soa_from_bake_cooperative()")
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)
	await map.init_soa_from_bake_cooperative(owner._generator._loading_frames)
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)
	await owner._generator._yield_generation_frame()
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)
	owner._generator._loading_profile_step("_generate_static_research_signals(map)")
	owner._generator._generate_static_research_signals(map)
	await owner._generator._yield_generation_frame()
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)
	# Natural resources are bootstrapped in _setup_sus after the deferred
	# physical circulation solve has published per-cell currents/upwelling.
	# This keeps fisheries from silently sampling zero-valued ocean drivers.
	var env_pixel_size: Vector2i = Vector2i.ZERO
	if world != null and "derived_size" in world:
		env_pixel_size = world.derived_size
	owner._generator._loading_profile_step("ensure_environment_runtime(map, env_pixel_size)")
	owner._generator.ensure_environment_runtime(map, env_pixel_size)
	await owner._generator._yield_generation_frame()
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)
	# B1-A：SoA 就位后立即 bake 每 cell 的常量 LUT（归一化纬度 + 年均温度）。
	# Pass A 运行期内层仅需数组索引，不再调用 _cube_row_norm / pow / cos。
	owner._generator._loading_profile_step("map.bake_lat_temp_year_lut(_generator)")
	map.bake_lat_temp_year_lut(owner._generator)
	# 季节 round-start knob 几何缓存预热（perf-2026-06）：row_indices + rain-shadow
	# jitter 各跑 n_cells 次 HexCell 解引用共 ~3ms，是 season_refresh B+ round-start
	# tick 的全部峰值。两者是地图几何/固定噪声种子的纯函数，此处地图已完全烘焙
	# （_build_indices / SoA / lat LUT 就绪），一次性预建缓存把这 ~3ms 从首个季节
	# SUS tick 挪到生成期（本就数秒级，开销不可见），让运行期 round-start 命中缓存
	# 降到 ~0.01ms。失败（cfg/warp 未就绪）静默回退到 round 内惰性构建，行为不变。
	if map != null and map.has_indices():
		owner._generator._loading_profile_step("_ensure_season_knob_geometry_cache(map, map.cell_count())")
		await owner._generator._prepare_season_geometry_cooperative(map, map.cell_count())
		if epoch != owner._generator._loading_epoch:
			return owner._generator._generation_superseded(owner._generator._mapgen_stage)
	owner._generator.bake_progress.emit("simulation", 0.96)
	await owner._generator._yield_generation_frame()
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)
	# ─── SUS 注册（任务 4：接入点 ① + ③）─────────────────────────────────
	# 此时 baker.bake_world 已经一次性烘完了 ocean currents + upwelling 完整版，
	# per-cell 也已经被 _compute_ocean_currents 回填。SUS 从这里开始接管"逐日
	# 增量重烘"——每个完整 round 在 ocean_currents_period_ticks 天内分
	# ocean_currents_slice_count 个切片完成，commit 时再一次性原子替换 4 件
	# 产物（ocean_current_buffer / ocean_upwelling_buffer / vector_atlas_tex /
	# upwelling_tex）并回填 per-cell。
	owner._generator._mapgen_stage = "sus"
	await owner._generator._setup_sus(map, world, cfg, hex_size)
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)
	owner._generator.bake_progress.emit("done", 1.0)
	await owner._generator._yield_generation_frame()
	if epoch != owner._generator._loading_epoch:
		return owner._generator._generation_superseded(owner._generator._mapgen_stage)

	return {"map": map, "world_data": world, "seed": effective_seed}
