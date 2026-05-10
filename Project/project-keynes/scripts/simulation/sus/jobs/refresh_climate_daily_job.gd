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
	}

# ─── 内部：round 结束时把累积埋点写回 generator + 重置游标 ────────────────
func _finalize_round() -> void:
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
		}
		var n: int = generator._daily_climate_call_count
		if n == 1 or (n % 365) == 0:
			print("refresh_climate_daily(sliced) #%d: %dms across sub-ticks (cells=%d, phase=%.3f) | A=%.1f B=%.1f ocean=%.1f sea_ice=%.1f transp=%.1f" % [
				n,
				int(Time.get_ticks_msec() - _round_t_round_start_ms),
				map.cell_count(),
				_phase_locked,
				_round_t_pass_a_ms, _round_t_pass_b_ms, _round_t_ocean_ms, _round_t_sea_ice_ms, _round_t_transp_ms,
			])
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
