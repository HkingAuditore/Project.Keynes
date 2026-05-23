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
const _PASS_SEA_ICE: int = 4
const _PASS_TRANSP: int = 5
const _PASS_COUNT: int = 6
const _PASS_NAMES: PackedStringArray = [
	"pass_a", "pass_b", "ocean_water", "ocean_land", "sea_ice", "transp"
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

# A.2.1.A4 — Dirty Mask 季节强制全图 / 每 30 日 full sweep 钩子。
# _last_phase_int_seen：上一次 round 进入时 floor(_phase_locked) 的整数部分；
#   跨过整数（季节切换）→ 本 round 开始时 mark_all_climate_dirty()
# _full_sweep_counter：每完成一 round +1，达到 30 时下一 round 入口 mark_all
# 初始化为 30：让"加载存档后首日"立刻强制全图，建立稳态 baseline
var _last_phase_int_seen: int = -9999
var _full_sweep_counter: int = 30


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
	# 与原 RefreshClimateDailyJob._on_world_bound 内手写 25 个 _comp_cell_*
	# cache 1:1 对齐（基类 DCSystem.setup() 自动 cache 到 _cid）
	return [
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
		DCComponentIds.CELL_OCEAN_CURRENT_X,
		DCComponentIds.CELL_OCEAN_CURRENT_Y,
		DCComponentIds.CELL_WIND_X,
		DCComponentIds.CELL_WIND_Y,
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
	]


func declare_writes() -> Array[StringName]:
	return [
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
	]


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
	_reset_last_pass_diag()
	# A.2.1.A4 — 重置 Dirty Mask 季节钩子状态，保证加载存档后首日 mark_all
	_last_phase_int_seen = -9999
	_full_sweep_counter = 30


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


func _diagnostics_enabled() -> bool:
	var cp = generator._c() if generator != null else null
	if cp == null:
		return true
	if cp.get("climate_pass_diagnostics_enabled") != null:
		return bool(cp.climate_pass_diagnostics_enabled)
	if cp.get("performance_diagnostics_enabled") != null:
		return bool(cp.performance_diagnostics_enabled)
	return true


func _begin_round_pass_state() -> void:
	_pass_generation += 1
	_active_pass_token = _pass_generation
	_active_pass_state = {
		"token": _active_pass_token,
		"state": _PASS_STATE_RUNNING,
		"pass_cursor": 0,
		"stage": "round_begin",
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
	_active_pass_state["token"] = token
	_active_pass_state["state"] = _PASS_STATE_DONE if result_done else _PASS_STATE_RUNNING
	_active_pass_state["pass_cursor"] = _pass_cursor
	_active_pass_state["stage"] = pass_name
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
	if bool(_active_pass_state.get("diagnostics_enabled", true)):
		_last_pass_diag = _active_pass_state.duplicate(true)
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


## 主 tick / run_slice 入口。基类 DCSystem.run_slice 默认转发到 tick(ctx)，
## 这里直接重写 run_slice 保留与 RefreshClimateDailyJob 1:1 同名签名（SUS 直接调）。
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
		_begin_round_pass_state()
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
			_PASS_TRANSP:
				should_skip = not local_coupling
			_:
				should_skip = false
		if should_skip:
			_pass_cursor += 1
			continue
		# 找到当前应执行的段——执行它并退出 while（每 tick 只跑 1 段）
		var pass_done: bool = _run_pass(pass_id)
		ran_pass_id = pass_id
		if pass_done:
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
	var processed_cells_out: int = _last_pass_processed_cells
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
	}


# ─── 内部：按 pass_id 调用 generator 上的 sub-pass 并累积埋点 ─────────────
func _run_pass(pass_id: int) -> bool:
	var token: int = _active_pass_token
	var t_us0: int = Time.get_ticks_usec()
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
		_PASS_SEA_ICE:
			if generator.has_method("run_climate_pass_slice"):
				var r_si: Dictionary = generator.run_climate_pass_slice("sea_ice", map, _phase_locked)
				_round_t_sea_ice_ms += float(r_si.get("elapsed_ms", 0.0))
				_record_pass_result(pass_id, token, r_si, float(r_si.get("elapsed_ms", 0.0)), "sea_ice", str(r_si.get("stage", "state_machine")), "climate_chunk_api")
				return bool(r_si.get("done", true))
			else:
				generator._apply_sea_ice_daily_pass(map, _phase_locked)
				_round_t_sea_ice_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
				var r_si: Dictionary = _make_pass_result(true, _round_t_sea_ice_ms, map.cell_count(), 0, map.cell_count())
				_record_pass_result(pass_id, token, r_si, _round_t_sea_ice_ms, "sea_ice", "oneshot_fallback", "native_or_gd")
				return true
		_PASS_TRANSP:
			generator._apply_transpiration_pass(map)
			_round_t_transp_ms = (Time.get_ticks_usec() - t_us0) / 1000.0
			var r_tr: Dictionary = _make_pass_result(true, _round_t_transp_ms, map.cell_count(), 0, map.cell_count())
			_record_pass_result(pass_id, token, r_tr, _round_t_transp_ms, "transp", "oneshot", "gdscript")
			return true
	return true


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
		"processed_cells": _last_pass_processed_cells,
		"cursor_start": _last_pass_cursor_start,
		"cursor_end": _last_pass_cursor_end,
		"progress_ratio": progress,
		"budget_interrupted": _last_pass_budget_interrupted,
		"pass_status": _last_pass_status,
		"pass_token": _active_pass_token,
		"pass_diag": _last_pass_diag.duplicate(true),
		"dirty_ratio": dirty_ratio_out,
		"visited_ratio": visited_ratio_out,
		"pass_b_path": pass_b_path_out,
		# 方案 ④ Step 1：写入时打 fast tick 戳，perf_recorder 据此判定 stale 回放
		"_tick_idx": int(generator._current_fast_tick_idx) if "_current_fast_tick_idx" in generator else 0,
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
		# A.2.1.B — Pass-A push 稀疏度（dynamic_visual_atlas M1 AB 验证字段）
		var _pa_pushed_out: int = int(generator._pa_last_pushed_cells) if "_pa_last_pushed_cells" in generator else 0
		var _pa_total_out: int = int(generator._pa_last_total_cells) if "_pa_last_total_cells" in generator else 0
		var _pa_push_ratio_out: float = (float(_pa_pushed_out) / float(_pa_total_out)) if _pa_total_out > 0 else 1.0
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
			"processed_cells": 0,
			"cursor_start": -1,
			"cursor_end": -1,
			"progress_ratio": 1.0,
			"budget_interrupted": false,
			"pass_status": _PASS_RESULT_DONE,
			"pass_token": _active_pass_token,
			"pass_diag": _last_pass_diag.duplicate(true),
			"dirty_ratio": dirty_ratio_out,
			"visited_ratio": visited_ratio_out,
			"pass_b_path": pass_b_path_out,
			# A.2.1.B — Pass-A 写路径下移 push 集大小（≤ cells，反映 ε sparse 有效性）
			"pa_pushed_cells": _pa_pushed_out,
			"pa_total_cells": _pa_total_out,
			"pa_push_ratio": _pa_push_ratio_out,
			# 方案 ④ Step 1：写入时打 fast tick 戳，perf_recorder 据此判定 stale 回放
			"_tick_idx": int(generator._current_fast_tick_idx) if "_current_fast_tick_idx" in generator else 0,
		}
		var n: int = generator._daily_climate_call_count
		if n == 1 or (n % 365) == 0:
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
			# PR-2.4（2026-05-14）：flush_soa_to_cells 已删除。
			# HexCell facade 让 cell.<field> getter 直接走 SoA，不再需要反向同步。
			pass
	# DCSoakDump（dots-storage-同源紧急修复 2026-05-14）：climate pipeline 末尾，
	# 写一段 climate-phase 记录。is_active() 失败时本调用是 nop，不引入额外开销；
	# 启动后会在 N tick 后自动 stop。
	if DCSoakDump.instance != null and DCSoakDump.instance.is_active():
		var sim_day: int = 0
		if generator != null and "_daily_climate_call_count" in generator:
			sim_day = int(generator._daily_climate_call_count)
		DCSoakDump.instance.record_tick("climate", sim_day, _phase_locked, map)
	_finish_active_pass()
	_round_active = false
	_pass_cursor = 0


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
