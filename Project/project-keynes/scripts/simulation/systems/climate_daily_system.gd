extends DCSystem
class_name ClimateDailySystem

const DailyPublication = preload("res://scripts/simulation/systems/climate_daily_publication.gd")

const PassSteps = preload("res://scripts/simulation/systems/climate_daily_pass_steps.gd")

const DailyTick = preload("res://scripts/simulation/systems/climate_daily_tick.gd")

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
	return DailyTick.run_slice(self, ctx)


# ─── 内部：按 pass_id 调用 generator 上的 sub-pass 并累积埋点 ─────────────
func _run_pass(pass_id: int) -> bool:
	return PassSteps._run_pass(self, pass_id)


func _begin_transpiration_sliced() -> void:
	PassSteps._begin_transpiration_sliced(self)


func _transp_stage_label(stage_id: int) -> String:
	return PassSteps._transp_stage_label(self, stage_id)


func _transp_should_yield(t_us0: int, processed: int) -> bool:
	return PassSteps._transp_should_yield(self, t_us0, processed)


func _transp_is_water_idx(idx: int) -> bool:
	return PassSteps._transp_is_water_idx(self, idx)


func _transp_factor_idx(idx: int) -> float:
	return PassSteps._transp_factor_idx(self, idx)


func _transp_moisture_idx(idx: int) -> float:
	return PassSteps._transp_moisture_idx(self, idx)


func _run_transpiration_pass_slice() -> Dictionary:
	return PassSteps._run_transpiration_pass_slice(self)


func _publish_partial_round(pass_id: int, slice_elapsed_ms: float, progress: float) -> void:
	DailyPublication._publish_partial_round(self, pass_id, slice_elapsed_ms, progress)


func _finalize_round(async_poll_result: Dictionary = {}, finalize_tail_boundary_intents: Array = []) -> void:
	DailyPublication._finalize_round(self, async_poll_result, finalize_tail_boundary_intents)


func get_last_pass_diag() -> Dictionary:
	return DailyPublication.get_last_pass_diag(self)


func climate_round_state_snapshot() -> Dictionary:
	return DailyPublication.climate_round_state_snapshot(self)


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
