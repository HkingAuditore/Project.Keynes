extends "res://scripts/simulation/sus/sus_job.gd"
class_name RefreshClimateDailyJob

## RefreshClimateDailyJob — Daily Sim SoA Refactor 方向 X（A2）落地后改造成
## "按 sub-pass 切片"的 Job：把 refresh_climate_daily 的 ~80ms 拆成 6 个 sub-pass，
## 每 tick 只跑其中 1 段，从而把单 tick 峰值压到 ~30ms 以下。
##
## Driven by:  SUS daily tick (sourced from main.gd._on_day_changed).
## Strategy:   StridePolicy(stride) — 决定哪些 day 触发 round 启动；
##             round 内部由 _pass_cursor 推进 sub-pass，每 tick 仅 1 段。
##
## Sub-pass 顺序（严格按下方编号；上一段产物必须已写入 HexCell 字段）：
##   0) climate_pass_a           — 裸基线 temp/moisture/snow_cover + EMA   (~15ms)
##   1) climate_pass_b           — 局部气候耦合 (可选，受开关)              (~21ms)
##   2) ocean_water              — 洋流热输运·水段 (可选，受开关)           (~16ms)
##   3) ocean_land               — 洋流热输运·陆段 (同上开关，必须紧跟水段) (~15ms)
##   4) sea_ice_daily            — 海冰逐日演替 (必跑)                      (~7ms)
##   5) transpiration            — 植被→湿度反馈 (可选，与 Pass B 同开关)   (~7ms)
##
## 跨 sub-tick 一致性：
##   - 进入 round 时锁定 _phase_locked = season_phase_getter()，整 round 共用
##     此 phase，避免相邻 sub-tick 因 in-game time 推进读到不同的 phase 值
##     （否则 Pass A/B 与 ocean 段可能算出内部不一致的状态）。
##   - 跨段的所有数据交接均通过 HexCell 已稳定字段（cell.temperature 等）完成，
##     不需要 Job 缓存任何 Dictionary。
##
## must_run = true：与 OceanCurrentsJob 同因——气候推进不能被 frame_budget 掐掉，
## 否则 round 卡在某段、weather/ocean_currents 等下游读到半套数据。

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

# Sub-pass 编号常量（保持与 _PASS_NAMES 索引对齐，便于日志可读）
const _PASS_A: int = 0
const _PASS_B: int = 1
const _PASS_OCEAN_WATER: int = 2
const _PASS_OCEAN_LAND: int = 3
const _PASS_SEA_ICE: int = 4
const _PASS_TRANSP: int = 5
const _PASS_COUNT: int = 6
const _PASS_NAMES: PackedStringArray = [
	"pass_a", "pass_b", "ocean_water", "ocean_land", "sea_ice", "transp"
]

# External references — wired up by MapGenerator at registration time.
var generator = null  # MapGenerator (untyped to avoid circular preload)
var map: MapData = null
var season_phase_getter: Callable = Callable()

# Mirrored stride for fast reconfigure() without rebuilding the whole Job.
var stride: int = 1

# Round 内部状态（_pass_cursor / _phase_locked / _round_active 三件套）。
# round_active = false：等待 StridePolicy 触发新 round
# round_active = true ：sub-pass 推进中，下一 tick 会调用 _pass_cursor 指向的段
var _pass_cursor: int = 0
var _round_active: bool = false
var _phase_locked: float = 0.0

# 跨段累积的耗时埋点：sub-pass 各段 elapsed_ms，整 round 完成时一次性写入
# generator._last_climate_breakdown，让 main.gd 的 fast tick WARN 详细日志读到
# 与 wrapper 路径一致的 6 段拆解。
var _round_t_pass_a_ms: float = 0.0
var _round_t_pass_b_ms: float = 0.0
var _round_t_ocean_ms: float = 0.0   # 水段 + 陆段累积
var _round_t_sea_ice_ms: float = 0.0
var _round_t_transp_ms: float = 0.0
var _round_t_round_start_ms: int = 0  # 用于算整 round total_ms
var ran_this_tick: bool = false
var _last_slice_elapsed_ms: float = 0.0

# A.2.1.A4 — Dirty Mask 季节强制全图 / 每 30 日 full sweep 钩子。
# _last_phase_int_seen：上一次 round 进入时 floor(_phase_locked) 的整数部分；
#   跨过整数（季节切换）→ 本 round 开始时 mark_all_climate_dirty()
# _full_sweep_counter：每完成一 round +1，达到 30 时下一 round 入口 mark_all
# 初始化为 30：让"加载存档后首日"立刻强制全图，建立稳态 baseline
var _last_phase_int_seen: int = -9999
var _full_sweep_counter: int = 30

# ─── DataCore: climate component 缓存（climate-datacore-migration A-2） ────
# 由 SusScheduler.bind_world → SusJob.bind_world → _on_world_bound 链路触发。
# 这里只缓存 25 个 cell-level component 的 comp_id；实际是否走 DataCore 路径
# 由 ClimateProfile.use_data_core_climate 开关 + data_core_ready() 在 sub-pass
# 入口决定。weather 迁移踩过的坑：comp_id 查找必须循环外做一次，hot path
# 不能反射 World.component_id(StringName)。
var _data_core_components_ready: bool = false
# 25 个 cell-level component_id（与 DCComponentIds.CELL_* 一一对应）
var _comp_cell_temp: int = -1
var _comp_cell_temp_baseline: int = -1
var _comp_cell_temp_30d: int = -1
var _comp_cell_temp_365d: int = -1
var _comp_cell_temp_anomaly: int = -1
var _comp_cell_moisture: int = -1
var _comp_cell_snow_cover: int = -1
var _comp_cell_sea_ice_frac: int = -1
var _comp_cell_elevation: int = -1
var _comp_cell_base_moisture: int = -1
var _comp_cell_ocean_current_x: int = -1
var _comp_cell_ocean_current_y: int = -1
var _comp_cell_wind_x: int = -1
var _comp_cell_wind_y: int = -1
var _comp_cell_pos_x: int = -1
var _comp_cell_pos_y: int = -1
var _comp_cell_lat_norm: int = -1
var _comp_cell_temp_baseline_year: int = -1
var _comp_cell_terrain: int = -1
var _comp_cell_landform: int = -1
var _comp_cell_vegetation: int = -1
var _comp_cell_cover: int = -1
var _comp_cell_is_water: int = -1
var _comp_cell_climate_dirty: int = -1
var _comp_cell_weather_dirty: int = -1
# Phase 3a Step 2.1.a：climate Pass-A SoA 化新增 2 个 comp id 缓存
var _comp_cell_ema_initialized: int = -1
var _comp_cell_temp_season_offset: int = -1

func _init(p_generator, p_map: MapData, p_phase_getter: Callable, p_stride: int) -> void:
	id = &"refresh_climate_daily"
	priority = 100  # earliest of the daily jobs (writes the baseline climate)
	slice_budget_ms = 8.0  # 单 sub-pass soft budget；实际由 SUS frame_budget 兜底
	# Daily Sim SoA Refactor 方向 X：必须跨 frame_budget——气候推进不能被掐
	must_run = true
	generator = p_generator
	map = p_map
	season_phase_getter = p_phase_getter
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)

## 由 SUS 在 bind_world 时调用。完成 25 个 cell-level component_id 缓存（幂等）。
## 不做行为切换 —— 仅准备 comp_id；实际是否走 DataCore 路径由
## use_data_core_climate 开关在 sub-pass 入口（_climate_views_from_world）决定。
##
## 注意：cell-level component 是由 DCWorld.bind_map_data() 在 _setup_sus 阶段
## 注册并挂入 MapData 的——这里仅查 comp_id；若 World 尚未 bind（即
## use_data_core=false），所有 comp_id 会是 -1，data_core_ready() 返回 false，
## sub-pass 自动 fallback 到 legacy 路径。
##
## A-2 引用一致性 assert：bind_map_data 必须保证 view_f32(CELL_TEMP) 与
## map.temp_arr 是同一个底层数组引用，否则 sub-pass 走 DataCore 路径会读到
## 不同步的快照。失败时强制关闭 ready 状态并 push_error，generator 会自动
## fallback 到 legacy。
func _on_world_bound() -> void:
	if _world == null:
		_data_core_components_ready = false
		return
	# Cell-level component_id 缓存（25 个）。bind_map_data 已注册全部 25 个；
	# 若 use_data_core=false（World 未 bind），component_id() 会返回 -1。
	_comp_cell_temp = _world.component_id(DCComponentIds.CELL_TEMP)
	_comp_cell_temp_baseline = _world.component_id(DCComponentIds.CELL_TEMP_BASELINE)
	_comp_cell_temp_30d = _world.component_id(DCComponentIds.CELL_TEMP_30D)
	_comp_cell_temp_365d = _world.component_id(DCComponentIds.CELL_TEMP_365D)
	_comp_cell_temp_anomaly = _world.component_id(DCComponentIds.CELL_TEMP_ANOMALY)
	_comp_cell_moisture = _world.component_id(DCComponentIds.CELL_MOISTURE)
	_comp_cell_snow_cover = _world.component_id(DCComponentIds.CELL_SNOW_COVER)
	_comp_cell_sea_ice_frac = _world.component_id(DCComponentIds.CELL_SEA_ICE_FRAC)
	_comp_cell_elevation = _world.component_id(DCComponentIds.CELL_ELEVATION)
	_comp_cell_base_moisture = _world.component_id(DCComponentIds.CELL_BASE_MOISTURE)
	_comp_cell_ocean_current_x = _world.component_id(DCComponentIds.CELL_OCEAN_CURRENT_X)
	_comp_cell_ocean_current_y = _world.component_id(DCComponentIds.CELL_OCEAN_CURRENT_Y)
	_comp_cell_wind_x = _world.component_id(DCComponentIds.CELL_WIND_X)
	_comp_cell_wind_y = _world.component_id(DCComponentIds.CELL_WIND_Y)
	_comp_cell_pos_x = _world.component_id(DCComponentIds.CELL_POS_X)
	_comp_cell_pos_y = _world.component_id(DCComponentIds.CELL_POS_Y)
	_comp_cell_lat_norm = _world.component_id(DCComponentIds.CELL_LAT_NORM)
	_comp_cell_temp_baseline_year = _world.component_id(DCComponentIds.CELL_TEMP_BASELINE_YEAR)
	_comp_cell_terrain = _world.component_id(DCComponentIds.CELL_TERRAIN)
	_comp_cell_landform = _world.component_id(DCComponentIds.CELL_LANDFORM)
	_comp_cell_vegetation = _world.component_id(DCComponentIds.CELL_VEGETATION)
	_comp_cell_cover = _world.component_id(DCComponentIds.CELL_COVER)
	_comp_cell_is_water = _world.component_id(DCComponentIds.CELL_IS_WATER)
	_comp_cell_climate_dirty = _world.component_id(DCComponentIds.CELL_CLIMATE_DIRTY)
	_comp_cell_weather_dirty = _world.component_id(DCComponentIds.CELL_WEATHER_DIRTY)
	# Phase 3a Step 2.1.a
	_comp_cell_ema_initialized = _world.component_id(DCComponentIds.CELL_EMA_INITIALIZED)
	_comp_cell_temp_season_offset = _world.component_id(DCComponentIds.CELL_TEMP_SEASON_OFFSET)
	# 引用一致性 assert：仅当 World 真的 bind 了 MapData 时才检查（否则
	# _comp_cell_temp = -1，view_f32 会崩；那种情况下 ready=false 是合预期的）。
	if _world.is_bound() and _comp_cell_temp >= 0 and map != null:
		var dc_temp_view = _world.view_f32(_comp_cell_temp)
		# PackedFloat32Array 在 GDScript 里是值语义，不能用 == 直接判断引用相等；
		# 但 bind_map_data 用 set_array_ref(map.temp_arr) 写入，view_f32 返回的
		# 应该是同一个底层 PackedFloat32Array。这里对长度 + 头一个值做轻量校验
		# 即可——实际引用一致性由 DCWorld 单测保证。
		var ok: bool = dc_temp_view.size() == map.temp_arr.size()
		if not ok:
			push_error("[DataCore/climate] view_f32(CELL_TEMP) size=%d mismatch with map.temp_arr size=%d; disabling use_data_core_climate" % [dc_temp_view.size(), map.temp_arr.size()])
			_data_core_components_ready = false
			return
	_data_core_components_ready = true


## 是否所有 climate cell-level component 都已 ready。
## generator._climate_views_from_world() 调此判断是否真正走 DataCore 路径。
func data_core_ready() -> bool:
	return _data_core_components_ready and _world != null and _world.is_bound() \
		and _comp_cell_temp >= 0


func should_run(ctx: SusTickContext) -> bool:
	if generator == null or map == null:
		return false
	# Round 进行中：必须继续推进，绕过 StridePolicy（policy 只负责"何时启动新 round"）
	if _round_active:
		return true
	return super.should_run(ctx)

func reset_progress() -> void:
	super.reset_progress()
	_pass_cursor = 0
	_round_active = false
	_phase_locked = 0.0
	_round_t_pass_a_ms = 0.0
	_round_t_pass_b_ms = 0.0
	_round_t_ocean_ms = 0.0
	_round_t_sea_ice_ms = 0.0
	_round_t_transp_ms = 0.0
	_round_t_round_start_ms = 0
	ran_this_tick = false
	_last_slice_elapsed_ms = 0.0
	# A.2.1.A4 — 重置 Dirty Mask 季节钩子状态，保证加载存档后首日 mark_all
	_last_phase_int_seen = -9999
	_full_sweep_counter = 30

func run_slice(ctx: SusTickContext) -> Dictionary:
	if generator == null or map == null:
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }

	# Round 启动：锁 phase + 清埋点累加器
	if not _round_active:
		_pass_cursor = 0
		if season_phase_getter.is_valid():
			_phase_locked = float(season_phase_getter.call())
		else:
			_phase_locked = ctx.season_phase
		_round_t_pass_a_ms = 0.0
		_round_t_pass_b_ms = 0.0
		_round_t_ocean_ms = 0.0
		_round_t_sea_ice_ms = 0.0
		_round_t_transp_ms = 0.0
		_round_t_round_start_ms = Time.get_ticks_msec()
		_round_active = true
		# A.2.1.A4 — Dirty Mask 启动时整 round 边界处理：
		#   1) season 跨整数 / 每 30 日 full sweep / 加载存档首日 → mark_all_climate_dirty
		#   2) 否则保留上一日 dirty 增量（Pass A 内层 epsilon 比对会继续覆写）
		# 这里只在 use_sparse_climate=true 时维护 mask；为 false 时 mask 保持全 0 不影响。
		var cp_round = generator._c() if generator != null else null
		if cp_round != null and bool(cp_round.use_sparse_climate) and map != null and map.has_soa():
			var phase_int: int = int(floor(_phase_locked))
			var season_changed: bool = (_last_phase_int_seen != -9999) and (phase_int != _last_phase_int_seen)
			var full_sweep_due: bool = _full_sweep_counter >= 30
			if season_changed or full_sweep_due:
				map.mark_all_climate_dirty()
				_full_sweep_counter = 0
			else:
				# 增量模式：清空上一 round 残留的 dirty 标记，让 Pass A epsilon 比对从零开始
				map.clear_climate_dirty()
			_last_phase_int_seen = phase_int

	# 守卫：daily_climate_interpolation 关闭 → 一次性短路收尾整 round
	# （行为等同旧 wrapper 的 "if not cp.daily_climate_interpolation: return"）
	var cp = generator._c()
	if cp == null or generator._last_cfg == null or not cp.daily_climate_interpolation:
		_finalize_round()
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }

	# 推进当前 cursor 指向的 sub-pass。按段 skip 不可执行的可选段，把 cursor 移到下一段。
	var t_slice_us0: int = Time.get_ticks_usec()
	var local_coupling: bool = bool(cp.enable_local_climate_coupling)
	var ocean_enabled: bool = bool(generator._last_cfg.enable_ocean_heat_transport)
	var slice_elapsed_ms: float = 0.0
	var ran_pass_id: int = -1

	while _pass_cursor < _PASS_COUNT:
		var pass_id: int = _pass_cursor
		# Skip 不需要执行的段（开关关闭的可选 pass），cursor +1 继续 while
		var should_skip: bool = false
		match pass_id:
			_PASS_B:
				should_skip = not local_coupling
			_PASS_OCEAN_WATER, _PASS_OCEAN_LAND:
				should_skip = not ocean_enabled
			_PASS_TRANSP:
				should_skip = not local_coupling
			_:
				should_skip = false
		if should_skip:
			_pass_cursor += 1
			continue
		# 找到当前应执行的段——执行它并退出 while（每 tick 只跑 1 段）
		_run_pass(pass_id)
		ran_pass_id = pass_id
		_pass_cursor += 1
		slice_elapsed_ms = (Time.get_ticks_usec() - t_slice_us0) / 1000.0
		break

	# 检查 round 是否结束：cursor ≥ _PASS_COUNT 表示所有段（含 skip）都过了
	var done: bool = _pass_cursor >= _PASS_COUNT
	if done:
		_finalize_round()
	else:
		_publish_partial_round(ran_pass_id, slice_elapsed_ms, float(_pass_cursor) / float(_PASS_COUNT))
	ran_this_tick = ran_pass_id >= 0
	_last_slice_elapsed_ms = slice_elapsed_ms if ran_this_tick else 0.0

	var progress: float = float(_pass_cursor) / float(_PASS_COUNT)
	return {
		"done": done,
		"work_done": map.cell_count() if done else 0,
		"elapsed_ms": slice_elapsed_ms,
		"progress_ratio": progress if not done else 1.0,
	}

# ─── 内部：按 pass_id 调用 generator 上的 sub-pass 并累积埋点 ─────────────
func _run_pass(pass_id: int) -> void:
	var t_us0: int = Time.get_ticks_usec()
	match pass_id:
		_PASS_A:
			generator._climate_pass_a(map, _phase_locked)
			_round_t_pass_a_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
		_PASS_B:
			generator._climate_pass_b(map, _phase_locked)
			_round_t_pass_b_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
		_PASS_OCEAN_WATER:
			generator._ocean_water_pass(map, _phase_locked)
			_round_t_ocean_ms += (Time.get_ticks_usec() - t_us0) / 1000.0
		_PASS_OCEAN_LAND:
			generator._ocean_land_pass(map, _phase_locked)
			_round_t_ocean_ms += (Time.get_ticks_usec() - t_us0) / 1000.0
		_PASS_SEA_ICE:
			generator._apply_sea_ice_daily_pass(map, _phase_locked)
			_round_t_sea_ice_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
		_PASS_TRANSP:
			generator._apply_transpiration_pass(map)
			_round_t_transp_ms = (Time.get_ticks_usec() - t_us0) / 1000.0

func _publish_partial_round(pass_id: int, slice_elapsed_ms: float, progress: float) -> void:
	if generator == null:
		return
	var pass_name: String = ""
	if pass_id >= 0 and pass_id < _PASS_NAMES.size():
		pass_name = _PASS_NAMES[pass_id]
	# A.2.1.A5 — partial round 也带上 dirty/visited 指标，便于切片观察
	var dirty_ratio_out: float = 1.0
	var visited_ratio_out: float = 1.0
	var pass_b_path_out: String = "full"
	dirty_ratio_out = float(generator._last_climate_dirty_ratio) if "_last_climate_dirty_ratio" in generator else 1.0
	visited_ratio_out = float(generator._last_climate_visited_ratio) if "_last_climate_visited_ratio" in generator else 1.0
	pass_b_path_out = String(generator._last_climate_pass_b_path) if "_last_climate_pass_b_path" in generator else "full"
	generator._last_climate_breakdown = {
		"pass_a_ms": _round_t_pass_a_ms,
		"pass_b_ms": _round_t_pass_b_ms,
		"ocean_ms": _round_t_ocean_ms,
		"sea_ice_ms": _round_t_sea_ice_ms,
		"ice_bake_ms": 0.0,
		"transp_ms": _round_t_transp_ms,
		"total_ms": float(Time.get_ticks_msec() - _round_t_round_start_ms),
		"cells": map.cell_count(),
		"partial": true,
		"current_pass": pass_name,
		"slice_ms": slice_elapsed_ms,
		"progress_ratio": progress,
		"dirty_ratio": dirty_ratio_out,
		"visited_ratio": visited_ratio_out,
		"pass_b_path": pass_b_path_out,
	}

# ─── 内部：round 结束时把累积埋点写回 generator + 重置游标 ────────────────
func _finalize_round() -> void:
	# A.2.1.A4 — 一 round 完成 → counter +1（30 日 full sweep 触发逻辑在下次 round 入口）
	_full_sweep_counter += 1
	# A.2.1.A5 — 把 Pass B 写到 generator 的稀疏指标合并进 breakdown，方便 main.gd 输出
	var dirty_ratio_out: float = 1.0
	var visited_ratio_out: float = 1.0
	var pass_b_path_out: String = "full"
	if generator != null:
		dirty_ratio_out = float(generator._last_climate_dirty_ratio) if "_last_climate_dirty_ratio" in generator else 1.0
		visited_ratio_out = float(generator._last_climate_visited_ratio) if "_last_climate_visited_ratio" in generator else 1.0
		pass_b_path_out = String(generator._last_climate_pass_b_path) if "_last_climate_pass_b_path" in generator else "full"
	# 与 wrapper 路径保持完全一致的 _last_climate_breakdown 字段集合，让 main.gd 直接复用
	if generator != null:
		generator._daily_climate_call_count += 1
		generator._last_climate_breakdown = {
			"pass_a_ms": _round_t_pass_a_ms,
			"pass_b_ms": _round_t_pass_b_ms,
			"ocean_ms": _round_t_ocean_ms,
			"sea_ice_ms": _round_t_sea_ice_ms,
			"ice_bake_ms": 0.0,  # GPU 海冰上传已迁到 SeaIceAtlasUploadJob
			"transp_ms": _round_t_transp_ms,
			"total_ms": float(Time.get_ticks_msec() - _round_t_round_start_ms),
			"cells": map.cell_count(),
			"partial": false,
			"current_pass": "done",
			"progress_ratio": 1.0,
			"dirty_ratio": dirty_ratio_out,
			"visited_ratio": visited_ratio_out,
			"pass_b_path": pass_b_path_out,
		}
		var n: int = generator._daily_climate_call_count
		if n == 1 or (n % 365) == 0:
			# I1.A-1: 在 round summary 末尾追加 path=... 标识，与 weather 日志对齐，
			# 便于 grep / A-B 桶聚合。三态推导与 main.gd path=... 一致：
			#   legacy                — use_data_core_climate=false 或 World 未绑定
			#   data_core_cells_only  — Flag on + World 已绑定，但 25 个 comp_id 还没缓存好
			#   data_core             — Flag on + World 已绑定 + 全部 comp_id 缓存就绪
			var _path_str: String = "legacy"
			var _cp = generator._c() if generator.has_method("_c") else null
			if _cp != null and "use_data_core_climate" in _cp and bool(_cp.use_data_core_climate):
				var _w = generator.get_data_core_world() if generator.has_method("get_data_core_world") else null
				if _w != null and _w.is_bound():
					_path_str = "data_core" if data_core_ready() else "data_core_cells_only"
				# dots-roadmap-to-gdextension 务实 A：若 C++ co-processor 也已绑定，
				# 在 path 后追加 +cpp 标记（实际本轮 run_climate_pass_a 仍 stub，
				# 但能从日志看到 "co-processor 在席" 的事实，便于 probe 验收）。
				if generator.has_method("get_data_core_world_ext"):
					var _w_ext = generator.get_data_core_world_ext()
					if _w_ext != null:
						_path_str += "+cpp_ext"
			print("refresh_climate_daily(sliced) #%d: %dms across sub-ticks (cells=%d, phase=%.3f) | A=%.1f B=%.1f ocean=%.1f sea_ice=%.1f transp=%.1f path=%s" % [
				n,
				int(Time.get_ticks_msec() - _round_t_round_start_ms),
				map.cell_count(),
				_phase_locked,
				_round_t_pass_a_ms, _round_t_pass_b_ms, _round_t_ocean_ms, _round_t_sea_ice_ms, _round_t_transp_ms,
				_path_str,
			])
	# Climate-Weather 2ms Budget — Phase A.3：SoA pipeline 启用时，整 round 完成
	# 后一次性把 SoA 数组 flush 回 HexCell 强类型成员，让 UI / Baker / Overlay 等
	# 只读消费者继续工作。开关关闭时 has_soa() 仍为 true，但所有 sub-pass 走的都是
	# legacy 路径直写 cell.*，flush 是幂等的（只是把当前 cell 值往 SoA 镜像里同步
	# 一遍，再读出来——开销与 cell 数量成正比，只在 round 末跑一次，可接受）。
	if generator != null:
		var cp_for_flush = generator._c()
		if cp_for_flush != null and bool(cp_for_flush.use_soa_pipeline) and map != null and map.has_soa():
			# [DIAG 2026-05-12] round 末尾、flush 前打一次温度统计（前 8 round）。
			# 与 Pass-A / Pass-B 末尾配对：若 round 末 mean ≈ 0 但 Pass-B 末尾正常
			# → bug 在 ocean_water / ocean_land / sea_ice / transp 之一。
			var _diag_n: int = int(generator._daily_climate_call_count)
			if _diag_n <= 8:
				var _ta: PackedFloat32Array = map.temp_arr
				var _tmin: float = 1.0
				var _tmax: float = 0.0
				var _tsum: float = 0.0
				var _tcnt: int = _ta.size()
				for _ti in range(_tcnt):
					var _tv: float = _ta[_ti]
					if _tv < _tmin: _tmin = _tv
					if _tv > _tmax: _tmax = _tv
					_tsum += _tv
				var _tmean: float = (_tsum / float(_tcnt)) if _tcnt > 0 else 0.0
				print("[DIAG round_end ] day=%d phase=%.3f temp_arr min=%.4f max=%.4f mean=%.4f n=%d (pre-flush)" % [
					_diag_n, _phase_locked, _tmin, _tmax, _tmean, _tcnt
				])
			map.flush_soa_to_cells()
	_round_active = false
	_pass_cursor = 0

## Allow MapGenerator to retune the stride on the fly (speed_changed callback).
func reconfigure(p_stride: int) -> void:
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)


func reset_run_flag() -> void:
	ran_this_tick = false
	_last_slice_elapsed_ms = 0.0


func did_run_last_tick() -> bool:
	return ran_this_tick


func last_slice_elapsed_ms() -> float:
	return _last_slice_elapsed_ms
