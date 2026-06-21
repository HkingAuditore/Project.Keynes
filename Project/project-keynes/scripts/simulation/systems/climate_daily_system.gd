extends DCSystem
class_name ClimateDailySystem

## Phase W.1 — DCSystem 原生重写（dots-migration-roadmap §I.2）。
##
## 把 [`RefreshClimateDailyJob`](../sus/jobs/refresh_climate_daily_job.gd) 的
## 419 行 6-stage round 切片逻辑 + 25 个手写 _comp_cell_* cache 全部上提到
## 本类，删除 _inner delegate wrapper。25 个 _comp_cell_* 替换为基类
## DCSystem.setup() 自动填充的 _cid 字典。
##
## ─── 类层级与兼容性 ─────────────────────────────────────────────────
##
## ClimateDailySystem extends DCSystem extends SusJob —— 本类 IS-A SusJob，
## 可被 SlicedUpdateScheduler.register_job 和 DCSystemScheduler.register_system
## 两条路径同时接受。
##
## RefreshClimateDailyJob 现在退化为 `extends ClimateDailySystem` 的薄壳，
## 仅保留 class_name 以兼容旧 preload 路径（map_generator 的 RefreshClimateDailyJobScript
## const、weather_refresh_job 的注释引用等）。所有业务逻辑在本类。
##
## ─── reads / writes / pools 声明 ───────────────────────────────────
##
## reads: 25 个 cell-level component（climate Pass-A/B、ocean、sea_ice、
##        transp 计算的全部输入）；与原 RefreshClimateDailyJob._on_world_bound
##        手写的 25 个 _comp_cell_* 一一对应（基类 setup() 自动 cache 到 _cid）
## writes: 主要写 cell.temp / cell.moisture / cell.snow_cover / cell.sea_ice_frac /
##         cell.temp_30d / cell.temp_365d / cell.temp_anomaly / cell.temp_baseline /
##         cell.temp_season_offset / cell.air_mass_temp_anomaly / cell.climate_dirty /
##         cell.ema_initialized
##
## feature_flag：留空（climate daily 是世界推进必跑流程）。
##
## ─── Driver / strategy（搬迁自 RefreshClimateDailyJob 类注释） ──────
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
##   - 跨段的所有数据交接均通过 HexCell 已稳定字段（cell.temperature 等）完成。
##
## must_run = true：与 OceanCurrentsJob 同因——气候推进不能被 frame_budget 掐掉，
## 否则 round 卡在某段、weather/ocean_currents 等下游读到半套数据。

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

# Sub-pass 编号常量（保持与 _PASS_NAMES 索引对齐，便于日志可读）
const _PASS_A: int = 0
const _PASS_B: int = 1
const _PASS_OCEAN_WATER: int = 2
const _PASS_OCEAN_LAND: int = 3
# climate-loop-closure Phase 1.1：风致热平流接入 sliced round（ocean_land 之后、
# sea_ice 之前）。气团段先把上风温度混合写回 temp + air_mass_temp_anomaly，地表段
# 再把邻格 anomaly 注入；顺序必须 wind_air → wind_surface（地表段读气团段产物）。
const _PASS_WIND_AIR: int = 4
const _PASS_WIND_SURFACE: int = 5
const _PASS_SEA_ICE: int = 6
const _PASS_TRANSP: int = 7
const _PASS_COUNT: int = 8
const _PASS_NAMES: PackedStringArray = [
	"pass_a", "pass_b", "ocean_water", "ocean_land", "wind_air", "wind_surface", "sea_ice", "transp"
]

# 通用 climate pass 生命周期状态。先在 ClimateDailySystem 内落地，后续
# begin_climate_pass/run_climate_pass_slice/abort_climate_pass 直接复用同一 schema。
const _PASS_STATE_IDLE: String = "idle"
const _PASS_STATE_RUNNING: String = "running"
const _PASS_STATE_DONE: String = "done"
const _PASS_STATE_FAILED: String = "failed"
const _PASS_STATE_ABORTED: String = "aborted"

const _PASS_RESULT_DONE: String = "done"
const _PASS_RESULT_CONTINUE: String = "continue"
const _PASS_RESULT_FAILED: String = "failed"
const _PASS_RESULT_ABORTED: String = "aborted"

const _ABORT_REASON_RESET: String = "reset"
const _ABORT_REASON_RESTART: String = "restart"
const _ABORT_REASON_REPLACED: String = "replaced"

const _TRANSP_STAGE_IDLE: int = 0
const _TRANSP_STAGE_COMPUTE: int = 1
const _TRANSP_STAGE_APPLY: int = 2
const _TRANSP_STAGE_DONE: int = 3
const _TRANSP_MIN_CELLS_PER_SLICE: int = 64
const _TRANSP_TIME_CHECK_INTERVAL: int = 32
const _TRANSP_WATER_LANDFORM_MAX: int = 3

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
# Fix #6 (2026-06-15): finalizer 拆 slice 跨帧。所有 pass 完成后不立即 finalize，
# 把 5-8ms 的 finalizer cell loop 推到下一片，让本片 p95 下降。
# false → 还没进入 finalize 队列；true → 下一片专门跑 _finalize_round()。
var _finalize_pending: bool = false

# ─── Async climate round（plan §async-stage-3，2026-06-14） ──────────
# 当 cp.use_climate_round_async=true 时启用：worker thread 后台跑完整 round，
# 主线程 run_slice 入口 kick + poll。
# _async_round_kicked：当前 round 已 kick 但 worker 还没完成。
# _async_round_poll_attempts：从 kick 到现在试过的 poll 次数（diagnostic）。
# _async_round_kick_tick：kick 时的 tick_index，用于"超时强制 finalize"兜底。
var _async_round_kicked: bool = false
var _async_round_poll_attempts: int = 0
# Fix #11 second pass (2026-06-16)：async DIAG print 用 round 计数节流（之前
# 用 poll_attempts，worker 快时每 round 都打）。
var _async_round_log_count: int = 0
var _async_round_kick_tick: int = -1
# Stage 3 一次性 boot probe 打印（"async path active 第 N 次 round"）。
var _async_first_round_logged: bool = false
# Stage 3 调试一次性 probe，run_slice 第一次进时 dump async branch condition
var _async_branch_probe_logged: bool = false

# 跨段累积的耗时埋点：sub-pass 各段 elapsed_ms，整 round 完成时一次性写入
# generator._last_climate_breakdown，让 main.gd 的 fast tick WARN 详细日志读到
# 与 wrapper 路径一致的 6 段拆解。
var _round_t_pass_a_ms: float = 0.0
var _round_t_pass_b_ms: float = 0.0
var _round_t_ocean_ms: float = 0.0   # 水段 + 陆段累积
var _round_t_wind_ms: float = 0.0    # 风温气团段 + 地表段累积
var _round_t_sea_ice_ms: float = 0.0
var _round_t_transp_ms: float = 0.0
var _round_t_round_start_ms: int = 0  # 用于算整 round total_ms
var ran_this_tick: bool = false
var _last_slice_elapsed_ms: float = 0.0
var _last_pass_processed_cells: int = 0
var _last_pass_cursor_start: int = -1
var _last_pass_cursor_end: int = -1
var _last_pass_stage: String = ""
var _last_pass_substage: String = ""
var _last_pass_path: String = ""
var _last_pass_budget_interrupted: bool = false
var _last_pass_status: String = _PASS_RESULT_DONE

# 通用 pass generation/token：每次 round 开始递增 token；slice 返回时校验 token，
# 防止 reset/restart 后旧 pass 结果覆盖新 round 诊断或发布结果。
var _pass_generation: int = 0
var _active_pass_token: int = 0
var _active_pass_state: Dictionary = {}
var _last_pass_diag: Dictionary = {}
var _last_transp_native_diag: Dictionary = {}
var _last_round_start_diag: Dictionary = {}
var _last_finalize_diag: Dictionary = {}
var _last_slice_pass_overhead_ms: float = 0.0
var _temp_start_of_day_arr: PackedFloat32Array = PackedFloat32Array()
var _tta_start_of_day_arr: PackedFloat32Array = PackedFloat32Array()
var _round_start_terrain_sync_bootstrap_done: bool = false
# Stage 9 / Fix #11 (2026-06-16) STAGE-TOTAL 打印 budget。
var _fin_stage_log_count: int = 0
var _last_finalizer_diag: Dictionary = {}
var _transp_stage: int = _TRANSP_STAGE_IDLE
var _transp_cells: Array = []
var _transp_neighbor_indices: PackedInt32Array = PackedInt32Array()
var _transp_deltas: PackedFloat32Array = PackedFloat32Array()
var _transp_landform_arr: PackedByteArray = PackedByteArray()
var _transp_vegetation_arr: PackedByteArray = PackedByteArray()
var _transp_moisture_arr: PackedFloat32Array = PackedFloat32Array()
var _transp_donor_table: PackedFloat32Array = PackedFloat32Array()
var _transp_cursor: int = 0
var _transp_n_cells: int = 0
var _transp_fast_indexed: bool = false

# A.2.1.A4 — Dirty Mask 季节强制全图 / 每 30 日 full sweep 钩子。
# _last_phase_int_seen：上一次 round 进入时 floor(_phase_locked) 的整数部分；
#   跨过整数（季节切换）→ 本 round 开始时 mark_all_climate_dirty()
# _full_sweep_counter：每完成一 round +1，达到 30 时下一 round 入口 mark_all
# 初始化为 _FULL_SWEEP_PERIOD：让"加载存档后首日"立刻强制全图，建立稳态 baseline
# climate-loop-closure Phase 5.2：full sweep 周期 30 → 8 日。
# 根因：稀疏 push 扣除全图季节 drift 后，均匀季节升温的 cell 不超 epsilon → 不推 GPU，
# 直到 full sweep 才一次性补帧，造成"每 30 日视觉温度台阶跳变"。把周期缩到 8 日，把
# 最大视觉滞后从 ~30 日降到 ~8 日，台阶幅度大幅减小、过渡更平滑（代价：push 频率略升）。
const _FULL_SWEEP_PERIOD: int = 8
var _last_phase_int_seen: int = -9999
var _full_sweep_counter: int = 8

const _CLIMATE_INTEGRITY_INITIAL_LOGS: int = 18
const _CLIMATE_INTEGRITY_MIN_INTERVAL_MSEC: int = 2500
const _CLIMATE_INTEGRITY_TEMP_EDGE_WARN: float = 0.35
const _CLIMATE_INTEGRITY_EPS: float = 0.00001
const _CLIMATE_TERRAIN_VIEW_SYNC_INITIAL_LOGS: int = 12
var _climate_integrity_log_count: int = 0
var _climate_integrity_last_msec: int = -1000000
var _last_integrity_diag_ms: float = 0.0
var _last_integrity_diag_stage: String = ""
var _climate_terrain_view_sync_log_count: int = 0
var _climate_integrity_prev_wind_x: PackedFloat32Array = PackedFloat32Array()
var _climate_integrity_prev_wind_y: PackedFloat32Array = PackedFloat32Array()
var _climate_integrity_prev_wind_speed: PackedFloat32Array = PackedFloat32Array()
var _climate_integrity_prev_ocean_x: PackedFloat32Array = PackedFloat32Array()
var _climate_integrity_prev_ocean_y: PackedFloat32Array = PackedFloat32Array()


func _init(p_generator, p_map: MapData, p_phase_getter: Callable, p_stride: int) -> void:
	id = &"refresh_climate_daily"
	priority = 100  # earliest of the daily jobs (writes the baseline climate)
	slice_budget_ms = 0.55  # 单 sub-pass soft budget；实际由 SUS frame_budget 兜底
	max_slices_per_tick = 1
	# Daily Sim SoA Refactor 方向 X：必须跨 frame_budget——气候推进不能被掐
	must_run = false
	generator = p_generator
	map = p_map
	season_phase_getter = p_phase_getter
	stride = max(1, p_stride)
	# Fix #10 (2026-06-15): mobile 上 climate 落奇 tick 错峰调度。
	# 用户提议："1, 3, 5, 7, 9 跑 climate，2 跑 A，4 跑 B，6 跑 C"。
	# Mobile climate stride=2 phase=1 → 仿真每 2 仿真日推进一次（玩家肉眼可察觉
	# +1 仿真日延迟，但收益是单 tick load 大幅下降）。Desktop 不变（profile 默认 1）。
	if OS.has_feature("mobile"):
		stride = 2
		policy = SusPolicyScript.StridePolicy.new(2, 1)
	else:
		policy = SusPolicyScript.StridePolicy.new(stride, 0)


# ─── DCSystem 声明 ──────────────────────────────────────────────────

func declare_reads() -> Array[StringName]:
	# 与原 RefreshClimateDailyJob._on_world_bound 内手写 25 个 _comp_cell_*
	# cache 1:1 对齐（基类 DCSystem.setup() 自动 cache 到 _cid）
	var reads: Array[StringName] = [
		DCComponentIds.CELL_TEMP,
		DCComponentIds.CELL_TEMP_BASELINE,
		DCComponentIds.CELL_TEMP_30D,
		DCComponentIds.CELL_TEMP_365D,
		DCComponentIds.CELL_TEMP_ANOMALY,
		DCComponentIds.CELL_MOISTURE,
		DCComponentIds.CELL_SNOW_COVER,
		DCComponentIds.CELL_SEA_ICE_FRAC,
		DCComponentIds.CELL_ELEVATION,
		DCComponentIds.CELL_BASE_MOISTURE,
		DCComponentIds.CELL_POS_X,
		DCComponentIds.CELL_POS_Y,
		DCComponentIds.CELL_LAT_NORM,
		DCComponentIds.CELL_TEMP_BASELINE_YEAR,
		DCComponentIds.CELL_TERRAIN,
		DCComponentIds.CELL_LANDFORM,
		DCComponentIds.CELL_VEGETATION,
		DCComponentIds.CELL_COVER,
		DCComponentIds.CELL_IS_WATER,
		DCComponentIds.CELL_EMA_INITIALIZED,
		DCComponentIds.CELL_TEMP_SEASON_OFFSET,
		DCComponentIds.CELL_INSOLATION_NOW,
		DCComponentIds.CELL_INSOLATION_DEV,
		DCComponentIds.CELL_DAY_LENGTH,
		DCComponentIds.CELL_HEAT_INPUT,
		DCComponentIds.CELL_THERMAL_ENERGY,
		DCComponentIds.CELL_SNOWPACK,
		DCComponentIds.CELL_WATER_BALANCE_30D,
		DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY,
	]
	if _standalone_sea_ice_enabled():
		reads.erase(DCComponentIds.CELL_SEA_ICE_FRAC)
	return reads


func declare_writes() -> Array[StringName]:
	var writes: Array[StringName] = [
		DCComponentIds.CELL_TEMP,
		DCComponentIds.CELL_TEMP_30D,
		DCComponentIds.CELL_TEMP_365D,
		DCComponentIds.CELL_TEMP_ANOMALY,
		DCComponentIds.CELL_TEMP_BASELINE,
		DCComponentIds.CELL_TEMP_SEASON_OFFSET,
		DCComponentIds.CELL_MOISTURE,
		DCComponentIds.CELL_SNOW_COVER,
		DCComponentIds.CELL_SEA_ICE_FRAC,
		DCComponentIds.CELL_AIR_MASS_TEMP_ANOMALY,
		DCComponentIds.CELL_CLIMATE_DIRTY,
		DCComponentIds.CELL_EMA_INITIALIZED,
		DCComponentIds.CELL_INSOLATION_NOW,
		DCComponentIds.CELL_INSOLATION_DEV,
		DCComponentIds.CELL_DAY_LENGTH,
		DCComponentIds.CELL_HEAT_INPUT,
		DCComponentIds.CELL_THERMAL_ENERGY,
		DCComponentIds.CELL_SNOWPACK,
		DCComponentIds.CELL_WATER_BALANCE_30D,
		DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY,
	]
	if _standalone_sea_ice_enabled():
		writes.erase(DCComponentIds.CELL_SEA_ICE_FRAC)
	return writes


func declare_pools() -> Array[StringName]:
	return [DCComponentIds.POOL_CELLS]


func feature_flag() -> StringName:
	return &""


# ─── 生命周期 ──────────────────────────────────────────────────────
#
# 基类 DCSystem.setup(w) 已自动把 declare_reads/writes 中的 component 解析为
# comp_id 并 cache 到 _cid 字典；本类只额外做"view_f32 size 一致性" assert
# （原 RefreshClimateDailyJob._on_world_bound 第 177-187 行的轻量校验）。

func _on_world_bound() -> void:
	# 基类 setup() 已填好 _cid；此处仅做引用一致性 assert。
	if _world == null:
		return
	# 仅当 World 真的 bind 了 MapData 时检查（否则 _cid 全 -1，data_core_ready=false 是合预期的）。
	if not _world.is_bound() or map == null:
		return
	var cid_temp: int = int(_cid.get(DCComponentIds.CELL_TEMP, -1))
	if cid_temp < 0:
		return
	var dc_temp_view = _world.view_f32(cid_temp)
	# PackedFloat32Array 在 GDScript 里是值语义，不能用 == 直接判断引用相等；
	# 这里对长度做轻量校验，实际引用一致性由 DCWorld 单测保证。
	if dc_temp_view.size() != map.temp_arr.size():
		push_error("[ClimateDailySystem] view_f32(CELL_TEMP) size=%d mismatch with map.temp_arr size=%d; disabling DataCore climate path" % [dc_temp_view.size(), map.temp_arr.size()])
		_components_ready = false


# ─── tick 入口 ─────────────────────────────────────────────────────

## 是否所有 climate cell-level component 都已 ready。
## generator._climate_views_from_world() 调此判断是否真正走 DataCore 路径。
func data_core_ready() -> bool:
	if not _components_ready:
		return false
	if _world == null or not _world.is_bound():
		return false
	return int(_cid.get(DCComponentIds.CELL_TEMP, -1)) >= 0


func should_run(ctx: SusTickContext) -> bool:
	if generator == null or map == null:
		return false
	# Round 进行中：必须继续推进，绕过 StridePolicy（policy 只负责"何时启动新 round"）
	if _round_active:
		return true
	return super.should_run(ctx)


func reset_progress() -> void:
	super.reset_progress()
	_abort_active_pass(_ABORT_REASON_RESET)
	# Fix R4 (climate-pipeline-spike-reduction)：在 budget=2ms / 每帧 1 pass 节奏下，
	# ocean_water/land 的 cursor 跨 round 持续累加。如果不在 reset 时同步清掉
	# generator._climate_ocean_slice_state，下一 round 进来会发现 slice_state 非空 +
	# map_id 一致 → 跳过 _begin_ocean_heat_transport_sliced → 继续从旧 cursor 推进 →
	# 永远不会从 0 开始一个新 round 的洋流计算，洋流热输运彻底"消失"。
	if generator != null and generator.has_method("_abort_all_climate_passes"):
		generator._abort_all_climate_passes("daily_reset")
	_pass_cursor = 0
	_round_active = false
	_phase_locked = 0.0
	_finalize_pending = false
	_round_t_pass_a_ms = 0.0
	_round_t_pass_b_ms = 0.0
	_round_t_ocean_ms = 0.0
	_round_t_wind_ms = 0.0
	_round_t_sea_ice_ms = 0.0
	_round_t_transp_ms = 0.0
	_round_t_round_start_ms = 0
	_temp_start_of_day_arr = PackedFloat32Array()
	_tta_start_of_day_arr = PackedFloat32Array()
	_last_finalizer_diag = {}
	_last_round_start_diag = {}
	_last_finalize_diag = {}
	_last_slice_pass_overhead_ms = 0.0
	_reset_transpiration_slice_state()
	ran_this_tick = false
	_last_slice_elapsed_ms = 0.0
	_reset_last_pass_diag()
	# A.2.1.A4 — 重置 Dirty Mask 季节钩子状态，保证加载存档后首日 mark_all
	_last_phase_int_seen = -9999
	_full_sweep_counter = _FULL_SWEEP_PERIOD


func _reset_last_pass_diag() -> void:
	_last_pass_processed_cells = 0
	_last_pass_cursor_start = -1
	_last_pass_cursor_end = -1
	_last_pass_stage = ""
	_last_pass_substage = ""
	_last_pass_path = ""
	_last_pass_budget_interrupted = false
	_last_pass_status = _PASS_RESULT_DONE
	_last_pass_diag = {}
	_last_slice_pass_overhead_ms = 0.0


func _merge_climate_wrapper_diag(breakdown: Dictionary) -> void:
	breakdown["pass_overhead_ms"] = _last_slice_pass_overhead_ms
	breakdown["round_start_diag"] = _last_round_start_diag.duplicate(true)
	breakdown["finalize_diag"] = _last_finalize_diag.duplicate(true)
	for k in _last_round_start_diag.keys():
		breakdown[k] = _last_round_start_diag[k]
	for k in _last_finalize_diag.keys():
		breakdown[k] = _last_finalize_diag[k]


func _reset_transpiration_slice_state() -> void:
	_transp_stage = _TRANSP_STAGE_IDLE
	_transp_cells = []
	_transp_neighbor_indices = PackedInt32Array()
	_transp_deltas = PackedFloat32Array()
	_transp_landform_arr = PackedByteArray()
	_transp_vegetation_arr = PackedByteArray()
	_transp_moisture_arr = PackedFloat32Array()
	_transp_donor_table = PackedFloat32Array()
	_transp_cursor = 0
	_transp_n_cells = 0
	_transp_fast_indexed = false


func _diagnostics_enabled() -> bool:
	var cp = generator._c() if generator != null else null
	if cp == null:
		return true
	if cp.get("climate_pass_diagnostics_enabled") != null:
		return bool(cp.climate_pass_diagnostics_enabled)
	if cp.get("performance_diagnostics_enabled") != null:
		return bool(cp.performance_diagnostics_enabled)
	return true


func _should_sync_runtime_terrain_views(reason: String) -> bool:
	if reason != "round_start":
		return true
	var cp = generator._c() if generator != null else null
	if not _round_start_terrain_sync_bootstrap_done:
		_round_start_terrain_sync_bootstrap_done = true
		return true
	if cp != null and cp.get("climate_round_start_terrain_sync_enabled") != null:
		return bool(cp.climate_round_start_terrain_sync_enabled)
	return _diagnostics_enabled()


func _sync_runtime_terrain_views_for_reason(reason: String) -> Dictionary:
	if _should_sync_runtime_terrain_views(reason):
		return _sync_runtime_terrain_views(reason)
	return {
		"reason": reason,
		"skipped": true,
		"skip_reason": "round_start_terrain_sync_disabled",
	}


func _standalone_sea_ice_enabled() -> bool:
	var cp = generator._c() if generator != null else null
	return cp != null \
			and cp.get("sea_ice_independent_system_enabled") != null \
			and bool(cp.sea_ice_independent_system_enabled)


func _sync_runtime_terrain_views(reason: String) -> Dictionary:
	var diag: Dictionary = {}
	if map == null or not map.has_soa():
		return diag
	var n: int = mini(map.cell_count(), map.terrain_arr.size())
	if n <= 0:
		return diag
	var samples: PackedStringArray = PackedStringArray()
	var cell_terrain_mismatch: int = 0
	for i in range(n):
		var cell: HexCell = map.cell_at(i)
		if cell == null:
			continue
		var soa_terrain: int = int(map.terrain_arr[i]) & 0xFF
		if int(cell.terrain) != soa_terrain:
			cell_terrain_mismatch += 1
			if samples.size() < 3:
				samples.append("idx=%d q=%s r=%s cell=%d soa=%d" % [
					i, str(cell.q), str(cell.r), int(cell.terrain), soa_terrain
				])
	var facade_fixed: int = 0
	if map.has_method("sync_runtime_terrain_facade_from_soa"):
		facade_fixed = int(map.sync_runtime_terrain_facade_from_soa())

	var dc_terrain_mismatch_observed: int = 0
	var dc_iswater_mismatch_observed: int = 0
	if _world != null and _world.is_bound() and _world.has_method("view_u8"):
		var cid_terrain: int = int(_cid.get(DCComponentIds.CELL_TERRAIN, -1))
		if cid_terrain >= 0:
			var dc_terrain: PackedByteArray = _world.view_u8(cid_terrain)
			for i in range(mini(n, mini(dc_terrain.size(), map.terrain_arr.size()))):
				if int(dc_terrain[i]) != int(map.terrain_arr[i]):
					dc_terrain_mismatch_observed += 1
		var cid_iswater: int = int(_cid.get(DCComponentIds.CELL_IS_WATER, -1))
		if cid_iswater >= 0:
			var dc_iswater: PackedByteArray = _world.view_u8(cid_iswater)
			for i in range(mini(n, mini(dc_iswater.size(), map.is_water_arr.size()))):
				if int(dc_iswater[i]) != int(map.is_water_arr[i]):
					dc_iswater_mismatch_observed += 1

	if cell_terrain_mismatch <= 0 and facade_fixed <= 0 \
			and dc_terrain_mismatch_observed <= 0 and dc_iswater_mismatch_observed <= 0:
		return diag

	diag = {
		"reason": reason,
		"cell_terr_mis_before": cell_terrain_mismatch,
		"facade_fixed": facade_fixed,
		"dc_terr_mis_observed": dc_terrain_mismatch_observed,
		"dc_isw_mis_observed": dc_iswater_mismatch_observed,
	}
	if _diagnostics_enabled() or _climate_terrain_view_sync_log_count < _CLIMATE_TERRAIN_VIEW_SYNC_INITIAL_LOGS:
		_climate_terrain_view_sync_log_count += 1
		var sample_text: String = ""
		if samples.size() > 0:
			sample_text = " samples=%s" % " | ".join(samples)
		print("[climate/terrain_sync] reason=%s phase=%.3f cell_terr_mis_before=%d facade_fixed=%d dc_terr_mis_observed=%d dc_isw_mis_observed=%d%s" % [
			reason, _phase_locked, cell_terrain_mismatch, facade_fixed,
			dc_terrain_mismatch_observed, dc_iswater_mismatch_observed, sample_text,
		])
	return diag


func _begin_round_pass_state() -> void:
	_pass_generation += 1
	_active_pass_token = _pass_generation
	var t_capture_us: int = Time.get_ticks_usec()
	_capture_daily_finalizer_start_state()
	if not _last_round_start_diag.is_empty():
		_last_round_start_diag["capture_start_state_ms"] = float(Time.get_ticks_usec() - t_capture_us) / 1000.0
	_last_transp_native_diag = {}
	_active_pass_state = {
		"token": _active_pass_token,
		"state": _PASS_STATE_RUNNING,
		"pass_cursor": 0,
		"stage": "round_begin",
		"stage_name": "round_begin",
		"substage": "init",
		"phase": _phase_locked,
		"cursor_start": 0,
		"cursor_end": 0,
		"processed_cells": 0,
		"budget_interrupted": false,
		"abort_reason": "",
		"started_msec": Time.get_ticks_msec(),
		"diagnostics_enabled": _diagnostics_enabled(),
	}
	_reset_last_pass_diag()


func _capture_daily_finalizer_start_state() -> void:
	_temp_start_of_day_arr = PackedFloat32Array()
	_tta_start_of_day_arr = PackedFloat32Array()
	_last_finalizer_diag = {}
	if map == null:
		return
	var n: int = map.cell_count()
	if n <= 0:
		return
	if map.temp_arr.size() == n:
		_temp_start_of_day_arr = map.temp_arr.duplicate()
	if map.temperature_transport_anomaly_arr.size() == n:
		_tta_start_of_day_arr = map.temperature_transport_anomaly_arr.duplicate()


func _percentile_from_sorted(values, p: float) -> float:
	if values.is_empty():
		return 0.0
	var idx: int = clampi(int(floor(float(values.size() - 1) * clampf(p, 0.0, 1.0))), 0, values.size() - 1)
	return float(values[idx])


func _calendar_days_per_year() -> int:
	if generator != null and generator.has_method("_calendar_days_per_year"):
		return clampi(int(generator._calendar_days_per_year()), 1, 3660)
	return 365


func _is_annual_log_tick(counter: int) -> bool:
	var dpy: int = _calendar_days_per_year()
	return counter == 1 or (counter > 0 and (counter % dpy) == 0)


# Stage 9 / Fix #11 (2026-06-16)：C++ worker 已跑 finalizer 时，把 poll_result 里
# fin_* 字段 平移到 GDScript 期望的 diag schema。返回字段必须 1:1 兼容
# _apply_daily_climate_finalizer() 的 return shape（main.gd / generator 解析这些字段）。
# 与 sync GDScript path 的区别：finalizer_total_ms / finalizer_cell_ms 用 worker 算的
# 整个 finalizer_us（一个数表示整个 kernel wall time），不细分。temperature/tta cell
# mirror 字段恒 false（C++ worker 不能碰 HexCell；GDScript facade 启用时 cell.temperature
# getter 直接走 SoA，所以 worker 写 slot 即等价）。
func _build_finalizer_diag_from_worker(poll: Dictionary) -> Dictionary:
	var fin_us: float = float(poll.get("finalizer_us", 0))
	var fin_ms: float = fin_us / 1000.0
	return {
		"max_temp_delta":              float(poll.get("fin_max_temp_delta", 0.0)),
		"p95_temp_delta":              float(poll.get("fin_p95_temp_delta", 0.0)),
		"p99_temp_delta":              float(poll.get("fin_p99_temp_delta", 0.0)),
		"preclamp_max_temp_delta":     float(poll.get("fin_preclamp_max_temp_delta", 0.0)),
		"preclamp_p99_temp_delta":     float(poll.get("fin_preclamp_p99_temp_delta", 0.0)),
		"temp_delta_gt_005_count":     int(poll.get("fin_temp_delta_gt_005_count", 0)),
		"temp_delta_gt_010_count":     int(poll.get("fin_temp_delta_gt_010_count", 0)),
		"temp_delta_gt_020_count":     int(poll.get("fin_temp_delta_gt_020_count", 0)),
		"temp_delta_clamped_count":    int(poll.get("fin_temp_delta_clamped_count", 0)),
		"max_transport_anomaly":       float(poll.get("fin_max_transport_anomaly", 0.0)),
		"sea_ice_delta_max":           float(poll.get("fin_sea_ice_delta_max", 0.0)),
		"precip_p95":                  float(poll.get("fin_precip_p95", 0.0)),
		"thermal_finalizer_applied":   true,
		"finalizer_total_ms":          fin_ms,
		"finalizer_cell_ms":           fin_ms,  # worker kernel 不细分
		"finalizer_temp_ms":           0.0,
		"finalizer_tta_ms":            0.0,
		"finalizer_thermal_ms":        0.0,
		"finalizer_sort_ms":           0.0,
		"finalizer_sea_ice_ms":        0.0,
		"finalizer_precip_ms":         0.0,
		"finalizer_write_dense_ms":    0.0,  # worker 已 publish slot；main thread 不再 write_f32_dense
		"finalizer_cells_seen":        int(poll.get("fin_cells_seen", 0)),
		"finalizer_temperature_cell_mirror": false,
		"finalizer_tta_cell_mirror":         false,
		"finalizer_tta_cell_mirror_count":   0,
		"finalizer_tta_clamped_count":       int(poll.get("fin_tta_clamped_count", 0)),
		"finalizer_thermal_init_count":      int(poll.get("fin_thermal_init_count", 0)),
	}


func _async_finalizer_fallback_reason(poll: Dictionary) -> String:
	if poll.is_empty():
		return "sync_path_no_worker"
	if not poll.has("fin_applied"):
		return "missing_fin_applied"
	if bool(poll.get("fin_applied", false)):
		return ""
	var n_cells: int = int(poll.get("n_cells", map.cell_count() if map != null else 0))
	if n_cells <= 0:
		return "missing_sizes:n_cells"
	if _temp_start_of_day_arr.size() != n_cells:
		return "missing_sizes:temp_start"
	if _tta_start_of_day_arr.size() != n_cells:
		return "missing_sizes:tta_start"
	if map == null or map.temp_arr.size() != n_cells \
			or map.temperature_transport_anomaly_arr.size() != n_cells \
			or map.thermal_energy_arr.size() != n_cells:
		return "missing_sizes:map_arrays"
	return "fin_applied_false"


func _apply_daily_climate_finalizer() -> Dictionary:
	var t_total_us: int = Time.get_ticks_usec()
	var diag: Dictionary = {
		"max_temp_delta": 0.0,
		"p95_temp_delta": 0.0,
		"p99_temp_delta": 0.0,
		"preclamp_max_temp_delta": 0.0,
		"preclamp_p99_temp_delta": 0.0,
		"temp_delta_gt_005_count": 0,
		"temp_delta_gt_010_count": 0,
		"temp_delta_gt_020_count": 0,
		"temp_delta_clamped_count": 0,
		"max_transport_anomaly": 0.0,
		"sea_ice_delta_max": 0.0,
		"precip_p95": 0.0,
		"thermal_finalizer_applied": false,
		"finalizer_total_ms": 0.0,
		"finalizer_cell_ms": 0.0,
		"finalizer_temp_ms": 0.0,
		"finalizer_tta_ms": 0.0,
		"finalizer_thermal_ms": 0.0,
		"finalizer_sort_ms": 0.0,
		"finalizer_sea_ice_ms": 0.0,
		"finalizer_precip_ms": 0.0,
		"finalizer_write_dense_ms": 0.0,
		"finalizer_cells_seen": 0,
		"finalizer_temperature_cell_mirror": false,
		"finalizer_tta_cell_mirror": false,
		"finalizer_tta_cell_mirror_count": 0,
		"finalizer_tta_clamped_count": 0,
		"finalizer_thermal_init_count": 0,
	}
	if generator == null or map == null:
		_last_finalizer_diag = diag
		return diag
	var cp = generator._c()
	var n: int = map.cell_count()
	if cp == null or n <= 0:
		_last_finalizer_diag = diag
		return diag
	var temp_cap_enabled: bool = true
	if cp.get("thermal_final_delta_cap_enabled") != null:
		temp_cap_enabled = bool(cp.thermal_final_delta_cap_enabled)
	var temp_cap: float = float(cp.thermal_daily_delta_cap) if cp.get("thermal_daily_delta_cap") != null else 0.15
	var tta_cap: float = float(cp.temperature_transport_anomaly_daily_cap) if cp.get("temperature_transport_anomaly_daily_cap") != null else 0.12
	var temp_a: PackedFloat32Array = map.temp_arr
	var tta_a: PackedFloat32Array = map.temperature_transport_anomaly_arr
	var mirror_temperature_cells: bool = true
	if map.has_indices() and n > 0:
		var probe_cell: HexCell = map.cell_at(0)
		mirror_temperature_cells = probe_cell == null or not probe_cell.is_facade_enabled()
	diag["finalizer_temperature_cell_mirror"] = mirror_temperature_cells
	var mirror_tta_cells: bool = mirror_temperature_cells
	diag["finalizer_tta_cell_mirror"] = mirror_tta_cells
	var cells: Array = []
	if mirror_temperature_cells or mirror_tta_cells:
		cells = map.iter_cells() if map.has_indices() else map.all_cells()
	var has_temp_start: bool = _temp_start_of_day_arr.size() == n
	var has_tta_start: bool = _tta_start_of_day_arr.size() == n
	var t_cells_us: int = Time.get_ticks_usec()
	var t_part_us: int = t_cells_us
	var temp_limit: int = mini(n, temp_a.size())
	var temp_deltas: PackedFloat32Array = PackedFloat32Array()
	var preclamp_temp_deltas: PackedFloat32Array = PackedFloat32Array()
	temp_deltas.resize(temp_limit)
	preclamp_temp_deltas.resize(temp_limit)
	var max_temp_delta: float = 0.0
	var preclamp_max_temp_delta: float = 0.0
	var temp_delta_gt_005_count: int = 0
	var temp_delta_gt_010_count: int = 0
	var temp_delta_gt_020_count: int = 0
	var temp_delta_clamped_count: int = 0
	for i in range(temp_limit):
		var start_t: float = _temp_start_of_day_arr[i] if has_temp_start else temp_a[i]
		var raw_final_t: float = temp_a[i]
		var final_t: float = raw_final_t
		var pre_abs_dt: float = absf(raw_final_t - start_t)
		preclamp_temp_deltas[i] = pre_abs_dt
		if pre_abs_dt > preclamp_max_temp_delta:
			preclamp_max_temp_delta = pre_abs_dt
		if temp_cap_enabled and has_temp_start:
			final_t = clampf(final_t, start_t - temp_cap, start_t + temp_cap)
			final_t = clampf(final_t, 0.0, 1.0)
			if absf(final_t - raw_final_t) > 0.000001:
				temp_delta_clamped_count += 1
			temp_a[i] = final_t
		var abs_dt: float = absf(final_t - start_t)
		temp_deltas[i] = abs_dt
		if abs_dt > 0.005:
			temp_delta_gt_005_count += 1
		if abs_dt > 0.010:
			temp_delta_gt_010_count += 1
		if abs_dt > 0.020:
			temp_delta_gt_020_count += 1
		if abs_dt > max_temp_delta:
			max_temp_delta = abs_dt
		if mirror_temperature_cells and i < cells.size() and cells[i] != null:
			cells[i].temperature = final_t
	diag["max_temp_delta"] = max_temp_delta
	diag["preclamp_max_temp_delta"] = preclamp_max_temp_delta
	diag["temp_delta_gt_005_count"] = temp_delta_gt_005_count
	diag["temp_delta_gt_010_count"] = temp_delta_gt_010_count
	diag["temp_delta_gt_020_count"] = temp_delta_gt_020_count
	diag["temp_delta_clamped_count"] = temp_delta_clamped_count
	diag["finalizer_temp_ms"] = float(Time.get_ticks_usec() - t_part_us) / 1000.0
	t_part_us = Time.get_ticks_usec()
	var tta_limit: int = mini(n, tta_a.size())
	var max_transport_anomaly: float = 0.0
	var finalizer_tta_clamped_count: int = 0
	var finalizer_tta_cell_mirror_count: int = 0
	for i in range(tta_limit):
		var start_tta: float = _tta_start_of_day_arr[i] if has_tta_start else 0.0
		var raw_final_tta: float = tta_a[i]
		var final_tta: float = raw_final_tta
		var tta_clamped: bool = false
		if tta_cap > 0.0 and has_tta_start:
			final_tta = clampf(final_tta, start_tta - tta_cap, start_tta + tta_cap)
			if absf(final_tta - raw_final_tta) > 0.000001:
				tta_a[i] = final_tta
				tta_clamped = true
				finalizer_tta_clamped_count += 1
		var abs_tta: float = absf(final_tta)
		if abs_tta > max_transport_anomaly:
			max_transport_anomaly = abs_tta
		if mirror_tta_cells and tta_clamped and i < cells.size() and cells[i] != null:
			cells[i].temperature_transport_anomaly = final_tta
			finalizer_tta_cell_mirror_count += 1
	diag["max_transport_anomaly"] = max_transport_anomaly
	diag["finalizer_tta_clamped_count"] = finalizer_tta_clamped_count
	diag["finalizer_tta_cell_mirror_count"] = finalizer_tta_cell_mirror_count
	diag["finalizer_tta_ms"] = float(Time.get_ticks_usec() - t_part_us) / 1000.0
	t_part_us = Time.get_ticks_usec()
	var thermal_a: PackedFloat32Array = map.thermal_energy_arr
	var ema_a: PackedByteArray = map.ema_initialized_arr
	var thermal_limit: int = mini(n, thermal_a.size())
	var finalizer_thermal_init_count: int = 0
	for i in range(thermal_limit):
		var needs_init: bool = is_nan(thermal_a[i]) or is_inf(thermal_a[i])
		if i < ema_a.size() and ema_a[i] == 0:
			needs_init = true
		if needs_init and i < temp_a.size():
			thermal_a[i] = temp_a[i]
			finalizer_thermal_init_count += 1
	diag["finalizer_thermal_init_count"] = finalizer_thermal_init_count
	diag["finalizer_thermal_ms"] = float(Time.get_ticks_usec() - t_part_us) / 1000.0
	diag["finalizer_cell_ms"] = float(Time.get_ticks_usec() - t_cells_us) / 1000.0
	diag["finalizer_cells_seen"] = n
	var t_sort_us: int = Time.get_ticks_usec()
	temp_deltas.sort()
	preclamp_temp_deltas.sort()
	diag["p95_temp_delta"] = _percentile_from_sorted(temp_deltas, 0.95)
	diag["p99_temp_delta"] = _percentile_from_sorted(temp_deltas, 0.99)
	diag["preclamp_p99_temp_delta"] = _percentile_from_sorted(preclamp_temp_deltas, 0.99)
	diag["finalizer_sort_ms"] = float(Time.get_ticks_usec() - t_sort_us) / 1000.0
	var t_sea_ice_us: int = Time.get_ticks_usec()
	if map.sea_ice_frac_arr.size() == n and map.sea_ice_frac_arr_prev.size() == n:
		for i in range(n):
			var ds: float = absf(map.sea_ice_frac_arr[i] - map.sea_ice_frac_arr_prev[i])
			if ds > float(diag["sea_ice_delta_max"]):
				diag["sea_ice_delta_max"] = ds
	diag["finalizer_sea_ice_ms"] = float(Time.get_ticks_usec() - t_sea_ice_us) / 1000.0
	var t_precip_us: int = Time.get_ticks_usec()
	if map.weather_precip_arr.size() == n:
		var precip_vals: PackedFloat32Array = map.weather_precip_arr.duplicate()
		precip_vals.sort()
		diag["precip_p95"] = _percentile_from_sorted(precip_vals, 0.95)
	diag["finalizer_precip_ms"] = float(Time.get_ticks_usec() - t_precip_us) / 1000.0
	if _world != null and _world.is_bound():
		var t_write_us: int = Time.get_ticks_usec()
		var cid_temp: int = int(_cid.get(DCComponentIds.CELL_TEMP, -1))
		if cid_temp >= 0 and _world.has_method("write_f32_dense"):
			_world.write_f32_dense(cid_temp, temp_a)
		var cid_tta: int = int(_cid.get(DCComponentIds.CELL_TEMPERATURE_TRANSPORT_ANOMALY, -1))
		if cid_tta >= 0 and _world.has_method("write_f32_dense"):
			_world.write_f32_dense(cid_tta, tta_a)
		var cid_heat: int = int(_cid.get(DCComponentIds.CELL_THERMAL_ENERGY, -1))
		if cid_heat >= 0 and _world.has_method("write_f32_dense"):
			_world.write_f32_dense(cid_heat, thermal_a)
		diag["finalizer_write_dense_ms"] = float(Time.get_ticks_usec() - t_write_us) / 1000.0
	diag["thermal_finalizer_applied"] = true
	diag["finalizer_total_ms"] = float(Time.get_ticks_usec() - t_total_us) / 1000.0
	_last_finalizer_diag = diag
	return diag


func _abort_active_pass(reason: String) -> void:
	if _active_pass_state.is_empty():
		return
	_active_pass_state["state"] = _PASS_STATE_ABORTED
	_active_pass_state["abort_reason"] = reason
	_active_pass_state["budget_interrupted"] = false
	_active_pass_state["ended_msec"] = Time.get_ticks_msec()
	_last_pass_status = _PASS_RESULT_ABORTED
	_last_pass_diag = _active_pass_state.duplicate(true)
	_active_pass_token = 0
	_active_pass_state = {}


func _is_active_pass_token(token: int) -> bool:
	return token > 0 and token == _active_pass_token and not _active_pass_state.is_empty()


func _make_pass_result(done: bool, elapsed_ms: float, processed_cells: int,
		cursor_start: int, cursor_end: int, status: String = "") -> Dictionary:
	var result_status: String = status
	if result_status == "":
		result_status = _PASS_RESULT_DONE if done else _PASS_RESULT_CONTINUE
	return {
		"done": done,
		"status": result_status,
		"elapsed_ms": elapsed_ms,
		"processed_cells": processed_cells,
		"cursor_start": cursor_start,
		"cursor_end": cursor_end,
		"budget_interrupted": not done,
	}


func _record_pass_result(pass_id: int, token: int, result: Dictionary, elapsed_ms: float,
		stage_override: String = "", substage_override: String = "", path_override: String = "") -> bool:
	if not _is_active_pass_token(token):
		return false
	var pass_name: String = stage_override
	if pass_name == "" and pass_id >= 0 and pass_id < _PASS_NAMES.size():
		pass_name = _PASS_NAMES[pass_id]
	var result_done: bool = bool(result.get("done", true))
	var result_status: String = str(result.get("status", _PASS_RESULT_DONE if result_done else _PASS_RESULT_CONTINUE))
	_last_pass_processed_cells = int(result.get("processed_cells", 0))
	_last_pass_cursor_start = int(result.get("cursor_start", result.get("start_idx", -1)))
	_last_pass_cursor_end = int(result.get("cursor_end", result.get("end_idx", -1)))
	_last_pass_stage = pass_name
	_last_pass_substage = substage_override
	_last_pass_path = path_override
	_last_pass_budget_interrupted = bool(result.get("budget_interrupted", not result_done))
	_last_pass_status = result_status
	var diag_enabled: bool = bool(_active_pass_state.get("diagnostics_enabled", true))
	var integrity_ms: float = 0.0
	_active_pass_state["token"] = token
	_active_pass_state["state"] = _PASS_STATE_DONE if result_done else _PASS_STATE_RUNNING
	_active_pass_state["pass_cursor"] = _pass_cursor
	_active_pass_state["stage"] = pass_name
	_active_pass_state["stage_name"] = pass_name
	_active_pass_state["substage"] = substage_override
	_active_pass_state["path"] = path_override
	_active_pass_state["elapsed_ms"] = elapsed_ms
	_active_pass_state["reported_elapsed_ms"] = float(result.get("elapsed_ms", elapsed_ms))
	_active_pass_state["processed_cells"] = _last_pass_processed_cells
	_active_pass_state["cursor_start"] = _last_pass_cursor_start
	_active_pass_state["cursor_end"] = _last_pass_cursor_end
	_active_pass_state["budget_interrupted"] = _last_pass_budget_interrupted
	_active_pass_state["status"] = result_status
	_active_pass_state["progress_ratio"] = float(_pass_cursor) / float(_PASS_COUNT)
	if result.has("cursor_remaining"):
		_active_pass_state["cursor_remaining"] = int(result.get("cursor_remaining", 0))
	if result.has("budget_cells"):
		_active_pass_state["budget_cells"] = int(result.get("budget_cells", 0))
	if result.has("next_stage"):
		_active_pass_state["next_stage"] = str(result.get("next_stage", ""))
	if result.has("abort_reason"):
		_active_pass_state["abort_reason"] = str(result.get("abort_reason", ""))
	for k in [
		"native_ms", "native_call_ms", "native_compute_ms", "native_apply_ms",
		"native_flush_ms", "refresh_ms", "sync_ms", "sync_total_ms",
		"sync_write_ms", "sync_mark_ms", "sync_path", "dirty_count",
		"diagnostic_wall_ms",
	]:
		if result.has(k):
			_active_pass_state[k] = result[k]
	if generator != null and "_current_fast_tick_idx" in generator:
		_active_pass_state["_tick_idx"] = int(generator._current_fast_tick_idx)
	if diag_enabled:
		var t_integrity_us: int = Time.get_ticks_usec()
		_debug_climate_integrity("%s:%s" % [pass_name, result_status])
		integrity_ms = (Time.get_ticks_usec() - t_integrity_us) / 1000.0
		_last_integrity_diag_ms = integrity_ms
		_last_integrity_diag_stage = "%s:%s" % [pass_name, result_status]
		_active_pass_state["integrity_ms"] = integrity_ms
	_last_pass_diag = _active_pass_state.duplicate(true)
	if pass_name == "transp" and path_override == "gdext":
		_last_transp_native_diag = _last_pass_diag.duplicate(true)
	return true


func _finish_active_pass() -> void:
	if _active_pass_state.is_empty():
		return
	_active_pass_state["state"] = _PASS_STATE_DONE
	_active_pass_state["ended_msec"] = Time.get_ticks_msec()
	_active_pass_state["progress_ratio"] = 1.0
	_last_pass_diag = _active_pass_state.duplicate(true)
	_active_pass_token = 0
	_active_pass_state = {}


# Climate integrity diagnostics. Read-only checks for terrain/is_water,
# DataCore mirrors, temperature seams, wind/ocean transport, and moisture/precip.
func _climate_diag_terrain_water(t: int) -> bool:
	return t == int(TerrainType.TERRAIN.OCEAN) \
			or t == int(TerrainType.TERRAIN.COAST) \
			or t == int(TerrainType.TERRAIN.LAKE) \
			or t == int(TerrainType.TERRAIN.REEF) \
			or t == int(TerrainType.TERRAIN.KELP) \
			or t == int(TerrainType.TERRAIN.SEA_ICE)


func _climate_diag_ocean_water(t: int) -> bool:
	return t == int(TerrainType.TERRAIN.OCEAN) \
			or t == int(TerrainType.TERRAIN.COAST) \
			or t == int(TerrainType.TERRAIN.REEF) \
			or t == int(TerrainType.TERRAIN.KELP)


func _climate_diag_corr(a: PackedFloat32Array, b: PackedFloat32Array, limit: int) -> float:
	var n: int = mini(limit, mini(a.size(), b.size()))
	if n <= 1:
		return 0.0
	var sum_a: float = 0.0
	var sum_b: float = 0.0
	var sum_ab: float = 0.0
	var sum_aa: float = 0.0
	var sum_bb: float = 0.0
	for i in range(n):
		var av: float = a[i]
		var bv: float = b[i]
		sum_a += av
		sum_b += bv
		sum_ab += av * bv
		sum_aa += av * av
		sum_bb += bv * bv
	var nf: float = float(n)
	var den_a: float = nf * sum_aa - sum_a * sum_a
	var den_b: float = nf * sum_bb - sum_b * sum_b
	if den_a <= _CLIMATE_INTEGRITY_EPS or den_b <= _CLIMATE_INTEGRITY_EPS:
		return 0.0
	return (nf * sum_ab - sum_a * sum_b) / sqrt(den_a * den_b)


func _climate_diag_p95(arr: PackedFloat32Array, limit: int) -> float:
	var n: int = mini(limit, arr.size())
	if n <= 0:
		return 0.0
	var vals: Array = []
	vals.resize(n)
	for i in range(n):
		vals[i] = float(arr[i])
	vals.sort()
	return _percentile_from_sorted(vals, 0.95)


func _climate_diag_push_sample(samples: PackedStringArray, text: String) -> void:
	if samples.size() < 6:
		samples.append(text)


func _debug_climate_integrity(stage_name: String, force: bool = false) -> void:
	# 移动端硬短路：诊断在 ARM 上跑 2400 cell × 17 PackedArray read × 8 pass / tick
	# ≈ 6ms 纯 GDScript 开销，吃掉 refresh_climate_daily 80% 的 SUS budget。无论
	# ClimateProfile.climate_pass_diagnostics_enabled 是不是被误设为 true，这里
	# 都不跑——避免移动端误开诊断后 fps 直接塌。force=true 也不破例。
	if OS.has_feature("mobile"):
		return
	if not _diagnostics_enabled():
		return
	if map == null or not map.has_soa():
		return
	var n: int = map.cell_count()
	if n <= 0:
		return
	var now_msec: int = Time.get_ticks_msec()
	if not force \
			and _climate_integrity_log_count >= _CLIMATE_INTEGRITY_INITIAL_LOGS \
			and now_msec - _climate_integrity_last_msec < _CLIMATE_INTEGRITY_MIN_INTERVAL_MSEC:
		return
	_climate_integrity_last_msec = now_msec

	var terrain_a: PackedByteArray = map.terrain_arr
	var base_terrain_a: PackedByteArray = map.base_terrain_arr
	var is_water_a: PackedByteArray = map.is_water_arr
	var temp_a: PackedFloat32Array = map.temp_arr
	var moisture_a: PackedFloat32Array = map.moisture_arr
	var base_moisture_a: PackedFloat32Array = map.base_moisture_arr
	var air_a: PackedFloat32Array = map.air_mass_temp_anomaly_arr
	var tta_a: PackedFloat32Array = map.temperature_transport_anomaly_arr
	var wind_x_a: PackedFloat32Array = map.wind_x_arr
	var wind_y_a: PackedFloat32Array = map.wind_y_arr
	var wind_speed_a: PackedFloat32Array = map.wind_speed_arr
	var ocean_x_a: PackedFloat32Array = map.ocean_current_x_arr
	var ocean_y_a: PackedFloat32Array = map.ocean_current_y_arr
	var sea_ice_a: PackedFloat32Array = map.sea_ice_frac_arr
	var precip_a: PackedFloat32Array = map.weather_precip_arr
	var vapor_a: PackedFloat32Array = map.weather_vapor_arr
	var cloud_a: PackedFloat32Array = map.weather_cloud_arr
	var instability_a: PackedFloat32Array = map.weather_instability_arr
	var lat_a: PackedFloat32Array = map.cell_lat_norm_arr
	var elev_a: PackedFloat32Array = map.elevation_arr
	var nb_a: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var water_lut: PackedByteArray = MapData.is_water_lut()

	var terrain_iswater_mismatch: int = 0
	var terrain_lut_mismatch: int = 0
	var cell_terrain_mismatch: int = 0
	var cell_passable_mismatch: int = 0
	var cell_iswater_mismatch: int = 0
	var ocean_water_zero_current: int = 0
	var non_ocean_nonzero_current: int = 0
	var samples: PackedStringArray = PackedStringArray()
	for i in range(n):
		var t: int = int(terrain_a[i]) if i < terrain_a.size() else -1
		var terrain_water: bool = MapData.terrain_is_water(t)
		var ocean_water: bool = _climate_diag_ocean_water(t)
		var iw_arr: int = int(is_water_a[i]) if i < is_water_a.size() else -1
		var lut_water: int = int(water_lut[t]) if t >= 0 and t < water_lut.size() else -1
		if iw_arr >= 0 and iw_arr != (1 if terrain_water else 0):
			terrain_iswater_mismatch += 1
			if terrain_iswater_mismatch <= 3:
				var c_m: HexCell = map.cell_at(i)
				_climate_diag_push_sample(samples, "idx=%d q=%s r=%s terr=%d terrWater=%s isw=%d temp=%.3f oc=(%.3f,%.3f)" % [
					i,
					str(c_m.q) if c_m != null else "?",
					str(c_m.r) if c_m != null else "?",
					t, str(terrain_water), iw_arr,
					temp_a[i] if i < temp_a.size() else -1.0,
					ocean_x_a[i] if i < ocean_x_a.size() else 0.0,
					ocean_y_a[i] if i < ocean_y_a.size() else 0.0,
				])
		if iw_arr >= 0 and lut_water >= 0 and iw_arr != lut_water:
			terrain_lut_mismatch += 1
		var c: HexCell = map.cell_at(i)
		if c != null:
			var cell_terrain_water: bool = MapData.terrain_is_water(int(c.terrain))
			if int(c.terrain) != t:
				cell_terrain_mismatch += 1
				if cell_terrain_mismatch <= 3:
					_climate_diag_push_sample(samples, "cellTerrMismatch idx=%d q=%s r=%s cellTerr=%d soaTerr=%d cellBase=%d soaBase=%d isw=%d seaIce=%.3f temp=%.3f" % [
						i,
						str(c.q),
						str(c.r),
						int(c.terrain),
						t,
						int(c.base_terrain),
						int(base_terrain_a[i]) if i < base_terrain_a.size() else -1,
						iw_arr,
						sea_ice_a[i] if i < sea_ice_a.size() else -1.0,
						temp_a[i] if i < temp_a.size() else -1.0,
					])
			if cell_terrain_water != terrain_water:
				cell_passable_mismatch += 1
			if iw_arr >= 0 and iw_arr != (1 if cell_terrain_water else 0):
				cell_iswater_mismatch += 1
		var ocx: float = ocean_x_a[i] if i < ocean_x_a.size() else 0.0
		var ocy: float = ocean_y_a[i] if i < ocean_y_a.size() else 0.0
		var oc_mag: float = sqrt(ocx * ocx + ocy * ocy)
		if ocean_water and oc_mag <= 0.001:
			ocean_water_zero_current += 1
		elif not ocean_water and oc_mag > 0.001:
			non_ocean_nonzero_current += 1

	var dc_terrain_mismatch: int = 0
	var dc_iswater_mismatch: int = 0
	if _world != null and _world.is_bound() and _world.has_method("view_u8"):
		var cid_terrain: int = int(_cid.get(DCComponentIds.CELL_TERRAIN, -1))
		if cid_terrain >= 0:
			var dc_terrain: PackedByteArray = _world.view_u8(cid_terrain)
			for i in range(mini(n, mini(dc_terrain.size(), terrain_a.size()))):
				if int(dc_terrain[i]) != int(terrain_a[i]):
					dc_terrain_mismatch += 1
		var cid_iswater: int = int(_cid.get(DCComponentIds.CELL_IS_WATER, -1))
		if cid_iswater >= 0:
			var dc_iswater: PackedByteArray = _world.view_u8(cid_iswater)
			for i in range(mini(n, mini(dc_iswater.size(), is_water_a.size()))):
				if int(dc_iswater[i]) != int(is_water_a[i]):
					dc_iswater_mismatch += 1

	var temp_edge_max: float = 0.0
	var temp_edge_warn: int = 0
	var temp_edge_sample: String = ""
	var edge_vals: Array = []
	if temp_a.size() >= n and nb_a.size() >= n * 6:
		for i in range(n):
			for d in range(6):
				var ni: int = int(nb_a[i * 6 + d])
				if ni <= i or ni >= n:
					continue
				var dt_edge: float = absf(temp_a[i] - temp_a[ni])
				edge_vals.append(dt_edge)
				if dt_edge > _CLIMATE_INTEGRITY_TEMP_EDGE_WARN:
					temp_edge_warn += 1
				if dt_edge > temp_edge_max:
					temp_edge_max = dt_edge
					var ci: HexCell = map.cell_at(i)
					var cn: HexCell = map.cell_at(ni)
					var ox_i: float = ocean_x_a[i] if i < ocean_x_a.size() else 0.0
					var oy_i: float = ocean_y_a[i] if i < ocean_y_a.size() else 0.0
					var ox_n: float = ocean_x_a[ni] if ni < ocean_x_a.size() else 0.0
					var oy_n: float = ocean_y_a[ni] if ni < ocean_y_a.size() else 0.0
					temp_edge_sample = "%d(%s,%s,t%d,iw%d,e%.3f,T%.3f,bm%.3f,si%.3f,tta%.3f,om%.3f)->%d(%s,%s,t%d,iw%d,e%.3f,T%.3f,bm%.3f,si%.3f,tta%.3f,om%.3f)" % [
						i, str(ci.q) if ci != null else "?", str(ci.r) if ci != null else "?",
						int(terrain_a[i]) if i < terrain_a.size() else -1,
						int(is_water_a[i]) if i < is_water_a.size() else -1,
						elev_a[i] if i < elev_a.size() else -1.0,
						temp_a[i] if i < temp_a.size() else -1.0,
						base_moisture_a[i] if i < base_moisture_a.size() else -1.0,
						sea_ice_a[i] if i < sea_ice_a.size() else -1.0,
						tta_a[i] if i < tta_a.size() else 0.0,
						sqrt(ox_i * ox_i + oy_i * oy_i),
						ni, str(cn.q) if cn != null else "?", str(cn.r) if cn != null else "?",
						int(terrain_a[ni]) if ni < terrain_a.size() else -1,
						int(is_water_a[ni]) if ni < is_water_a.size() else -1,
						elev_a[ni] if ni < elev_a.size() else -1.0,
						temp_a[ni] if ni < temp_a.size() else -1.0,
						base_moisture_a[ni] if ni < base_moisture_a.size() else -1.0,
						sea_ice_a[ni] if ni < sea_ice_a.size() else -1.0,
						tta_a[ni] if ni < tta_a.size() else 0.0,
						sqrt(ox_n * ox_n + oy_n * oy_n),
					]
	edge_vals.sort()
	var temp_edge_p99: float = _percentile_from_sorted(edge_vals, 0.99)

	var lat_band_max: float = 0.0
	var lat_band_sample: String = ""
	if lat_a.size() >= n and temp_a.size() >= n:
		var bands: Dictionary = {}
		for i in range(n):
			var key: int = int(round(lat_a[i] * 1000000.0))
			var rec: Array = bands.get(key, [0.0, 0])
			rec[0] = float(rec[0]) + temp_a[i]
			rec[1] = int(rec[1]) + 1
			bands[key] = rec
		var keys: Array = bands.keys()
		keys.sort()
		for ki in range(1, keys.size()):
			var k0: int = int(keys[ki - 1])
			var k1: int = int(keys[ki])
			var r0: Array = bands[k0]
			var r1: Array = bands[k1]
			var m0: float = float(r0[0]) / maxf(1.0, float(r0[1]))
			var m1: float = float(r1[0]) / maxf(1.0, float(r1[1]))
			var dm: float = absf(m1 - m0)
			if dm > lat_band_max:
				lat_band_max = dm
				lat_band_sample = "%.6f->%.6f mean %.3f->%.3f" % [float(k0) / 1000000.0, float(k1) / 1000000.0, m0, m1]

	var air_nonzero: int = 0
	var air_abs_max: float = 0.0
	for i in range(mini(n, air_a.size())):
		var av_abs: float = absf(air_a[i])
		if av_abs > _CLIMATE_INTEGRITY_EPS:
			air_nonzero += 1
		air_abs_max = maxf(air_abs_max, av_abs)
	var tta_abs_max: float = 0.0
	for i in range(mini(n, tta_a.size())):
		tta_abs_max = maxf(tta_abs_max, absf(tta_a[i]))

	var wind_mag_min: float = 999999.0
	var wind_mag_max: float = 0.0
	var wind_mag_sum: float = 0.0
	var wind_delta_vals: Array = []
	var wind_n: int = mini(n, mini(wind_x_a.size(), wind_y_a.size()))
	for i in range(wind_n):
		var wx: float = wind_x_a[i]
		var wy: float = wind_y_a[i]
		var wm: float = sqrt(wx * wx + wy * wy)
		wind_mag_min = minf(wind_mag_min, wm)
		wind_mag_max = maxf(wind_mag_max, wm)
		wind_mag_sum += wm
		if _climate_integrity_prev_wind_x.size() == wind_x_a.size() and _climate_integrity_prev_wind_y.size() == wind_y_a.size():
			var dwx: float = wx - _climate_integrity_prev_wind_x[i]
			var dwy: float = wy - _climate_integrity_prev_wind_y[i]
			wind_delta_vals.append(sqrt(dwx * dwx + dwy * dwy))
	wind_delta_vals.sort()
	if wind_n <= 0:
		wind_mag_min = 0.0
	var wind_mag_avg: float = wind_mag_sum / maxf(1.0, float(wind_n))
	var wind_delta_p95: float = _percentile_from_sorted(wind_delta_vals, 0.95)

	var wind_speed_min: float = 999999.0
	var wind_speed_max: float = 0.0
	var wind_speed_sum: float = 0.0
	var wind_speed_delta_vals: Array = []
	var wind_speed_n: int = mini(n, wind_speed_a.size())
	for i in range(wind_speed_n):
		var wspd: float = wind_speed_a[i]
		wind_speed_min = minf(wind_speed_min, wspd)
		wind_speed_max = maxf(wind_speed_max, wspd)
		wind_speed_sum += wspd
		if _climate_integrity_prev_wind_speed.size() == wind_speed_a.size():
			wind_speed_delta_vals.append(absf(wspd - _climate_integrity_prev_wind_speed[i]))
	wind_speed_delta_vals.sort()
	if wind_speed_n <= 0:
		wind_speed_min = 0.0
	var wind_speed_avg: float = wind_speed_sum / maxf(1.0, float(wind_speed_n))
	var wind_speed_delta_p95: float = _percentile_from_sorted(wind_speed_delta_vals, 0.95)

	var ocean_mag_max: float = 0.0
	var ocean_mag_sum: float = 0.0
	var ocean_delta_vals: Array = []
	var ocean_n: int = mini(n, mini(ocean_x_a.size(), ocean_y_a.size()))
	for i in range(ocean_n):
		var ox: float = ocean_x_a[i]
		var oy: float = ocean_y_a[i]
		var om: float = sqrt(ox * ox + oy * oy)
		ocean_mag_max = maxf(ocean_mag_max, om)
		ocean_mag_sum += om
		if _climate_integrity_prev_ocean_x.size() == ocean_x_a.size() and _climate_integrity_prev_ocean_y.size() == ocean_y_a.size():
			var dox: float = ox - _climate_integrity_prev_ocean_x[i]
			var doy: float = oy - _climate_integrity_prev_ocean_y[i]
			ocean_delta_vals.append(sqrt(dox * dox + doy * doy))
	ocean_delta_vals.sort()
	var ocean_mag_avg: float = ocean_mag_sum / maxf(1.0, float(ocean_n))
	var ocean_delta_p95: float = _percentile_from_sorted(ocean_delta_vals, 0.95)

	var moisture_base_r: float = _climate_diag_corr(moisture_a, base_moisture_a, n)
	var precip_vapor_r: float = _climate_diag_corr(precip_a, vapor_a, n)
	var precip_cloud_r: float = _climate_diag_corr(precip_a, cloud_a, n)
	var precip_instability_r: float = _climate_diag_corr(precip_a, instability_a, n)
	var precip_p95: float = _climate_diag_p95(precip_a, n)

	_climate_integrity_log_count += 1
	print("[climate/integrity] #%d stage=%s phase=%.3f n=%d terr_isw_mis=%d terr_lut_mis=%d cell_terr_mis=%d cell_pass_mis=%d cell_isw_mis=%d dc_terr_mis=%d dc_isw_mis=%d temp_edge_max=%.3f temp_edge_p99=%.3f temp_edge_warn=%d lat_band_max=%.3f air_nonzero=%d air_abs_max=%.5f tta_abs_max=%.5f wind_dir_mag=%.3f/%.3f/%.3f wind_dir_delta_p95=%.6f wind_speed=%.3f/%.3f/%.3f wind_speed_delta_p95=%.6f ocean_mag_avg=%.3f ocean_mag_max=%.3f ocean_delta_p95=%.6f ocean_water_zero=%d non_ocean_nonzero=%d moisture_base_r=%.3f precip_vapor_r=%.3f precip_cloud_r=%.3f precip_instab_r=%.3f precip_p95=%.3f" % [
		_climate_integrity_log_count, stage_name, _phase_locked, n,
		terrain_iswater_mismatch, terrain_lut_mismatch, cell_terrain_mismatch,
		cell_passable_mismatch, cell_iswater_mismatch, dc_terrain_mismatch,
		dc_iswater_mismatch, temp_edge_max, temp_edge_p99, temp_edge_warn,
		lat_band_max, air_nonzero, air_abs_max, tta_abs_max,
		wind_mag_min, wind_mag_avg, wind_mag_max, wind_delta_p95,
		wind_speed_min, wind_speed_avg, wind_speed_max, wind_speed_delta_p95,
		ocean_mag_avg, ocean_mag_max, ocean_delta_p95,
		ocean_water_zero_current, non_ocean_nonzero_current,
		moisture_base_r, precip_vapor_r, precip_cloud_r, precip_instability_r,
		precip_p95,
	])
	if temp_edge_sample != "":
		print("  [climate/integrity edge] max=%.3f %s" % [temp_edge_max, temp_edge_sample])
	if lat_band_sample != "":
		print("  [climate/integrity lat] max=%.3f %s" % [lat_band_max, lat_band_sample])
	if samples.size() > 0:
		print("  [climate/integrity samples] %s" % " | ".join(samples))

	_climate_integrity_prev_wind_x = wind_x_a.duplicate()
	_climate_integrity_prev_wind_y = wind_y_a.duplicate()
	_climate_integrity_prev_wind_speed = wind_speed_a.duplicate()
	_climate_integrity_prev_ocean_x = ocean_x_a.duplicate()
	_climate_integrity_prev_ocean_y = ocean_y_a.duplicate()


# ─── Async climate round helpers（plan §async-stage-3，2026-06-14） ─────
#
# 设计：当 cp.use_climate_round_async=true，sync sliced run_slice 路径完全短路。
# 代之以两阶段状态机：
#   _round_active=false, _async_round_kicked=false
#     → kick worker，置 _async_round_kicked=true，return partial (round 还没完)
#   _round_active=true, _async_round_kicked=true
#     → 调 poll；返空（worker 没完）→ return partial；返非空 → 同步回 _slots +
#       同步 sea_ice flip events + _finalize_round() 走原逻辑（埋点 / dirty mask）
#
# 主线程单帧开销：kick ~100us + memcpy 220 KB ≈ 0.5ms；poll busy 0；
# 完成 poll 那帧 ≈ memcpy 220 KB + flush_slots_to_map + dirty mark ≈ 2-5ms。
# x1 速度下每 game day = 每 ~1 sec 一次 round；worker 在后台跑 30-50ms 不阻塞主线程。
#
# Stage 3 不再用 _PASS_CURSOR / _pass_cursor 状态机推进（async path 一次性
# 跑完整 round）。breakdown 字段仍照 sync 路径填好以便 main.gd fast tick WARN
# 解析无差异。
func _run_slice_async(ctx: SusTickContext) -> Dictionary:
	var ext = generator._data_core_world_ext
	if ext == null:
		return _async_round_partial_report(0.0, "ext null")
	# Worker 没注册 → first time enter → register（幂等）。
	if not _async_first_round_logged:
		_async_first_round_logged = true
		ext.async_climate_round_register()
		# 静态 knobs 推一次（neighbor_indices + donor_table + foliage_table）
		var static_knobs: Dictionary = _build_async_static_knobs()
		ext.async_climate_round_set_static_knobs(static_knobs)
		print("[climate/async] worker registered + static knobs set (n_cells=%d)" % map.cell_count())

	# Round 启动：kick
	if not _round_active:
		var t_round_start_us: int = Time.get_ticks_usec()
		var t_round_part_us: int = t_round_start_us
		_last_round_start_diag = {
			"round_start_total_ms": 0.0,
			"round_start_phase_ms": 0.0,
			"round_start_terrain_sync_ms": 0.0,
			"round_start_terrain_sync_skipped": false,
			"capture_start_state_ms": 0.0,
			"round_start_state_ms": 0.0,
			"round_start_reset_transp_ms": 0.0,
			"round_start_mark_stale_ms": 0.0,
			"round_start_soa_begin_ms": 0.0,
			"round_start_dirty_ms": 0.0,
		}
		_pass_cursor = 0
		if season_phase_getter.is_valid():
			_phase_locked = float(season_phase_getter.call())
		else:
			_phase_locked = ctx.season_phase
		_last_round_start_diag["round_start_phase_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		_round_t_pass_a_ms = 0.0
		_round_t_pass_b_ms = 0.0
		_round_t_ocean_ms = 0.0
		_round_t_wind_ms = 0.0
		_round_t_sea_ice_ms = 0.0
		_round_t_transp_ms = 0.0
		_round_t_round_start_ms = Time.get_ticks_msec()
		_round_active = true
		_async_round_kicked = false
		_async_round_poll_attempts = 0
		_async_round_kick_tick = ctx.tick_index
		t_round_part_us = Time.get_ticks_usec()
		var async_terrain_diag: Dictionary = _sync_runtime_terrain_views_for_reason("round_start")
		_last_round_start_diag["round_start_terrain_sync_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		_last_round_start_diag["round_start_terrain_sync_skipped"] = bool(async_terrain_diag.get("skipped", false))
		if not async_terrain_diag.is_empty():
			_last_round_start_diag["round_start_terrain_sync_diag"] = async_terrain_diag.duplicate(true)
		t_round_part_us = Time.get_ticks_usec()
		_begin_round_pass_state()
		_last_round_start_diag["round_start_state_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		# 静态天气根因修复(2026-06-20)：async round 路径原先漏调 soa_begin_climate_transaction()，
		#   而 sync 路径在 round-start(line ~1873)调它。结果 temp_arr_prev / moisture_arr_prev /
		#   snow_cover_arr_prev / sea_ice_frac_arr_prev 四个双缓冲快照永远停在 bake 当天值
		#   （use_climate_round_async 默认 true → 永远走 async → 永远不 swap）。
		#   weather field solve(field_solver.gd:120-121)把 *_prev 作为温度/湿度输入读取 →
		#   热力学强迫(蒸发/水汽容量/不稳定/暖冷门控/地表湿度)全程冻结 → 整图天气类型高度静止、
		#   永久干区/永久湿区，即便风/辐合/SLP 已随 synoptic 修复而移动也带不动一半格子。
		#   这里补齐 swap，镜像 sync：在 _begin_round_pass_state 之后、kick 之前执行；只写 *_prev、
		#   读当前 *_arr（_build_async_kick_input 也只读当前 *_arr），故对 worker 无竞态、无行为改变。
		t_round_part_us = Time.get_ticks_usec()
		if map != null and map.has_soa() and map.has_method("soa_begin_climate_transaction"):
			map.soa_begin_climate_transaction()
		_last_round_start_diag["round_start_soa_begin_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		_last_round_start_diag["round_start_total_ms"] = float(Time.get_ticks_usec() - t_round_start_us) / 1000.0

	# Worker pending 时不重复 kick（kick 返回 false → reused++）。
	if not _async_round_kicked:
		var kick_t0: int = Time.get_ticks_usec()
		var input: Dictionary = _build_async_kick_input(_phase_locked)
		var kicked: bool = bool(ext.async_climate_round_kick(input))
		var kick_ms: float = (Time.get_ticks_usec() - kick_t0) / 1000.0
		if kicked:
			_async_round_kicked = true
		else:
			# Worker busy 处理上一 round → 本 tick 继续等。下个 tick 还可以 poll。
			pass
		# 真异步关键：kick 完立刻让 SUS 把 budget 让给后续 jobs（atlas / weather / ocean）。
		# 报 done=true progress=1.0 → SUS 不会同 tick 内 re-entry。**下一个 tick** 才会
		# 再进 run_slice，那时 worker 已经在后台跑完，poll 直接拿结果。
		# bug 修复 2026-06-14（plan §async-stage-4 真机验证）：之前报 done=false
		# 导致 SUS 同 tick re-entry → busy-wait worker → 主线程 30+ms 全卡死，atlas / weather
		# 拿不到 budget → 视觉冻结。
		return {
			"done": true,
			"work_done": 0,
			"elapsed_ms": kick_ms,
			"progress_ratio": 1.0,
			"stage_name": "async_round_kicked",
			"substage": "kicked" if kicked else "worker_busy",
			"path": "data_core_async",
		}

	# 已 kick → poll
	_async_round_poll_attempts += 1
	var poll_t0: int = Time.get_ticks_usec()
	var poll_result: Dictionary = ext.async_climate_round_poll()
	var poll_ms: float = (Time.get_ticks_usec() - poll_t0) / 1000.0
	if poll_result.is_empty():
		# Worker 还没完成 → 报 done=true 让出 budget。下一 tick 再 poll。
		# bug 修复 2026-06-14（同上）：之前报 done=false 导致 busy-wait。
		return {
			"done": true,
			"work_done": 0,
			"elapsed_ms": poll_ms,
			"progress_ratio": 1.0,
			"stage_name": "async_round_poll_pending",
			"substage": "attempts=%d" % _async_round_poll_attempts,
			"path": "data_core_async",
		}

	# Worker 完成：poll 已经把 19 个 slot 写回 _slots + flush 到 MapData。
	# 主线程要处理 sea_ice flip events（map.terrain_arr 镜像 + atlas dirty）。
	var finish_t0: int = Time.get_ticks_usec()
	var flip_t0: int = Time.get_ticks_usec()
	_handle_async_sea_ice_flips(poll_result)
	var flip_ms: float = float(Time.get_ticks_usec() - flip_t0) / 1000.0

	# 填充 per-pass breakdown 让 main.gd 日志解析无差异
	_round_t_pass_a_ms     = float(poll_result.get("pass_a_us", 0)) / 1000.0
	_round_t_pass_b_ms     = float(poll_result.get("pass_b_us", 0)) / 1000.0
	_round_t_ocean_ms      = (float(poll_result.get("ocean_water_us", 0)) + float(poll_result.get("ocean_land_us", 0))) / 1000.0
	_round_t_wind_ms       = (float(poll_result.get("wind_air_us", 0)) + float(poll_result.get("wind_surface_us", 0))) / 1000.0
	_round_t_sea_ice_ms    = float(poll_result.get("sea_ice_us", 0)) / 1000.0
	_round_t_transp_ms     = float(poll_result.get("transp_us", 0)) / 1000.0

	# Stage 4 真机诊断（前 5 round 打一次）：判断每个 pass 是否真的跑了。
	# 每个 pass kernel 守卫失败时 us=0，证明该 pass 因 input size mismatch 跳过。
	# Fix #11 second pass (2026-06-16)：原条件 `_async_round_poll_attempts <= 5`
	# 在 worker 完成快时（每 round 都只 1 个 attempt）变成每 round 都触发，
	# 50 lines/10s 污染 logcat。改为按 round 计数（_async_round_log_count）。
	_async_round_log_count += 1
	if PKLog.enabled and (_async_round_log_count <= 5 or (_async_round_log_count % 60 == 0)):
		var sip: int = int(poll_result.get("sea_ice_us", 0))
		var pap: int = int(poll_result.get("pass_a_us", 0))
		var pbp: int = int(poll_result.get("pass_b_us", 0))
		var owp: int = int(poll_result.get("ocean_water_us", 0))
		var olp: int = int(poll_result.get("ocean_land_us", 0))
		var wap: int = int(poll_result.get("wind_air_us", 0))
		var wsp: int = int(poll_result.get("wind_surface_us", 0))
		var trp: int = int(poll_result.get("transp_us", 0))
		var fci: int = int(poll_result.get("flipped_cell_indices", PackedInt32Array()).size())
		print("[climate/async DIAG] round #%d: pa=%dus pb=%dus ow=%dus ol=%dus wa=%dus ws=%dus si=%dus tr=%dus | flipped=%d" % [
			_async_round_log_count, pap, pbp, owp, olp, wap, wsp, sip, trp, fci])

	# Fix #6 async (2026-06-15 v3 已回退)：实测显示拆 slice 让 sus_ticks/120 从 61
	# 涨到 79（+30%），sus_frame_avg 28→36ms，FPS 66→29。每个 SUS slice 都有
	# scheduler 边界开销 + 让更多帧承担 SUS 工作。finalize 5-8ms 是确定性 cost
	# 不是随机 spike，拆 slice 反而恶化整体。保留代码作为 reference。
	# 直接走原行为：同 tick 跑完 finalize，return done=true。
	# Round 结束：原 _finalize_round 处理 dirty mask / climate breakdown / annual log。
	_pass_cursor = _PASS_COUNT
	var finalize_t0: int = Time.get_ticks_usec()
	# Stage 9 / Fix #11 (2026-06-16)：传 poll_result 进 _finalize_round，
	# 让它优先用 worker 已算好的 finalizer diag，跳过同名 GDScript 2400-loop。
	_finalize_round(poll_result)
	var finalize_ms: float = float(Time.get_ticks_usec() - finalize_t0) / 1000.0
	var finish_ms: float = float(Time.get_ticks_usec() - finish_t0) / 1000.0
	if generator != null and "_last_climate_breakdown" in generator:
		generator._last_climate_breakdown["async_poll_ms"] = poll_ms
		generator._last_climate_breakdown["async_flip_ms"] = flip_ms
		generator._last_climate_breakdown["async_finalize_ms"] = finalize_ms
		generator._last_climate_breakdown["async_finish_ms"] = finish_ms

	if int(poll_result.get("worker_total_us", 0)) > 50_000:
		# Worker 跑超 50ms 偶尔可见，但不严重。可以提示。
		print("[climate/async] slow round worker_total_us=%d kick_to_poll_attempts=%d" % [
			int(poll_result.get("worker_total_us", 0)), _async_round_poll_attempts,
		])

	return {
		"done": true,
		"work_done": map.cell_count(),
		"elapsed_ms": poll_ms,
		"progress_ratio": 1.0,
		"stage_name": "async_round_done",
		"substage": "pass_count=%d" % _PASS_COUNT,
		"path": "data_core_async",
		"poll_ms": poll_ms,
		"flip_ms": flip_ms,
		"finalize_ms": finalize_ms,
		"finish_ms": finish_ms,
		"finalizer_cpp_worker": bool(poll_result.get("fin_applied", false)),
		"finalizer_fallback_reason": _async_finalizer_fallback_reason(poll_result),
	}


# 返回 partial report 给 SUS scheduler（round 还没完）。
func _async_round_partial_report(slice_ms: float, stage_label: String) -> Dictionary:
	return {
		"done": false,
		"work_done": 0,
		"elapsed_ms": slice_ms,
		"progress_ratio": 0.0,
		"stage_name": "async_round_" + stage_label,
		"substage": "attempts=%d" % _async_round_poll_attempts,
		"path": "data_core_async",
	}


# 构造 async kick 用的 input Dictionary（所有 climate pass 需要读的字段 + cp scalars）。
# 主线程跑一次 ~0.5ms（memcpy 220 KB），值得：worker 在后台 30-50ms 不阻塞主线程。
func _build_async_kick_input(season_phase: float) -> Dictionary:
	var cp: ClimateProfile = generator._c()
	var n_cells: int = map.cell_count()
	# 默认 mask = 0xFF（全开 round 模式）。Stage 3 把开关字段也放进来便于调试。
	var input: Dictionary = {
		"n_cells": n_cells,
		"passes_mask": 0xFF,
		# pass_a 用
		"is_water": map.is_water_arr,
		"terrain": map.terrain_arr,
		"cover": map.cover_arr,
		"ema_initialized": map.ema_initialized_arr,
		"elevation": map.elevation_arr,
		"base_moisture": map.base_moisture_arr,
		"lat_norm": map.cell_lat_norm_arr,
		"temp_baseline_year": map.temp_baseline_year_arr,
		"temp": map.temp_arr,
		"temp_30d": map.temp_30d_arr,
		"temp_365d": map.temp_365d_arr,
		"thermal_energy": map.thermal_energy_arr,
		"snowpack": map.snowpack_arr,
		# pass_b 共享
		"landform": map.landform_arr,
		"vegetation": map.vegetation_arr,
		"moisture": map.moisture_arr,
		"snow_cover": map.snow_cover_arr,
		"pos_x": map.cell_pos_x_arr,
		"pos_y": map.cell_pos_y_arr,
		"insolation_dev": map.insolation_dev_arr,
		"temp_transport_anomaly": map.temperature_transport_anomaly_arr,
		"local_thermal_anomaly": map.local_thermal_anomaly_arr,
		"sea_ice_frac": map.sea_ice_frac_arr,
		"sea_ice_frac_inout": map.sea_ice_frac_arr,  # sea_ice 也用
		"base_terrain": map.base_terrain_arr,
		"upwelling_strength": map.upwelling_strength_arr,
		"insolation_now": map.insolation_now_arr,
		"cell_temperature_arr": map.temp_arr,  # sea_ice 期望 climate-adjusted T（round 内 wind_surface 写完更新）
		# ocean_water/land 共享
		"ocean_current_x": map.ocean_current_x_arr,
		"ocean_current_y": map.ocean_current_y_arr,
		"ocean_thermal_anomaly": map.ocean_thermal_anomaly_arr,
		# wind_air/surface 共享
		"wind_x": map.wind_x_arr,
		"wind_y": map.wind_y_arr,
		"wind_speed": map.wind_speed_arr,
		"temp_baseline": map.temp_baseline_arr,
		"air_mass_temp_anomaly": map.air_mass_temp_anomaly_arr,
		# water_terrain_ids LUT（与 sync run_sea_ice_daily_pass 同源）
		"water_terrain_ids": PackedByteArray([
			int(TerrainType.TERRAIN.OCEAN) & 0xFF,
			int(TerrainType.TERRAIN.COAST) & 0xFF,
			int(TerrainType.TERRAIN.LAKE) & 0xFF,
			int(TerrainType.TERRAIN.REEF) & 0xFF,
			int(TerrainType.TERRAIN.KELP) & 0xFF,
			int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
		]),
		# sea_ice 翻转用的 terrain enum ids
		"si_terrain_lake_id":    int(TerrainType.TERRAIN.LAKE) & 0xFF,
		"si_terrain_sea_ice_id": int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
		"si_terrain_ocean_id":   int(TerrainType.TERRAIN.OCEAN) & 0xFF,
		# round scalars
		"season_phase": season_phase,
		"axial_tilt_deg": float(cp.axial_tilt_deg) if "axial_tilt_deg" in cp else 23.5,
		"day_length_gain": float(cp.insolation_daylen_amp) if "insolation_daylen_amp" in cp else 0.35,
		"solar_gain": float(cp.solar_gain) if "solar_gain" in cp else 1.0,
		"insol_amp": float(cp.season_temp_amp) if "season_temp_amp" in cp else 0.20,
		"insol_gain": float(cp.insolation_season_gain) if "insolation_season_gain" in cp else 1.0,
		"moist_scale_now": 1.0,
		"days_per_year": generator._calendar_days_per_year(),
		"sea_level": float(generator._last_cfg.sea_level) if generator._last_cfg != null else 0.5,
		# pass_a 扩展 scalars — mirror sync `_climate_pass_a` cp_struct。
		"thermal_inertia_land": float(cp.thermal_inertia_land) if "thermal_inertia_land" in cp else 0.35,
		"thermal_inertia_water": float(cp.thermal_inertia_water) if "thermal_inertia_water" in cp else 0.07,
		"thermal_inertia_snow": float(cp.thermal_inertia_snow) if "thermal_inertia_snow" in cp else 0.09,
		"thermal_inertia_high_mountain": float(cp.thermal_inertia_high_mountain) if "thermal_inertia_high_mountain" in cp else 0.16,
		"thermal_daily_delta_cap": float(cp.thermal_daily_delta_cap) if "thermal_daily_delta_cap" in cp else 0.15,
		"snowpack_cover_low": float(cp.snowpack_cover_low) if "snowpack_cover_low" in cp else 0.05,
		"snowpack_cover_full": float(cp.snowpack_cover_full) if "snowpack_cover_full" in cp else 0.32,
		"insol_dev_min": float(cp.insolation_dev_clamp_min) if "insolation_dev_clamp_min" in cp else -1.0,
		"insol_dev_max": float(cp.insolation_dev_clamp_max) if "insolation_dev_clamp_max" in cp else 1.0,
		# transp scalars
		"transp_outflow_rate": float(cp.transpiration_outflow_rate) if "transpiration_outflow_rate" in cp else 0.025,
		"transp_self_rate":    float(cp.transpiration_self_rate)    if "transpiration_self_rate"    in cp else 0.015,
	}
	# pass_b knobs（移植自 sync _build_native_daily_climate_pass_b_knobs，字段名必须 mirror）
	input["pb_winter_boost"]  = 1.0
	input["pb_snow_cool"]     = float(cp.snow_albedo_cooling) if "snow_albedo_cooling" in cp else 0.0
	input["pb_veg_cool"]      = float(cp.vegetation_cooling) if "vegetation_cooling" in cp else 0.0
	input["pb_diurnal_amp"]   = float(cp.landform_diurnal_amp) if "landform_diurnal_amp" in cp else 0.0
	input["pb_evap_gain"]     = float(cp.evaporation_gain) if "evaporation_gain" in cp else 0.0
	input["pb_rs_threshold"]  = float(cp.rain_shadow_threshold) if "rain_shadow_threshold" in cp else 0.0
	input["pb_rs_factor"]     = float(cp.rain_shadow_factor) if "rain_shadow_factor" in cp else 1.0
	input["pb_rs_lookback"]   = max(0, int(cp.rain_shadow_lookback)) if "rain_shadow_lookback" in cp else 0
	input["pb_t_freeze"]      = float(cp.sea_ice_form_threshold) if "sea_ice_form_threshold" in cp else 0.0
	input["pb_coupling_gain"] = float(cp.ocean_moisture_coupling_gain) if "ocean_moisture_coupling_gain" in cp else 0.0
	# coast_leak 来自 _last_cfg.COASTAL_HEAT_LEAK，不是 cp 字段
	input["pb_coast_leak"]    = float(generator._last_cfg.COASTAL_HEAT_LEAK) if generator._last_cfg != null else 0.0
	input["pb_sea_ice_albedo_cooling"] = float(cp.sea_ice_albedo_cooling) if "sea_ice_albedo_cooling" in cp else 0.0
	# ocean_water knobs — sync 用 _last_cfg.OCEAN_HEAT_* （map_generator.gd:9679-9680）
	input["ow_advect_steps"] = max(0, int(generator._last_cfg.OCEAN_HEAT_ADVECT_STEPS)) if generator._last_cfg != null else 3
	input["ow_heat_mix"]     = clampf(float(generator._last_cfg.OCEAN_HEAT_MIX), 0.0, 1.0) if generator._last_cfg != null else 0.40
	# ocean TTA scalars — sync 用 _temperature_transport_anomaly_knobs (map_generator.gd:2083-2104)
	# 来源：cp.temperature_transport_anomaly_source_cap / blend_rate / decay_rate / zero_current_decay
	# 缺省值：source_cap=0.16, blend_rate=0.55, decay_rate=0.08, zero_current_decay=0.12
	var _tta_source_cap: float = 0.16
	var _tta_blend_rate: float = 0.55
	var _tta_decay_rate: float = 0.08
	var _tta_zero_curr_decay: float = 0.12
	if cp != null:
		if "temperature_transport_anomaly_source_cap" in cp:
			_tta_source_cap = clampf(float(cp.temperature_transport_anomaly_source_cap), 0.0, 0.5)
		if "temperature_transport_anomaly_blend_rate" in cp:
			_tta_blend_rate = clampf(float(cp.temperature_transport_anomaly_blend_rate), 0.0, 1.0)
		if "temperature_transport_anomaly_decay_rate" in cp:
			_tta_decay_rate = clampf(float(cp.temperature_transport_anomaly_decay_rate), 0.0, 1.0)
		if "temperature_transport_anomaly_zero_current_decay" in cp:
			_tta_zero_curr_decay = clampf(float(cp.temperature_transport_anomaly_zero_current_decay), 0.0, 1.0)
	# ocean_water 和 ocean_land 都需要这 4 个；C++ 端用 ow_tta_*/ol_tta_* 分别取
	input["ow_tta_source_cap"]          = _tta_source_cap
	input["ow_tta_blend_rate"]          = _tta_blend_rate
	input["ow_tta_zero_current_decay"]  = _tta_zero_curr_decay
	input["ol_tta_source_cap"]          = _tta_source_cap
	input["ol_tta_blend_rate"]          = _tta_blend_rate
	input["ol_tta_decay_rate"]          = _tta_decay_rate
	# ocean_land knobs — sync 用 _last_cfg.COASTAL_HEAT_LEAK * winter_boost(1.0)（map_generator.gd:9916-9917）
	input["ol_effective_leak"] = float(generator._last_cfg.COASTAL_HEAT_LEAK) if generator._last_cfg != null else 0.45
	# wind_air knobs — sync 用 _last_cfg.WIND_HEAT_*（map_generator.gd:12637-12638）
	input["wa_advect_steps"] = max(0, int(generator._last_cfg.WIND_HEAT_ADVECT_STEPS)) if generator._last_cfg != null else 3
	input["wa_heat_mix"]     = clampf(float(generator._last_cfg.WIND_HEAT_MIX), 0.0, 1.0) if generator._last_cfg != null else 0.25
	# wind_surface knobs — sync 用 _last_cfg.AIR_MASS_HEAT_LEAK（map_generator.gd:12672）
	input["ws_air_leak"]     = float(generator._last_cfg.AIR_MASS_HEAT_LEAK) if generator._last_cfg != null else 0.35
	# sea_ice knobs — sync 用 cp.sea_ice_freeze_rate / sea_ice_melt_rate / sea_ice_form_threshold /
	#   sea_ice_melt_threshold / sea_ice_neighbor_contagion / sea_ice_terrain_threshold /
	#   sea_ice_terrain_hysteresis（_apply_sea_ice_daily_pass map_generator.gd:8020-8026）
	# 还有 sea_ice_freeze_insol_low/high / sea_ice_solar_melt_start/gain / sea_ice_daily_delta_cap /
	#   sea_ice_solar_gate_enabled / OCEAN_CURRENT_ICE_DELAY / enable_ocean_heat_transport
	input["si_k_freeze"]     = float(cp.sea_ice_freeze_rate) if "sea_ice_freeze_rate" in cp else 0.55
	input["si_k_melt"]       = float(cp.sea_ice_melt_rate)   if "sea_ice_melt_rate"   in cp else 1.45
	input["si_t_form"]       = float(cp.sea_ice_form_threshold) if "sea_ice_form_threshold" in cp else 0.12
	input["si_t_melt"]       = float(cp.sea_ice_melt_threshold) if "sea_ice_melt_threshold" in cp else 0.22
	input["si_contagion"]    = float(cp.sea_ice_neighbor_contagion) if "sea_ice_neighbor_contagion" in cp else 0.06
	input["si_threshold"]    = float(cp.sea_ice_terrain_threshold) if "sea_ice_terrain_threshold" in cp else 0.68
	input["si_hysteresis"]   = float(cp.sea_ice_terrain_hysteresis) if "sea_ice_terrain_hysteresis" in cp else 0.12
	input["si_ice_delay"]    = float(generator._last_cfg.OCEAN_CURRENT_ICE_DELAY) if generator._last_cfg != null else 0.0
	input["si_solar_gate_enabled"] = bool(cp.sea_ice_solar_gate_enabled) if "sea_ice_solar_gate_enabled" in cp else true
	input["si_freeze_insol_low"]  = float(cp.sea_ice_freeze_insol_low) if "sea_ice_freeze_insol_low" in cp else 0.30
	input["si_freeze_insol_high"] = float(cp.sea_ice_freeze_insol_high) if "sea_ice_freeze_insol_high" in cp else 0.55
	input["si_solar_melt_start"]  = float(cp.sea_ice_solar_melt_start) if "sea_ice_solar_melt_start" in cp else 0.45
	input["si_solar_melt_gain"]   = float(cp.sea_ice_solar_melt_gain) if "sea_ice_solar_melt_gain" in cp else 0.65
	input["si_daily_delta_cap"]   = float(cp.sea_ice_daily_delta_cap) if "sea_ice_daily_delta_cap" in cp else 0.08
	input["si_enable_oht"]        = bool(generator._last_cfg.enable_ocean_heat_transport) if generator._last_cfg != null else true
	# climate_anomaly 阈值偏移（与 _apply_sea_ice_daily_pass map_generator.gd:8044-8046 同源）
	# sync 路径在调 C++ run_sea_ice_daily_pass 前已把 t_form/t_melt 减去 climate_anomaly_now * 0.10。
	# async 模式要 mirror 这个 shift —— worker 用相同 t_form/t_melt 才能 bit-equal。
	var _ca_now: float = 0.0
	if generator._world_clock_ref != null:
		var _ca_v = generator._world_clock_ref.get("climate_anomaly")
		if _ca_v != null:
			_ca_now = float(_ca_v)
	if not is_equal_approx(_ca_now, 0.0):
		var _ice_thr_shift: float = 0.10 * _ca_now
		input["si_t_form"] = clampf(float(input["si_t_form"]) - _ice_thr_shift, 0.0, 1.0)
		input["si_t_melt"] = clampf(float(input["si_t_melt"]) - _ice_thr_shift, 0.0, 1.0)
	# apply_terrain_flips：sync 路径里由 GDScript caller 处理翻转，async 模式建议
	# 让 C++ worker 写好 out.terrain（apply=true）→ poll 写回 _slots[cell_terrain]，
	# 减少主线程处理量。
	input["si_apply_terrain_flips"] = true
	# si_dt_days：sync 路径每次调 sea_ice 时从 generator consume（map_generator.gd:8011
	# `_apply_sea_ice_daily_pass` 调用 `_consume_sea_ice_dt_days()`）。async 模式在
	# kick 时 consume，传给 worker 用。
	if generator.has_method("_consume_sea_ice_dt_days"):
		input["si_dt_days"] = float(generator._consume_sea_ice_dt_days())
	else:
		input["si_dt_days"] = 1.0
	# thermal_dt_days：与 si_dt_days 同源。pass_a 热惯性松弛/delta_cap 按实际经过
	# 天数积分，否则加速档下海洋温度欠积分、滞后太阳直射点。worker 默认 1.0（缺键时）。
	if generator.has_method("_consume_climate_dt_days"):
		input["thermal_dt_days"] = float(generator._consume_climate_dt_days())
	else:
		input["thermal_dt_days"] = 1.0
	# ─── finalizer pass fields（Stage 9 / Fix #11, 2026-06-16） ─────────────
	# C++ worker 的 finalizer kernel 等价 _apply_daily_climate_finalizer，
	# 跳过 main thread 上 4 个 2400-loop + 2 个 sort + 3 个 write_f32_dense（实测 13-17ms）。
	# 关键输入：round-start snapshot（temp / TTA / sea_ice_prev / precip）。
	input["fin_temp_start_of_day"] = _temp_start_of_day_arr
	input["fin_tta_start_of_day"]  = _tta_start_of_day_arr
	input["fin_sea_ice_frac_prev"] = map.sea_ice_frac_arr_prev if map.sea_ice_frac_arr_prev.size() == n_cells else PackedFloat32Array()
	input["fin_weather_precip"]    = map.weather_precip_arr if map.weather_precip_arr.size() == n_cells else PackedFloat32Array()
	input["fin_temp_cap_enabled"]  = bool(cp.thermal_final_delta_cap_enabled) if cp != null and "thermal_final_delta_cap_enabled" in cp else true
	input["fin_temp_cap"]          = float(cp.thermal_daily_delta_cap) if cp != null and "thermal_daily_delta_cap" in cp else 0.15
	input["fin_tta_cap"]           = float(cp.temperature_transport_anomaly_daily_cap) if cp != null and "temperature_transport_anomaly_daily_cap" in cp else 0.12
	input["fin_has_temp_start"]    = _temp_start_of_day_arr.size() == n_cells
	input["fin_has_tta_start"]     = _tta_start_of_day_arr.size() == n_cells
	# passes_mask: 0x1FF 全开（默认含 finalizer bit 8）；旧 DLL 看不到 bit 8 还是 fallback。
	input["passes_mask"] = 0x1FF
	return input


# 静态 knobs（round 间不变化）。register 后第一次 set，round 间复用。
func _build_async_static_knobs() -> Dictionary:
	var n_cells: int = map.cell_count()
	var nb_idx: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var donor_table: PackedFloat32Array = generator._build_transpiration_donor_table()
	var foliage_table: PackedFloat32Array = generator._build_climate_b_foliage_table() if generator.has_method("_build_climate_b_foliage_table") else PackedFloat32Array()
	return {
		"n_cells": n_cells,
		"neighbor_indices": nb_idx,
		"donor_table": donor_table,
		"foliage_table": foliage_table,
	}


# Worker poll 完成时处理 sea_ice flip events。
# - 写 _slots[cell_terrain] 已由 C++ poll 完成（apply_terrain_flips=true）。
# - 这里只做 GDScript 端的：map.terrain_arr 已被 flush 同步过；
#   告诉 atlas pipeline / sea_ice atlas 把翻转 cell 标 dirty。
func _handle_async_sea_ice_flips(poll_result: Dictionary) -> void:
	if not poll_result.has("flipped_cell_indices"):
		return
	var indices: PackedInt32Array = poll_result["flipped_cell_indices"]
	if indices.size() <= 0:
		return
	var terrain_values: PackedByteArray = poll_result.get("flipped_new_terrain", PackedByteArray())
	var applied_indexed: bool = false
	if generator != null and generator.has_method("_apply_sea_ice_terrain_flips_indexed") \
			and terrain_values.size() >= indices.size():
		var diag: Dictionary = generator._apply_sea_ice_terrain_flips_indexed(map, indices, terrain_values, true)
		applied_indexed = bool(diag.get("applied", false))
	if not applied_indexed:
		for idx in indices:
			if map.has_method("mark_climate_dirty"):
				map.mark_climate_dirty(int(idx))
		if _world != null and _world.has_method("mark_dirty_indexed"):
			_world.mark_dirty_indexed(indices)


func run_slice(ctx: SusTickContext) -> Dictionary:
	if generator == null or map == null:
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }

	# Fix #6 (2026-06-15): finalizer 拆 slice 跨帧。上一片（async 或 sync）设了
	# _finalize_pending，本片专门跑 _finalize_round() —— 把 5-8ms finalizer 从
	# 最后一个 pass slice 剥离出来，让 mobile p95 下降。
	# 必须在 async branch 之前，避免 next-tick 再进 _run_slice_async 又跑一遍 round。
	# 仅 mobile 启用（桌面端不会设 _finalize_pending，所以分支不会触发）。
	if _finalize_pending:
		var t_fin_us: int = Time.get_ticks_usec()
		_pass_cursor = _PASS_COUNT
		_finalize_round()
		_finalize_pending = false
		_round_active = false
		# async path 也要清 kick 标志，否则下个 round 入 _run_slice_async 跳过 kick
		# 直接 poll 返回 empty 等结果，永远循环。
		_async_round_kicked = false
		_async_round_poll_attempts = 0
		ran_this_tick = true
		var fin_elapsed_ms: float = float(Time.get_ticks_usec() - t_fin_us) / 1000.0
		_last_slice_elapsed_ms = fin_elapsed_ms
		return {
			"done": true,
			"work_done": map.cell_count() if map != null else 0,
			"elapsed_ms": fin_elapsed_ms,
			"progress_ratio": 1.0,
			"stage_name": "round_finalize",
			"substage": "finalizer_split",
			"path": "data_core_finalizer",
			"processed_cells": 0,
			"cursor_start": -1,
			"cursor_end": -1,
			"budget_interrupted": false,
			"status": _PASS_RESULT_DONE,
			"pass_token": _active_pass_token,
			"kernel_ms": 0.0,
			"slice_wall_ms": fin_elapsed_ms,
			"finalizer_ms": float(_last_finalize_diag.get("finalize_total_ms", fin_elapsed_ms)),
		}

	# ─── Async climate round 分支（plan §async-stage-3） ──────────────
	# cp.use_climate_round_async=true + ext 支持 → worker thread 跑完整 round。
	# 主线程 run_slice 只 kick / poll，单帧 < 1.5ms。sync path 保留作 fallback。
	var cp_async_check = generator._c() if generator != null else null
	var async_enabled: bool = false
	if cp_async_check != null and "use_climate_round_async" in cp_async_check:
		async_enabled = bool(cp_async_check.use_climate_round_async)
	# Mobile 默认开启 climate async（Fix #2, 2026-06-15）：log_next.txt 显示
	# transp/finalizer 持续报到 SUS-cpp largest 19ms（实际 kernel 0.06ms，
	# 其余 8ms 在 finalize_finalizer_ms 拼 cell_ms/sort_ms）。worker thread 框架
	# 已在 plan §async-stage-1/3 落地（async_climate_round_kick/poll），
	# desktop 上 KEY_B bench 验过 bit-equal，所以 mobile 默认开。
	# 桌面端继续按 ClimateProfile.use_climate_round_async 显式 opt-in。
	if not async_enabled and OS.has_feature("mobile"):
		async_enabled = true
	# Stage 3 调试 print（一次性）：第一次进 run_slice 时 dump 实际 condition
	if not _async_branch_probe_logged:
		_async_branch_probe_logged = true
		var ext_ok: bool = generator._data_core_world_ext != null
		var has_kick: bool = ext_ok and generator._data_core_world_ext.has_method("async_climate_round_kick")
		var has_poll: bool = ext_ok and generator._data_core_world_ext.has_method("async_climate_round_poll")
		var cp_path: String = "<null>" if cp_async_check == null else (cp_async_check.resource_path if cp_async_check.resource_path != "" else "<in-memory>")
		print("[climate/async PROBE] cp=%s async_enabled=%s ext=%s has_kick=%s has_poll=%s" % [
			cp_path, str(async_enabled), str(ext_ok), str(has_kick), str(has_poll),
		])
	if async_enabled and generator._data_core_world_ext != null \
			and generator._data_core_world_ext.has_method("async_climate_round_kick") \
			and generator._data_core_world_ext.has_method("async_climate_round_poll"):
		return _run_slice_async(ctx)

	# ─── Sync sliced round（原行为，保留作 fallback）──────────────────
	# Round 启动：锁 phase + 清埋点累加器
	if not _round_active:
		var t_round_start_us: int = Time.get_ticks_usec()
		var t_round_part_us: int = t_round_start_us
		_last_round_start_diag = {
			"round_start_total_ms": 0.0,
			"round_start_phase_ms": 0.0,
			"round_start_terrain_sync_ms": 0.0,
			"round_start_terrain_sync_skipped": false,
			"capture_start_state_ms": 0.0,
			"round_start_state_ms": 0.0,
			"round_start_reset_transp_ms": 0.0,
			"round_start_mark_stale_ms": 0.0,
			"round_start_soa_begin_ms": 0.0,
			"round_start_dirty_ms": 0.0,
		}
		_pass_cursor = 0
		if season_phase_getter.is_valid():
			_phase_locked = float(season_phase_getter.call())
		else:
			_phase_locked = ctx.season_phase
		_last_round_start_diag["round_start_phase_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		_round_t_pass_a_ms = 0.0
		_round_t_pass_b_ms = 0.0
		_round_t_ocean_ms = 0.0
		_round_t_wind_ms = 0.0
		_round_t_sea_ice_ms = 0.0
		_round_t_transp_ms = 0.0
		_last_finalize_diag = {}
		_last_slice_pass_overhead_ms = 0.0
		_round_t_round_start_ms = Time.get_ticks_msec()
		_round_active = true
		t_round_part_us = Time.get_ticks_usec()
		var terrain_diag: Dictionary = _sync_runtime_terrain_views_for_reason("round_start")
		_last_round_start_diag["round_start_terrain_sync_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		_last_round_start_diag["round_start_terrain_sync_skipped"] = bool(terrain_diag.get("skipped", false))
		if not terrain_diag.is_empty():
			_last_round_start_diag["round_start_terrain_sync_diag"] = terrain_diag.duplicate(true)
		t_round_part_us = Time.get_ticks_usec()
		_begin_round_pass_state()
		_last_round_start_diag["round_start_state_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		t_round_part_us = Time.get_ticks_usec()
		_reset_transpiration_slice_state()
		_last_round_start_diag["round_start_reset_transp_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		# refresh-consolidation-2026-06：round 入口 mark stale，让 pass_a 入口的
		# _ensure_climate_daily_round_slots_fresh() 做一次真实 refresh；同 round 内
		# 后续 pass 的 ensure 调用全部跳过（除非跨 pass 边界由本 system 再次 mark stale）。
		t_round_part_us = Time.get_ticks_usec()
		if generator != null and generator.has_method("_mark_climate_daily_round_slots_stale"):
			generator._mark_climate_daily_round_slots_stale()
		_last_round_start_diag["round_start_mark_stale_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		t_round_part_us = Time.get_ticks_usec()
		if map != null and map.has_soa() and map.has_method("soa_begin_climate_transaction"):
			map.soa_begin_climate_transaction()
		_last_round_start_diag["round_start_soa_begin_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		# A.2.1.A4 — Dirty Mask 启动时整 round 边界处理：
		#   1) season 跨整数 / 每 30 日 full sweep / 加载存档首日 → mark_all_climate_dirty
		#   2) 否则保留上一日 dirty 增量（Pass A 内层 epsilon 比对会继续覆写）
		# 这里只在 use_sparse_climate=true 时维护 mask；为 false 时 mask 保持全 0 不影响。
		t_round_part_us = Time.get_ticks_usec()
		var cp_round = generator._c() if generator != null else null
		if cp_round != null and bool(cp_round.use_sparse_climate) and map != null and map.has_soa():
			var phase_int: int = int(floor(_phase_locked))
			var season_changed: bool = (_last_phase_int_seen != -9999) and (phase_int != _last_phase_int_seen)
			var full_sweep_due: bool = _full_sweep_counter >= _FULL_SWEEP_PERIOD
			if season_changed or full_sweep_due:
				map.mark_all_climate_dirty()
				_full_sweep_counter = 0
			else:
				# 增量模式：清空上一 round 残留的 dirty 标记，让 Pass A epsilon 比对从零开始
				map.clear_climate_dirty()
			_last_phase_int_seen = phase_int
		_last_round_start_diag["round_start_dirty_ms"] = float(Time.get_ticks_usec() - t_round_part_us) / 1000.0
		_last_round_start_diag["round_start_total_ms"] = float(Time.get_ticks_usec() - t_round_start_us) / 1000.0

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
	# climate-loop-closure Phase 1.1：风温段开关（profile 缺字段时默认 true）。
	var wind_heat_enabled: bool = true
	if cp.get("enable_wind_heat_transport") != null:
		wind_heat_enabled = bool(cp.enable_wind_heat_transport)
	var slice_elapsed_ms: float = 0.0
	var ran_pass_id: int = -1
	_reset_last_pass_diag()

	while _pass_cursor < _PASS_COUNT:
		var pass_id: int = _pass_cursor
		# Skip 不需要执行的段（开关关闭的可选 pass），cursor +1 继续 while
		var should_skip: bool = false
		match pass_id:
			_PASS_B:
				should_skip = not local_coupling
			_PASS_OCEAN_WATER, _PASS_OCEAN_LAND:
				should_skip = not ocean_enabled
			_PASS_WIND_AIR, _PASS_WIND_SURFACE:
				should_skip = not wind_heat_enabled
			_PASS_SEA_ICE:
				should_skip = _standalone_sea_ice_enabled()
			_PASS_TRANSP:
				should_skip = not local_coupling
			_:
				should_skip = false
		if should_skip:
			_pass_cursor += 1
			continue
		# 本 round 对应一个日级气候调度点：能立即完成的 pass 在同一调度点连续推进，
		# 避免 SLP/wind/ocean/soil 读取半成品。只有 chunked pass 返回未完成时暂停。
		var pass_done: bool = _run_pass(pass_id)
		ran_pass_id = pass_id
		if pass_done:
			_pass_cursor += 1
		slice_elapsed_ms = (Time.get_ticks_usec() - t_slice_us0) / 1000.0
		if not pass_done:
			break
		break

	if ran_pass_id >= 0:
		var pass_reported_ms: float = float(_last_pass_diag.get(
			"diagnostic_wall_ms",
			_last_pass_diag.get("reported_elapsed_ms", _last_pass_diag.get("elapsed_ms", 0.0))
		))
		_last_slice_pass_overhead_ms = maxf(0.0, slice_elapsed_ms - pass_reported_ms)
	else:
		_last_slice_pass_overhead_ms = 0.0

	# 检查 round 是否结束：cursor ≥ _PASS_COUNT 表示所有段（含 skip）都过了
	var done: bool = _pass_cursor >= _PASS_COUNT
	# Fix #6 已回退 (2026-06-15 v3)：实测把 finalize 拆 slice 反而让 sus_ticks/120 从 61
	# 涨到 79，sus_frame_avg 从 28ms 涨到 36ms，FPS 从 66 跌到 29。原因：每个 SUS slice
	# 都有边界 schedule overhead，把 1 个 22ms slice 拆成 16ms+6ms 反而让 2 帧都承担
	# SUS 工作（之前只 1 帧）。finalize 5-8ms 是确定性 cost 不是随机 spike，无法通过
	# 拆 slice 优化。真正瓶颈在 GPU fragment shader（fronts=12 时 draw_calls 41 /
	# primitives 5400），不在 climate finalize。
	# 保留 _finalize_pending 状态字段，但不再触发（done 时直接调 _finalize_round）。
	if done:
		_finalize_round()
	else:
		_publish_partial_round(ran_pass_id, slice_elapsed_ms, float(_pass_cursor) / float(_PASS_COUNT))
	ran_this_tick = ran_pass_id >= 0
	_last_slice_elapsed_ms = slice_elapsed_ms if ran_this_tick else 0.0

	var progress: float = float(_pass_cursor) / float(_PASS_COUNT)
	var stage_name_out: String = ""
	if ran_pass_id >= 0 and ran_pass_id < _PASS_NAMES.size():
		stage_name_out = _PASS_NAMES[ran_pass_id]
	elif done:
		stage_name_out = "round_done"
	else:
		stage_name_out = "skip"
	# 走 climate_pass_b 时有 sparse/full 三态，附带在 substage 上，便于
	# fast tick WARN/largest 行直接看出本片走的稀疏程度。
	# substage 用本 tick 真正执行的 pass_id（_pass_cursor 在执行后已 +1，
	# 取它会偏向 "下一片要跑哪段" 而不是 "本片刚跑了哪段"）。
	var substage_out: String = "cursor_%d" % ran_pass_id if ran_pass_id >= 0 else "cursor_skip"
	# dots-flag-prune-pr1 (2026-05-22)：use_data_core_climate flag 已删除——路径现恒
	# 走 DataCore，仅根据 data_core_ready() 探测决定 path 标签是 cells_only 还是完整
	# DataCore。上游 cp_for_path 仅为保留 generator._c() lookup 路径，用于后续
	# climate_pass_b path 诊断。
	var path_out: String = "data_core" if data_core_ready() else "data_core_cells_only"
	if ran_pass_id == _PASS_B and generator != null and "_last_climate_pass_b_path" in generator:
		substage_out = "pass_b_%s" % str(generator._last_climate_pass_b_path)
	elif _last_pass_substage != "":
		substage_out = _last_pass_substage
	if _last_pass_stage != "":
		stage_name_out = _last_pass_stage
	if _last_pass_path != "":
		path_out = _last_pass_path
	var processed_cells_out: int = _last_pass_processed_cells
	# Fix #5 (2026-06-15): SUS-cpp largest 归因修复。当 round 结束时 (done=true)，
	# _finalize_round 已经跑完整套 finalizer (cell loop / sort / tta / thermal)。
	# 之前 SUS 看 largest=refresh_climate_daily/transp/native path=gdext 19ms，
	# 但实际 transp/native 0.06ms，剩 18ms 全在 finalizer。让 substage 和 path
	# 在 round 结束帧明确反映 finalizer 主导，不让 transp 背锅。
	# kernel_wall = native_ms（C++ pass 自身），slice_wall = slice_elapsed_ms（含
	# finalizer + sync）—— 把两者都暴露给上层方便区分。
	var native_kernel_ms_out: float = float(_last_pass_diag.get("native_ms", 0.0))
	if done:
		var finalize_ms: float = float(_last_finalize_diag.get("finalize_total_ms", 0.0))
		if finalize_ms >= maxf(2.0, native_kernel_ms_out * 4.0):
			# 当 finalizer 比 kernel 大 4x 以上且超过 2ms 时（典型 5-8ms），
			# 重新指认为 finalizer 主导，避免 SUS-cpp 把 transp 当瓶颈追错方向。
			substage_out = "finalizer"
			path_out = "data_core_finalizer"
			stage_name_out = "round_finalize"
	return {
		"done": done,
		"work_done": map.cell_count() if done else 0,
		"elapsed_ms": slice_elapsed_ms,
		"progress_ratio": progress if not done else 1.0,
		"stage_name": stage_name_out,
		"substage": substage_out,
		"path": path_out,
		"processed_cells": processed_cells_out,
		"cursor_start": _last_pass_cursor_start,
		"cursor_end": _last_pass_cursor_end,
		"budget_interrupted": _last_pass_budget_interrupted,
		"status": _last_pass_status,
		"pass_token": _active_pass_token,
		# Fix #5 双口径暴露给 main.gd / scheduler diag：kernel_ms 是 C++ 算子
		# 单独耗时（path=gdext 真实成本），elapsed_ms 是整片墙钟（含 finalizer
		# / sync / write）。SUS-cpp 用 elapsed_ms 算 largest，但消费方拿 kernel_ms
		# 才能判断 C++ 优化是否还有空间。
		"kernel_ms": native_kernel_ms_out,
		"slice_wall_ms": slice_elapsed_ms,
		"finalizer_ms": float(_last_finalize_diag.get("finalize_total_ms", 0.0)) if done else 0.0,
	}


# ─── 内部：按 pass_id 调用 generator 上的 sub-pass 并累积埋点 ─────────────
func _run_pass(pass_id: int) -> bool:
	var token: int = _active_pass_token
	var t_us0: int = Time.get_ticks_usec()
	# refresh-consolidation-2026-06：跨 pass 边界处理 climate_daily round 守门员。
	# 凡是依赖前序 pass 写入 MapData 的 pass，进入前 mark stale 让 ensure 真实 refresh。
	# - PASS_A：round 入口已 mark stale，不需要再 mark
	# - PASS_B / OCEAN_LAND / SEA_ICE / TRANSP：读前序 pass flush 到 MapData 的输出
	# - WIND_AIR / WIND_SURFACE：仅读已 sync 的 C++ slot 内的 temp/wind/anomaly，跳过
	# - OCEAN_WATER：紧跟 pass_b 之后；pass_b 已改 moisture/local_anom 并 flush
	if generator != null and generator.has_method("_mark_climate_daily_round_slots_stale"):
		match pass_id:
			_PASS_B, _PASS_OCEAN_WATER, _PASS_OCEAN_LAND, _PASS_SEA_ICE, _PASS_TRANSP:
				generator._mark_climate_daily_round_slots_stale()
	match pass_id:
		_PASS_A:
			generator._climate_pass_a(map, _phase_locked)
			_round_t_pass_a_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
			var r_a: Dictionary = _make_pass_result(true, _round_t_pass_a_ms, map.cell_count(), 0, map.cell_count())
			_record_pass_result(pass_id, token, r_a, _round_t_pass_a_ms, "pass_a", "native_or_gd", "data_core" if data_core_ready() else "data_core_cells_only")
			return true
		_PASS_B:
			generator._climate_pass_b(map, _phase_locked)
			_round_t_pass_b_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
			var r_b: Dictionary = _make_pass_result(true, _round_t_pass_b_ms, map.cell_count(), 0, map.cell_count())
			var pb_substage: String = "pass_b_%s" % str(generator._last_climate_pass_b_path) if generator != null and "_last_climate_pass_b_path" in generator else "pass_b"
			_record_pass_result(pass_id, token, r_b, _round_t_pass_b_ms, "pass_b", pb_substage, "data_core" if data_core_ready() else "data_core_cells_only")
			return true
		_PASS_OCEAN_WATER:
			if generator.has_method("run_ocean_water_pass_slice"):
				var r_w: Dictionary = generator.run_ocean_water_pass_slice(map, _phase_locked)
				_round_t_ocean_ms += float(r_w.get("elapsed_ms", 0.0))
				_record_pass_result(pass_id, token, r_w, float(r_w.get("elapsed_ms", 0.0)), "ocean_water", "range_cursor", "native_chunk")
				return bool(r_w.get("done", true))
			else:
				generator._ocean_water_pass(map, _phase_locked)
				var ow_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
				_round_t_ocean_ms += ow_ms
				var r_ow: Dictionary = _make_pass_result(true, ow_ms, map.cell_count(), 0, map.cell_count())
				_record_pass_result(pass_id, token, r_ow, ow_ms, "ocean_water", "oneshot", "gdscript")
				return true
		_PASS_OCEAN_LAND:
			if generator.has_method("run_ocean_land_pass_slice"):
				var r_l: Dictionary = generator.run_ocean_land_pass_slice(map, _phase_locked)
				_round_t_ocean_ms += float(r_l.get("elapsed_ms", 0.0))
				_record_pass_result(pass_id, token, r_l, float(r_l.get("elapsed_ms", 0.0)), "ocean_land", "range_cursor", "native_chunk")
				return bool(r_l.get("done", true))
			else:
				generator._ocean_land_pass(map, _phase_locked)
				var ol_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
				_round_t_ocean_ms += ol_ms
				var r_ol: Dictionary = _make_pass_result(true, ol_ms, map.cell_count(), 0, map.cell_count())
				_record_pass_result(pass_id, token, r_ol, ol_ms, "ocean_land", "oneshot", "gdscript")
				return true
		_PASS_WIND_AIR:
			# climate-loop-closure Phase 1.1：风温气团段（沿 -wind 回溯混合上风温度）。
			var r_wa: Dictionary
			if generator.has_method("run_wind_air_mass_pass_native"):
				r_wa = generator.run_wind_air_mass_pass_native(map, _phase_locked)
			else:
				generator._wind_air_mass_pass(map, _phase_locked)
				var wa_fb_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
				r_wa = _make_pass_result(true, wa_fb_ms, map.cell_count(), 0, map.cell_count())
				r_wa["path"] = "gdscript"
				r_wa["stage"] = "oneshot"
			var wa_ms: float = float(r_wa.get("elapsed_ms", (Time.get_ticks_usec() - t_us0) / 1000.0))
			_round_t_wind_ms += wa_ms
			_record_pass_result(pass_id, token, r_wa, wa_ms, "wind_air",
				str(r_wa.get("stage", "oneshot")), str(r_wa.get("path", "gdscript")))
			return true
		_PASS_WIND_SURFACE:
			# 必须在 wind_air 之后：读取气团段写入的 air_mass_temp_anomaly 注入地表温度。
			var r_ws: Dictionary
			if generator.has_method("run_wind_surface_pass_native"):
				r_ws = generator.run_wind_surface_pass_native(map, _phase_locked)
			else:
				generator._wind_surface_pass(map, _phase_locked)
				var ws_fb_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
				r_ws = _make_pass_result(true, ws_fb_ms, map.cell_count(), 0, map.cell_count())
				r_ws["path"] = "gdscript"
				r_ws["stage"] = "oneshot"
			var ws_ms: float = float(r_ws.get("elapsed_ms", (Time.get_ticks_usec() - t_us0) / 1000.0))
			_round_t_wind_ms += ws_ms
			_record_pass_result(pass_id, token, r_ws, ws_ms, "wind_surface",
				str(r_ws.get("stage", "oneshot")), str(r_ws.get("path", "gdscript")))
			return true
		_PASS_SEA_ICE:
			if generator.has_method("run_climate_pass_slice"):
				var r_si: Dictionary = generator.run_climate_pass_slice("sea_ice", map, _phase_locked)
				_round_t_sea_ice_ms += float(r_si.get("elapsed_ms", 0.0))
				_sync_runtime_terrain_views("sea_ice_slice")
				_record_pass_result(pass_id, token, r_si, float(r_si.get("elapsed_ms", 0.0)), "sea_ice", str(r_si.get("stage", "state_machine")), "climate_chunk_api")
				return bool(r_si.get("done", true))
			else:
				generator._apply_sea_ice_daily_pass(map, _phase_locked)
				_round_t_sea_ice_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
				var r_si: Dictionary = _make_pass_result(true, _round_t_sea_ice_ms, map.cell_count(), 0, map.cell_count())
				_sync_runtime_terrain_views("sea_ice_fallback")
				_record_pass_result(pass_id, token, r_si, _round_t_sea_ice_ms, "sea_ice", "oneshot_fallback", "native_or_gd")
				return true
		_PASS_TRANSP:
			var r_tr: Dictionary = _run_transpiration_pass_slice()
			var tr_ms: float = float(r_tr.get("elapsed_ms", 0.0))
			_round_t_transp_ms += tr_ms
			_record_pass_result(pass_id, token, r_tr, tr_ms,
				"transp", str(r_tr.get("stage", "sliced")), str(r_tr.get("path", "gdscript_sliced")))
			return bool(r_tr.get("done", true))
	return true


func _begin_transpiration_sliced() -> void:
	if map == null:
		_transp_stage = _TRANSP_STAGE_DONE
		return
	_transp_cells = map.iter_cells() if map.has_indices() else map.all_cells()
	_transp_n_cells = _transp_cells.size()
	_transp_neighbor_indices = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	_transp_fast_indexed = _transp_neighbor_indices.size() >= _transp_n_cells * 6
	_transp_landform_arr = map.landform_arr
	_transp_vegetation_arr = map.vegetation_arr
	_transp_moisture_arr = map.moisture_arr
	if generator != null and generator.has_method("_build_transpiration_donor_table"):
		_transp_donor_table = generator._build_transpiration_donor_table()
	else:
		_transp_donor_table = PackedFloat32Array()
		_transp_donor_table.resize(VegetationType.VEG.size())
		for v in range(_transp_donor_table.size()):
			_transp_donor_table[v] = VegetationType.transpiration(v)
	_transp_deltas = PackedFloat32Array()
	_transp_deltas.resize(_transp_n_cells)
	_transp_cursor = 0
	_transp_stage = _TRANSP_STAGE_COMPUTE if _transp_n_cells > 0 else _TRANSP_STAGE_DONE


func _transp_stage_label(stage_id: int) -> String:
	match stage_id:
		_TRANSP_STAGE_COMPUTE:
			return "compute"
		_TRANSP_STAGE_APPLY:
			return "apply"
		_TRANSP_STAGE_DONE:
			return "done"
		_:
			return "idle"


func _transp_should_yield(t_us0: int, processed: int) -> bool:
	if processed < _TRANSP_MIN_CELLS_PER_SLICE:
		return false
	if processed % _TRANSP_TIME_CHECK_INTERVAL != 0:
		return false
	var elapsed_ms: float = float(Time.get_ticks_usec() - t_us0) / 1000.0
	return elapsed_ms >= maxf(0.2, slice_budget_ms)


func _transp_is_water_idx(idx: int) -> bool:
	if idx >= 0 and idx < _transp_landform_arr.size():
		return int(_transp_landform_arr[idx]) <= _TRANSP_WATER_LANDFORM_MAX
	if idx >= 0 and idx < _transp_cells.size():
		var cell: HexCell = _transp_cells[idx]
		return cell == null or LandformType.is_water(cell.landform)
	return true


func _transp_factor_idx(idx: int) -> float:
	if idx < 0 or idx >= _transp_vegetation_arr.size():
		return 0.0
	var veg_id: int = int(_transp_vegetation_arr[idx])
	if veg_id < 0 or veg_id >= _transp_donor_table.size():
		return 0.0
	return _transp_donor_table[veg_id]


func _transp_moisture_idx(idx: int) -> float:
	if idx >= 0 and idx < _transp_moisture_arr.size():
		return _transp_moisture_arr[idx]
	if idx >= 0 and idx < _transp_cells.size():
		var cell: HexCell = _transp_cells[idx]
		return cell.moisture if cell != null else 0.0
	return 0.0


func _run_transpiration_pass_slice() -> Dictionary:
	if _transp_stage == _TRANSP_STAGE_IDLE:
		if generator != null and generator.has_method("run_transpiration_pass_native"):
			var native_result: Dictionary = generator.run_transpiration_pass_native(map)
			if bool(native_result.get("done", false)) and str(native_result.get("path", "")) == "gdext":
				_transp_stage = _TRANSP_STAGE_DONE
				_transp_cursor = int(native_result.get("processed_cells", map.cell_count() if map != null else 0))
				_transp_n_cells = _transp_cursor
				native_result["status"] = _PASS_RESULT_DONE
				native_result["budget_interrupted"] = false
				return native_result
		_begin_transpiration_sliced()
	var t_us0: int = Time.get_ticks_usec()
	var stage_at_start: int = _transp_stage
	var cursor_start: int = _transp_cursor
	var processed: int = 0

	if _transp_stage == _TRANSP_STAGE_COMPUTE:
		var cp = generator._c() if generator != null else null
		var outflow_rate: float = 0.025
		var self_rate: float = 0.015
		if cp != null:
			if cp.get("transpiration_outflow_rate") != null:
				outflow_rate = float(cp.transpiration_outflow_rate)
			if cp.get("transpiration_self_rate") != null:
				self_rate = float(cp.transpiration_self_rate)
		var nb_share_factor: float = outflow_rate / 6.0
		while _transp_cursor < _transp_n_cells:
			var i: int = _transp_cursor
			_transp_cursor += 1
			processed += 1
			if _transp_is_water_idx(i):
				if _transp_should_yield(t_us0, processed):
					break
				continue
			var trans: float = _transp_factor_idx(i)
			if trans >= 0.01:
				var output: float = trans * _transp_moisture_idx(i)
				_transp_deltas[i] = _transp_deltas[i] + output * self_rate
				var nb_share: float = output * nb_share_factor
				if _transp_fast_indexed:
					var base: int = i * 6
					for d_idx in range(6):
						var nb_idx: int = _transp_neighbor_indices[base + d_idx]
						if nb_idx < 0 or nb_idx >= _transp_n_cells:
							continue
						if _transp_is_water_idx(nb_idx):
							continue
						_transp_deltas[nb_idx] = _transp_deltas[nb_idx] + nb_share
				else:
					var cell: HexCell = _transp_cells[i]
					if cell == null:
						if _transp_should_yield(t_us0, processed):
							break
						continue
					for nb: HexCell in map.get_neighbors(cell):
						if nb == null or LandformType.is_water(nb.landform):
							continue
						var nb_idx_fallback: int = map.index_of(nb)
						if nb_idx_fallback >= 0 and nb_idx_fallback < _transp_n_cells:
							_transp_deltas[nb_idx_fallback] = _transp_deltas[nb_idx_fallback] + nb_share
			if _transp_should_yield(t_us0, processed):
				break
		if _transp_cursor >= _transp_n_cells:
			_transp_stage = _TRANSP_STAGE_APPLY
			_transp_cursor = 0

	elif _transp_stage == _TRANSP_STAGE_APPLY:
		var dirty_idx: PackedInt32Array = PackedInt32Array()
		var dirty_val: PackedFloat32Array = PackedFloat32Array()
		var has_moisture_arr: bool = map != null and map.moisture_arr.size() == _transp_n_cells
		while _transp_cursor < _transp_n_cells:
			var i: int = _transp_cursor
			_transp_cursor += 1
			processed += 1
			var d: float = _transp_deltas[i]
			if d != 0.0:
				var cell: HexCell = _transp_cells[i]
				if cell != null:
					var new_moist: float = clampf(_transp_moisture_idx(i) + d, 0.0, 1.0)
					if i < _transp_moisture_arr.size():
						_transp_moisture_arr[i] = new_moist
					if has_moisture_arr:
						map.moisture_arr[i] = new_moist
					cell.moisture = new_moist
					dirty_idx.append(i)
					dirty_val.append(new_moist)
			if _transp_should_yield(t_us0, processed):
				break
		if _world != null and _world.is_bound() and dirty_idx.size() > 0:
			var cid_moist: int = int(_cid.get(DCComponentIds.CELL_MOISTURE, -1))
			if cid_moist >= 0 and _world.has_method("write_f32_indexed"):
				_world.write_f32_indexed(cid_moist, dirty_idx, dirty_val)
		if _transp_cursor >= _transp_n_cells:
			_transp_stage = _TRANSP_STAGE_DONE

	var elapsed_ms: float = float(Time.get_ticks_usec() - t_us0) / 1000.0
	var done: bool = _transp_stage == _TRANSP_STAGE_DONE
	var cursor_end: int = _transp_cursor
	if stage_at_start == _TRANSP_STAGE_COMPUTE and _transp_stage == _TRANSP_STAGE_APPLY:
		cursor_end = _transp_n_cells
	var stage_label: String = _transp_stage_label(stage_at_start)
	if stage_at_start == _TRANSP_STAGE_COMPUTE:
		stage_label = "compute_fast" if _transp_fast_indexed else "compute_fallback"
	return {
		"done": done,
		"status": _PASS_RESULT_DONE if done else _PASS_RESULT_CONTINUE,
		"elapsed_ms": elapsed_ms,
		"processed_cells": processed,
		"cursor_start": cursor_start,
		"cursor_end": cursor_end,
		"cursor_remaining": maxi(0, _transp_n_cells - _transp_cursor),
		"budget_interrupted": not done,
		"stage": stage_label,
		"next_stage": _transp_stage_label(_transp_stage),
		"budget_cells": _TRANSP_MIN_CELLS_PER_SLICE,
		"path": "gdscript_sliced",
	}


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
		"wind_ms": _round_t_wind_ms,
		"sea_ice_ms": _round_t_sea_ice_ms,
		"ice_bake_ms": 0.0,
		"transp_ms": _round_t_transp_ms,
		"total_ms": float(Time.get_ticks_msec() - _round_t_round_start_ms),
		"cells": map.cell_count(),
		"partial": true,
		"current_pass": pass_name,
		"slice_ms": slice_elapsed_ms,
		"processed_cells": _last_pass_processed_cells,
		"cursor_start": _last_pass_cursor_start,
		"cursor_end": _last_pass_cursor_end,
		"progress_ratio": progress,
		"budget_interrupted": _last_pass_budget_interrupted,
		"pass_status": _last_pass_status,
		"pass_token": _active_pass_token,
		"pass_diag": _last_pass_diag.duplicate(true),
		"transp_native_diag": _last_transp_native_diag.duplicate(true),
		"dirty_ratio": dirty_ratio_out,
		"visited_ratio": visited_ratio_out,
		"pass_b_path": pass_b_path_out,
		# 方案 ④ Step 1：写入时打 fast tick 戳，perf_recorder 据此判定 stale 回放
		"_tick_idx": int(generator._current_fast_tick_idx) if "_current_fast_tick_idx" in generator else 0,
	}
	_merge_climate_wrapper_diag(generator._last_climate_breakdown)


# ─── 内部：round 结束时把累积埋点写回 generator + 重置游标 ────────────────
func _finalize_round(async_poll_result: Dictionary = {}) -> void:
	var t_finalize_us: int = Time.get_ticks_usec()
	var t_finalize_part_us: int = t_finalize_us
	# Stage 9 / Fix #11 (2026-06-16)：worker 跑了 finalizer kernel 时（fin_applied=true）
	# 直接复用 worker 算好的 13 个 diag 字段；跳过同名 _apply_daily_climate_finalizer 的
	# 4 个 2400-loop + 2 个 sort + 3 个 write_f32_dense（实测 main thread 13-17ms）。
	# poll_result 里 fin_applied=false 时（旧 DLL / mask bit 8 关闭 / 维度不齐 fallback）
	# 走原 GDScript 路径，保持行为等价。
	var finalizer_diag: Dictionary
	var _async_finalizer_used: bool = false
	var async_fin_fallback_reason: String = _async_finalizer_fallback_reason(async_poll_result)
	if bool(async_poll_result.get("fin_applied", false)):
		# 把 worker 返回的字段平移到 _last_finalizer_diag 兼容 schema（main.gd 解析这堆字段）。
		finalizer_diag = _build_finalizer_diag_from_worker(async_poll_result)
		_last_finalizer_diag = finalizer_diag
		_async_finalizer_used = true
	else:
		finalizer_diag = _apply_daily_climate_finalizer()
	_last_finalize_diag = {
		"finalize_total_ms": 0.0,
		"finalize_finalizer_ms": float(Time.get_ticks_usec() - t_finalize_part_us) / 1000.0,
		"finalize_breakdown_ms": 0.0,
		"finalize_annual_log_ms": 0.0,
		"finalize_soa_noop_ms": 0.0,
		"finalize_soak_ms": 0.0,
		"finalize_integrity_ms": 0.0,
		"finalize_finish_pass_ms": 0.0,
		"finalize_reset_transp_ms": 0.0,
		"finalize_flush_dirty_ms": 0.0,
		"finalize_mark_stale_ms": 0.0,
		"finalize_dump_stats_ms": 0.0,
		"finalizer_cpp_worker": _async_finalizer_used,
		"finalizer_fallback_reason": async_fin_fallback_reason,
	}
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
		# A.2.1.B — Pass-A push 稀疏度（dynamic_visual_atlas M1 AB 验证字段）
		t_finalize_part_us = Time.get_ticks_usec()
		var _pa_pushed_out: int = int(generator._pa_last_pushed_cells) if "_pa_last_pushed_cells" in generator else 0
		var _pa_total_out: int = int(generator._pa_last_total_cells) if "_pa_last_total_cells" in generator else 0
		var _pa_push_ratio_out: float = (float(_pa_pushed_out) / float(_pa_total_out)) if _pa_total_out > 0 else 1.0
		generator._last_climate_breakdown = {
			"pass_a_ms": _round_t_pass_a_ms,
			"pass_b_ms": _round_t_pass_b_ms,
			"ocean_ms": _round_t_ocean_ms,
			"wind_ms": _round_t_wind_ms,
			"sea_ice_ms": _round_t_sea_ice_ms,
			"ice_bake_ms": 0.0,  # GPU 海冰上传已迁到 SeaIceAtlasUploadJob
			"transp_ms": _round_t_transp_ms,
			"total_ms": float(Time.get_ticks_msec() - _round_t_round_start_ms),
			"cells": map.cell_count(),
			"partial": false,
			"current_pass": "done",
			"processed_cells": 0,
			"cursor_start": -1,
			"cursor_end": -1,
			"progress_ratio": 1.0,
			"budget_interrupted": false,
			"pass_status": _PASS_RESULT_DONE,
			"pass_token": _active_pass_token,
			"pass_diag": _last_pass_diag.duplicate(true),
			"transp_native_diag": _last_transp_native_diag.duplicate(true),
			"dirty_ratio": dirty_ratio_out,
			"visited_ratio": visited_ratio_out,
			"pass_b_path": pass_b_path_out,
			# A.2.1.B — Pass-A 写路径下移 push 集大小（≤ cells，反映 ε sparse 有效性）
			"pa_pushed_cells": _pa_pushed_out,
			"pa_total_cells": _pa_total_out,
			"pa_push_ratio": _pa_push_ratio_out,
			"max_temp_delta": float(finalizer_diag.get("max_temp_delta", 0.0)),
			"p95_temp_delta": float(finalizer_diag.get("p95_temp_delta", 0.0)),
			"p99_temp_delta": float(finalizer_diag.get("p99_temp_delta", 0.0)),
			"preclamp_max_temp_delta": float(finalizer_diag.get("preclamp_max_temp_delta", 0.0)),
			"preclamp_p99_temp_delta": float(finalizer_diag.get("preclamp_p99_temp_delta", 0.0)),
			"temp_delta_gt_005_count": int(finalizer_diag.get("temp_delta_gt_005_count", 0)),
			"temp_delta_gt_010_count": int(finalizer_diag.get("temp_delta_gt_010_count", 0)),
			"temp_delta_gt_020_count": int(finalizer_diag.get("temp_delta_gt_020_count", 0)),
			"temp_delta_clamped_count": int(finalizer_diag.get("temp_delta_clamped_count", 0)),
			"max_transport_anomaly": float(finalizer_diag.get("max_transport_anomaly", 0.0)),
			"sea_ice_delta_max": float(finalizer_diag.get("sea_ice_delta_max", 0.0)),
			"precip_p95": float(finalizer_diag.get("precip_p95", 0.0)),
			"thermal_finalizer_applied": bool(finalizer_diag.get("thermal_finalizer_applied", false)),
			"finalizer_cpp_worker": _async_finalizer_used,
			"finalizer_fallback_reason": async_fin_fallback_reason,
			"finalizer_total_ms": float(finalizer_diag.get("finalizer_total_ms", 0.0)),
			"finalizer_cell_ms": float(finalizer_diag.get("finalizer_cell_ms", 0.0)),
			"finalizer_temp_ms": float(finalizer_diag.get("finalizer_temp_ms", 0.0)),
			"finalizer_tta_ms": float(finalizer_diag.get("finalizer_tta_ms", 0.0)),
			"finalizer_thermal_ms": float(finalizer_diag.get("finalizer_thermal_ms", 0.0)),
			"finalizer_sort_ms": float(finalizer_diag.get("finalizer_sort_ms", 0.0)),
			"finalizer_sea_ice_ms": float(finalizer_diag.get("finalizer_sea_ice_ms", 0.0)),
			"finalizer_precip_ms": float(finalizer_diag.get("finalizer_precip_ms", 0.0)),
			"finalizer_write_dense_ms": float(finalizer_diag.get("finalizer_write_dense_ms", 0.0)),
			"finalizer_cells_seen": int(finalizer_diag.get("finalizer_cells_seen", 0)),
			"finalizer_temperature_cell_mirror": bool(finalizer_diag.get("finalizer_temperature_cell_mirror", false)),
			"finalizer_tta_cell_mirror": bool(finalizer_diag.get("finalizer_tta_cell_mirror", false)),
			"finalizer_tta_cell_mirror_count": int(finalizer_diag.get("finalizer_tta_cell_mirror_count", 0)),
			"finalizer_tta_clamped_count": int(finalizer_diag.get("finalizer_tta_clamped_count", 0)),
			"finalizer_thermal_init_count": int(finalizer_diag.get("finalizer_thermal_init_count", 0)),
			# 方案 ④ Step 1：写入时打 fast tick 戳，perf_recorder 据此判定 stale 回放
			"_tick_idx": int(generator._current_fast_tick_idx) if "_current_fast_tick_idx" in generator else 0,
		}
		_merge_climate_wrapper_diag(generator._last_climate_breakdown)
		_last_finalize_diag["finalize_breakdown_ms"] = float(Time.get_ticks_usec() - t_finalize_part_us) / 1000.0
		var n: int = generator._daily_climate_call_count
		t_finalize_part_us = Time.get_ticks_usec()
		if _is_annual_log_tick(n):
			# I1.A-1: 在 round summary 末尾追加 path=... 标识，与 weather 日志对齐，
			# 便于 grep / A-B 桶聚合。dots-flag-prune-pr1 (2026-05-22)：
			# use_data_core_climate flag 已删除——climate 现恒走 DataCore 单路径：
			#   legacy                — World 还没绑定（启动早期 fallback）
			#   data_core_cells_only  — World 已绑定，但 25 个 comp_id 还未缓存好
			#   data_core             — World 已绑定 + 全部 comp_id 缓存就绪
			var _path_str: String = "legacy"
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
			print("refresh_climate_daily(sliced) #%d: %dms across sub-ticks (cells=%d, phase=%.3f) | A=%.1f B=%.1f ocean=%.1f wind=%.1f sea_ice=%.1f transp=%.1f path=%s" % [
				n,
				int(Time.get_ticks_msec() - _round_t_round_start_ms),
				map.cell_count(),
				_phase_locked,
				_round_t_pass_a_ms, _round_t_pass_b_ms, _round_t_ocean_ms, _round_t_wind_ms, _round_t_sea_ice_ms, _round_t_transp_ms,
				_path_str,
			])
		_last_finalize_diag["finalize_annual_log_ms"] = float(Time.get_ticks_usec() - t_finalize_part_us) / 1000.0
	# Climate-Weather 2ms Budget — Phase A.3：SoA pipeline 启用时，整 round 完成
	# 后一次性把 SoA 数组 flush 回 HexCell 强类型成员，让 UI / Baker / Overlay 等
	# 只读消费者继续工作。开关关闭时 has_soa() 仍为 true，但所有 sub-pass 走的都是
	# legacy 路径直写 cell.*，flush 是幂等的（只是把当前 cell 值往 SoA 镜像里同步
	# 一遍，再读出来——开销与 cell 数量成正比，只在 round 末跑一次，可接受）。
	t_finalize_part_us = Time.get_ticks_usec()
	if generator != null:
		var cp_for_flush = generator._c()
		if cp_for_flush != null and bool(cp_for_flush.use_soa_pipeline) and map != null and map.has_soa():
			# PR-2.4（2026-05-14）：flush_soa_to_cells 已删除。
			# HexCell facade 让 cell.<field> getter 直接走 SoA，不再需要反向同步。
			pass
	_last_finalize_diag["finalize_soa_noop_ms"] = float(Time.get_ticks_usec() - t_finalize_part_us) / 1000.0
	# DCSoakDump（dots-storage-同源紧急修复 2026-05-14）：climate pipeline 末尾，
	# 写一段 climate-phase 记录。is_active() 失败时本调用是 nop，不引入额外开销；
	# 启动后会在 N tick 后自动 stop。
	t_finalize_part_us = Time.get_ticks_usec()
	if DCSoakDump.instance != null and DCSoakDump.instance.is_active():
		var sim_day: int = 0
		if generator != null and "_daily_climate_call_count" in generator:
			sim_day = int(generator._daily_climate_call_count)
		DCSoakDump.instance.record_tick("climate", sim_day, _phase_locked, map)
	_last_finalize_diag["finalize_soak_ms"] = float(Time.get_ticks_usec() - t_finalize_part_us) / 1000.0
	t_finalize_part_us = Time.get_ticks_usec()
	_debug_climate_integrity("round_done")
	_last_finalize_diag["finalize_integrity_ms"] = float(Time.get_ticks_usec() - t_finalize_part_us) / 1000.0
	t_finalize_part_us = Time.get_ticks_usec()
	_finish_active_pass()
	_last_finalize_diag["finalize_finish_pass_ms"] = float(Time.get_ticks_usec() - t_finalize_part_us) / 1000.0
	t_finalize_part_us = Time.get_ticks_usec()
	_reset_transpiration_slice_state()
	_last_finalize_diag["finalize_reset_transp_ms"] = float(Time.get_ticks_usec() - t_finalize_part_us) / 1000.0
	_round_active = false
	_pass_cursor = 0
	# dirty-mark-batch-2026-06：round 末尾合并发布 mark_dirty_all。pass_a 16 slot
	# flush 原本触发 16 次跨 GDExtension 边界 call，现合并为 1 次。atlas pipeline
	# 在下个 stride 看到的 dirty 信号语义不变（全图脏 → 增量消费）。
	t_finalize_part_us = Time.get_ticks_usec()
	if generator != null and generator._data_core_world_ext != null \
			and generator._data_core_world_ext.has_method("flush_pending_mark_dirty_all"):
		generator._data_core_world_ext.flush_pending_mark_dirty_all()
	_last_finalize_diag["finalize_flush_dirty_ms"] = float(Time.get_ticks_usec() - t_finalize_part_us) / 1000.0
	# refresh-consolidation-2026-06：round 末尾 mark stale，下一 round 必 refresh。
	# 同时 dump 计数到 logcat，便于验收"原本 N 次 refresh → 现在 M 次"的效果。
	if generator != null:
		t_finalize_part_us = Time.get_ticks_usec()
		if generator.has_method("_mark_climate_daily_round_slots_stale"):
			generator._mark_climate_daily_round_slots_stale()
		_last_finalize_diag["finalize_mark_stale_ms"] = float(Time.get_ticks_usec() - t_finalize_part_us) / 1000.0
		t_finalize_part_us = Time.get_ticks_usec()
		if generator.has_method("dump_climate_daily_round_slots_stats"):
			var stats: Dictionary = generator.dump_climate_daily_round_slots_stats()
			# 每 20 round 打一次，避免刷屏
			if int(stats.get("refresh_count", 0)) > 0 \
					and generator.get("_daily_climate_call_count") != null \
					and int(generator._daily_climate_call_count) % 20 == 1:
				print("[climate/round] refresh_count=%d skip_count=%d (per round)" % [
					int(stats.get("refresh_count", 0)),
					int(stats.get("skip_count", 0)),
				])
		_last_finalize_diag["finalize_dump_stats_ms"] = float(Time.get_ticks_usec() - t_finalize_part_us) / 1000.0
	_last_finalize_diag["finalize_total_ms"] = float(Time.get_ticks_usec() - t_finalize_us) / 1000.0
	# Stage 9 / Fix #11 (2026-06-16) STAGE-TOTAL 埋点：观察 C++ worker finalizer 是否启用。
	# 启用时 finalize_total_ms 应 < 3ms（之前 main thread 跑 _apply_*_finalizer 是 13-17ms）。
	# 前 5 round 必打，后续仅 >= 5ms 异常打。
	var _fin_total_ms: float = float(_last_finalize_diag["finalize_total_ms"])
	if PKLog.enabled and (_fin_stage_log_count < 5 or _fin_total_ms >= 5.0):
		_fin_stage_log_count += 1
		print("[climate_finalizer/STAGE-TOTAL] call#%d wall=%.2fms cpp_worker=%s fallback_reason=%s (target: <3ms cpp / 13-17ms gdscript_fallback)" % [
			_fin_stage_log_count, _fin_total_ms, str(_async_finalizer_used), async_fin_fallback_reason,
		])
	if generator != null and "_last_climate_breakdown" in generator:
		_merge_climate_wrapper_diag(generator._last_climate_breakdown)


func get_last_pass_diag() -> Dictionary:
	return _last_pass_diag.duplicate(true)


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


## 兼容性：旧 0.4.1 路径里 map_generator 用 climate_sys.get_inner() 取强类型
## RefreshClimateDailyJob 引用。W.1 之后本类本身就是 SusJob，get_inner()
## 直接返回 self。
func get_inner():
	return self
