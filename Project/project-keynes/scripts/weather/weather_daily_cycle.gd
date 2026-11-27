extends RefCounted

## Owns the weather calculation calls within a day and the field slice handoffs.

# 历史目标：把本文件拆到 ≤200 行。实际只完成了 hot-loop 抽出，本文件至今仍是
# 天气子系统的「编排 + 配置中心」（数千行 = 已知上帝类，见下方职责清单）。
#
# ✅ 已落地的拆分：
#   weather/field_solver.gd (DCWeatherFieldSolver)
#       已接管天气场 slice hot loop：begin_slice / run_slice / commit /
#       _solve_weather_field + 邻居/上风/抬升/辐合/海洋异常 helper。
#       本文件的 begin/run/commit_weather_field_solve 仅是薄转发入口。
#   weather/front_advect.gd (DCWeatherFrontAdvect)
#       已接管 front 推进 + cyclone wake。
#
# ❌ 计划但未落地（仍在本文件，是后续「做减法」的目标）：
#   - _distribute_weather_field_to_cells（field→cell 反馈）→ 计划 feedback.gd
#   - _build_field_summary_fronts（field→front 聚类）→ 计划 summary_builder.gd
#   - _spawn_random_front / _build_front_at（legacy front 对象层）
#
# 本文件当前实际承担的职责（≥10 个关注点）：配置中心(_field_* + configure_weather_field)、
# ClimateProfile 同步、C++ knobs 三件套构造、GDExtension 调度 + A/B verify、
# 天气类型分类、distribute 反馈、summary 聚类、legacy front 路径、查询 API。
#
# ⚠ 双份镜像维护铁律：天气物理公式在 field_solver.gd(GDScript fallback) 与
#   world_ext.cpp::run_weather_field_solve_pass(C++ 权威) 各有一份，改任一侧
#   必须同步另一侧，并跑 set_field_verify_mode(true) 对账（默认容差 1e-4）。
#
# ─── 原始职责说明（保留）────────────────────────────────────────────────
#
# 职责：
#   1. 维护一个最多 MAX_FRONTS 个活动 WeatherFront 的队列
#   2. 每天 tick：
#      a) 推进所有 front（advect by wind_field, decay intensity, age++）
#      b) 回收 dead front
#      c) 按 season + 全球气候 spawn 新 front（带类型分布）
#      d) 把每个 cell 的"被覆盖到的最强 front"写到 cell.current_state.weather/intensity
#      e) 根据 weather 临时调整 cell.moisture / temperature（覆盖 current_state.*）
#      f) 必要时短期改写 cell.cover（BLIZZARD → SNOW、MONSOON/STORM → FLOODING）
#   3. 提供 query_at(world_pos) 与 pack_to_uniforms() 让 UI / shader 直接复用
#
# 设计原则：
#   - 不写回 base_*：天气是临时性的，年度漂移（Phase 8）只看 base_moisture，
#     这样 weather 不会污染长期生态记忆，玩家手感 = "天气是表层、生态是底层"
#   - max-merge 而非线性叠加：避免双暴雨之类的数值爆炸
#   - 与 WorldClock seed 解耦：自己持有 RNG，可独立 seed → 复盘 / 多人同步友好
#   - 仅 max 16 fronts：可一次塞进 shader uniform 数组，每 fragment 16 次距离测试
#     就能完整渲染所有天气效果

static func init(weather: WeatherSystem, seed_val: int, world_bounds: Rect2, hex_size: float) -> void:
	weather._rng = RandomNumberGenerator.new()
	weather._rng.seed = seed_val ^ 0xBEEF1234
	weather._world_bounds = world_bounds
	weather._hex_size = hex_size
	weather._active_fronts.clear()
	weather._day_counter = 0
	# Continuity-fix：换地图/重 init 时必须清掉跨 tick 继承状态，
	# 否则旧地图的 HexCell 弱引用 + 旧 cluster 中心会污染新地图的首帧聚类。
	weather._prev_summary_membership.clear()
	weather._prev_summary_seeds.clear()
	# dots-monolith-split §1.1：sub-module 实例化（owner 引用 self，
	# sub-module 通过 owner 访问 ocean_current_perturbation / _active_fronts /
	# _hex_size / _cyclone_wake_days 等共享状态）。
	if weather._advect == null:
		weather._advect = DCWeatherFrontAdvect.new(weather)
	if weather._front_spawn == null:
		weather._front_spawn = DCWeatherFrontSpawn.new(weather)
	if weather._native_bridge == null:
		weather._native_bridge = weather.DCWeatherNativeBridge.new()
	# dots-monolith-split §1.2：field_solver 实例化。已接管天气场 slice hot loop
	# （begin_slice/run_slice/commit/_solve_weather_field）；本类对应函数仅薄转发。
	if weather._field_solver == null:
		weather._field_solver = DCWeatherFieldSolver.new(weather)
	if weather._feedback == null:
		weather._feedback = DCWeatherFeedback.new(weather)
	if weather._summary_builder == null:
		weather._summary_builder = DCWeatherSummaryBuilder.new(weather)
	else:
		weather._summary_builder.reset()


# --- 每日 tick（由 MapGenerator.refresh_daily 调用） ---

# season_idx: 0=春 1=夏 2=秋 3=冬
# climate_anomaly: 全球长期温度偏移 [-0.2, +0.2]
# season_phase: 连续浮点 [0,4)；如果 caller 不传则 fallback 到 season_idx + 0.5。
# 返回当前活动 front 的快照（给 main / renderer 上传 shader uniform 用）


static func tick_one_day(weather: WeatherSystem, map: MapData, world: WorldData, season_idx: int, climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	if map == null or world == null:
		return weather._active_fronts
	weather._day_counter += 1
	weather._current_map_for_tick = map
	# 缓存当前轨道相位给 wind_fn / spawn 的兼容签名。
	# fallback：如果 caller 没提供（旧调用方兼容），按 season_idx 取季中点。
	weather._season_phase = season_phase if season_phase >= 0.0 else float(season_idx) + 0.5

	# wind_fn 优先读 per-cell 风场；fallback 只给无风场时的纬向基线。
	var bounds := weather._world_bounds
	var sp := weather._season_phase
	var map_ref := map
	var self_ref := weather
	var wind_fn := func(pos: Vector2) -> Vector2:
		var ny: float = 0.5
		if bounds.size.y > 0.001:
			ny = clampf((pos.y - bounds.position.y) / bounds.size.y, 0.0, 1.0)
		return self_ref._sample_terrain_wind(map_ref, world, pos, ny, sp)

	if weather._weather_field_enabled:
		weather.begin_weather_field_solve(map, world, season_idx, climate_anomaly, weather._season_phase, false)
		while true:
			var slice_result: Dictionary = weather.run_weather_field_solve_slice(2147483647)
			if bool(slice_result.get("done", true)):
				break
		return weather.commit_weather_field_solve()

	# Daily-sim perf instrumentation：带埋点的 advance / spawn / distribute / cyclone 四段。
	var t_us0: int = Time.get_ticks_usec()

	# 1) 推进所有 front + 2) 回收 dead 与出图 front
	# dots-monolith-split §1.1 第 2 步：130 行内联实现已迁出至
	# scripts/weather/front_advect.gd::tick_advance_fronts(map, wind_fn)。
	# 业务等价：emergent_coupling 预算 + F.6 C++ 快路径 + GDScript fallback + reap。
	var advance_ms: float = weather._advect.tick_advance_fronts(map, wind_fn)

	# 3) Spawn 新 front
	t_us0 = Time.get_ticks_usec()
	var spawn_prob: float = 0.34
	for i in range(weather.SPAWN_TRIES_PER_DAY):
		if weather._active_fronts.size() >= weather.MAX_FRONTS:
			break
		if weather._rng.randf() < spawn_prob:
			var f: WeatherFront
			if weather._emergent_coupling:
				f = weather._spawn_emergent_front(map, world, season_idx, climate_anomaly)
			else:
				f = weather._spawn_random_front(world, season_idx, climate_anomaly)
			if f != null:
				weather._active_fronts.append(f)
	var spawn_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0

	# 4) 把当前所有 front 影响分发到每个 cell
	t_us0 = Time.get_ticks_usec()
	weather._distribute_to_cells(map)
	var distribute_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0

	# 5) Systemic Ocean Currents：台风尾迹扰动（可选，默认关闭）
	# 在强海上风暴（STORM + on_water + intensity > 0.8）点注入旋转扰动向量，
	# 随后每天线性衰减，_cyclone_wake_days 后清零。仅 CPU 端维护；渲染消费方
	# 可按需扩展（例如上传 RG8 overlay 让 shader 与主流场相加）。
	var cyclone_ms: float = 0.0
	if weather._cyclone_wake_enabled:
		t_us0 = Time.get_ticks_usec()
		# dots-monolith-split §1.1：cyclone_wake 已迁出至 DCWeatherFrontAdvect。
		weather._advect.tick_cyclone_wake(map)
		cyclone_ms = (Time.get_ticks_usec() - t_us0) / 1000.0

	weather._last_breakdown = {
		"advance_ms": advance_ms,
		"spawn_ms": spawn_ms,
		"distribute_ms": distribute_ms,
		"cyclone_ms": cyclone_ms,
	}
	weather._last_breakdown.merge(weather._front_diagnostic_counts(weather._active_fronts), true)
	weather._last_breakdown.merge(weather._mark_weather_commit_tick(), true)
	weather._current_map_for_tick = null
	return weather._active_fronts

# --- 内部：按 season + 经纬度 spawn 一个新 front ---


static func uses_weather_field(weather: WeatherSystem) -> bool:
	return weather._weather_field_enabled


static func is_weather_field_solve_active(weather: WeatherSystem) -> bool:
	return weather._field_solver._field_slice_active


static func begin_weather_field_solve(weather: WeatherSystem, map: MapData, world: WorldData, season_idx: int, climate_anomaly: float, season_phase: float = -1.0, count_day: bool = true, for_worker_knobs_only: bool = false) -> void:
	# dots-monolith-split §1.2 / PR-6：切片初始化主体已搬迁到
	# scripts/weather/field_solver.gd::begin_slice()。本侧仅作为外部 caller
	# (map_generator.gd / weather_refresh_job 等 SUS job) 的薄转发入口。
	weather._field_solver.begin_slice(map, world, season_idx, climate_anomaly, season_phase, count_day, for_worker_knobs_only)


static func run_weather_field_solve_slice(weather: WeatherSystem, cell_budget: int) -> Dictionary:
	# dots-monolith-split §1.2 / PR-6：切片单步主体（含 DCWorldExt fast path
	# 与 GDScript fallback hot loop）已搬迁到 scripts/weather/field_solver.gd::run_slice()。
	return weather._field_solver.run_slice(cell_budget)


static func commit_weather_field_solve(weather: WeatherSystem) -> Array[WeatherFront]:
	# dots-monolith-split §1.2 / PR-5：149 行 commit 主体已整体搬迁到
	# scripts/weather/field_solver.gd::commit()。weather_system 本侧末端仅作为
	# tick_one_day 调用入口作薄转发，然后 PR-7 可考虑进一步清理。
	return weather._field_solver.commit()

# ─── Phase F.1：DCWorldExt 路径 helper ───────────────────────────────────
# 把 GDScript 端的所有 cp/profile/_field_* 旋钮、世界边界、预先打包好的
# PackedArray 输入打包成一个 Dictionary 交给 C++。所有 key 名与 world_ext.h
# 的 F.1 文档块一一对应；任何 key 缺失都会让 C++ return -1.0 透明 fallback。


static func run_synoptic_advance_pass(weather: WeatherSystem, map: MapData, world: WorldData) -> float:
	if weather._data_core_world_ext == null or not weather._use_gdext_weather_field:
		return -1.0
	var knobs: Dictionary = weather._field_solver._field_slice_native_knobs
	if knobs.is_empty():
		# native_knobs 未就绪 → 自建一份(合并/切片路径 begin 已设 _field_slice_* 状态)。
		var n_cells: int = map.cell_count() if map != null and map.has_method("cell_count") else 0
		if n_cells <= 0:
			return -1.0
		knobs = weather._build_weather_field_knobs(map, world, n_cells, 0, n_cells)
	if knobs.is_empty():
		return -1.0
	var rc: float = float(weather._data_core_world_ext.run_synoptic_advance_pass(knobs))
	return rc


static func build_field_knobs_for_worker(weather: WeatherSystem, map: MapData, world: WorldData,
		season_idx: int, climate_anomaly: float,
		season_phase: float, defer_thermal_equator: bool = false) -> Dictionary:
	if weather._data_core_world_ext == null or map == null or world == null:
		return {}
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		return {}
	weather._current_map_for_tick = map
	weather._field_solver.begin_slice(map, world, season_idx, climate_anomaly,
		season_phase, true, true, defer_thermal_equator)
	var knobs: Dictionary = {}
	if weather._field_solver._field_slice_fast_indexed:
		# The weather stage needs indexed neighbors. Copy the resident knobs
		# before clearing the solver because both names refer to one dictionary.
		var resident := weather._field_solver._field_slice_native_knobs
		knobs = resident.duplicate(false) if not resident.is_empty() \
			else weather._build_weather_field_knobs(map, world, n_cells)
		if defer_thermal_equator:
			knobs["thermal_equator_capture_bounds"] = weather._world_bounds
	weather._clear_weather_field_slice_state()
	weather._current_map_for_tick = null
	return knobs


# begin_weather_field_solve 的 refresh_convergence 按 _field_solve_tick 调用次数取
# 奇偶；worker 的 capture 会因失败重试或其他调用多走一步，所以 worker 侧改按
# 捕获日取同一个 stride。


static func convergence_refresh_due_on_day(weather: WeatherSystem, day: int) -> bool:
	return posmod(day - 1, maxi(1, weather._field_convergence_refresh_stride)) == 0


# ACTIVE climate authority：worker 侧 distribute stage 的 knobs 入口。
#
# 生产路径经 build_unified_fast_tick_weather_knobs 一次拿 field+distribute+summary
# 三组，但那条会先调 begin_weather_field_solve 初始化 field slice state；worker
# 权威下生产的 weather 段是被抑制的，那份 state 没人消费。这里只暴露 distribute
# 段，与生产共用同一个 builder —— 那些 snow/flood 阈值有一半是 builder 里的硬编码
# 常量，在 map_generator 侧重抄一份等于给它们开第二个漂移入口。
#
# 无副作用：_build_weather_distribute_knobs 只读 map 与 profile 派生的标量，
# 唯一的写是 _dist_acc_snow_cache / _dist_pre_cover_cache 的重建，而那是幂等的。


static func build_distribute_knobs_for_worker(weather: WeatherSystem, map: MapData, n_cells: int) -> Dictionary:
	if map == null or n_cells <= 0:
		return {}
	return weather._build_weather_distribute_knobs(map, n_cells)


# 调用 C++ 端 run_weather_distribute_pass。返回 Dictionary {"elapsed_ms", "cover_dirty",
# "changed_cells"(PackedInt32Array), "accumulated_snow_days"/"pre_snow_cover"(已被 C++ 改写)}。
# elapsed_ms < 0 表示 precondition 失败，调用方走 GDScript fallback。


static func _sync_weather_distribute_cache_to_cells(weather: WeatherSystem, map: MapData, n_cells: int) -> void:
	if map == null:
		return
	if weather._dist_acc_snow_cache.size() != n_cells or weather._dist_pre_cover_cache.size() != n_cells:
		return
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var limit: int = mini(n_cells, cells.size())
	for i in range(limit):
		var c: HexCell = cells[i]
		c.accumulated_snow_days = weather._dist_acc_snow_cache[i]
		c.pre_snow_cover = weather._dist_pre_cover_cache[i]
		c.current_state["cover"] = int(c.cover)

# ─── Weather Hot-Path：summary fronts pass GDExt 接入（任务 6）────────────
# C++ pass 要求的 SoA + 静态查表数据由 _build_weather_summary_knobs 一次构造。
# 输出：Dictionary{ elapsed_ms: float, fronts: Array[Dictionary] }；GDScript 端
# 把 Array[Dictionary] 解包为 Array[WeatherFront]（与原 _build_field_summary_fronts
# 的返回签名严格一致），让 field_solver 调用方完全无感。
# elapsed_ms < 0 → fallback 到 GDScript（push_warning 一次）。


static func _clear_weather_field_slice_state(weather: WeatherSystem) -> void:
	weather._field_solver._field_slice_active = false
	weather._field_solver._field_slice_map = null
	weather._field_solver._field_slice_world = null
	weather._field_solver._field_slice_season_idx = 0
	weather._field_solver._field_slice_climate_anomaly = 0.0
	weather._field_solver._field_slice_cursor = 0
	weather._field_solver._field_slice_refresh_convergence = false
	weather._field_solver._field_slice_fast_indexed = false
	weather._field_solver._field_slice_cells = []
	weather._field_solver._field_slice_cell_pos = PackedVector2Array()
	weather._field_solver._field_slice_neighbor_indices = PackedInt32Array()
	weather._field_solver._field_slice_prev_vapor = PackedFloat32Array()
	weather._field_solver._field_slice_prev_precip = PackedFloat32Array()
	weather._field_solver._field_slice_next_vapor = PackedFloat32Array()
	weather._field_solver._field_slice_next_cloud = PackedFloat32Array()
	weather._field_solver._field_slice_next_cloud_water = PackedFloat32Array()
	weather._field_solver._field_slice_next_precip = PackedFloat32Array()
	weather._field_solver._field_slice_next_instability = PackedFloat32Array()
	weather._field_solver._field_slice_next_intensity = PackedFloat32Array()
	weather._field_solver._field_slice_next_convergence = PackedFloat32Array()
	weather._field_solver._field_slice_next_type = PackedInt32Array()
	weather._field_solver._field_slice_solve_ms = 0.0
	weather._field_solver._field_slice_last_ms = 0.0
	weather._field_solver._field_slice_results_in_soa = false
	weather._field_solver._field_slice_native_convergence_boost = false
	weather._field_solver._field_slice_temp_anom = PackedFloat32Array()
	weather._field_solver._field_slice_wrap_width_x = 0.0
	weather._field_solver._field_slice_cell_pos_scale = 1.0
	weather._field_solver._field_slice_native_knobs.clear()

	# dots-monolith-split §1.2 / PR-6：250 行 dead code 已删除；逻辑入口
	# 整体下沉到 scripts/weather/field_solver.gd::solve()，内部走
	# begin_slice → 循环 run_slice → commit。
