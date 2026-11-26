extends "res://scripts/simulation/sus/sus_job.gd"
class_name OceanCurrentsJob

const OceanVisualRound = preload("res://scripts/simulation/sus/jobs/ocean_currents_visual_round.gd")

const OceanPhysicalRound = preload("res://scripts/simulation/sus/jobs/ocean_currents_physical_round.gd")

const OceanDiagnostics = preload("res://scripts/simulation/sus/jobs/ocean_currents_diagnostics.gd")

## OceanCurrentsJob — slices the ocean currents + upwelling bake across many
## days so no single day_changed tick takes the legacy ~1000ms hit.
##
## Driven by: SUS daily tick (sourced from main.gd._on_day_changed).
## Strategy:  ContinuousSlicedPolicy(period_ticks, slice_count). Each slice
##            advances the physical solver one stage; after solver done we
##            EITHER short-circuit to round_done (per-cell data already in
##            HexCell, no pixel work) OR run the pixel rasterizer + commit
##            once when season_phase crosses an integer boundary (event-
##            driven pixel buffer refresh — see _need_pixel_rebake() below).
##
## 像素 buffer 是纯视觉 overlay（vector_atlas_tex / world.wind_field_buffer
## / world.ocean_current_buffer）的输入，被 hex_renderer / weather_layer 的
## shader 消费。模拟逻辑（weather_system / climate_daily / sea_ice）全部读
## HexCell.* per-cell 字段，不读这些像素 buffer。因此把"hex→620k 像素喷射"
## 移出每日 SUS、改为季节切换事件驱动可以把 day_changed 路径再砍掉 ~25ms
## 而不影响任何模拟正确性 — 视觉 overlay 仅在 phase_int 跨越（每季 1 次）
## 时刷新一次，玩家观感等同。

const MapBakerScript = preload("res://scripts/rendering/map_baker.gd")
const SusJobScript = preload("res://scripts/simulation/sus/sus_job.gd")
const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
const WorkerVisual = preload("res://scripts/simulation/ocean/ocean_currents_worker_visual.gd")

const _DEFER_AFTER_CLIMATE_SLICE_MS: float = 1.0
const _MAX_CLIMATE_DEFER_STREAK: int = 1
const _PIXEL_TARGET_MS: float = 0.85
const _PIXEL_MIN_QUOTA: int = 512
# 修复（2026-06-13）：原值 8192 把 base_quota 锁死。配合 climate_profile.tres
# 的 ocean_currents_slice_count=16（pixels_per_slice = ceil(620544/16) = 38784），
# 8192 cap 让全图填充实际跨 ~78 ticks（@x1 = 78s）而非预期 16s。C++ raster
# kernel 实测 ~0.07ms / 5172px → 65536 px 仅 ~0.9ms 仍在 sim budget 内。移动端
# HM_MAX_DIM=512 时 pixels_per_slice = ceil(155136/16) = 9696，65536 cap 几乎
# 没碰到下限，但保留余量给 quota=20 等更激进的 slice_count 配置。
const _PIXEL_MAX_QUOTA: int = 65536
const _NO_DAILY_WIND_TICK: int = -2147483648
const _NO_VISUAL_PHASE: int = -9999

# External references — wired up by MapGenerator at registration time.
var baker: MapBakerScript = null
var map: MapData = null
var world: WorldData = null
var cfg: MapConfig = null
var hex_size: float = 0.0
# Optional: callback to invoke on commit so MapGenerator can refill per-cell
# samples (avoids a hard import dependency from this file to MapGenerator).
var on_commit: Callable = Callable()
# Optional: phase getter from world_clock; if not set, falls back to ctx.season_phase.
var season_phase_getter: Callable = Callable()
# Optional: defer ocean phys slices after heavy climate sub-passes so the two
# ocean heat paths do not stack into one fast tick.
var climate_ran_this_tick_getter: Callable = Callable()
var climate_slice_ms_getter: Callable = Callable()
var data_core_world_ext = null
var _native_ocean_state: Dictionary = {}

# Internal slice cursor and locked phase for the in-flight bake round.
var _next_pixel_idx: int = 0
var _total_pixels: int = 0
# Locked at the start of each round so mid-round slices all use the same
# season_phase (avoids tiny per-slice drift).
var _phase_locked: float = 0.0
# False until the very first slice of the very first round runs (we need to
# know when to lock the phase fresh).
var _round_active: bool = false
# Commit Defer (2026-05-21)：raster 完成（_next_pixel_idx >= _total_pixels）后，
# 不立即 commit_ocean_buffers（含 620k×4 byte ImageTexture.update 同步上传 ~1-2ms）。
# 改为下一个 SUS tick 的专用 commit-only slice 跑，把单 slice 峰值
# 4.7ms（gdext_raster + commit）拆成 raster_slice ~3ms / commit_slice ~1.5ms。
# 状态：raster done → _pending_commit=true，本片 done=false 让 round 续；
# 下一片入口检测 → 跑 commit → 本片 done=true 收尾 round。
var _pending_commit: bool = false
# Phys Solve Sliced：物理化路径下，一轮 round 先做 N 个 slice 把 hex 求解（SLP /
# wind / ψ / current / upwelling / wind raster）推到 DONE，再开始按像素区间光栅化。
# True 表示求解阶段已完成，本轮余下 slice 全部用于像素工作。
var _phys_solve_done: bool = false

# Authoritative state is split so physical ocean solves can finish and start
# again while the visual pixel atlas is still rasterizing or waiting to commit.
# The legacy fields above remain as report aliases for existing diagnostics.
var _phys_round_active: bool = false
var _phys_phase_locked: float = 0.0
var _phys_need_visual: bool = false
var _phys_run_ocean_this_round: bool = true
var _physical_round_id: int = 0
var _last_physical_complete_tick: int = _NO_DAILY_WIND_TICK

var _visual_round_active: bool = false
var _visual_phase_locked: float = 0.0
var _visual_next_pixel_idx: int = 0
var _visual_total_pixels: int = 0
var _visual_pending_commit: bool = false
var _visual_round_id: int = 0
var _visual_enqueued_tick: int = _NO_DAILY_WIND_TICK

# Event-driven pixel rebake gate（2026-05-15 新增）：
#   每日只跑 hex 求解（per-cell 数据），像素 buffer 只在 season_phase 跨整数时
#   重 bake 一次。_NO_VISUAL_PHASE 表示下一轮必须重画。
#   _need_pixel_this_round 在 round 起点决定：true → 走完整 raster + commit；
#   false → 求解完成立即 round_done，跳过 stage 7 (WIND_RASTER) 与 pixel slices。
var _phase_int_seen: int = _NO_VISUAL_PHASE
var _need_pixel_this_round: bool = false
var _climate_defer_streak: int = 0
var _last_pixel_quota: int = _PIXEL_MAX_QUOTA
var _last_pixel_slice_ms: float = 0.0
var _last_pixel_slice_pixels: int = 0
var _ocean_rt_diag_count: int = 0
var _ocean_policy_diag_count: int = 0
var _ocean_pixel_rt_diag_count: int = 0
# Fix #11 (2026-06-15)：每个 phys stage 单独的诊断 budget。原 _ocean_rt_diag_count 24
# 次封顶后整个 ocean 静音，但 STAGE-TOTAL ≥ warn 阈值的异常应该一直报。
# _phys_stage_diag_count[stage_id] 记录该 stage 已打印的诊断次数（前 3 次必打，之后
# 仅在异常 >= warn 阈值时打）。budget 不与 _ocean_rt_diag_count 共享。
# stage_id 用 baker._PHYS_STAGE_* 值（1=SLP, 2=WIND, 3=PSI_INIT, 4=PSI_ITERS,
# 5=PSI_FINALIZE, 6=UPWELLING, 7=WIND_RASTER）。
# Fix #11 second pass (2026-06-16)：warn 阈值从 5ms 提到 15ms（mobile 60FPS budget
# 16.67ms / 8-tick D 桶平均 2ms/tick + 偶尔 daily_wind 叠 5-7ms 都正常，5ms 太严会
# 一直打印污染 logcat ~50× 触发 7 行 STAGE-DIAG 单次 spam）。
var _phys_stage_diag_count: Dictionary = {}
const _PHYS_STAGE_DIAG_INITIAL_PRINTS: int = 3
const _PHYS_STAGE_DIAG_WARN_MS: float = 15.0
var _last_defer_climate_ms: float = 0.0
var _current_pixel_quota_diag: int = 0
# Tunables — sourced from ClimateProfile at registration time, but stored
# here so policy and job stay in sync.
var period_ticks: int = 30
var wind_period_ticks: int = 30
var ocean_period_ticks: int = 30
var slice_count: int = 10
var _slow_slice_policy = null
var _run_ocean_this_round: bool = true
var _last_phys_diag: Dictionary = {}
var _last_daily_wind_tick: int = _NO_DAILY_WIND_TICK
var _last_daily_wind_report: Dictionary = {}
var _daily_wind_rt_diag_count: int = 0
# 每次"真正跑了一次每日风预解"就 +1。daily_wind_split 路径用它的奇偶决定本次跑
# SLP 还是 wind，确保两段都能被刷新——不能再用 day_index 奇偶，因为 wind_period_ticks>1
# 时 due 的 tick 会固定落在同一奇偶日，导致某一段永远不跑、对应场冻结。
var _daily_wind_due_seq: int = 0
var _worker_visual_source_id: int = 0
var _worker_visual_target: Array = []


func _init(p_baker: MapBakerScript, p_map: MapData, p_world: WorldData,
		p_cfg: MapConfig, p_hex_size: float,
		p_period_ticks: int, p_slice_count: int, p_ocean_period_ticks: int = -1) -> void:
	id = &"ocean_currents"
	priority = 200  # runs after refresh_climate_daily (100) / weather (150)
	slice_budget_ms = 0.55
	max_slices_per_tick = 1
	# Wind/ocean per-cell fields feed climate and weather. Keep one small slice
	# moving each eligible tick so physical circulation cannot freeze behind
	# frame-budget pressure.
	must_run = true
	use_job_should_run = true
	starvation_threshold = 4
	baker = p_baker
	map = p_map
	world = p_world
	cfg = p_cfg
	hex_size = p_hex_size
	wind_period_ticks = max(1, p_period_ticks)
	ocean_period_ticks = max(1, p_ocean_period_ticks if p_ocean_period_ticks > 0 else p_period_ticks)
	period_ticks = ocean_period_ticks
	slice_count = max(1, p_slice_count)
	_slow_slice_policy = SusPolicyScript.ContinuousSlicedPolicy.new(ocean_period_ticks, slice_count)
	# 弱机/移动端：拉长物理解周期（见 _apply_device_period_scale）。
	_apply_device_period_scale()
	# Keep this job policy-forwarded. Stateful should_run() gates require
	# use_job_should_run=true, but the slow ocean/pixel chain is intentionally
	# gated inside run_slice() while the daily wind prepass stays eligible.
	policy = SusPolicyScript.AlwaysPolicy.new()


## Total pixels for the current world. Cached at round start.
func _total_pixels_for(p_world: WorldData) -> int:
	if p_world == null:
		return 0
	return p_world.derived_size.x * p_world.derived_size.y


## Pixel quota per slice — ceil(total / slice_count).
func _pixels_per_slice() -> int:
	var total: int = _visual_total_pixels if _visual_total_pixels > 0 else _total_pixels
	return int(ceil(float(total) / float(max(1, slice_count))))


func _pixel_quota_for_next_slice(use_adaptive: bool = true) -> int:
	var base_quota: int = mini(_pixels_per_slice(), _PIXEL_MAX_QUOTA)
	if not use_adaptive:
		return max(1, base_quota)
	if base_quota <= _PIXEL_MIN_QUOTA:
		return max(1, base_quota)
	if _last_pixel_slice_ms <= 0.0 or _last_pixel_slice_pixels <= 0:
		return base_quota
	var scaled: int = int(floor(float(_last_pixel_slice_pixels) * (_PIXEL_TARGET_MS / _last_pixel_slice_ms)))
	var smoothed: int = int(round(lerpf(float(_last_pixel_quota), float(scaled), 0.5)))
	return clampi(smoothed, _PIXEL_MIN_QUOTA, base_quota)


func _sync_legacy_round_state() -> void:
	_next_pixel_idx = _visual_next_pixel_idx
	_total_pixels = _visual_total_pixels
	_phase_locked = _phys_phase_locked if _phys_round_active else _visual_phase_locked
	_round_active = _phys_round_active or _visual_round_active
	_pending_commit = _visual_pending_commit
	_need_pixel_this_round = _phys_need_visual
	_run_ocean_this_round = _phys_run_ocean_this_round


func _drop_visual_round() -> void:
	_visual_round_active = false
	_visual_pending_commit = false
	_visual_next_pixel_idx = 0
	_visual_total_pixels = 0
	_visual_phase_locked = 0.0
	_visual_enqueued_tick = _NO_DAILY_WIND_TICK
	_sync_legacy_round_state()


func _profile_drop_stale_visual() -> bool:
	var cp = cfg.climate_profile if cfg != null else null
	if cp != null and cp.get("ocean_decoupled_visual_raster") != null \
			and not bool(cp.ocean_decoupled_visual_raster):
		return false
	if cp != null and cp.get("ocean_visual_rebake_drop_stale") != null:
		return bool(cp.ocean_visual_rebake_drop_stale)
	return true


func _enqueue_visual_round(ctx: SusTickContext, phase: float) -> void:
	if _visual_round_active and _profile_drop_stale_visual():
		_drop_visual_round()
	if _visual_round_active:
		_sync_legacy_round_state()
		return
	_visual_total_pixels = _total_pixels_for(world)
	if _visual_total_pixels <= 0:
		_sync_legacy_round_state()
		return
	_visual_round_active = true
	_visual_pending_commit = false
	_visual_next_pixel_idx = 0
	_visual_phase_locked = phase
	_visual_round_id += 1
	_visual_enqueued_tick = ctx.tick_index
	_sync_legacy_round_state()


func _finish_physical_round(ctx: SusTickContext) -> void:
	_last_physical_complete_tick = ctx.tick_index
	_phys_round_active = false
	_phys_solve_done = false
	_phys_need_visual = false
	_phys_run_ocean_this_round = true
	_sync_legacy_round_state()
	_native_ocean_physical_finish(ctx, {"stage_name": "phys_done", "path": "native_lifecycle"})


func _visual_lag_ticks(ctx: SusTickContext) -> int:
	if not _visual_round_active or _visual_enqueued_tick == _NO_DAILY_WIND_TICK:
		return 0
	return max(0, ctx.tick_index - _visual_enqueued_tick)


func reset_progress() -> void:
	super.reset_progress()
	_phys_solve_done = false
	_phys_round_active = false
	_phys_phase_locked = 0.0
	_phys_need_visual = false
	_phys_run_ocean_this_round = true
	_physical_round_id = 0
	_last_physical_complete_tick = _NO_DAILY_WIND_TICK
	_visual_round_id = 0
	_phase_int_seen = _NO_VISUAL_PHASE
	_climate_defer_streak = 0
	_last_pixel_quota = _PIXEL_MAX_QUOTA
	_last_pixel_slice_ms = 0.0
	_last_pixel_slice_pixels = 0
	_ocean_rt_diag_count = 0
	_ocean_policy_diag_count = 0
	_ocean_pixel_rt_diag_count = 0
	_phys_stage_diag_count = {}
	_last_defer_climate_ms = 0.0
	_current_pixel_quota_diag = 0
	_last_phys_diag = {}
	_last_daily_wind_tick = _NO_DAILY_WIND_TICK
	_last_daily_wind_report = {}
	_daily_wind_rt_diag_count = 0
	_daily_wind_due_seq = 0
	_worker_visual_source_id = 0
	_worker_visual_target.clear()
	_drop_visual_round()
	if data_core_world_ext != null:
		_native_ocean_state = data_core_world_ext.reset_native_ocean_physical_state("ocean_job_reset")
	if baker != null and baker.has_method("discard_ocean_buffers"):
		baker.discard_ocean_buffers()


func _native_ocean_base_ctx(ctx: SusTickContext) -> Dictionary:
	return {
		"tick_index": ctx.tick_index,
		"day_index": ctx.day_index,
		"phase_locked": _phys_phase_locked,
		"physical_phase_locked": _phys_phase_locked,
		"physical_round_id": _physical_round_id,
		"physical_round_active": _phys_round_active,
		"physical_need_visual": _phys_need_visual,
		"physical_run_ocean": _phys_run_ocean_this_round,
		"phys_solve_done": _phys_solve_done,
		"visual_round_active": _visual_round_active,
		"visual_round_id": _visual_round_id,
		"visual_next_pixel_idx": _visual_next_pixel_idx,
		"visual_total_pixels": _visual_total_pixels,
	}


func _native_ocean_physical_begin(ctx: SusTickContext) -> void:
	if data_core_world_ext == null:
		return
	var native_ctx: Dictionary = _native_ocean_base_ctx(ctx)
	native_ctx["stage"] = _baker_phys_stage_id()
	native_ctx["stage_name"] = _phys_stage_name(int(native_ctx.get("stage", 0)))
	_native_ocean_state = data_core_world_ext.native_ocean_physical_begin(native_ctx)


func _native_ocean_physical_step(ctx: SusTickContext, report: Dictionary) -> void:
	if data_core_world_ext == null:
		return
	var native_ctx: Dictionary = _native_ocean_base_ctx(ctx)
	for key in report.keys():
		native_ctx[key] = report[key]
	_native_ocean_state = data_core_world_ext.native_ocean_physical_step(native_ctx)


func _native_ocean_physical_finish(ctx: SusTickContext, report: Dictionary) -> void:
	if data_core_world_ext == null:
		return
	var native_ctx: Dictionary = _native_ocean_base_ctx(ctx)
	for key in report.keys():
		native_ctx[key] = report[key]
	_native_ocean_state = data_core_world_ext.native_ocean_physical_finish(native_ctx)


func _ticks_per_slice_diag() -> int:
	return OceanDiagnostics._ticks_per_slice_diag(self)


func _record_phys_diag(ctx: SusTickContext, report: Dictionary, done: bool) -> Dictionary:
	return OceanDiagnostics._record_phys_diag(self, ctx, report, done)


func last_physical_diag() -> Dictionary:
	return OceanDiagnostics.last_physical_diag(self)


func ocean_physical_state_snapshot() -> Dictionary:
	return OceanDiagnostics.ocean_physical_state_snapshot(self)


func _log_should_skip(ctx: SusTickContext, reason: String, detail: String = "") -> void:
	OceanDiagnostics._log_should_skip(self, ctx, reason, detail)


func _log_pixel_slice(ctx: SusTickContext, stage_name: String, s: int, e: int,
		elapsed_ms: float, progress: float, used_cpp_raster: bool,
		raster_wall_ms: float, raster_native_ms: float) -> void:
	OceanDiagnostics._log_pixel_slice(self, ctx, stage_name, s, e, elapsed_ms, progress, used_cpp_raster, raster_wall_ms, raster_native_ms)


func _ocean_rt_log_budget() -> int:
	return OceanDiagnostics._ocean_rt_log_budget(self)


func should_run(ctx: SusTickContext) -> bool:
	# Guard against missing dependencies (e.g. before bake_world finishes).
	if baker == null or world == null or map == null or cfg == null:
		_log_should_skip(ctx, "missing_refs")
		return false
	var daily_due: bool = _daily_wind_due(ctx)
	var slow_due: bool = _slow_slice_policy_allows(ctx)
	# Commit Defer：raster 已完成、commit 待跑 → 绕过 climate-defer 让位
	# （commit 极轻 ~1.5ms 且必须尽快上传纹理，否则 shader 看的是旧 buffer）。
	if _visual_pending_commit:
		return true
	if _visual_round_active and not _phys_round_active:
		return true
	# 不要在 should_run 里按 phase_int 拦截整轮 ocean_currents。
	# phase_int 只用于 run_slice 起点判断本轮是否需要刷新像素 atlas；物理化路径下
	# wind / ocean_current / upwelling 仍必须按 ContinuousSlicedPolicy 的节奏更新，
	# 否则天气与 ocean heat transport 会在同一季内读到冻结的 per-cell 场。
	# Always defer to policy, even when a round is in flight: that keeps the
	# 'one slice every ticks_per_slice ticks' cadence intact (e.g. 1 slice
	# every 3 days). Drift of mid-round phase is bounded by the locked
	# _phase_locked, so spreading slices across the full period_ticks window
	# is exactly the desired behavior.
	if not slow_due and not daily_due:
		_log_should_skip(ctx, "physical_policy_gated", "tick_mod=%d" % (ctx.tick_index % max(1, _ticks_per_slice_diag())))
		return false
	# Climate-defer mutates a streak counter, so keep it in run_slice().
	# should_run() stays a pure eligibility check for the GDScript fallback path.
	return true


func _should_defer_after_climate_slice() -> bool:
	if not climate_ran_this_tick_getter.is_valid() or not climate_slice_ms_getter.is_valid():
		return false
	if not bool(climate_ran_this_tick_getter.call()):
		return false
	var climate_ms: float = float(climate_slice_ms_getter.call())
	_last_defer_climate_ms = climate_ms
	if climate_ms < _DEFER_AFTER_CLIMATE_SLICE_MS:
		return false
	if _climate_defer_streak >= _MAX_CLIMATE_DEFER_STREAK:
		return false
	_climate_defer_streak += 1
	return true


func _current_phase(ctx: SusTickContext) -> float:
	if season_phase_getter.is_valid():
		return float(season_phase_getter.call())
	return ctx.season_phase


func _daily_wind_due(ctx: SusTickContext) -> bool:
	if ctx.tick_index == _last_daily_wind_tick:
		return false
	if wind_period_ticks <= 1:
		return true
	return (ctx.tick_index % max(1, wind_period_ticks)) == 0


func _slow_slice_policy_allows(ctx: SusTickContext) -> bool:
	if _slow_slice_policy == null:
		return true
	return bool(_slow_slice_policy.should_run(self, ctx))


func _daily_wind_split_active() -> bool:
	# plan/daily-wind-stage-split：profile flag daily_wind_split_passes 控制是否把
	# 每日 SLP/wind 错峰到相邻游戏日。缺失/false → 保留合并路径（每日两段一起跑）。
	if cfg == null or cfg.climate_profile == null:
		return false
	var cp = cfg.climate_profile
	if "daily_wind_split_passes" in cp:
		return bool(cp.daily_wind_split_passes)
	return false


# 弱机/移动端物理解周期缩放（item ④）。
# 把 ocean_currents / wind 物理解的周期拉长（每 2–3 日而非每日），降低单帧物理尖峰
# 出现的频率。注意：
#   - wind/ocean_current/upwelling 仍由 ContinuousSlicedPolicy 节奏更新，不会整体冻结；
#     weather 与 ocean heat transport 仍按节奏读到新鲜 per-cell 场（注释见 should_run）。
#   - 每日风预解继续走 daily_wind_split_passes 错峰 SLP/wind，而非停更。
#   - 仅改变"多久跑一轮"，不改变单阶段工作量（单片 magnitude 由 per-cell 切片负责，
#     那是需要持久化中间状态的 native 重构，需重建 GDExtension + PROBE/A-B，本改动不动）。
# 触发：移动端默认 ×2；或 ClimateProfile.ocean_period_scale_weak > 1 时按该值缩放
# （弱 PC 可在 profile 设 2.0~3.0）。字段缺失视为 1.0（桌面不动）。
func _apply_device_period_scale() -> void:
	var scale: float = 1.0
	if OS.has_feature("mobile"):
		scale = 2.0
	if cfg != null and cfg.climate_profile != null \
			and cfg.climate_profile.get("ocean_period_scale_weak") != null:
		scale = max(1.0, float(cfg.climate_profile.ocean_period_scale_weak))
	if scale <= 1.0:
		return
	wind_period_ticks = max(1, int(round(float(wind_period_ticks) * scale)))
	ocean_period_ticks = max(1, int(round(float(ocean_period_ticks) * scale)))
	period_ticks = ocean_period_ticks
	_slow_slice_policy = SusPolicyScript.ContinuousSlicedPolicy.new(ocean_period_ticks, slice_count)


func _daily_wind_stage_for(ctx: SusTickContext) -> String:
	# 首次 prepass（或 reset 后）跑 "both"，保证 SLP+wind 都有一套新场作基线，
	# 之后按实际 due occurrence 错峰：一次只跑 SLP，下一次只跑 wind。
	if not _daily_wind_split_active():
		return "both"
	if _last_daily_wind_tick == _NO_DAILY_WIND_TICK:
		return "both"
	# 按"已实际执行的 due 次数"交替，而非 day_index 奇偶：wind_period_ticks>1 时
	# due 的 tick 会被钉在固定奇偶日，用 day_index 会让某一段永不刷新→风/SLP 冻结。
	return "slp" if (_daily_wind_due_seq % 2) == 0 else "wind"


func _run_daily_wind_prepass(ctx: SusTickContext) -> Dictionary:
	return OceanPhysicalRound._run_daily_wind_prepass(self, ctx)


func _should_run_ocean_this_round(ctx: SusTickContext) -> bool:
	return OceanPhysicalRound._should_run_ocean_this_round(self, ctx)


func _begin_physical_round(ctx: SusTickContext, daily_report: Dictionary) -> Dictionary:
	return OceanPhysicalRound._begin_physical_round(self, ctx, daily_report)


func _daily_wind_report_has_wind(daily_report: Dictionary) -> bool:
	return OceanPhysicalRound._daily_wind_report_has_wind(self, daily_report)


func _try_prime_physical_wind_from_daily(daily_report: Dictionary, phys_stage_before: int) -> Dictionary:
	return OceanPhysicalRound._try_prime_physical_wind_from_daily(self, daily_report, phys_stage_before)


func _run_physical_slice(ctx: SusTickContext, t_start_us: int, daily_report: Dictionary = {}) -> Dictionary:
	return OceanPhysicalRound._run_physical_slice(self, ctx, t_start_us, daily_report)


func _run_visual_slice(ctx: SusTickContext, t_start_us: int) -> Dictionary:
	return OceanVisualRound._run_visual_slice(self, ctx, t_start_us)


func _discard_worker_visual_round() -> void:
	OceanVisualRound._discard_worker_visual_round(self)


func _worker_visual_report(ctx: SusTickContext, started: int, commit: Dictionary,
		visual_error: String = "") -> Dictionary:
	return OceanVisualRound._worker_visual_report(self, ctx, started, commit, visual_error)


func _run_worker_visual(ctx: SusTickContext, started: int, is_mobile: bool) -> Dictionary:
	return OceanVisualRound._run_worker_visual(self, ctx, started, is_mobile)


func run_slice(ctx: SusTickContext) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if baker == null or world == null or map == null:
		return _record_phys_diag(ctx, {
			"done": true,
			"work_done": 0,
			"elapsed_ms": 0.0,
			"stage_name": "ocean_missing_refs",
			"path": "missing_refs",
		}, true)

	var worker_report := _run_worker_visual(ctx, t_start_us, OS.has_feature("mobile"))
	if not worker_report.is_empty():
		return worker_report
	var slow_due: bool = _slow_slice_policy_allows(ctx)
	var daily_report: Dictionary = {}
	if _daily_wind_due(ctx):
		daily_report = _run_daily_wind_prepass(ctx)

	if not slow_due:
		if _visual_pending_commit or _visual_round_active:
			return _run_visual_slice(ctx, t_start_us)
		var elapsed_daily_only: float = float(Time.get_ticks_usec() - t_start_us) / 1000.0
		var daily_cells: int = int(map.soa_size()) if map != null and map.has_method("soa_size") else 0
		var daily_ran: bool = not daily_report.is_empty()
		# 调度日志归因：daily wind 是 SLP + wind 两段 C++ 权威，substage 直接报
		# 主导段（daily_wind_slp / daily_wind_wind），让 sus_window largest=ocean_currents/
		# daily_wind_prepass/<dominant> 一眼看出是哪一段吃预算。slp/wind 分段耗时也
		# 显式补进 slice report，供 _print_daily_breakdown / 调度日志直接消费（不依赖
		# _record_phys_diag 的 daily_wind_ 前缀合并）。
		var daily_dominant: String = str(daily_report.get("dominant_stage", "")) if daily_ran else ""
		var daily_substage: String = "slow_slice_not_due"
		if daily_ran:
			daily_substage = daily_dominant if daily_dominant != "" else "slp_wind"
		var daily_only_report: Dictionary = {
			"done": true,
			"work_done": daily_cells if daily_ran else 0,
			"processed_cells": daily_cells if daily_ran else 0,
			"elapsed_ms": elapsed_daily_only,
			"progress_ratio": 1.0,
			"stage_name": "daily_wind_prepass" if daily_ran else "ocean_policy_wait",
			"substage": daily_substage,
			"path": str(daily_report.get("path", "daily_wind")) if daily_ran else "policy_wait",
			"ocean_solve_enabled": false,
			"pixel_skipped": true,
			"daily_wind_ran": daily_ran,
			"daily_wind_slp_ms": float(daily_report.get("slp_ms", -1.0)) if daily_ran else -1.0,
			"daily_wind_wind_ms": float(daily_report.get("wind_ms", -1.0)) if daily_ran else -1.0,
			"daily_wind_dominant_stage": daily_dominant,
			"daily_wind_dominant_stage_ms": float(daily_report.get("dominant_stage_ms", 0.0)) if daily_ran else 0.0,
		}
		return _record_phys_diag(ctx, daily_only_report, true)

	if slow_due and not _phys_round_active:
		if _should_defer_after_climate_slice():
			if _visual_pending_commit or _visual_round_active:
				return _run_visual_slice(ctx, t_start_us)
			_log_should_skip(ctx, "climate_defer", "climate_ms=%.3f" % _last_defer_climate_ms)
			return _record_phys_diag(ctx, {
				"done": true,
				"work_done": 0,
				"elapsed_ms": (Time.get_ticks_usec() - t_start_us) / 1000.0,
				"progress_ratio": 1.0,
				"stage_name": "ocean_climate_defer",
				"path": "climate_defer",
				"defer_climate_ms": _last_defer_climate_ms,
			}, true)
		_climate_defer_streak = 0
		var begin_res: Dictionary = _begin_physical_round(ctx, daily_report)
		if not bool(begin_res.get("ok", false)):
			return _record_phys_diag(ctx, begin_res.get("report", {}), true)

	if _phys_round_active:
		_climate_defer_streak = 0
		return _run_physical_slice(ctx, t_start_us, daily_report)

	if _visual_pending_commit or _visual_round_active:
		return _run_visual_slice(ctx, t_start_us)

	var elapsed_wait_ms: float = float(Time.get_ticks_usec() - t_start_us) / 1000.0
	var wait_report: Dictionary = {
		"done": true,
		"work_done": 0,
		"processed_cells": 0,
		"elapsed_ms": elapsed_wait_ms,
		"progress_ratio": 1.0,
		"stage_name": "ocean_policy_wait",
		"substage": "idle",
		"path": "policy_wait",
		"ocean_solve_enabled": false,
		"pixel_skipped": true,
	}
	return _record_phys_diag(ctx, wait_report, true)


func _baker_phys_stage_id() -> int:
	if baker != null and "_phys_stage" in baker:
		return int(baker._phys_stage)
	return -1


func _phys_stage_name(stage: int) -> String:
	match stage:
		0: return "phys_none"
		1: return "phys_slp"
		2: return "phys_wind"
		3: return "phys_psi_init"
		4: return "phys_psi_iters"
		5: return "phys_psi_finalize"
		6: return "phys_upwelling"
		7: return "phys_wind_raster"
		8: return "phys_done"
		_: return "phys_unknown"


func _phys_stage_path(stage: int) -> String:
	match stage:
		1:
			return baker.get_slp_path_str() if baker != null and baker.has_method("get_slp_path_str") else "gdscript"
		2:
			return "gdext" if baker != null and "_phys_wind_done_by_cpp" in baker and bool(baker._phys_wind_done_by_cpp) else "gdscript"
		3:
			return baker.get_psi_path_str() if baker != null and baker.has_method("get_psi_path_str") else "gdscript"
		4, 5:
			return "gdscript"
		6:
			return "physical_circulation"
		7:
			return "wind_raster"
		_:
			return "phys_solve"


func _phys_stage_substage(stage: int, next_stage: int) -> String:
	if baker != null and stage == 4 and "_phys_psi_iters_done" in baker:
		return "iters_%d" % int(baker._phys_psi_iters_done)
	if baker != null and stage == 7 and "_phys_wind_raster_idx" in baker:
		return "pixel_%d" % int(baker._phys_wind_raster_idx)
	return "next_%s" % _phys_stage_name(next_stage)


func _current_phys_stage_report(stage_before: int, elapsed_ms: float) -> Dictionary:
	var next_stage: int = _baker_phys_stage_id()
	var just_done: int = stage_before
	if just_done <= 0:
		just_done = max(0, next_stage - 1)
	# `_physical_solve_step_one()` may short-circuit stage 7 by directly marking
	# `_PHYS_STAGE_DONE` when pixel buffers are disabled; that slice still did
	# upwelling work, not a synthetic DONE stage.
	if stage_before == 6 and next_stage == 8:
		just_done = 6
	# First SLP slice enters with stage_before=NONE and exits at WIND.
	if stage_before <= 0 and next_stage == 2:
		just_done = 1
	var report: Dictionary = {
		"stage": just_done,
		"stage_name": _phys_stage_name(just_done),
		"substage": _phys_stage_substage(just_done, next_stage),
		"path": _phys_stage_path(just_done),
		"next_stage": next_stage,
		"next_stage_name": _phys_stage_name(next_stage),
		"elapsed_ms": elapsed_ms,
		"stage_slp_path": baker.get_slp_path_str() if baker != null and baker.has_method("get_slp_path_str") else "gdscript",
		"stage_slp_native_ms": baker.get_slp_native_ms() if baker != null and baker.has_method("get_slp_native_ms") else -1.0,
		"stage_psi_path": baker.get_psi_path_str() if baker != null and baker.has_method("get_psi_path_str") else "gdscript",
		"stage_psi_native_ms": baker.get_psi_native_ms() if baker != null and baker.has_method("get_psi_native_ms") else -1.0,
		"psi_iters_run": baker.get_psi_iters_run() if baker != null and baker.has_method("get_psi_iters_run") else 0,
		"psi_residual_final": baker.get_psi_residual_final() if baker != null and baker.has_method("get_psi_residual_final") else 0.0,
		"psi_early_exit": baker.get_psi_early_exit() if baker != null and baker.has_method("get_psi_early_exit") else false,
		"psi_mode": baker.get_psi_mode() if baker != null and baker.has_method("get_psi_mode") else "off",
		"slp_thermal_p95": baker.get_slp_thermal_p95() if baker != null and baker.has_method("get_slp_thermal_p95") else 0.0,
		"slp_delta_p95": baker.get_slp_delta_p95() if baker != null and baker.has_method("get_slp_delta_p95") else 0.0,
		"wind_delta_p95": baker.get_wind_delta_p95() if baker != null and baker.has_method("get_wind_delta_p95") else 0.0,
		"ocean_delta_p95": baker.get_ocean_delta_p95() if baker != null and baker.has_method("get_ocean_delta_p95") else 0.0,
		"thermal_current_p95": baker.get_thermal_current_p95() if baker != null and baker.has_method("get_thermal_current_p95") else 0.0,
		"ocean_current_preclamp_p95": baker.get_ocean_current_preclamp_p95() if baker != null and baker.has_method("get_ocean_current_preclamp_p95") else 0.0,
		"ocean_current_preclamp_max": baker.get_ocean_current_preclamp_max() if baker != null and baker.has_method("get_ocean_current_preclamp_max") else 0.0,
		"ocean_current_clamp_count": baker.get_ocean_current_clamp_count() if baker != null and baker.has_method("get_ocean_current_clamp_count") else 0,
		"ocean_current_clamp_ratio": baker.get_ocean_current_clamp_ratio() if baker != null and baker.has_method("get_ocean_current_clamp_ratio") else 0.0,
		"ocean_current_max_magnitude": baker.get_ocean_current_max_magnitude() if baker != null and baker.has_method("get_ocean_current_max_magnitude") else 0.0,
	}
	return report


## Allow MapGenerator to retune the policy on the fly (e.g. after climate
## profile reload). Re-creates the underlying ContinuousSlicedPolicy.
func reconfigure(p_period_ticks: int, p_slice_count: int, p_ocean_period_ticks: int = -1) -> void:
	wind_period_ticks = max(1, p_period_ticks)
	ocean_period_ticks = max(1, p_ocean_period_ticks if p_ocean_period_ticks > 0 else p_period_ticks)
	period_ticks = ocean_period_ticks
	slice_count = max(1, p_slice_count)
	_slow_slice_policy = SusPolicyScript.ContinuousSlicedPolicy.new(ocean_period_ticks, slice_count)
	# 弱机/移动端：拉长物理解周期（见 _apply_device_period_scale）。
	_apply_device_period_scale()
	policy = SusPolicyScript.AlwaysPolicy.new()
	# A round mid-flight stays as-is — only future rounds use the new pace.
