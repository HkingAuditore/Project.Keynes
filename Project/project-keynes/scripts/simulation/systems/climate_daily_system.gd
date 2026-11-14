extends DCSystem
class_name ClimateDailySystem

## Phase W.1 — DCSystem 原生重写（dots-migration-roadmap §I.2）。
##
## 原 `RefreshClimateDailyJob` 的 round 切片逻辑和手写 _comp_cell_* cache 已全部
## 上提到本类；旧兼容壳已删除。component cache 由基类 DCSystem.setup() 自动填充。
##
## ─── 类层级与兼容性 ─────────────────────────────────────────────────
##
## ClimateDailySystem extends DCSystem extends SusJob，是 production
## `refresh_climate_daily` 的唯一入口。
##
## ─── reads / writes / pools 声明 ───────────────────────────────────
##
## reads: 25 个 cell-level component（climate Pass-A/B、ocean、sea_ice、
##        transp 计算的全部输入）；基类 setup() 自动 cache 到 _cid。
## writes: 主要写 cell.temp / cell.moisture / cell.snowpack / cell.sea_ice_frac /
##         cell.temp_30d / cell.temp_365d / cell.temp_anomaly / cell.temp_baseline /
##         cell.temp_season_offset / cell.air_mass_temp_anomaly / cell.climate_dirty /
##         cell.ema_initialized
##
## feature_flag：留空（climate daily 是世界推进必跑流程）。
##
## ─── Driver / strategy ────────────────────────────────────────────
##
## Driven by:  SUS daily tick (sourced from main.gd._on_day_changed).
## Strategy:   StridePolicy(stride) — 决定哪些 day 触发 round 启动；
##             round 内部由 _pass_cursor 推进 sub-pass，每 tick 仅 1 段。
##
## Sub-pass 顺序（严格按下方编号；上一段产物必须已写入 HexCell 字段）：
##   0) climate_pass_a           — 裸基线 temp/moisture/snowpack + EMA   (~15ms)
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
const ClimateDailyRuntimeScript = preload("res://scripts/simulation/climate/climate_daily_runtime.gd")
var _runtime = ClimateDailyRuntimeScript.new()
const _SOAK_DUMP_SCRIPT_PATH := "res://scripts/tools/dots_soak_dump.gd"
var _soak_dump_script = null
func _get_soak_dump_instance():
	return _runtime._get_soak_dump_instance(self)
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
	policy = SusPolicyScript.StridePolicy.new(stride, 0)


# ─── DCSystem 声明 ──────────────────────────────────────────────────

func declare_reads() -> Array[StringName]:
	# 与旧 climate daily job 的读集对齐；基类 DCSystem.setup() 自动 cache 到 _cid。
	var reads: Array[StringName] = [
		DCComponentIds.CELL_TEMP,
		DCComponentIds.CELL_TEMP_BASELINE,
		DCComponentIds.CELL_TEMP_30D,
		DCComponentIds.CELL_TEMP_365D,
		DCComponentIds.CELL_TEMP_ANOMALY,
		DCComponentIds.CELL_MOISTURE,
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
		DCComponentIds.CELL_PLANT_AVAILABLE_WATER,
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
# （旧 job _on_world_bound 的轻量校验）。

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


func _default_reset_boundary_intents() -> Array:
	return [
		"abort_active_pass",
		"abort_all_climate_passes",
		"reset_round_local_state",
		"reset_async_lifecycle_local_state",
		"reset_round_timings",
		"reset_start_snapshots",
		"reset_last_diagnostics",
		"reset_transpiration_state",
		"reset_dirty_season_state",
		"seed_full_sweep_counter",
	]


func _execute_reset_boundary_intents(intents: Array, native_reset_report: Dictionary = {}) -> void:
	_last_finalize_diag = {
		"reset_boundary_intents": intents.duplicate(true),
		"reset_boundary_intent_owner": native_reset_report.get("reset_boundary_intent_owner", "gdscript_default"),
		"reset_boundary_unknown_intents": [],
	}
	for raw_intent in intents:
		var intent: String = str(raw_intent.get("kind", "")) if typeof(raw_intent) == TYPE_DICTIONARY else str(raw_intent)
		match intent:
			"abort_active_pass":
				_abort_active_pass(_ABORT_REASON_RESET)
			"abort_all_climate_passes":
				if generator != null and generator.has_method("_abort_all_climate_passes"):
					generator._abort_all_climate_passes("daily_reset")
			"reset_round_local_state":
				_pass_cursor = 0
				_round_active = false
				_phase_locked = 0.0
				_finalize_pending = false
			"reset_async_lifecycle_local_state":
				_async_round_kicked = false
				_async_round_poll_attempts = 0
				_async_round_kick_tick = -1
				_async_first_round_logged = false
			"reset_round_timings":
				_round_t_pass_a_ms = 0.0
				_round_t_pass_b_ms = 0.0
				_round_t_ocean_ms = 0.0
				_round_t_wind_ms = 0.0
				_round_t_sea_ice_ms = 0.0
				_round_t_transp_ms = 0.0
				_round_t_round_start_ms = 0
			"reset_start_snapshots":
				_temp_start_of_day_arr = PackedFloat32Array()
				_tta_start_of_day_arr = PackedFloat32Array()
			"reset_last_diagnostics":
				_last_finalizer_diag = {}
				_last_round_start_diag = {}
				_last_slice_pass_overhead_ms = 0.0
				ran_this_tick = false
				_last_slice_elapsed_ms = 0.0
				_reset_last_pass_diag()
			"reset_transpiration_state":
				_reset_transpiration_slice_state()
			"reset_dirty_season_state":
				_last_phase_int_seen = -9999
			"seed_full_sweep_counter":
				_full_sweep_counter = _FULL_SWEEP_PERIOD
			_:
				var unknown: Array = _last_finalize_diag.get("reset_boundary_unknown_intents", [])
				unknown.append(intent)
				_last_finalize_diag["reset_boundary_unknown_intents"] = unknown


func reset_progress() -> void:
	super.reset_progress()
	var native_reset_report: Dictionary = {}
	if generator != null and generator.get("_data_core_world_ext") != null :
		native_reset_report = generator._data_core_world_ext.reset_native_climate_round_state("ClimateDailySystem.reset_progress")
	var reset_intents: Array = native_reset_report.get("reset_boundary_intents", [])
	if reset_intents.is_empty():
		reset_intents = _default_reset_boundary_intents()
	_execute_reset_boundary_intents(reset_intents, native_reset_report)


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
	return _runtime._should_sync_runtime_terrain_views(self, reason)
func _sync_runtime_terrain_views_for_reason(reason: String) -> Dictionary:
	return _runtime._sync_runtime_terrain_views_for_reason(self, reason)
func _standalone_sea_ice_enabled() -> bool:
	return _runtime._standalone_sea_ice_enabled(self)
func _sync_runtime_terrain_views(reason: String) -> Dictionary:
	return _runtime._sync_runtime_terrain_views(self, reason)

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
	return ClimateDailyRuntimeScript._percentile_from_sorted(values, p)
func _calendar_days_per_year() -> int:
	return _runtime._calendar_days_per_year(self)
func _is_annual_log_tick(counter: int) -> bool:
	return _runtime._is_annual_log_tick(self, counter)
func _build_finalizer_diag_from_worker(poll: Dictionary) -> Dictionary:
	return ClimateDailyRuntimeScript._build_finalizer_diag_from_worker(poll)
func _async_finalizer_fallback_reason(poll: Dictionary) -> String:
	return _runtime._async_finalizer_fallback_reason(self, poll)
func _apply_daily_climate_finalizer() -> Dictionary:
	return _runtime._apply_daily_climate_finalizer(self)

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
func _climate_diag_terrain_water(t: int) -> bool:
	return ClimateDailyRuntimeScript._climate_diag_terrain_water(t)
func _climate_diag_ocean_water(t: int) -> bool:
	return ClimateDailyRuntimeScript._climate_diag_ocean_water(t)
func _climate_diag_corr(a: PackedFloat32Array, b: PackedFloat32Array, limit: int) -> float:
	return _runtime._climate_diag_corr(self, a, b, limit)
func _climate_diag_p95(arr: PackedFloat32Array, limit: int) -> float:
	return _runtime._climate_diag_p95(self, arr, limit)
func _climate_diag_push_sample(samples: PackedStringArray, text: String) -> void:
	ClimateDailyRuntimeScript._climate_diag_push_sample(samples, text)
func _debug_climate_integrity(stage_name: String, force: bool = false) -> void:
	_runtime._debug_climate_integrity(self, stage_name, force)
func _native_climate_lifecycle_state(ext: Object) -> Dictionary:
	return ClimateDailyRuntimeScript._native_climate_lifecycle_state(ext)
func _sync_async_lifecycle_from_native(state: Dictionary) -> void:
	_runtime._sync_async_lifecycle_from_native(self, state)
func _default_async_round_start_boundary_intents() -> Array:
	return ClimateDailyRuntimeScript._default_async_round_start_boundary_intents()
func _execute_async_round_start_boundary_intents(intents: Array) -> Dictionary:
	return _runtime._execute_async_round_start_boundary_intents(self, intents)
func _default_async_round_finish_boundary_intents() -> Array:
	return ClimateDailyRuntimeScript._default_async_round_finish_boundary_intents()
func _default_finalize_tail_boundary_intents(async_poll_result: Dictionary = {}) -> Array:
	return ClimateDailyRuntimeScript._default_finalize_tail_boundary_intents(async_poll_result)
func _execute_finalize_tail_boundary_intents(
		intents: Array,
		async_poll_result: Dictionary
) -> Dictionary:
	return _runtime._execute_finalize_tail_boundary_intents(self, intents, async_poll_result)
func _execute_async_round_finish_boundary_intents(intents: Array, poll_result: Dictionary, ext: Object, finish_t0_us: int, native_poll_report: Dictionary = {}) -> Dictionary:
	return _runtime._execute_async_round_finish_boundary_intents(self, intents, poll_result, ext, finish_t0_us, native_poll_report)
func _run_slice_async(ctx: SusTickContext) -> Dictionary:
	return _runtime._run_slice_async(self, ctx)
func _async_round_partial_report(slice_ms: float, stage_label: String) -> Dictionary:
	return _runtime._async_round_partial_report(self, slice_ms, stage_label)
func _build_async_kick_input(season_phase: float) -> Dictionary:
	return _runtime._build_async_kick_input(self, season_phase)
func _build_async_static_knobs() -> Dictionary:
	return _runtime._build_async_static_knobs(self)
func _handle_async_sea_ice_flips(poll_result: Dictionary) -> void:
	_runtime._handle_async_sea_ice_flips(self, poll_result)

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
func _finalize_round(async_poll_result: Dictionary = {}, finalize_tail_boundary_intents: Array = []) -> void:
	var t_finalize_us: int = Time.get_ticks_usec()
	_last_finalize_diag = {
		"finalize_total_ms": 0.0,
		"finalize_finalizer_ms": 0.0,
		"finalize_counter_ms": 0.0,
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
		"finalizer_cpp_worker": false,
		"finalizer_fallback_reason": "",
	}
	if finalize_tail_boundary_intents.is_empty():
		finalize_tail_boundary_intents = _default_finalize_tail_boundary_intents(async_poll_result)
	var finalize_exec_diag: Dictionary = _execute_finalize_tail_boundary_intents(
		finalize_tail_boundary_intents,
		async_poll_result
	)
	_last_finalize_diag["finalize_total_ms"] = float(Time.get_ticks_usec() - t_finalize_us) / 1000.0
	var _async_finalizer_used: bool = bool(finalize_exec_diag.get("finalizer_cpp_worker", false))
	var async_fin_fallback_reason: String = String(finalize_exec_diag.get("finalizer_fallback_reason", ""))
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


func climate_round_state_snapshot() -> Dictionary:
	var current_pass: String = "idle"
	if _round_active and _pass_cursor >= 0 and _pass_cursor < _PASS_NAMES.size():
		current_pass = _PASS_NAMES[_pass_cursor]
	elif _finalize_pending:
		current_pass = "round_finalize"
	elif _pass_cursor >= _PASS_COUNT:
		current_pass = "round_done"
	var active_owner_requested: bool = false
	var cp_owner = generator._c() if generator != null else null
	if cp_owner != null and cp_owner.get("native_climate_round_active_owner_enabled") != null:
		active_owner_requested = bool(cp_owner.native_climate_round_active_owner_enabled)
	var compact_capsule_enabled: bool = cp_owner != null \
			and cp_owner.get("native_daily_compact_state_capsule_enabled") != null \
			and bool(cp_owner.native_daily_compact_state_capsule_enabled)
	var native_state: Dictionary = {}
	var native_ext = generator._data_core_world_ext if generator != null else null
	if native_ext != null and active_owner_requested and compact_capsule_enabled:
		native_state = native_ext.get_native_climate_round_hot_state()
	elif native_ext != null:
		native_state = native_ext.get_native_climate_round_state_report()
	var compact_capsule: bool = bool(native_state.get("compact_state_capsule", false))
	var native_state_for_snapshot: Dictionary = native_state.duplicate(
			not compact_capsule)
	var snapshot_owner: String = "native_ready" if bool(native_state.get("climate_round_authority_ready", false)) else "gdscript_retained"
	if snapshot_owner == "native_ready" and active_owner_requested:
		snapshot_owner = "native_active"
		native_state_for_snapshot["authority"] = "native_active_owner"
		native_state_for_snapshot["simulation_authority"] = true
		native_state_for_snapshot["active_owner_requested"] = true
		native_state_for_snapshot["climate_round_authority_phase"] = "native_active_owner"
		var godot_boundaries: Array = native_state.get("remaining_godot_boundary_authority", [])
		if godot_boundaries.is_empty():
			godot_boundaries = ["godot_mapdata_boundary_execution", "reset_abort_boundary_execution"]
		native_state_for_snapshot["remaining_gdscript_simulation_authority"] = []
		native_state_for_snapshot["remaining_godot_boundary_authority"] = godot_boundaries
		native_state_for_snapshot["remaining_gdscript_authority"] = godot_boundaries
		native_state_for_snapshot["fallback_mode"] = "explicit_failure_only"
		native_state_for_snapshot["single_authority_claim"] = "climate_round_state_machine"
	elif not native_state_for_snapshot.is_empty():
		native_state_for_snapshot["active_owner_requested"] = active_owner_requested
	var native_state_status: String = "native_ready_probe_mirror" if snapshot_owner == "native_ready" else "probe_mirror_only"
	if snapshot_owner == "native_active":
		native_state_status = "native_active_owner_mirror"
	var out: Dictionary = {
		"owner": snapshot_owner,
		"native_state_status": native_state_status,
		"round_active": _round_active,
		"pass_cursor": _pass_cursor,
		"pass_count": _PASS_COUNT,
		"current_pass": current_pass,
		"phase_locked": _phase_locked,
		"finalize_pending": _finalize_pending,
		"async_round_kicked": _async_round_kicked,
		"async_round_poll_attempts": _async_round_poll_attempts,
		"async_round_kick_tick": _async_round_kick_tick,
		"pass_generation": _pass_generation,
		"active_pass_token": _active_pass_token,
			"active_pass_state": {} if compact_capsule else _active_pass_state.duplicate(true),
			"last_pass_diag": {} if compact_capsule else _last_pass_diag.duplicate(true),
		"transp_stage": _transp_stage_label(_transp_stage),
		"transp_cursor": _transp_cursor,
		"transp_n_cells": _transp_n_cells,
		"full_sweep_counter": _full_sweep_counter,
		"last_phase_int_seen": _last_phase_int_seen,
			"reset_owner": "ClimateDailySystem.reset_progress",
			"compact_state_capsule": compact_capsule,
	}
	if not native_state_for_snapshot.is_empty():
		out["native_probe_state"] = native_state_for_snapshot
	return out


## Allow MapGenerator to retune the stride/phase on the fly.
func reconfigure(p_stride: int, p_phase: int = 0) -> void:
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, posmod(p_phase, stride))


func reset_run_flag() -> void:
	ran_this_tick = false
	_last_slice_elapsed_ms = 0.0


func did_run_last_tick() -> bool:
	return ran_this_tick


func last_slice_elapsed_ms() -> float:
	return _last_slice_elapsed_ms


## 兼容性：map_generator 仍用 get_inner() 取得 SusJob 面引用；本类本身就是
## SusJob，直接返回 self。
func get_inner():
	return self
