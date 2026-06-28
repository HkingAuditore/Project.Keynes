extends "res://scripts/simulation/sus/sus_job.gd"
class_name OceanCurrentsJob

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
#   重 bake 一次。_phase_int_seen = -9999 视作"从未跑过"，第一次 round 强制 rebake。
#   _need_pixel_this_round 在 round 起点决定：true → 走完整 raster + commit；
#   false → 求解完成立即 round_done，跳过 stage 7 (WIND_RASTER) 与 pixel slices。
var _phase_int_seen: int = -9999
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
	_next_pixel_idx = 0
	_total_pixels = 0
	_round_active = false
	_phys_solve_done = false
	_pending_commit = false
	_phys_round_active = false
	_phys_phase_locked = 0.0
	_phys_need_visual = false
	_phys_run_ocean_this_round = true
	_physical_round_id = 0
	_last_physical_complete_tick = _NO_DAILY_WIND_TICK
	_visual_round_active = false
	_visual_phase_locked = 0.0
	_visual_next_pixel_idx = 0
	_visual_total_pixels = 0
	_visual_pending_commit = false
	_visual_round_id = 0
	_visual_enqueued_tick = _NO_DAILY_WIND_TICK
	# 重置事件驱动门 — 下一次 round 会因 _phase_int_seen=-9999 而强制 rebake，
	# 保证场景重载/换地图后第一帧像素 buffer 正确。
	_phase_int_seen = -9999
	_need_pixel_this_round = false
	_run_ocean_this_round = true
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
	_sync_legacy_round_state()
	if _native_ocean_facade_available("reset_native_ocean_physical_state"):
		_native_ocean_state = data_core_world_ext.reset_native_ocean_physical_state("ocean_job_reset")
	if baker != null and baker.has_method("discard_ocean_buffers"):
		baker.discard_ocean_buffers()


func _native_ocean_facade_available(method_name: String) -> bool:
	return data_core_world_ext != null and data_core_world_ext.has_method(method_name)


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
	if not _native_ocean_facade_available("native_ocean_physical_begin"):
		return
	var native_ctx: Dictionary = _native_ocean_base_ctx(ctx)
	native_ctx["stage"] = _baker_phys_stage_id()
	native_ctx["stage_name"] = _phys_stage_name(int(native_ctx.get("stage", 0)))
	_native_ocean_state = data_core_world_ext.native_ocean_physical_begin(native_ctx)


func _native_ocean_physical_step(ctx: SusTickContext, report: Dictionary) -> void:
	if not _native_ocean_facade_available("native_ocean_physical_step"):
		return
	var native_ctx: Dictionary = _native_ocean_base_ctx(ctx)
	for key in report.keys():
		native_ctx[key] = report[key]
	_native_ocean_state = data_core_world_ext.native_ocean_physical_step(native_ctx)


func _native_ocean_physical_finish(ctx: SusTickContext, report: Dictionary) -> void:
	if not _native_ocean_facade_available("native_ocean_physical_finish"):
		return
	var native_ctx: Dictionary = _native_ocean_base_ctx(ctx)
	for key in report.keys():
		native_ctx[key] = report[key]
	_native_ocean_state = data_core_world_ext.native_ocean_physical_finish(native_ctx)


func _ticks_per_slice_diag() -> int:
	if _slow_slice_policy != null and _slow_slice_policy.has_method("ticks_per_slice"):
		return int(_slow_slice_policy.ticks_per_slice())
	if policy != null and policy.has_method("ticks_per_slice"):
		return int(policy.ticks_per_slice())
	return 0


func _record_phys_diag(ctx: SusTickContext, report: Dictionary, done: bool) -> Dictionary:
	_sync_legacy_round_state()
	var out: Dictionary = report.duplicate(true)
	out["tick_idx"] = ctx.tick_index
	out["day_index"] = ctx.day_index
	out["daily_wind_due"] = _last_daily_wind_tick == ctx.tick_index
	out["phase_locked"] = _phase_locked
	out["round_active"] = _round_active
	out["phys_solve_done"] = _phys_solve_done
	out["need_pixel"] = _need_pixel_this_round
	out["run_ocean"] = _run_ocean_this_round
	out["phase_int_seen"] = _phase_int_seen
	out["pending_commit"] = _pending_commit
	out["next_pixel_idx"] = _next_pixel_idx
	out["total_pixels"] = _total_pixels
	out["phys_round_active"] = _phys_round_active
	out["visual_round_active"] = _visual_round_active
	out["physical_round_id"] = _physical_round_id
	out["visual_round_id"] = _visual_round_id
	out["phys_phase_locked"] = _phys_phase_locked
	out["visual_phase_locked"] = _visual_phase_locked
	out["visual_pending_commit"] = _visual_pending_commit
	out["visual_next_pixel_idx"] = _visual_next_pixel_idx
	out["visual_total_pixels"] = _visual_total_pixels
	out["visual_pixel_progress"] = float(_visual_next_pixel_idx) / float(max(1, _visual_total_pixels)) if _visual_round_active else 1.0
	out["visual_lag_ticks"] = _visual_lag_ticks(ctx)
	out["current_pixel_quota"] = _current_pixel_quota_diag
	out["wind_period_ticks"] = wind_period_ticks
	out["ocean_period_ticks"] = ocean_period_ticks
	out["slow_period_ticks"] = ocean_period_ticks
	out["slice_count"] = slice_count
	out["ticks_per_slice"] = _ticks_per_slice_diag()
	for daily_key in _last_daily_wind_report.keys():
		out["daily_wind_" + str(daily_key)] = _last_daily_wind_report[daily_key]
	out["done"] = done
	_native_ocean_physical_step(ctx, out)
	if not _native_ocean_state.is_empty():
		out["native_ocean_state"] = _native_ocean_state.duplicate(true)
	_last_phys_diag = out.duplicate(true)
	return out


func last_physical_diag() -> Dictionary:
	return _last_phys_diag.duplicate(true)


func ocean_physical_state_snapshot() -> Dictionary:
	_sync_legacy_round_state()
	if _native_ocean_facade_available("get_native_ocean_physical_state_report"):
		_native_ocean_state = data_core_world_ext.get_native_ocean_physical_state_report()
	var native_path_ready: bool = str(_last_phys_diag.get("path", "")).begins_with("gdext") \
			or str(_last_daily_wind_report.get("path", "")).begins_with("gdext")
	var active_owner_requested: bool = false
	var cp = cfg.climate_profile if cfg != null else null
	if cp != null and cp.get("native_ocean_physical_active_owner_enabled") != null:
		active_owner_requested = bool(cp.native_ocean_physical_active_owner_enabled)
	var native_lifecycle_ready: bool = not _native_ocean_state.is_empty()
	var owner: String = "gdscript_retained"
	if native_lifecycle_ready and active_owner_requested:
		owner = "native_active"
	elif native_lifecycle_ready:
		owner = "native_ready"
	elif native_path_ready:
		owner = "native_ready_probe"
	var snapshot: Dictionary = {
		"owner": owner,
		"native_state_status": "native_lifecycle_facade" if native_lifecycle_ready else "probe_mirror_only",
		"active_owner_requested": active_owner_requested,
		"simulation_authority": native_lifecycle_ready and active_owner_requested,
		"physical_round_active": _phys_round_active,
		"physical_round_id": _physical_round_id,
		"physical_phase_locked": _phys_phase_locked,
		"physical_need_visual": _phys_need_visual,
		"physical_run_ocean": _phys_run_ocean_this_round,
		"phys_solve_done": _phys_solve_done,
		"last_physical_complete_tick": _last_physical_complete_tick,
		"visual_round_active": _visual_round_active,
		"visual_round_id": _visual_round_id,
		"visual_phase_locked": _visual_phase_locked,
		"visual_next_pixel_idx": _visual_next_pixel_idx,
		"visual_total_pixels": _visual_total_pixels,
		"visual_pending_commit": _visual_pending_commit,
		"phase_int_seen": _phase_int_seen,
		"wind_period_ticks": wind_period_ticks,
		"ocean_period_ticks": ocean_period_ticks,
		"slice_count": slice_count,
		"last_phys_diag": _last_phys_diag.duplicate(true),
		"last_daily_wind_report": _last_daily_wind_report.duplicate(true),
		"remaining_gdscript_authority": [
			"visual_raster_boundary_execution",
			"texture_commit_boundary_execution",
		],
		"native_owned_output_slots": [
			"cell_wind_x",
			"cell_wind_y",
			"cell_ocean_current_x",
			"cell_ocean_current_y",
			"cell_upwelling",
		],
	}
	if not _native_ocean_state.is_empty():
		snapshot["native_lifecycle_state"] = _native_ocean_state.duplicate(true)
		snapshot["native_owned_lifecycle_authority"] = _native_ocean_state.get("native_owned_lifecycle_authority", [
			"physical_round_active",
			"physical_round_id",
			"phase_locked",
			"physical_stage",
			"physical_stage_cursor",
		])
	return snapshot


func _log_should_skip(ctx: SusTickContext, reason: String, detail: String = "") -> void:
	if _ocean_policy_diag_count >= 32:
		return
	if not PKLog.enabled:
		return
	_ocean_policy_diag_count += 1
	var suffix: String = ""
	if detail != "":
		suffix = " " + detail
	print("[ocean_currents][RT] skip#%d tick=%d reason=%s phys_round=%s visual_round=%s phys_done=%s pending_commit=%s cursor=%d/%d tps=%d streak=%d%s" % [
		_ocean_policy_diag_count, ctx.tick_index, reason, str(_phys_round_active), str(_visual_round_active),
		str(_phys_solve_done), str(_visual_pending_commit), _visual_next_pixel_idx, _visual_total_pixels,
		_ticks_per_slice_diag(), _climate_defer_streak, suffix,
	])


func _log_pixel_slice(ctx: SusTickContext, stage_name: String, s: int, e: int,
		elapsed_ms: float, progress: float, used_cpp_raster: bool,
		raster_wall_ms: float, raster_native_ms: float) -> void:
	if _ocean_pixel_rt_diag_count >= 64:
		return
	if not PKLog.enabled:
		return
	var should_log: bool = _ocean_pixel_rt_diag_count < 16 \
			or stage_name == "ocean_pixel_raster_done" \
			or stage_name == "ocean_pixel_commit_deferred" \
			or (ctx.tick_index % 60) == 0
	if not should_log:
		return
	_ocean_pixel_rt_diag_count += 1
	print("[ocean_currents][RT] pixel#%d tick=%d stage=%s cursor=%d..%d/%d progress=%.3f elapsed=%.3f pps=%d quota_last=%d path=%s raster_wall=%.3f raster_native=%.3f pending_commit=%s" % [
		_ocean_pixel_rt_diag_count, ctx.tick_index, stage_name,
		s, e, _visual_total_pixels, progress, elapsed_ms,
		max(0, e - s), _last_pixel_quota,
		"gdext_raster" if used_cpp_raster else "gdscript_slice",
		raster_wall_ms, raster_native_ms, str(_visual_pending_commit),
	])


# Fix #11 second pass (2026-06-16) mobile：[ocean_currents][RT] / [daily_wind] 24 行
# 上限对 mobile 仍然太多（logcat ~10ms/行 → 240ms 的 startup overhead）。
# mobile 收紧到 6 行（前几个 round 看完算）。desktop 保留 24 方便开发期排查。
func _ocean_rt_log_budget() -> int:
	return 6 if OS.has_feature("mobile") else 24


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


func _daily_wind_stage_for(ctx: SusTickContext) -> String:
	# 首次 prepass（或 reset 后）跑 "both"，保证 SLP+wind 都有一套新场作基线，
	# 之后按游戏日 parity 错峰：偶数日只跑 SLP、奇数日只跑 wind。
	if not _daily_wind_split_active():
		return "both"
	if _last_daily_wind_tick == _NO_DAILY_WIND_TICK:
		return "both"
	return "slp" if (ctx.day_index % 2) == 0 else "wind"


func _run_daily_wind_prepass(ctx: SusTickContext) -> Dictionary:
	if ctx.tick_index == _last_daily_wind_tick:
		return _last_daily_wind_report.duplicate(true)
	var phase_now: float = _current_phase(ctx)
	var stage: String = _daily_wind_stage_for(ctx)
	var report: Dictionary = {
		"ran": false,
		"path": "daily_wind_skip",
		"elapsed_ms": 0.0,
		"fallback_reason": "",
	}
	if baker == null or world == null or map == null or cfg == null:
		report["fallback_reason"] = "missing_refs"
	elif not baker._use_physical_circulation(cfg):
		report["path"] = "daily_wind_disabled"
		report["fallback_reason"] = "physical_disabled"
	elif not baker.has_method("run_daily_wind_field_update"):
		report["fallback_reason"] = "missing_baker_method"
	else:
		report = baker.run_daily_wind_field_update(
				map, world, cfg, hex_size, phase_now, ctx.day_index, stage)
		if typeof(report) != TYPE_DICTIONARY:
			report = {
				"ran": false,
				"path": "daily_wind_bad_report",
				"elapsed_ms": 0.0,
				"fallback_reason": "non_dict_report",
			}
	report["tick_idx"] = ctx.tick_index
	report["day_index"] = ctx.day_index
	report["season_phase"] = phase_now
	report["due"] = true
	report["stage_requested"] = stage
	_last_daily_wind_tick = ctx.tick_index
	_last_daily_wind_report = report.duplicate(true)
	if PKLog.enabled and _daily_wind_rt_diag_count < _ocean_rt_log_budget():
		_daily_wind_rt_diag_count += 1
		print("[ocean_currents][daily_wind] #%d tick=%d stage=%s ran=%s path=%s elapsed=%.3f slp=%.3f wind=%.3f passA=%.3f passB=%.3f norm=%.3f marshall=%.3f dominant=%s/%.3f delta=%.6f reason=%s" % [
			_daily_wind_rt_diag_count,
			ctx.tick_index,
			stage,
			str(report.get("ran", false)),
			str(report.get("path", "")),
			float(report.get("elapsed_ms", 0.0)),
			float(report.get("slp_ms", -1.0)),
			float(report.get("wind_ms", -1.0)),
			float(report.get("slp_passA_ms", -1.0)),
			float(report.get("slp_passB_ms", -1.0)),
			float(report.get("slp_norm_ms", -1.0)),
			float(report.get("slp_marshall_ms", -1.0)),
			str(report.get("dominant_stage", "")),
			float(report.get("dominant_stage_ms", 0.0)),
			float(report.get("wind_delta_p95", 0.0)),
			str(report.get("fallback_reason", "")),
		])
	return report


func _should_run_ocean_this_round(ctx: SusTickContext) -> bool:
	if baker == null or not baker._use_physical_circulation(cfg):
		return true
	if _phase_int_seen == -9999:
		return true
	return (ctx.tick_index % max(1, ocean_period_ticks)) == 0


func _begin_physical_round(ctx: SusTickContext, daily_report: Dictionary) -> Dictionary:
	_visual_total_pixels = _total_pixels_for(world)
	if _visual_total_pixels <= 0:
		return {
			"ok": false,
			"report": {
				"done": true,
				"work_done": 0,
				"elapsed_ms": 0.0,
				"stage_name": "ocean_no_pixels",
				"path": "no_pixels",
			},
		}
	_phys_phase_locked = _current_phase(ctx)
	_phase_locked = _phys_phase_locked
	_phys_round_active = true
	_phys_solve_done = not baker._use_physical_circulation(cfg)
	_phys_run_ocean_this_round = _should_run_ocean_this_round(ctx)
	_physical_round_id += 1
	if not _phys_solve_done:
		var primed_from_daily_wind: bool = false
		if not daily_report.is_empty() and bool(daily_report.get("ran", false)) \
				and baker.has_method("prime_physical_solve_from_current_wind"):
			primed_from_daily_wind = baker.prime_physical_solve_from_current_wind(map, _phys_phase_locked)
		if not primed_from_daily_wind and baker.has_method("reset_physical_solve_state"):
			baker.reset_physical_solve_state()
	var phase_int: int = int(floor(_phys_phase_locked))
	if baker._use_physical_circulation(cfg):
		_phys_need_visual = _phys_run_ocean_this_round \
				and (_phase_int_seen == -9999 or phase_int != _phase_int_seen)
		if _phys_run_ocean_this_round:
			_phase_int_seen = phase_int
	else:
		_phys_need_visual = true
		_phase_int_seen = phase_int
	# Mobile 60 FPS（Fix #1, 2026-06-15）：每次 phase_int 跨整数都 rebake ocean
	# 像素 atlas 是 frame=2412 起 non_sus_frame_avg 8→22ms 的直接原因
	#   （atlas 一旦可见，hex_terrain shader 多采样 dyn/eco/smo/ice 4 张 RGBA8
	#   512×304，移动端 fragment bandwidth 翻 3 倍）。
	# 移动端策略：只允许首次 bake 一次（让 shader 拿到非全黑的 ocean overlay
	#   纹理避免 NaN），后续物理 solve 继续运行（authority 保留在 cell_ocean_*）
	#   但视觉层不再 rebake → primitives 7096 → 1644，non_sus 22ms → 8ms。
	# 桌面端不动。
	if _phys_need_visual and OS.has_feature("mobile") and _phase_int_seen != -9999 \
			and _visual_round_id > 0:
		_phys_need_visual = false
	# [ocean-visual-skip 2026-06-16] ocean_current_visual 开关关 → 永不做逐像素视觉
	# 光栅 / commit（vector_atlas 是纯视觉 overlay）。need_visual=false 时本 round 求解
	# 完成即 round_done（见下方 stage 推进），跳过 stage 7 WIND_RASTER + pixel slices +
	# commit_ocean_buffers。per-cell SLP/风/洋流 solve（上方 stages + daily_wind prepass）
	# 照常跑并写 HexCell，气候/天气仿真完全不受影响。
	if _phys_need_visual and not DCFeatureFlags.ocean_current_visual_active():
		_phys_need_visual = false
	_sync_legacy_round_state()
	if PKLog.enabled and _ocean_rt_diag_count < _ocean_rt_log_budget():
		var tps: int = 0
		if _slow_slice_policy != null and _slow_slice_policy.has_method("ticks_per_slice"):
			tps = int(_slow_slice_policy.ticks_per_slice())
		print("[ocean_currents][RT] phys_round_start#%d tick=%d phase=%.4f physical=%s wind_period=%d ocean_period=%d slice_count=%d tps=%d max_slices=%d run_ocean=%s need_visual=%s phase_int=%d phase_seen=%d total_pixels=%d visual_active=%s" % [
			_physical_round_id, ctx.tick_index, _phys_phase_locked,
			str(baker._use_physical_circulation(cfg)), wind_period_ticks, ocean_period_ticks,
			slice_count, tps, max_slices_per_tick, str(_phys_run_ocean_this_round),
			str(_phys_need_visual), phase_int, _phase_int_seen, _visual_total_pixels,
			str(_visual_round_active),
		])
	_native_ocean_physical_begin(ctx)
	return {"ok": true}


func _run_physical_slice(ctx: SusTickContext, t_start_us: int) -> Dictionary:
	if not _phys_round_active:
		return {}
	if not _phys_solve_done:
		var phys_stage_before: int = _baker_phys_stage_id()
		_phys_solve_done = baker._physical_solve_step_one(
				map, world, hex_size, cfg, _phys_phase_locked, _phys_run_ocean_this_round)
		if not _phys_solve_done and not _phys_need_visual \
				and baker.has_method("_use_physical_circulation") \
				and "_phys_stage" in baker \
				and "_PHYS_STAGE_WIND_RASTER" in baker \
				and "_PHYS_STAGE_DONE" in baker \
				and int(baker._phys_stage) == int(baker._PHYS_STAGE_WIND_RASTER):
			baker._phys_stage = baker._PHYS_STAGE_DONE
			if "_pending_phys_solved_phase" in baker:
				baker._pending_phys_solved_phase = _phys_phase_locked
			_phys_solve_done = true
		var elapsed_solve_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
		var phys_report: Dictionary = _current_phys_stage_report(phys_stage_before, elapsed_solve_ms)
		# Fix #11 (2026-06-15) stage-level diag：前 3 次每 stage 必打，之后只在 >= 5ms 时打。
		# stage_id 取自 phys_report.stage（_phys_stage_name 已映射好）。每个 stage 独立 budget，
		# 不与 _ocean_rt_diag_count 24 上限互相吃。配合 mobile 60FPS bench 用：哪个 stage 在
		# 8 tick 桶里出现峰值，下一次 bench log 会清楚标出来。
		var _stage_id_for_diag: int = int(phys_report.get("stage", -1))
		if _stage_id_for_diag > 0:
			var _stage_diag_seen: int = int(_phys_stage_diag_count.get(_stage_id_for_diag, 0))
			var _should_stage_diag: bool = (_stage_diag_seen < _PHYS_STAGE_DIAG_INITIAL_PRINTS) \
					or (elapsed_solve_ms >= _PHYS_STAGE_DIAG_WARN_MS)
			if _should_stage_diag and PKLog.enabled:
				_phys_stage_diag_count[_stage_id_for_diag] = _stage_diag_seen + 1
				var _stage_kind: String = "warn" if elapsed_solve_ms >= _PHYS_STAGE_DIAG_WARN_MS else "init"
				print("[ocean_currents/STAGE-DIAG] %s tick=%d round=%d stage=%d/%s path=%s next=%s elapsed_ms=%.2f slp_native=%.2f psi_native=%.2f wind_dp95=%.6f ocean_dp95=%.6f slp_dp95=%.6f phys_done=%s need_visual=%s" % [
					_stage_kind, ctx.tick_index, _physical_round_id,
					_stage_id_for_diag, str(phys_report.get("stage_name", "?")),
					str(phys_report.get("path", "?")), str(phys_report.get("next_stage_name", "?")),
					elapsed_solve_ms,
					float(phys_report.get("stage_slp_native_ms", -1.0)),
					float(phys_report.get("stage_psi_native_ms", -1.0)),
					float(phys_report.get("wind_delta_p95", 0.0)),
					float(phys_report.get("ocean_delta_p95", 0.0)),
					float(phys_report.get("slp_delta_p95", 0.0)),
					str(_phys_solve_done), str(_phys_need_visual),
				])
		if PKLog.enabled and _ocean_rt_diag_count < _ocean_rt_log_budget():
			_ocean_rt_diag_count += 1
			print("[ocean_currents][RT] phys_slice#%d tick=%d round=%d stage=%s->%s done=%s run_ocean=%s need_visual=%s elapsed=%.3f ocean_delta_p95=%.6f wind_delta_p95=%.6f slp_delta_p95=%.6f psi_path=%s" % [
				_ocean_rt_diag_count, ctx.tick_index, _physical_round_id,
				str(phys_report.get("stage_name", "?")), str(phys_report.get("next_stage_name", "?")),
				str(_phys_solve_done), str(_phys_run_ocean_this_round), str(_phys_need_visual),
				elapsed_solve_ms, float(phys_report.get("ocean_delta_p95", 0.0)),
				float(phys_report.get("wind_delta_p95", 0.0)), float(phys_report.get("slp_delta_p95", 0.0)),
				str(phys_report.get("stage_psi_path", "?")),
			])
		if elapsed_solve_ms > 8.0:
			print("  [ocean_currents] slow phys slice=%.1fms (just-finished stage=%d/%s, next=%d/%s, path=%s, round_done=%s)" % [
				elapsed_solve_ms,
				int(phys_report.get("stage", -1)),
				str(phys_report.get("stage_name", "?")),
				int(phys_report.get("next_stage", -1)),
				str(phys_report.get("next_stage_name", "?")),
				str(phys_report.get("path", "")),
				str(_phys_solve_done),
			])
		if not _phys_solve_done:
			phys_report["done"] = false
			phys_report["work_done"] = 0
			phys_report["elapsed_ms"] = elapsed_solve_ms
			phys_report["progress_ratio"] = 0.0
			phys_report["ocean_solve_enabled"] = _phys_run_ocean_this_round
			return _record_phys_diag(ctx, phys_report, false)
		phys_report["done"] = true
		phys_report["work_done"] = 0
		phys_report["elapsed_ms"] = elapsed_solve_ms
		phys_report["progress_ratio"] = 1.0
		phys_report["ocean_solve_enabled"] = _phys_run_ocean_this_round
		phys_report["physical_round_complete"] = true
		if _phys_need_visual:
			_enqueue_visual_round(ctx, _phys_phase_locked)
			phys_report["visual_enqueued"] = _visual_round_active
		else:
			phys_report["pixel_skipped"] = true
			if on_commit.is_valid():
				on_commit.call()
		_finish_physical_round(ctx)
		return _record_phys_diag(ctx, phys_report, true)

	if _phys_need_visual:
		_enqueue_visual_round(ctx, _phys_phase_locked)
		var queued_report: Dictionary = {
			"done": true,
			"work_done": 0,
			"elapsed_ms": (Time.get_ticks_usec() - t_start_us) / 1000.0,
			"progress_ratio": 1.0,
			"stage_name": "ocean_visual_enqueued",
			"substage": "physical_complete",
			"path": "scheduler",
			"visual_enqueued": true,
			"physical_round_complete": true,
		}
		_finish_physical_round(ctx)
		return _record_phys_diag(ctx, queued_report, true)

	var skip_report: Dictionary = {
		"done": true,
		"work_done": 0,
		"elapsed_ms": (Time.get_ticks_usec() - t_start_us) / 1000.0,
		"progress_ratio": 1.0,
		"stage_name": "phys_done",
		"substage": "no_visual",
		"path": "physical_circulation",
		"pixel_skipped": true,
		"ocean_solve_enabled": _phys_run_ocean_this_round,
	}
	if on_commit.is_valid():
		on_commit.call()
	_finish_physical_round(ctx)
	return _record_phys_diag(ctx, skip_report, true)


func _run_visual_slice(ctx: SusTickContext, t_start_us: int) -> Dictionary:
	_sync_legacy_round_state()
	if _visual_pending_commit:
		var t_commit2_us: int = Time.get_ticks_usec()
		baker.commit_ocean_buffers(world, true)
		var commit_only_ms: float = (Time.get_ticks_usec() - t_commit2_us) / 1000.0
		if on_commit.is_valid():
			on_commit.call()
		var elapsed_commit_only: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
		var committed_round_id: int = _visual_round_id
		_visual_pending_commit = false
		_visual_round_active = false
		_visual_next_pixel_idx = 0
		_visual_total_pixels = 0
		_visual_enqueued_tick = _NO_DAILY_WIND_TICK
		_sync_legacy_round_state()
		_log_pixel_slice(ctx, "ocean_pixel_commit_deferred", 0, 0,
			elapsed_commit_only, 1.0, true, -1.0, -1.0)
		var commit_report: Dictionary = {
			"done": true,
			"work_done": 0,
			"elapsed_ms": elapsed_commit_only,
			"progress_ratio": 1.0,
			"stage_name": "ocean_pixel_commit_deferred",
			"substage": "commit_only",
			"path": "gpu_upload",
			"commit_wall_ms": commit_only_ms,
			"visual_round_id": committed_round_id,
		}
		return _record_phys_diag(ctx, commit_report, true)

	if not _visual_round_active:
		return {}

	var use_cpp_raster_plan: bool = baker._use_physical_circulation(cfg) \
			and cfg != null \
			and cfg.climate_profile != null \
			and baker.has_method("run_ocean_field_rasterize_full")
	var pps: int = _pixel_quota_for_next_slice(not use_cpp_raster_plan)
	_current_pixel_quota_diag = pps
	var s: int = _visual_next_pixel_idx
	var e: int = mini(_visual_total_pixels, s + pps)
	if s == 0:
		print("[ocean_currents] season_crossed -> rebaking pixel atlas at phase=%.3f (phase_int=%d, total_pixels=%d)" % [
			_visual_phase_locked, _phase_int_seen, _visual_total_pixels
		])

	var used_cpp_raster: bool = false
	var raster_native_ms: float = -1.0
	var raster_wall_ms: float = -1.0
	var raster_fallback_reason: String = "gdscript_slice"
	var raster_pixels: int = 0
	var raster_requested_start: int = -1
	var raster_requested_end: int = -1
	var raster_returned_start: int = -1
	var raster_returned_end: int = -1
	var raster_progress_guard_fired: bool = false
	var raster_atlas_updated: bool = false
	var cpp_sub_s: int = -1
	var cpp_sub_e: int = -1
	if use_cpp_raster_plan:
		var cp_oc: ClimateProfile = cfg.climate_profile if cfg != null else null
		if cp_oc != null and baker.has_method("run_ocean_field_rasterize_full"):
			var sub_count: int = 1
			if "ocean_pixel_subslice_count" in cp_oc:
				sub_count = max(1, int(cp_oc.ocean_pixel_subslice_count))
			var sub_pps: int = mini(int(ceil(float(_visual_total_pixels) / float(sub_count))), pps)
			var sub_s: int = _visual_next_pixel_idx
			var sub_e: int = mini(_visual_total_pixels, sub_s + sub_pps)
			raster_requested_start = sub_s
			raster_requested_end = sub_e
			var t_raster_us: int = Time.get_ticks_usec()
			var raster_res: Dictionary = baker.run_ocean_field_rasterize_full(map, world, cfg, sub_s, sub_e)
			raster_wall_ms = (Time.get_ticks_usec() - t_raster_us) / 1000.0
			raster_native_ms = float(raster_res.get("elapsed_ms", -1.0))
			raster_pixels = int(raster_res.get("pixels", 0))
			raster_atlas_updated = bool(raster_res.get("atlas_updated", false))
			if bool(raster_res.get("fallback", true)):
				raster_fallback_reason = str(raster_res.get("reason", "cpp_fallback"))
			if not bool(raster_res.get("fallback", true)):
				cpp_sub_s = int(raster_res.get("start_idx", sub_s))
				cpp_sub_e = int(raster_res.get("end_idx", sub_e))
				raster_returned_start = cpp_sub_s
				raster_returned_end = cpp_sub_e
				var returned_span: int = max(0, cpp_sub_e - cpp_sub_s)
				var returned_range_ok: bool = (cpp_sub_s == sub_s \
						and cpp_sub_e > sub_s \
						and cpp_sub_e <= _visual_total_pixels \
						and cpp_sub_e <= sub_e)
				var returned_pixels_ok: bool = (raster_pixels == returned_span)
				if returned_range_ok and returned_pixels_ok:
					used_cpp_raster = true
					_visual_next_pixel_idx = cpp_sub_e
					s = cpp_sub_s
					e = cpp_sub_e
					raster_fallback_reason = ""
				else:
					raster_progress_guard_fired = true
					raster_fallback_reason = "cpp_non_progress start=%d end=%d pixels=%d requested=%d..%d" % [
						cpp_sub_s, cpp_sub_e, raster_pixels, sub_s, sub_e,
					]
	if not used_cpp_raster:
		baker.bake_ocean_currents_slice(map, world, hex_size, cfg, _visual_phase_locked, s, e)
		baker.bake_ocean_upwelling_slice(map, world, hex_size, cfg, _visual_phase_locked, s, e)
		_visual_next_pixel_idx = e

	var done: bool = (_visual_next_pixel_idx >= _visual_total_pixels)
	var commit_wall_ms: float = -1.0
	if done:
		_visual_pending_commit = true
		done = false

	var elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
	if elapsed_ms > 25.0:
		var marker: String = "pixel_commit_pending" if _visual_pending_commit else "pixel"
		var rest_ms: float = elapsed_ms
		if raster_wall_ms >= 0.0:
			rest_ms -= raster_wall_ms
		if commit_wall_ms >= 0.0:
			rest_ms -= commit_wall_ms
		print("  [ocean_currents] slow visual slice=%.1fms (%s, pixels=%d-%d / %d) raster_wall=%.1f raster_native=%.1f commit_wall=%.1f rest=%.1f" % [
			elapsed_ms, marker, s, e, _visual_total_pixels,
			raster_wall_ms, raster_native_ms, commit_wall_ms, rest_ms
		])
	var progress: float = 0.0
	if _visual_total_pixels > 0:
		if done or _visual_pending_commit:
			progress = 1.0
		else:
			progress = float(_visual_next_pixel_idx) / float(_visual_total_pixels)
	var work_done_pixels: int = e - s
	if work_done_pixels > 0:
		_last_pixel_slice_ms = elapsed_ms
		_last_pixel_slice_pixels = work_done_pixels
		_last_pixel_quota = work_done_pixels
	var slice_stage_name: String = "ocean_pixel_slice"
	if _visual_pending_commit:
		slice_stage_name = "ocean_pixel_raster_done"
	elif done:
		slice_stage_name = "ocean_pixel_commit"
	_sync_legacy_round_state()
	_log_pixel_slice(ctx, slice_stage_name, s, e, elapsed_ms, progress,
		used_cpp_raster, raster_wall_ms, raster_native_ms)
	var pixel_report: Dictionary = {
		"done": done,
		"work_done": work_done_pixels,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": progress,
		"pixel_quota": pps,
		"stage_name": slice_stage_name,
		"substage": "pixels_%d_%d" % [s, e],
		"path": "gdext_raster" if used_cpp_raster else "gdscript_slice",
		"processed_pixels": work_done_pixels,
		"cursor_start": s,
		"cursor_end": e,
		"raster_requested_start": raster_requested_start,
		"raster_requested_end": raster_requested_end,
		"raster_returned_start": raster_returned_start,
		"raster_returned_end": raster_returned_end,
		"raster_pixels": raster_pixels,
		"raster_wall_ms": raster_wall_ms,
		"raster_native_ms": raster_native_ms,
		"raster_used_cpp": used_cpp_raster,
		"raster_atlas_updated": raster_atlas_updated,
		"raster_fallback_reason": raster_fallback_reason,
		"raster_progress_guard_fired": raster_progress_guard_fired,
	}
	return _record_phys_diag(ctx, pixel_report, done)


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
		return _run_physical_slice(ctx, t_start_us)

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


func __run_slice_legacy_unused(_ctx: SusTickContext) -> Dictionary:
	return {
		"done": true,
		"work_done": 0,
		"elapsed_ms": 0.0,
		"stage_name": "legacy_disabled",
		"path": "legacy_disabled",
	}

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
	policy = SusPolicyScript.AlwaysPolicy.new()
	# A round mid-flight stays as-is — only future rounds use the new pace.
