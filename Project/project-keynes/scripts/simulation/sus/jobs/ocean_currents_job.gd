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

const _DEFER_AFTER_CLIMATE_SLICE_MS: float = 9.0
const _MAX_CLIMATE_DEFER_STREAK: int = 2

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
# Tunables — sourced from ClimateProfile at registration time, but stored
# here so policy and job stay in sync.
var period_ticks: int = 30
var slice_count: int = 10


func _init(p_baker: MapBakerScript, p_map: MapData, p_world: WorldData,
		p_cfg: MapConfig, p_hex_size: float,
		p_period_ticks: int, p_slice_count: int) -> void:
	id = &"ocean_currents"
	priority = 200  # runs after refresh_climate_daily (100) / weather (150)
	slice_budget_ms = 0.55
	max_slices_per_tick = 1
	# Ocean currents are a slow visual/simulation layer. Let the scheduler defer
	# slices when the frame budget is already exhausted instead of forcing a
	# fast-tick spike.
	must_run = false
	# Starvation 防护（2026-05-11）：连续被 frame_budget_exhausted 跳过 6 次后
	# 强制让步一次。配合 ContinuousSlicedPolicy 的 period_ticks 节流，依然能
	# 保证慢层视觉/物理推进不冻结。
	starvation_threshold = 0
	baker = p_baker
	map = p_map
	world = p_world
	cfg = p_cfg
	hex_size = p_hex_size
	period_ticks = max(1, p_period_ticks)
	slice_count = max(1, p_slice_count)
	policy = SusPolicyScript.ContinuousSlicedPolicy.new(period_ticks, slice_count)


## Total pixels for the current world. Cached at round start.
func _total_pixels_for(p_world: WorldData) -> int:
	if p_world == null:
		return 0
	return p_world.derived_size.x * p_world.derived_size.y


## Pixel quota per slice — ceil(total / slice_count).
func _pixels_per_slice() -> int:
	return int(ceil(float(_total_pixels) / float(max(1, slice_count))))


func reset_progress() -> void:
	super.reset_progress()
	_next_pixel_idx = 0
	_total_pixels = 0
	_round_active = false
	_phys_solve_done = false
	# 重置事件驱动门 — 下一次 round 会因 _phase_int_seen=-9999 而强制 rebake，
	# 保证场景重载/换地图后第一帧像素 buffer 正确。
	_phase_int_seen = -9999
	_need_pixel_this_round = false
	_climate_defer_streak = 0
	if baker != null and baker.has_method("discard_ocean_buffers"):
		baker.discard_ocean_buffers()


func should_run(ctx: SusTickContext) -> bool:
	# Guard against missing dependencies (e.g. before bake_world finishes).
	if baker == null or world == null or map == null or cfg == null:
		return false
	if not _round_active and _phase_int_seen != -9999:
		var phase_now: float = ctx.season_phase
		if season_phase_getter.is_valid():
			phase_now = float(season_phase_getter.call())
		if int(floor(phase_now)) == _phase_int_seen:
			return false
	# Always defer to policy, even when a round is in flight: that keeps the
	# 'one slice every ticks_per_slice ticks' cadence intact (e.g. 1 slice
	# every 3 days). Drift of mid-round phase is bounded by the locked
	# _phase_locked, so spreading slices across the full period_ticks window
	# is exactly the desired behavior.
	if not super.should_run(ctx):
		return false
	if _should_defer_after_climate_slice():
		return false
	_climate_defer_streak = 0
	return true


func _should_defer_after_climate_slice() -> bool:
	if not climate_ran_this_tick_getter.is_valid() or not climate_slice_ms_getter.is_valid():
		return false
	if not bool(climate_ran_this_tick_getter.call()):
		return false
	var climate_ms: float = float(climate_slice_ms_getter.call())
	if climate_ms < _DEFER_AFTER_CLIMATE_SLICE_MS:
		return false
	if _climate_defer_streak >= _MAX_CLIMATE_DEFER_STREAK:
		return false
	_climate_defer_streak += 1
	return true


func run_slice(ctx: SusTickContext) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if baker == null or world == null or map == null:
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0 }

	# Begin a new round: lock total pixels and phase.
	if not _round_active:
		_total_pixels = _total_pixels_for(world)
		if _total_pixels <= 0:
			return { "done": true, "work_done": 0, "elapsed_ms": 0.0 }
		_next_pixel_idx = 0
		if season_phase_getter.is_valid():
			_phase_locked = float(season_phase_getter.call())
		else:
			_phase_locked = ctx.season_phase
		_round_active = true
		# Phys Solve Sliced：新一轮起点 → 把 baker 的求解状态机复位（_phys_stage,
		# _pending_phys_solved_phase 等），让接下来的 step_one 从 SLP 阶段重新跑。
		# 旧路径（ny-only）下 _phys_solve_done 立即设为 true，本轮所有 slice 全用于像素工作。
		_phys_solve_done = not baker._use_physical_circulation(cfg)
		if not _phys_solve_done and baker.has_method("reset_physical_solve_state"):
			baker.reset_physical_solve_state()
		# Event-driven pixel rebake：决定本轮是否需要重 bake 像素 buffer。
		#   像素 buffer (vector_atlas / wind_field_buffer / ocean_current_buffer) 只
		#   被视觉 overlay shader 消费 (hex_renderer.vector_atlas + weather_layer)。
		#   模拟逻辑全部走 HexCell.* per-cell，所以可以把 hex→pixel 喷射改为
		#   "phase_int 跨整数" 时才执行（每季 1 次）。
		#   - 首次启动 (_phase_int_seen == -9999) → 强制 rebake，确保启动 frame 有像素纹理
		#   - phase_int 跨越（春→夏 / 夏→秋 / ...） → rebake，让 overlay 反映新季节风迹
		#   - 其他情况 → 跳过像素 raster + commit（节省 ~25-30ms / day）
		#
		# 旧路径（_use_physical_circulation=false / ny-only）保留原"每天 commit"
		# 行为：那条路径没有 hex 求解阶段，整个 round 全部用于像素 slice，
		# 跳过会让 overlay 完全无更新。仅在物理化新路径下启用事件驱动门。
		# C3 plan (vector_atlas removal)：像素 buffer / vector_atlas_tex 不再被任何
		# shader 消费（world_map / weather_overlay 都已退化为零向量 fallback），
		# 所以无论是否跨季都强制不做像素阶段。stage 7 (WIND_RASTER) + commit 永
		# 久死亡，每天直接节省 ~30ms slow slice + 季节切换节省 ~49ms commit。
		# 旧路径（ny-only）下也置 false：那条路径从此 round 立即 round_done。
		_need_pixel_this_round = false
		_phase_int_seen = int(floor(_phase_locked))

	# Phys Solve Sliced：先把物理求解推进 1 阶段（~5ms）。完成前不做像素工作，
	# 把单 slice 的最大耗时从 ~200ms 降到 ~10ms。求解共有 7 阶段（见 map_baker
	# `_PHYS_STAGE_*` 常量），因此一轮新增 7 个 slice；用 ContinuousSlicedPolicy
	# 的 period_ticks/slice_count 决定每天跑几片即可。
	#
	# Event-driven pixel rebake 短路：_need_pixel_this_round=false 时，跑完
	# stage 6 (UPWELLING) 即认为求解完成，跳过 stage 7 (WIND_RASTER) 与后续
	# pixel slices + commit — 把 day_changed 路径砍掉 ~25-30ms。
	if not _phys_solve_done:
		_phys_solve_done = baker._physical_solve_step_one(map, world, hex_size, cfg, _phase_locked)
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
		# H 诊断（2026-05-14 补丁）：phys_solve 单 stage > 8ms → 打印来源 stage。
		# 历史 line 167 的诊断只覆盖 pixel/commit slice，phys_solve stage 走 early
		# return 漏掉了；ocean_currents p95 outlier 通常就是这里。
		# 注意：函数内是"跑完当前 stage → 设为下一 stage"，所以返回时读 _phys_stage
		# 拿到的是**下一**阶段的 id；这里要换算成"刚跑完的 stage"。
		if elapsed_solve_ms > 8.0:
			var next_stage_id: int = -1
			if "_phys_stage" in baker:
				next_stage_id = int(baker._phys_stage)
			# next stage = 3 (PSI_INIT) → 刚跑完 = 2 (WIND)，依此类推
			var just_done_id: int = max(0, next_stage_id - 1)
			var stage_names: Array = ["NONE", "SLP", "WIND", "PSI_INIT", "PSI_ITERS",
				"PSI_FINALIZE", "UPWELLING", "WIND_RASTER", "DONE"]
			# 修正：WIND_RASTER (7) 内部分片时 _phys_stage 不切换，next_stage_id
			# 仍是 7。此时实际"刚跑完一片像素"的就是 WIND_RASTER 本身，不是 UPWELLING。
			# 用 baker._phys_wind_raster_idx > 0 判断是否处于 stage 7 的 in-flight 状态。
			var in_wind_raster_loop: bool = (next_stage_id == 7) \
					and ("_phys_wind_raster_idx" in baker) \
					and (int(baker._phys_wind_raster_idx) > 0)
			if in_wind_raster_loop:
				just_done_id = 7
			var just_done_name: String = "?"
			if just_done_id >= 0 and just_done_id < stage_names.size():
				just_done_name = String(stage_names[just_done_id])
			print("  [ocean_currents] slow slice=%.1fms (just-finished stage=%d/%s, next=%d, round_done=%s)" % [
				elapsed_solve_ms, just_done_id, just_done_name, next_stage_id, str(_phys_solve_done)
			])
		# 求解未完成 → 本片返回，等下一个 SUS tick 继续；
		# 求解完成且不需要像素 rebake → 立刻收尾本轮，不进入 pixel slice 分支
		if not _phys_solve_done:
			return {
				"done": false,
				"work_done": 0,
				"elapsed_ms": elapsed_solve_ms,
				"progress_ratio": 0.0,
				# plan/dots-slp-psi-cpp — surface SLP / PSI C++ path decision +
				# native ms onto the slice result so [SUS] aggregation / season
				# breakdown can attribute the time correctly. Only meaningful
				# after the relevant stage has actually run (defaults remain
				# "gdscript" / -1.0 otherwise).
				"stage_slp_path": baker.get_slp_path_str() if baker.has_method("get_slp_path_str") else "gdscript",
				"stage_slp_native_ms": baker.get_slp_native_ms() if baker.has_method("get_slp_native_ms") else -1.0,
				"stage_psi_path": baker.get_psi_path_str() if baker.has_method("get_psi_path_str") else "gdscript",
				"stage_psi_native_ms": baker.get_psi_native_ms() if baker.has_method("get_psi_native_ms") else -1.0,
			}
		# _phys_solve_done = true & !_need_pixel_this_round → 跳过像素阶段，
		# 立刻 round_done。on_commit 仍要触发，让 MapGenerator 重置 per-cell
		# sample 缓存 / 通知下游 dirty。但不调 baker.commit_ocean_buffers（无新像素）。
		if not _need_pixel_this_round:
			if on_commit.is_valid():
				on_commit.call()
			_round_active = false
			_next_pixel_idx = 0
			_phys_solve_done = false
			return {
				"done": true,
				"work_done": 0,
				"elapsed_ms": elapsed_solve_ms,
				"progress_ratio": 1.0,
				"pixel_skipped": true,
				"stage_slp_path": baker.get_slp_path_str() if baker.has_method("get_slp_path_str") else "gdscript",
				"stage_slp_native_ms": baker.get_slp_native_ms() if baker.has_method("get_slp_native_ms") else -1.0,
				"stage_psi_path": baker.get_psi_path_str() if baker.has_method("get_psi_path_str") else "gdscript",
				"stage_psi_native_ms": baker.get_psi_native_ms() if baker.has_method("get_psi_native_ms") else -1.0,
			}
		# 否则（_need_pixel_this_round=true）→ 落入下面的 pixel slice 分支

	# Event-driven rebake notification — 每次跨季节进入像素阶段时打一条日志，
	# 让玩家/开发者能在 console 看到"vector_atlas 在 phase=X.XX 重 bake"提示。
	# 只在 round 的第一次像素 slice (s == 0) 打。
	var pps: int = _pixels_per_slice()
	var s: int = _next_pixel_idx
	var e: int = mini(_total_pixels, s + pps)
	if s == 0 and _need_pixel_this_round:
		print("[ocean_currents] season_crossed → rebaking pixel atlas at phase=%.3f (phase_int=%d, total_pixels=%d)" % [
			_phase_locked, _phase_int_seen, _total_pixels
		])
	# DOTS-Total-CPP（plan/dots-total-cpp 任务 4+5）：
	# 物理化路径下，rasterize 改为 C++ 一次性 hex→pixel 直出（替代 10 个 GDScript pixel slice）。
	# Gate：ClimateProfile.use_gdext_ocean_currents_pixel=true + ext.has_method
	# +baker.run_ocean_field_rasterize_full（新引入）。失败/未导出 → fallback 到旧 slice 路径。
	var used_cpp_raster: bool = false
	if s == 0 and baker._use_physical_circulation(cfg):
		var cp_oc: ClimateProfile = cfg.climate_profile if cfg != null else null
		if cp_oc != null and bool(cp_oc.use_gdext_ocean_currents_pixel) \
				and baker.has_method("run_ocean_field_rasterize_full"):
			var raster_res: Dictionary = baker.run_ocean_field_rasterize_full(map, world, cfg)
			if not bool(raster_res.get("fallback", true)):
				used_cpp_raster = true
				_next_pixel_idx = _total_pixels
	if not used_cpp_raster:
		# Fallback / 旧路径：按 [s, e) 切片光栅化。
		baker.bake_ocean_currents_slice(map, world, hex_size, cfg, _phase_locked, s, e)
		baker.bake_ocean_upwelling_slice(map, world, hex_size, cfg, _phase_locked, s, e)
		_next_pixel_idx = e

	var done: bool = (_next_pixel_idx >= _total_pixels)
	if done:
		# Daily fast ticks only need CPU buffers + HexCell.ocean_current for simulation.
		# Texture/atlas uploads are expensive GPU work and caused 200ms+ commit spikes.
		baker.commit_ocean_buffers(world, false)
		if on_commit.is_valid():
			on_commit.call()
		_round_active = false
		_next_pixel_idx = 0
		_phys_solve_done = false

	var elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
	# H 诊断：单 slice > 25ms → 标注是 commit 那一片还是普通像素片，定位 78ms 尖峰来源。
	if elapsed_ms > 25.0:
		var marker: String = "commit" if done else "pixel"
		print("  [ocean_currents] slow slice=%.1fms (%s, pixels=%d-%d / %d)" % [
			elapsed_ms, marker, s, e, _total_pixels
		])
	var progress: float = 0.0
	if _total_pixels > 0:
		progress = float(_next_pixel_idx) / float(_total_pixels) if not done else 1.0
	return {
		"done": done,
		"work_done": e - s,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": progress,
	}


## Allow MapGenerator to retune the policy on the fly (e.g. after climate
## profile reload). Re-creates the underlying ContinuousSlicedPolicy.
func reconfigure(p_period_ticks: int, p_slice_count: int) -> void:
	period_ticks = max(1, p_period_ticks)
	slice_count = max(1, p_slice_count)
	policy = SusPolicyScript.ContinuousSlicedPolicy.new(period_ticks, slice_count)
	# A round mid-flight stays as-is — only future rounds use the new pace.
