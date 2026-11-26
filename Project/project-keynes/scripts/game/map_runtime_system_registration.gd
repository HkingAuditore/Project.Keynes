extends RefCounted

## Binds the world and registers the systems that consume it.


static func _setup_sus(context, map: MapData, world: WorldData, cfg: MapConfig, hex_size: float) -> void:
	context._generator._sus_map = map
	context._generator._sus_world = world
	# 生成收尾建立散布同步基线，供显示侧比较已发布的地块变化。
	context._generator._loading_profile_step("scatter_snapshot")
	context._generator._prime_scatter_sync_snapshot(map)
	await context._generator._yield_generation_frame()
	# 创建一个全新 DCSystemScheduler 实例（regenerate 路径会让旧实例随
	# MapGenerator 一起被替换，不需要手动 reset_all_progress）。
	var cp_sched = context._generator._c()
	context._generator._sus = context._generator.DCSystemSchedulerScript.new()
	context._generator._sea_ice_daily_job = null
	context._generator._weather_refresh_system = null
	context._generator._weather_refresh_job = null
	context._generator._ocean_currents_system = null
	context._generator._ocean_currents_job = null
	context._generator._sus.configure_from_profile(cp_sched)
	# DataCore World 接入（dots-foundation-and-weather-migration）：
	# 在 SUS 注册任何 job 前先把 World 实例创建出来并 bind 到 MapData，
	# 这样所有 register_job 会自动被注入 world 引用。
	#
	# dots-flag-prune-pr1 (2026-05-22)： use_data_core flag 已删除——DataCore 现
	# 恒挂载并 bind（不再区分 "创建但不 bind" 的 legacy 路径）。
	var dc_enabled: bool = true
	var cp_dc = context._generator._c()
	context._generator._data_core_world = DCWorld.new()
	if dc_enabled:
		# Reference-impl Pass #2 (performance-charter §12.6)：把 demo 开关透传，
		# 使 DCWorld 在 bind 阶段注册 CELL_DEMO_THERMAL_GRADIENT slot 并把
		# map.demo_thermal_gradient_arr resize 到 N。否则 baker 看到 size=0 全部
		# invalid，overlay 全屏空白（典型现象：stats min/max/mean=0、invalid=N）。
		var demo_tg_on: bool = false
		if cp_dc != null and "demo_thermal_gradient_enabled" in cp_dc:
			demo_tg_on = bool(cp_dc.demo_thermal_gradient_enabled)
		context._generator._loading_profile_step("dc_world_bind")
		context._generator._data_core_world.bind_map_data(map, demo_tg_on)
		await context._generator._yield_generation_frame()
	context._generator._sus.bind_world(context._generator._data_core_world)

	# DataCore World — C++ co-processor（dots-roadmap-to-gdextension 务实 A）。
	# 与 _data_core_world 同时 bind 到同一份 MapData PackedArray。CoW alias 已在
	# Phase 3a Step 2.0 验证：两侧 view_f32 看到同一块底层 buffer；C++ Pass 写完后
	# 调一次 map.set("temp_arr", arr) 推回（snapshot contract，详见 world_ext.cpp）。
	# - 仅 use_data_core=true 时创建（与主 World 一致门控）
	# - NativeWorld.create 失败（GDExtension 未加载）→ 保持 null，climate Pass-A
	#   走 GDScript 路径，不报 error（dev 机器上不一定每次都构建过 gdext）
	# - 不注入 SUS.bind_world：weather / sus 子系统对此实例零感知，避免 weather
	#   迁移连锁（接口集差异详见 plan/dots-roadmap-to-gdextension/architecture.md §7）
	if dc_enabled:
		if ClassDB.class_exists("DCWorldExt"):
			var ext_obj: Object = context._generator._data_core_world_ext if context._generator._data_core_world_ext != null else context._generator.NativeWorld.create()
			if ext_obj != null and ext_obj is RefCounted:
				context._generator._data_core_world_ext = ext_obj
				# C++ _diag_logs_enabled 默认 true；创建/复用时同步 PKLog 状态，
				# 避免 PKLog 默认关闭下原生 diag print 仍然刷屏。
				context._generator._data_core_world_ext.set_diag_logs_enabled(PKLog.enabled)
				context._generator._loading_profile_step("native_world_bind")
				var ext_bound: bool = bool(context._generator._data_core_world_ext.bind_map_data(map))
				await context._generator._yield_generation_frame()
				print("[DataCore] _data_core_world_ext bound=%s (climate co-processor; class=DCWorldExt)" % str(ext_bound))
				context._generator._dc_terrain_mirror_dirty = true
				if not ext_bound:
					push_warning("[DataCore] DCWorldExt.bind_map_data returned false; climate Pass-A C++ acceleration disabled (will fall back to DataCore/GDScript path)")
					context._generator._data_core_world_ext = null
				else:
					if context._generator._gameplay_event_bus != null:
						context._generator._gameplay_event_bus.bind_world_ext(context._generator._data_core_world_ext)
					# sea-ice-snow-visual-fix-2026-06：bind 后注入 DCWorld 句柄。C++ pass
					# `_flush_slot_to_map` 末尾会 call("mark_dirty_all")，让 atlas pipeline
					# 在下个 stride 通过 `read_and_clear_dirty_mask` 拿到信号。修复 wind_surface
					# / pass_b / ocean_* 写 slot 后 atlas 不知道脏 → 视觉冻结。
					if context._generator._data_core_world != null:
						context._generator._data_core_world_ext.bind_dirty_world(context._generator._data_core_world)
					# Block B（master 手册 §4）：把 DCWorldExt 注入 MapBaker，
					# 让 _PHYS_STAGE_WIND 等 C++ hook 在启用 use_gdext_wind_field 时使用。
					if context._generator._baker != null and context._generator._baker.has_method("set_world_ext"):
						context._generator._baker.set_world_ext(context._generator._data_core_world_ext)
					context._generator._configure_native_world_context(map, world, cfg, hex_size)
					# cpp-dots（native-generation-publish-2026-06）：生成期地图对象/拓扑仍由
					# GDScript 编排，SoA/slot 初始仿真字段由 C++ publish 成权威，再 flush 回
					# MapData。失败时保留 map.bake_lat_temp_year_lut 的 GDScript fallback。
					var native_gen_ok: bool = context._generator._publish_native_generation_from_slots(map, cfg)
					if not native_gen_ok:
						# cpp-dots（temp-baseline-authority-2026-06）：cell_temp_baseline_year
						# （海冰 + 显示温度的运行期 baseline）权威计算归 C++。L1235 的
						# bake_lat_temp_year_lut 已用 GDScript fallback 填好 cell_lat_norm +
						# temp_baseline_year；ext 现已 bind，把 temp_baseline_year 交给 C++
						# pk_lat_temp_bell 权威重算并 flush 回 MapData（ext 未就绪则保留 GDScript 值）。
						context._generator._bake_temp_baseline_year_native(map)
			else:
				push_warning("[DataCore] NativeWorld.create() returned null/non-RefCounted; gdext likely not loaded — climate C++ accel disabled")
		else:
			# GDExtension 没加载（开发机没编译 gdext / 平台不支持等），完全降级。
			# 不打 error 避免噪声，main.gd 的 [DataCore] flags 那行已能体现整体路径。
			print("[DataCore] DCWorldExt class not registered (gdext unavailable); climate Pass-A will use DataCore/GDScript path only")
	if context._generator._data_core_world_ext == null and context._generator._gameplay_event_bus != null:
		context._generator._gameplay_event_bus.bind_world_ext(null)

	# PR-2.3a HexCell facade infra：bake_world / 加载存档末尾给每个 cell 注入 world
	# 引用 + facade flag。
	#
	# dots-flag-prune-pr1 (2026-05-22)： use_hexcell_facade flag 已删除——
	# facade 现恒启用（bind_world 第 2 参 _facade_on=true），热字段 getter/setter 全走
	# DCWorld view（PR-2.3c 已验收）。
	#
	# plan/3b-single-read-source：本段已从 _data_core_world 创建紧后移到此处，
	# 在 _data_core_world_ext 创建之后才 bind，使第 3 参 world_ext 能正确传入。
	# 当 ext 为 null（gdext 未编译 / bind_map_data 失败）时退化为旧 2 参行为，
	# facade getter 走 _world.read_*，与 PR-2.3c 实现 100% 等价。
	if dc_enabled:
		var _facade_on: bool = true
		var _cell_arr_for_bind: Array = map._cell_array
		var _n_cells_for_bind: int = _cell_arr_for_bind.size()
		context._generator._loading_profile_step("cell_facade_bind")
		# dots-boot-facade-2026-10：bind_world() 的 cid 缓存只取决于
		# (DCWorld, DCWorldExt) 两侧的注册表，与具体 cell 无关，但原实现要逐格做
		# 39×2 次 component_id 查询 + 39 次 String.replace（2400 格 ≈ 19 万次调用，
		# Web 实测 520~1000ms）。这里改成「第 0 格走原路径顺手产出 cid 表，其余格
		# 直接注入同一份 PackedArray」，每格只剩 5 次属性赋值。
		# 任何一步不符合预期（脚本字段改名 / 拿不到 cid 表）→ 立即整体退回原循环。
		var _cid_gd := PackedInt32Array()
		var _cid_ext := PackedInt32Array()
		var _hoisted := false
		for _ci in range(_n_cells_for_bind):
			if context._generator._generation_slice_due():
				await context._generator._yield_generation_frame()
				context._generator._generation_slice_start_usec = Time.get_ticks_usec()
			var _c_for_bind = _cell_arr_for_bind[_ci]
			if _c_for_bind == null or not _c_for_bind.has_method("bind_world"):
				continue
			if _ci == 0:
				_c_for_bind.bind_world(context._generator._data_core_world, _facade_on, context._generator._data_core_world_ext)
				_cid_gd = context._generator._cell_facade_cids_of(_c_for_bind, &"_cid_array")
				_cid_ext = context._generator._cell_facade_cids_of(_c_for_bind, &"_cid_array_ext")
				_hoisted = not _cid_gd.is_empty() and not _cid_ext.is_empty()
				continue
			if _hoisted and context._generator._bind_cell_facade_with_cids(
					_c_for_bind, _facade_on, _cid_gd, _cid_ext):
				continue
			# 兜底：cid 表不可复用 → 逐格走原路径（与迁移前完全一致）。
			_hoisted = false
			_c_for_bind.bind_world(context._generator._data_core_world, _facade_on, context._generator._data_core_world_ext)
		if _facade_on:
			print("[hex_cell] facade ENABLED (%d cells bound; ext=%s; shared_cids=%s)" % [
				_n_cells_for_bind, str(context._generator._data_core_world_ext != null), str(_cid_gd.size())])
	# DOTS-Final-Push 修复：把 ClimateProfile 直接注入 MapBaker。
	# 历史上 sea_ice prepare / albedo / veg_dyn / feedback 通过 `world.get("config")`
	# 取 cp 永远拿到 null（WorldData 上没有 config 字段），导致 use_native 一直 false，
	# sea_ice prepare 稳定 48ms GDScript 全图回扫。这里显式注入修正这一长期 bug。
	# 不被 dc_enabled 门控——GDScript 路径同样需要 cp.flag 做配置读取。
	if context._generator._baker != null and context._generator._baker.has_method("set_climate_profile"):
		var cp_for_baker = context._generator._c()
		context._generator._baker.set_climate_profile(cp_for_baker)
		print("[DataCore] _baker climate_profile injected=%s (fixes WorldData.config==null sea_ice prepare path)" % str(cp_for_baker != null))
	if cfg != null:
		cfg.climate_profile = context._generator._c()
	if context._generator._baker != null and context._generator._baker.has_method("run_deferred_initial_physical_circulation"):
		context._generator._loading_profile_step("deferred_physical_circulation")
		context._generator._baker.run_deferred_initial_physical_circulation(map, world, hex_size, cfg)
	# per-cell LUT 同样推迟到这里：ext 已 bind、原生温度场已 publish，encode_cell_luts
	# 因此能走 C++ 并读到权威气候值。仍在 generate() 内，早于渲染器绑定 lut 纹理。
	if context._generator._baker != null and context._generator._baker.has_method("run_deferred_initial_cell_luts"):
		context._generator._loading_profile_step("deferred_cell_luts")
		context._generator._baker.run_deferred_initial_cell_luts(map, world)
	# Resource bootstrap must observe committed physical geography. It still
	# precedes economy bootstrap, and the explicit push keeps the native
	# snapshot slots identical to MapData after replacing PackedArrays.
	await context._generator._yield_generation_frame()
	# dots-boot-facade-2026-10：资源勘测 → 槽发布 → 研究信号 → 生态播种四段原本是
	# 「GDScript 造数组 → native 单 pass」，每段之间还要 `_yield_generation_frame()`
	# 让帧（Web 非 headless 下每次等 4 帧）。现在整链压成一次 `run_boot_facade_pass`：
	# habitat 掩码 / 河口羽流两段 per-cell 循环搬进 C++，中间量不出语言边界。
	# native 不可用（旧 DLL）或任一段被拒 → 逐段走下面原链路，行为逐位不变。
	context._generator._loading_profile_step("_bootstrap_world_facades")
	var _fused_boot = context._generator._bootstrap_world_facades(map, cfg)
	context._generator._loading_profile_step("natural_resource_deposits")
	if not _fused_boot:
		await context._generator._get_map_resource_initializer()._bootstrap_natural_resource_deposits(map, cfg, true)
	await context._generator._yield_generation_frame()
	context._generator._loading_profile_step("publish_natural_resources")
	context._generator._get_map_resource_initializer()._publish_bootstrapped_natural_resources_to_runtime(map)
	if not _fused_boot:
		await context._generator._yield_generation_frame()
		context._generator._loading_profile_step("resource_research_signals")
		context._generator._append_natural_resource_research_signals(map)
		await context._generator._yield_generation_frame()
		context._generator._loading_profile_step("seed_bio_occupancy")
		context._generator._seed_bio_occupancy(map)
	context._generator._loading_profile_step("facade_bootstrap_tail_done")
	if not context._generator._gameplay_start_context.is_empty():
		var gameplay_config: Dictionary = context._generator._gameplay_start_context.get("config", {})
		var country_config: Dictionary = gameplay_config.get("country", {})
		context._generator._gameplay_start_report = await context._generator.StartLocationPolicyScript.select_and_prepare_cooperative(
			map,
			world,
			int(cfg.seed),
			int(country_config.get("foreign_count", NewGameConfig.DEFAULT_FOREIGN_COUNT)),
			String(country_config.get("name", "新国家")), context._generator._loading_frames)
		if not bool(context._generator._gameplay_start_report.get("ok", false)):
			return
		context._generator._gameplay_start_context.merge(context._generator._gameplay_start_report, true)
		if context._generator._get_map_country_initializer()._gameplay_start_has_resource_topups(context._generator._gameplay_start_report):
			await context._generator._yield_generation_frame()
			context._generator._loading_profile_step("_append_natural_resource_research_signals")
			context._generator._append_natural_resource_research_signals(map)
			await context._generator._yield_generation_frame()
			context._generator._loading_profile_step("_publish_bootstrapped_natural_resources_to_runtime")
			context._generator._get_map_resource_initializer()._publish_bootstrapped_natural_resources_to_runtime(map)
	# ─── Phase F.1：DCWorldExt 接管 weather field solve（charter §7 P0）──
	# 把 ext 句柄一次性下发给 WeatherSystem。ext 为 null（gdext 未编译 / 未 bind）
	# 时 WeatherSystem 自动走 GDScript legacy path，对 caller 完全透明。
	#
	# dots-flag-prune-pr1 (2026-05-22)： use_gdext_weather_field/distribute/summary
	# /weather_front 四个 flag 已删除——enabled 参数现恒传 true，WeatherSystem 内部
	# 走 ext+has_method+sig 探测单边分支。
	# PR-2.1.6：第 4 个参数注入 GDScript DCWorld，让 weather field commit 写路径
	# 走 world.write_f32_indexed。详见 master 手册 §3.9。
	if context._generator._weather_system != null and context._generator._weather_system.has_method("configure_gdext_acceleration"):
		var cp_f1 = context._generator._c()
		context._generator._weather_system.configure_gdext_acceleration(context._generator._data_core_world_ext, true, cp_f1, context._generator._data_core_world)
	await context._generator._get_map_rules_initializer()._setup_effect_runtime(cp_sched)
	if context._generator._loading_frames.canceled:
		context._generator._get_map_rules_initializer()._release_loading_catalog_context()
		return
	# Independent ECONOMY_GRAPH is registered after EffectRuntime and before the
	# native/legacy daily fork, so both environmental authority modes share one
	# economy schedule.
	await context._generator._yield_generation_frame()
	context._generator._loading_profile_step("_setup_economy_runtime")
	await context._generator._get_map_country_initializer()._setup_economy_runtime(map, cfg, cp_sched)
	context._generator._get_map_rules_initializer()._release_loading_catalog_context()
	if context._generator._loading_frames.canceled:
		return
	context._generator._season_refresh_job = context._generator.SeasonRefreshSystemScript.new(context._generator, map, world)
	context._generator._sus.configure_job_from_profile(context._generator._season_refresh_job, cp_sched)
	context._generator._runtime_register_system(context._generator._season_refresh_job)
	# dots-flag-prune-pr1 (2026-05-22)：ocean_current_refresh_seasons E 类废字段已
	# 从 ClimateProfile 删除——原有的 deprecated warning 不再需要。SUS 路径仅
	# 读 ocean_currents_period_ticks / ocean_currents_slice_count。
	var cp = context._generator._c()
	var enum_atlas_stride: int = 2
	var dynamic_visual_atlas_stride: int = context._generator._dyn_atlas_upload_stride
	if cp != null:
		if cp.get("enum_atlas_upload_stride") != null:
			enum_atlas_stride = clampi(int(cp.enum_atlas_upload_stride), 1, 8)
		if cp.get("dynamic_visual_atlas_upload_stride") != null:
			dynamic_visual_atlas_stride = clampi(int(cp.dynamic_visual_atlas_upload_stride), 1, 8)
	context._generator._dyn_atlas_upload_stride = dynamic_visual_atlas_stride
	# 注册 OceanCurrentsJob。
	var wind_period_ticks: int = context._generator._ocean_daily_wind_period_ticks_for(cp)
	var ocean_period_ticks: int = 30
	var slice_count: int = 10
	if cp != null:
		ocean_period_ticks = max(1, int(cp.ocean_currents_period_ticks))
		slice_count = max(1, int(cp.ocean_currents_slice_count))
	# Physical Wind & Ocean Circulation：把激活的 ClimateProfile 引用注入 cfg，
	# 让 MapBaker 在切片烘焙时（OceanCurrentsJob.run_slice 调用 baker.bake_*_slice）
	# 通过 cfg.climate_profile 读到 physical_circulation_enabled 等开关。null 时
	# 走 ny-only 旧路径。
	if cfg != null:
		cfg.climate_profile = cp
	# OceanCurrentsSystem 仍是 delegate wrapper；_ocean_currents_job 指向内部
	# job，保持 on_commit / season_phase_getter / 诊断访问路径不变。
	var ocean_sys = context._generator.OceanCurrentsSystemScript.new(
			context._generator._baker, map, world, cfg, hex_size, wind_period_ticks, slice_count, ocean_period_ticks)
	context._generator._ocean_currents_system = ocean_sys
	context._generator._ocean_currents_job = ocean_sys.get_inner()
	context._generator._sus.configure_job_from_profile(ocean_sys, cp, false, &"ocean_currents", 1)
	context._generator._sus.configure_job_from_profile(context._generator._ocean_currents_job, cp, false, &"ocean_currents", 1)
	# A method Callable borrows context; an owned lambda retains the generator.
	context._generator._ocean_currents_job.on_commit = context._generator._compute_ocean_currents.bind(map, world, hex_size)
	if context._generator._world_clock_ref != null:
		context._generator._ocean_currents_job.season_phase_getter = Callable(context._generator._world_clock_ref, "season_phase")
	context._generator._runtime_register_system(ocean_sys)
	if context._generator._ocean_currents_job != null:
		context._generator._ocean_currents_job.data_core_world_ext = context._generator._data_core_world_ext
		context._generator._ocean_currents_job.climate_ran_this_tick_getter = Callable(context._generator, "did_refresh_climate_run_this_tick")
		context._generator._ocean_currents_job.climate_slice_ms_getter = Callable(context._generator, "last_refresh_climate_slice_ms")
	# NaturalResourceDailySystem：自然资源每日生成/衰减（独立于气候的资源计算任务）。
	# **必须在 native/legacy 分叉之前注册**，作为与 season_refresh / ocean_currents 同级
	# 的"保留边界 job"——否则 native_daily ACTIVE 时下方 early-return 会跳过 legacy 段的
	# 注册，资源 reserve 永不演化（玩家观察不到生物质变化）。
	# reads cell.temp / cell.moisture（native_daily_sim 或 refresh_climate_daily 写）
	# → build_topology 自动排在气候之后；不加硬 depends_on（避免切片 job 长期 dep_pending）。
	var natural_resource_stride: int = 1
	if cp != null and cp.get("natural_resource_daily_stride") != null:
		natural_resource_stride = max(1, int(cp.natural_resource_daily_stride))
	context._generator._natural_resource_daily_job = context._generator.NaturalResourceDailySystemScript.new(context._generator, map, natural_resource_stride)
	context._generator._sus.configure_job_from_profile(context._generator._natural_resource_daily_job, cp, false, &"natural_resource_daily", natural_resource_stride)
	context._generator._runtime_register_system(context._generator._natural_resource_daily_job)
	context._generator._bio_occupancy_daily_job = context._generator.BioOccupancyDailySystemScript.new(context._generator, map, 8)
	context._generator._sus.configure_job_from_profile(context._generator._bio_occupancy_daily_job, cp, false, &"bio_occupancy_daily", 1)
	context._generator._runtime_register_system(context._generator._bio_occupancy_daily_job)
	# military_daily 同样必须注册在 native/legacy 分叉之前（contract §0.1）。整图
	# ACTIVE 时它的 should_run 恒 false，由 WorldRuntimeHost 在已提交日之后补跑；
	# 但注册本身要在分叉前完成，否则 ACTIVE→SHADOW/legacy 降级后没有任何 Military
	# 日阶段。未配置（旧 DLL / 目录缺失）时 _military_daily_job 保持 null。
	context._generator._get_map_country_initializer()._maybe_register_military_system()
	await context._generator._yield_generation_frame()
	context._generator._loading_profile_step("if _try_register_native_daily_sim_job")
	if context._generator._try_register_native_daily_sim_job(map, world):
		if OS.is_debug_build():
			print("[native_daily] ACTIVE: registered native_daily_sim + natural_resource_daily + bio_occupancy_daily; retained season_refresh + ocean_currents boundary jobs")
		context._generator._register_visual_upload_jobs(map, world, hex_size, cp_sched)
		context._generator._runtime_build_topology("native_daily path")
		if context._generator._sus_bootstrap == null:
			context._generator._sus_bootstrap = context._generator.DCSusSystemsBootstrapScript.new(context._generator)
		await context._generator._yield_generation_frame()
		context._generator._loading_profile_step("_sus_bootstrap.attach_post_setup")
		context._generator._sus_bootstrap.attach_post_setup(context._generator, context._generator._sus)
		return

	# 注册 ClimateDailySystem + WeatherDCSystem。
	# stride 仍读取 ClimateProfile 的 cadence 字段；实际 phase/bucket 由
	# DCSystemScheduler.configure_job_from_profile() 统一解释。
	var climate_stride: int = 1
	var sea_ice_stride: int = 1
	if cp != null:
		climate_stride = max(1, int(cp.daily_climate_refresh_stride))
		if cp.get("sea_ice_daily_stride") != null:
			sea_ice_stride = clampi(int(cp.sea_ice_daily_stride), 1, 8)
	# ClimateDailySystem：写连续气候基线（priority 100）
	var climate_phase_getter := Callable()
	if context._generator._world_clock_ref != null:
		climate_phase_getter = Callable(context._generator._world_clock_ref, "season_phase")
	var climate_sys = context._generator.ClimateDailySystemScript.new(context._generator, map, climate_phase_getter, climate_stride)
	context._generator._refresh_climate_daily_job = climate_sys.get_inner()
	context._generator._sus.configure_job_from_profile(climate_sys, cp, false, &"refresh_climate_daily", climate_stride)
	context._generator._sus.configure_job_from_profile(context._generator._refresh_climate_daily_job, cp, false, &"refresh_climate_daily", climate_stride)
	context._generator._runtime_register_system(climate_sys)
	# 注：natural_resource_daily 已在 native/legacy 分叉前作为保留边界 job 统一注册
	# （见上方 _try_register_native_daily_sim_job 之前的段落），此处不再重复注册。
	context._generator._sea_ice_daily_job = null
	if cp != null and cp.get("sea_ice_independent_system_enabled") != null \
			and bool(cp.sea_ice_independent_system_enabled):
		context._generator._sea_ice_daily_job = context._generator.SeaIceDailySystemScript.new(context._generator, map, climate_phase_getter, sea_ice_stride)
		context._generator._sus.configure_job_from_profile(context._generator._sea_ice_daily_job, cp, false, &"sea_ice_daily", sea_ice_stride)
		context._generator._runtime_register_system(context._generator._sea_ice_daily_job)
	if context._generator._ocean_currents_job != null:
		context._generator._ocean_currents_job.data_core_world_ext = context._generator._data_core_world_ext
		context._generator._ocean_currents_job.climate_ran_this_tick_getter = Callable(context._generator, "did_refresh_climate_run_this_tick")
		context._generator._ocean_currents_job.climate_slice_ms_getter = Callable(context._generator, "last_refresh_climate_slice_ms")
	context._generator._enum_atlas_upload_job = context._generator.EnumAtlasUploadSystemScript.new(context._generator, context._generator._baker, map, world, hex_size, enum_atlas_stride, context._generator._data_core_world_ext)
	context._generator._sus.configure_job_from_profile(context._generator._enum_atlas_upload_job, cp, true, &"enum_atlas_upload", enum_atlas_stride)
	context._generator._runtime_register_system(context._generator._enum_atlas_upload_job)
	# WeatherRefreshJob：天气推进 + 反馈链（priority 150，依赖 refresh_climate_daily）
	var season_idx_getter := Callable()
	var season_phase_getter := Callable()
	var climate_anomaly_getter := Callable()
	if context._generator._world_clock_ref != null:
		season_idx_getter = Callable(context._generator._world_clock_ref, "season_index")
		season_phase_getter = Callable(context._generator._world_clock_ref, "season_phase")
		# climate_anomaly 是 WorldClock 的普通 property、不是方法，
		# Callable 只能绑方法，这里用 lambda 包一层读。
		var wc_ref = context._generator._world_clock_ref
		climate_anomaly_getter = func() -> float:
			return float(wc_ref.climate_anomaly)
	var weather_dc_system = context._generator.WeatherDCSystemScript.new(
		context._generator, map, world,
		season_idx_getter, season_phase_getter, climate_anomaly_getter,
		1
	)
	context._generator._weather_refresh_system = weather_dc_system
	context._generator._weather_refresh_job = weather_dc_system.get_inner()
	context._generator._sus.configure_job_from_profile(weather_dc_system, cp, false, &"weather_refresh", 1)
	context._generator._sus.configure_job_from_profile(context._generator._weather_refresh_job, cp, false, &"weather_refresh", 1)
	# Weather=0 fix（2026-05-13，与 weather_refresh_job.gd line 498-507 同源
	# 历史教训）：原 `_weather_refresh_job.depends_on.append(&"season_refresh")`
	# 把 weather 硬挂在 season_refresh 上，但 season 是 11-stage 切片 round
	# （每 round 前 10 个 stage 返回 done=false），weather 在 SUS 优先级序里
	# 排在 season 之后（150 > 50），只要 season 切片中 weather 立刻 dep_pending。
	# 实测 30 tick 内 weather ran=0（详见 docs/architecture/current-state.md 排查记录）。
	#
	# 真实依赖关系：weather hot loop 读的是 cell.temperature / moisture / wind /
	# has_river 等慢层 baseline——这些字段跟 season 切换的"植被/cover redecide"
	# 是正交的；即使 weather 读到旧 base_vegetation 一两 tick 也不影响 weather
	# field 求解（与 weather_refresh_job.gd 注释里描述的 climate dep 解除是同
	# 一类问题）。所以 weather 不应阻塞在 season 上。
	# _weather_refresh_job.depends_on.append(&"season_refresh")  # ← 移除（保留作历史记录）
	context._generator._runtime_register_system(weather_dc_system)

	# WeatherLUT 发布直接内联在 WeatherRefreshJob 的 commit/merged/direct 完成点，避免独立 job
	# 的 should_run 相位早于 weather_refresh 时读到 ran_this_tick=false，也避免额外每 tick 扫描。

	# 海冰主视觉数据通道：水路径 shader 从 dyn_atlas_smooth_atlas.A 通道读取
	# sea_ice_fraction（与 UI/info_panel 同源；sea-ice-render-source-unify 阶段 A）。
	# 不再需要 sea_ice_atlas_upload 周期性光栅化 / GPU 上传作为 shader 主源；
	# 保留 sea_ice_tex 作为兼容空纹理，但不注册 SUS job。
	context._generator._last_sea_ice_atlas_upload_breakdown = context._generator._disabled_sea_ice_atlas_report("dyn_atlas_smooth_a_unified_source")
	# plan/dirty-push-atlas-encode 阶段 D：把 cp 传给 system，让其入口可调
	# DCFeatureFlags.is_on(&"dirty_push_enabled", cp) 决定是否走 mask 路径。
	context._generator._dynamic_visual_atlas_upload_job = context._generator.DynamicVisualAtlasUploadSystemScript.new(
			context._generator._baker, map, world, context._generator._dyn_atlas_upload_stride, cp, context._generator._data_core_world,
			context._generator._data_core_world_ext)
	context._generator._sus.configure_job_from_profile(context._generator._dynamic_visual_atlas_upload_job, cp, true, &"dynamic_visual_atlas_upload", context._generator._dyn_atlas_upload_stride)
	context._generator._runtime_register_system(context._generator._dynamic_visual_atlas_upload_job)
	context._generator._try_register_native_environment_runtime_system(map, cp)

	var topo_ok: bool = context._generator._runtime_build_topology("cycle detected; fast tick will not run")
	if topo_ok and OS.is_debug_build():
		print("[map_generator] DCSystemScheduler topology built: %s" % str(context._generator._sus.topology_order_names()))

	# Phase 1.4 — sus_systems_bootstrap attach。让 main.gd / debug overlay 能通过
	# generator.get_sus_bootstrap() 拿到 scheduler 引用做诊断 / 未来直接 tick。
	# 注意：实际注册逻辑仍在本函数内（Phase 3.4 拆分时才搬到 bootstrap.bootstrap()）。
	if context._generator._sus_bootstrap == null:
		context._generator._sus_bootstrap = context._generator.DCSusSystemsBootstrapScript.new(context._generator)
	await context._generator._yield_generation_frame()
	context._generator._loading_profile_step("_sus_bootstrap.attach_post_setup")
	context._generator._sus_bootstrap.attach_post_setup(context._generator, context._generator._sus)
	if OS.is_debug_build():
		print("[map_generator] %s" % context._generator._sus_bootstrap.status_one_liner())
