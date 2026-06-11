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
const _PIXEL_MAX_QUOTA: int = 8192
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
	# The native SUS scheduler evaluates only the registered policy descriptor.
	# Keep this job eligible every day; run_slice() gates the slow ocean/pixel
	# chain internally while always allowing the C++ daily wind prepass.
	policy = SusPolicyScript.AlwaysPolicy.new()


## Total pixels for the current world. Cached at round start.
func _total_pixels_for(p_world: WorldData) -> int:
	if p_world == null:
		return 0
	return p_world.derived_size.x * p_world.derived_size.y


## Pixel quota per slice — ceil(total / slice_count).
func _pixels_per_slice() -> int:
	return int(ceil(float(_total_pixels) / float(max(1, slice_count))))


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


func reset_progress() -> void:
	super.reset_progress()
	_next_pixel_idx = 0
	_total_pixels = 0
	_round_active = false
	_phys_solve_done = false
	_pending_commit = false
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
	_last_defer_climate_ms = 0.0
	_current_pixel_quota_diag = 0
	_last_phys_diag = {}
	_last_daily_wind_tick = _NO_DAILY_WIND_TICK
	_last_daily_wind_report = {}
	_daily_wind_rt_diag_count = 0
	if baker != null and baker.has_method("discard_ocean_buffers"):
		baker.discard_ocean_buffers()


func _ticks_per_slice_diag() -> int:
	if _slow_slice_policy != null and _slow_slice_policy.has_method("ticks_per_slice"):
		return int(_slow_slice_policy.ticks_per_slice())
	if policy != null and policy.has_method("ticks_per_slice"):
		return int(policy.ticks_per_slice())
	return 0


func _record_phys_diag(ctx: SusTickContext, report: Dictionary, done: bool) -> Dictionary:
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
	out["current_pixel_quota"] = _current_pixel_quota_diag
	out["wind_period_ticks"] = wind_period_ticks
	out["ocean_period_ticks"] = ocean_period_ticks
	out["slow_period_ticks"] = ocean_period_ticks
	out["slice_count"] = slice_count
	out["ticks_per_slice"] = _ticks_per_slice_diag()
	for daily_key in _last_daily_wind_report.keys():
		out["daily_wind_" + str(daily_key)] = _last_daily_wind_report[daily_key]
	out["done"] = done
	_last_phys_diag = out.duplicate(true)
	return out


func last_physical_diag() -> Dictionary:
	return _last_phys_diag.duplicate(true)


func _log_should_skip(ctx: SusTickContext, reason: String, detail: String = "") -> void:
	if _ocean_policy_diag_count >= 32:
		return
	_ocean_policy_diag_count += 1
	var suffix: String = ""
	if detail != "":
		suffix = " " + detail
	print("[ocean_currents][RT] skip#%d tick=%d reason=%s round=%s phys_done=%s pending_commit=%s cursor=%d/%d tps=%d streak=%d%s" % [
		_ocean_policy_diag_count, ctx.tick_index, reason, str(_round_active),
		str(_phys_solve_done), str(_pending_commit), _next_pixel_idx, _total_pixels,
		_ticks_per_slice_diag(), _climate_defer_streak, suffix,
	])


func _log_pixel_slice(ctx: SusTickContext, stage_name: String, s: int, e: int,
		elapsed_ms: float, progress: float, used_cpp_raster: bool,
		raster_wall_ms: float, raster_native_ms: float) -> void:
	if _ocean_pixel_rt_diag_count >= 64:
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
		s, e, _total_pixels, progress, elapsed_ms,
		max(0, e - s), _last_pixel_quota,
		"gdext_raster" if used_cpp_raster else "gdscript_slice",
		raster_wall_ms, raster_native_ms, str(_pending_commit),
	])


func should_run(ctx: SusTickContext) -> bool:
	# Guard against missing dependencies (e.g. before bake_world finishes).
	if baker == null or world == null or map == null or cfg == null:
		_log_should_skip(ctx, "missing_refs")
		return false
	var daily_due: bool = _daily_wind_due(ctx)
	var slow_due: bool = _slow_slice_policy_allows(ctx)
	# Commit Defer：raster 已完成、commit 待跑 → 绕过 climate-defer 让位
	# （commit 极轻 ~1.5ms 且必须尽快上传纹理，否则 shader 看的是旧 buffer）。
	if _pending_commit:
		var commit_allowed: bool = slow_due or daily_due
		if not commit_allowed:
			_log_should_skip(ctx, "policy_pending_commit")
		return commit_allowed
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
		_log_should_skip(ctx, "policy_gated", "tick_mod=%d" % (ctx.tick_index % max(1, _ticks_per_slice_diag())))
		return false
	if slow_due and _should_defer_after_climate_slice() and not daily_due:
		_log_should_skip(ctx, "climate_defer", "climate_ms=%.3f" % _last_defer_climate_ms)
		return false
	_climate_defer_streak = 0
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


func _run_daily_wind_prepass(ctx: SusTickContext) -> Dictionary:
	if ctx.tick_index == _last_daily_wind_tick:
		return _last_daily_wind_report.duplicate(true)
	var phase_now: float = _current_phase(ctx)
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
				map, world, cfg, hex_size, phase_now, ctx.day_index)
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
	_last_daily_wind_tick = ctx.tick_index
	_last_daily_wind_report = report.duplicate(true)
	if _daily_wind_rt_diag_count < 24:
		_daily_wind_rt_diag_count += 1
		print("[ocean_currents][daily_wind] #%d tick=%d ran=%s path=%s elapsed=%.3f slp=%.3f wind=%.3f delta=%.6f reason=%s" % [
			_daily_wind_rt_diag_count,
			ctx.tick_index,
			str(report.get("ran", false)),
			str(report.get("path", "")),
			float(report.get("elapsed_ms", 0.0)),
			float(report.get("slp_ms", -1.0)),
			float(report.get("wind_ms", -1.0)),
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
	if not slow_due and not _pending_commit:
		var elapsed_daily_only: float = float(Time.get_ticks_usec() - t_start_us) / 1000.0
		var daily_cells: int = int(map.soa_size()) if map != null and map.has_method("soa_size") else 0
		var daily_only_report: Dictionary = {
			"done": true,
			"work_done": daily_cells if not daily_report.is_empty() else 0,
			"processed_cells": daily_cells if not daily_report.is_empty() else 0,
			"elapsed_ms": elapsed_daily_only,
			"progress_ratio": 1.0,
			"stage_name": "daily_wind_prepass" if not daily_report.is_empty() else "ocean_policy_wait",
			"substage": "slp_wind" if not daily_report.is_empty() else "slow_slice_not_due",
			"path": str(daily_report.get("path", "daily_wind")) if not daily_report.is_empty() else "policy_wait",
			"ocean_solve_enabled": false,
			"pixel_skipped": true,
		}
		return _record_phys_diag(ctx, daily_only_report, true)

	# Commit Defer fast-path：上一片 raster 完成后挂了 _pending_commit。
	# 本片专门跑 commit_ocean_buffers（一次同步 620k×4 byte tex.update + 杂项），
	# 跑完即 round_done。把 raster 与 commit 错峰到两帧上。
	if _pending_commit:
		var t_commit2_us: int = Time.get_ticks_usec()
		baker.commit_ocean_buffers(world, true)
		var commit_only_ms: float = (Time.get_ticks_usec() - t_commit2_us) / 1000.0
		if on_commit.is_valid():
			on_commit.call()
		_pending_commit = false
		_round_active = false
		_next_pixel_idx = 0
		_phys_solve_done = false
		var elapsed_commit_only: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
		_log_pixel_slice(ctx, "ocean_pixel_commit_deferred", _next_pixel_idx, _next_pixel_idx,
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
		}
		return _record_phys_diag(ctx, commit_report, true)

	# Begin a new round: lock total pixels and phase.
	if not _round_active:
		_total_pixels = _total_pixels_for(world)
		if _total_pixels <= 0:
			return _record_phys_diag(ctx, {
				"done": true,
				"work_done": 0,
				"elapsed_ms": 0.0,
				"stage_name": "ocean_no_pixels",
				"path": "no_pixels",
			}, true)
		_next_pixel_idx = 0
		_phase_locked = _current_phase(ctx)
		_round_active = true
		_run_ocean_this_round = _should_run_ocean_this_round(ctx)
		# Phys Solve Sliced：新一轮起点 → 把 baker 的求解状态机复位（_phys_stage,
		# _pending_phys_solved_phase 等），让接下来的 step_one 从 SLP 阶段重新跑。
		# 旧路径（ny-only）下 _phys_solve_done 立即设为 true，本轮所有 slice 全用于像素工作。
		_phys_solve_done = not baker._use_physical_circulation(cfg)
		if not _phys_solve_done:
			var primed_from_daily_wind: bool = false
			if not daily_report.is_empty() and bool(daily_report.get("ran", false)) \
					and baker.has_method("prime_physical_solve_from_current_wind"):
				primed_from_daily_wind = baker.prime_physical_solve_from_current_wind(map, _phase_locked)
			if not primed_from_daily_wind and baker.has_method("reset_physical_solve_state"):
				baker.reset_physical_solve_state()
		# Event-driven pixel rebake：决定本轮是否需要重 bake 像素 buffer。
		#   像素 buffer (vector_atlas / wind_field_buffer / ocean_current_buffer) 只
		#   被视觉 shader 消费；模拟逻辑全部走 HexCell.* per-cell。
		#   物理化路径下仅在首次 round 或 season_phase 跨整数时刷新 GPU atlas；
		#   旧 ny-only 路径没有独立 hex 求解阶段，保留每轮像素刷新。
		var phase_int: int = int(floor(_phase_locked))
		if baker._use_physical_circulation(cfg):
			_need_pixel_this_round = _run_ocean_this_round \
					and (_phase_int_seen == -9999 or phase_int != _phase_int_seen)
			if _run_ocean_this_round:
				_phase_int_seen = phase_int
		else:
			_need_pixel_this_round = true
			_phase_int_seen = phase_int
		if _ocean_rt_diag_count < 24:
			var tps: int = 0
			if _slow_slice_policy != null and _slow_slice_policy.has_method("ticks_per_slice"):
				tps = int(_slow_slice_policy.ticks_per_slice())
			print("[ocean_currents][RT] round_start#%d tick=%d phase=%.4f physical=%s wind_period=%d ocean_period=%d slice_count=%d tps=%d max_slices=%d run_ocean=%s need_pixel=%s phase_int=%d phase_seen=%d total_pixels=%d" % [
				_ocean_rt_diag_count + 1, ctx.tick_index, _phase_locked,
				str(baker._use_physical_circulation(cfg)), wind_period_ticks, ocean_period_ticks,
				slice_count, tps, max_slices_per_tick, str(_run_ocean_this_round),
				str(_need_pixel_this_round), phase_int, _phase_int_seen, _total_pixels,
			])

	# Phys Solve Sliced：先把物理求解推进 1 阶段（~5ms）。完成前不做像素工作，
	# 把单 slice 的最大耗时从 ~200ms 降到 ~10ms。求解共有 7 阶段（见 map_baker
	# `_PHYS_STAGE_*` 常量），因此一轮新增 7 个 slice；用 ContinuousSlicedPolicy
	# 的 period_ticks/slice_count 决定每天跑几片即可。
	#
	# Event-driven pixel rebake 短路：_need_pixel_this_round=false 时，跑完
	# stage 6 (UPWELLING) 即认为求解完成，跳过 stage 7 (WIND_RASTER) 与后续
	# pixel slices + commit — 把 day_changed 路径砍掉 ~25-30ms。
	if not _phys_solve_done:
		var phys_stage_before: int = _baker_phys_stage_id()
		_phys_solve_done = baker._physical_solve_step_one(
				map, world, hex_size, cfg, _phase_locked, _run_ocean_this_round)
		# 短路检测：baker 跑完 stage 6 (UPWELLING) 后会把 _phys_stage 设为 7
		# (_PHYS_STAGE_WIND_RASTER)。本轮不需要像素 → 手动推到 _PHYS_STAGE_DONE
		# 并把 _pending_phys_solved_phase 锁定到当前 phase，下次同 phase 调入
		# step_one 也会瞬间命中 NaN 守门 short-circuit。
		if not _phys_solve_done and not _need_pixel_this_round \
				and baker.has_method("_use_physical_circulation") \
				and "_phys_stage" in baker \
				and "_PHYS_STAGE_WIND_RASTER" in baker \
				and "_PHYS_STAGE_DONE" in baker \
				and int(baker._phys_stage) == int(baker._PHYS_STAGE_WIND_RASTER):
			baker._phys_stage = baker._PHYS_STAGE_DONE
			if "_pending_phys_solved_phase" in baker:
				baker._pending_phys_solved_phase = _phase_locked
			_phys_solve_done = true
		var elapsed_solve_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
		var phys_report: Dictionary = _current_phys_stage_report(phys_stage_before, elapsed_solve_ms)
		if _ocean_rt_diag_count < 24:
			_ocean_rt_diag_count += 1
			print("[ocean_currents][RT] slice#%d tick=%d stage=%s->%s done=%s run_ocean=%s need_pixel=%s elapsed=%.3f ocean_delta_p95=%.6f wind_delta_p95=%.6f slp_delta_p95=%.6f psi_path=%s" % [
				_ocean_rt_diag_count, ctx.tick_index,
				str(phys_report.get("stage_name", "?")), str(phys_report.get("next_stage_name", "?")),
				str(_phys_solve_done), str(_run_ocean_this_round), str(_need_pixel_this_round),
				elapsed_solve_ms, float(phys_report.get("ocean_delta_p95", 0.0)),
				float(phys_report.get("wind_delta_p95", 0.0)), float(phys_report.get("slp_delta_p95", 0.0)),
				str(phys_report.get("stage_psi_path", "?")),
			])
		# H 诊断（2026-05-14 补丁）：phys_solve 单 stage > 8ms → 打印来源 stage。
		# 历史 line 167 的诊断只覆盖 pixel/commit slice，phys_solve stage 走 early
		# return 漏掉了；ocean_currents p95 outlier 通常就是这里。
		if elapsed_solve_ms > 8.0:
			print("  [ocean_currents] slow slice=%.1fms (just-finished stage=%d/%s, next=%d/%s, path=%s, round_done=%s)" % [
				elapsed_solve_ms,
				int(phys_report.get("stage", -1)),
				str(phys_report.get("stage_name", "?")),
				int(phys_report.get("next_stage", -1)),
				str(phys_report.get("next_stage_name", "?")),
				str(phys_report.get("path", "")),
				str(_phys_solve_done),
			])
		# 求解未完成 → 本片返回，等下一个 SUS tick 继续；
		# 求解完成且不需要像素 rebake → 立刻收尾本轮，不进入 pixel slice 分支
		if not _phys_solve_done:
			phys_report["done"] = false
			phys_report["work_done"] = 0
			phys_report["elapsed_ms"] = elapsed_solve_ms
			phys_report["progress_ratio"] = 0.0
			phys_report["ocean_solve_enabled"] = _run_ocean_this_round
			return _record_phys_diag(ctx, phys_report, false)
		# _phys_solve_done = true & !_need_pixel_this_round → 跳过像素阶段，
		# 立刻 round_done。on_commit 仍要触发，让 MapGenerator 重置 per-cell
		# sample 缓存 / 通知下游 dirty。但不调 baker.commit_ocean_buffers（无新像素）。
		if not _need_pixel_this_round:
			phys_report["done"] = true
			phys_report["work_done"] = 0
			phys_report["elapsed_ms"] = elapsed_solve_ms
			phys_report["progress_ratio"] = 1.0
			phys_report["pixel_skipped"] = true
			phys_report["ocean_solve_enabled"] = _run_ocean_this_round
			var skip_report: Dictionary = _record_phys_diag(ctx, phys_report, true)
			if on_commit.is_valid():
				on_commit.call()
			_round_active = false
			_next_pixel_idx = 0
			_phys_solve_done = false
			return skip_report
		# 否则（_need_pixel_this_round=true）→ 落入下面的 pixel slice 分支

	# Event-driven rebake notification — 每次跨季节进入像素阶段时打一条日志，
	# 让玩家/开发者能在 console 看到"vector_atlas 在 phase=X.XX 重 bake"提示。
	# 只在 round 的第一次像素 slice (s == 0) 打。
	var use_cpp_raster_plan: bool = baker._use_physical_circulation(cfg) \
			and cfg != null \
			and cfg.climate_profile != null \
			and baker.has_method("run_ocean_field_rasterize_full")
	var pps: int = _pixel_quota_for_next_slice(not use_cpp_raster_plan)
	_current_pixel_quota_diag = pps
	var s: int = _next_pixel_idx
	var e: int = mini(_total_pixels, s + pps)
	if s == 0 and _need_pixel_this_round:
		print("[ocean_currents] season_crossed → rebaking pixel atlas at phase=%.3f (phase_int=%d, total_pixels=%d)" % [
			_phase_locked, _phase_int_seen, _total_pixels
		])
	# DOTS-Total-CPP（plan/dots-total-cpp 任务 4+5）：
	# 物理化路径下，rasterize 改为 C++ 一次性 hex→pixel 直出（替代 10 个 GDScript pixel slice）。
	# Gate：baker.has_method("run_ocean_field_rasterize_full") + ext 路径 ACTIVE。
	# 失败/未导出 → fallback 到旧 slice 路径。
	#
	# dots-flag-prune-pr1 (2026-05-22)：use_gdext_ocean_currents_pixel flag 已从
	# ClimateProfile 删除——hot pass 现恒走 has_method 探测单边分支（rc<0 时
	# transparent fallback 到旧 slice 路径）。
	#
	# Sub-slice 切片（plan/ocean-raster-subslice 2026-05-22）：
	# 每片只 raster 一段像素区间，并额外限制最大像素数，最后一片完成后挂 _pending_commit。
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
			# 计算本片像素区间 [sub_s, sub_e)。
			# subslice_count 至少 1；越大每片越小（更平滑），越小越粗（旧行为）。
			var sub_count: int = 1
			if "ocean_pixel_subslice_count" in cp_oc:
				sub_count = max(1, int(cp_oc.ocean_pixel_subslice_count))
			# C++ raster 只在这里受 ocean_pixel_subslice_count 限制；外层 pps
			# 已按 ocean_currents_slice_count 固定，避免自适应降到 512 后拖慢整轮。
			var sub_pps: int = mini(int(ceil(float(_total_pixels) / float(sub_count))), pps)
			var sub_s: int = _next_pixel_idx
			var sub_e: int = mini(_total_pixels, sub_s + sub_pps)
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
						and cpp_sub_e <= _total_pixels \
						and cpp_sub_e <= sub_e)
				var returned_pixels_ok: bool = (raster_pixels == returned_span)
				if returned_range_ok and returned_pixels_ok:
					used_cpp_raster = true
					_next_pixel_idx = cpp_sub_e
					s = cpp_sub_s
					e = cpp_sub_e
					raster_fallback_reason = ""
				else:
					raster_progress_guard_fired = true
					raster_fallback_reason = "cpp_non_progress start=%d end=%d pixels=%d requested=%d..%d" % [
						cpp_sub_s, cpp_sub_e, raster_pixels, sub_s, sub_e,
					]
	if not used_cpp_raster:
		# Fallback / 旧路径：按 [s, e) 切片光栅化。
		baker.bake_ocean_currents_slice(map, world, hex_size, cfg, _phase_locked, s, e)
		baker.bake_ocean_upwelling_slice(map, world, hex_size, cfg, _phase_locked, s, e)
		_next_pixel_idx = e

	var done: bool = (_next_pixel_idx >= _total_pixels)
	var commit_wall_ms: float = -1.0
	if done:
		# Commit Defer：raster 完成 → 仅挂 _pending_commit，本片不立即 commit_ocean_buffers。
		# 下一个 SUS tick 入口的 fast-path 会专门跑 commit。这样把单片峰值
		# raster(3ms)+commit(1.5ms)≈4.7ms 拆成两片各 ~3ms / ~1.5ms，
		# 不再撑爆任何单帧 budget。
		_pending_commit = true
		# 强制本片返回 done=false，让 SUS round 续到下一个调度点。
		# round_active / _next_pixel_idx 状态保持不变（commit-defer fast-path 会清）。
		done = false

	var elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
	# H 诊断：单 slice > 25ms → 标注是 commit 那一片还是普通像素片，定位 78ms 尖峰来源。
	# 拆分 raster_wall（包含 ext 调用 + ensure_pending + refresh_slots）/
	# raster_native（C++ 内部 elapsed_ms）/ commit_wall（Image.create_from_data + tex.update）/
	# rest（on_commit 回调 + slice 头尾杂项）。
	if elapsed_ms > 25.0:
		var marker: String = "commit" if done else "pixel"
		var rest_ms: float = elapsed_ms
		if raster_wall_ms >= 0.0:
			rest_ms -= raster_wall_ms
		if commit_wall_ms >= 0.0:
			rest_ms -= commit_wall_ms
		print("  [ocean_currents] slow slice=%.1fms (%s, pixels=%d-%d / %d) raster_wall=%.1f raster_native=%.1f commit_wall=%.1f rest=%.1f" % [
			elapsed_ms, marker, s, e, _total_pixels,
			raster_wall_ms, raster_native_ms, commit_wall_ms, rest_ms
		])
	var progress: float = 0.0
	if _total_pixels > 0:
		if done or _pending_commit:
			progress = 1.0
		else:
			progress = float(_next_pixel_idx) / float(_total_pixels)
	# work_done = 本片实际 raster 的像素数。GD fallback 路径与 C++ sub-slice
	# 路径都是 (e - s)；旧"C++ 一次吃完"路径已被 sub-slice 替代。
	var work_done_pixels: int = e - s
	if work_done_pixels > 0:
		_last_pixel_slice_ms = elapsed_ms
		_last_pixel_slice_pixels = work_done_pixels
		_last_pixel_quota = work_done_pixels
	# Commit Defer：raster 完成片标 ocean_pixel_raster_done；
	# 普通中途 slice 标 ocean_pixel_slice；done=true 不再可能（raster 完即转 commit defer）。
	var slice_stage_name: String = "ocean_pixel_slice"
	if _pending_commit:
		slice_stage_name = "ocean_pixel_raster_done"
	elif done:
		slice_stage_name = "ocean_pixel_commit"
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
