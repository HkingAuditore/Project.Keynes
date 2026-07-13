# world_clock.gd
# 实时时间核心：游戏内时间持续推进，提供日/季/年三层信号 + 速度/暂停控制
#
# 设计：
#   1 day = 1 game second × speed_multiplier。所以 x1 速度下，1 现实秒 = 1 游戏天。
#   年历长度由 days_per_year_count 决定；season_phase 由 day_in_year / days_per_year
#   映射到 [0, 4)，供气候/日照使用。
#   x5/x20 加速倍率简化等比缩放。
#
# 信号：
#   day_changed(day_idx)        — 跨整数日触发
#   season_changed(season_idx)  — 跨整数季触发（0=冬 1=春 2=夏 3=秋；北半球日历语义）
#   year_changed(year_idx)      — 跨整数年触发
#
# Phase 4：year_changed 时长期 climate_anomaly 做随机游走漂移。
# Phase 1：season_phase() 返回 [0, 4) 浮点，给 shader 做平滑插值。

class_name WorldClock
extends Node

signal day_changed(day_idx: int)
signal season_changed(season_idx: int)
signal year_changed(year_idx: int)
signal season_phase_changed(season_phase: float)
# 任务 2：昼夜相位信号。由 _process 默认逐帧发射；day_phase_emit_step > 0 时可选节流。
# 与年历一致：current_day 的小数部分是一日内时刻。
signal day_phase_changed(day_phase: float)
# [cylindrical-earth-daylight] 视觉昼夜相位信号：与游戏倍速解耦的"晨昏线"驱动相位。
# 默认按真实时间缓慢推进（visual_daylen_seconds 一圈），快进不再闪烁。
signal visual_day_phase_changed(visual_day_phase: float)
# Fast-tick perf opt (D)：速度倍率变更通知，供 MapGenerator / main.gd 等订阅，
# 实现 stride 自动调档、phase 节流自动调档等。
signal speed_changed(new_speed: float)
signal simulation_backpressure_changed(active: bool, sources: PackedStringArray)
signal simulation_backpressure_pulse(day_idx: int)

# ─── 可调参数 ────────────────────────────────────────────────────────────
# 一年多少天。默认 365；如果调试时压缩年份，也应只改这里这一处。
@export_range(1, 3660, 1) var days_per_year_count: int = 365
# 启动后立即自动推进；false 时进入暂停状态由 UI 唤醒
@export var auto_start: bool = true
# 启动初速（x1 倍）
@export var initial_speed: float = 1.0

# 长期气候漂移（Phase 4 用）：每年随机游走 [-RANDOM_DRIFT, +RANDOM_DRIFT]
@export_range(0.0, 0.05, 0.001) var climate_random_drift: float = 0.01
# 气候漂移上下限（防止累积失控）
@export_range(0.0, 0.5, 0.01) var climate_anomaly_max: float = 0.20

# 任务 2：day_phase 发射步长。默认 0.0 表示每帧发射，保证昼夜/TOD
# 视觉过渡与帧率同步；如需调试 uniform 写入频率，可手动调高做节流。
@export_range(0.0, 0.05, 0.0005) var day_phase_emit_step: float = 0.0

# Fast-tick perf opt (D)：season_phase 发射步长。默认 0.0 每帧发射，
# 加速档位下会自动调档（见 _apply_phase_step_for_speed）。
@export_range(0.0, 0.05, 0.0005) var season_phase_emit_step: float = 0.0

# [cylindrical-earth-daylight] 视觉昼夜（晨昏线）独立时钟参数。
# visual_daylen_seconds：解耦模式下一整圈昼夜的真实秒数（越大越慢），默认 120≈2 分钟一圈，
#   快进时晨昏线移动速度不变 → 杜绝快进闪烁。
# visual_tod_follow_speed：true 回退旧行为（跟随 day_phase()，随倍速变快）；false（默认）按真实时间匀速推进。
@export_range(8.0, 1200.0, 1.0) var visual_daylen_seconds: float = 120.0
@export var visual_tod_follow_speed: bool = false

# plan/best-effort-sim-stepping（2026-06-17）：best-effort 吞吐模型的每帧闸。
# 倍速 = "目标天/秒"，而非死锁墙钟的契约。每帧最多推进有限天数（时间盒 +
# 硬上限），跑不完的整数天直接丢弃（不积债）→ 杜绝 fast-forward 的死亡螺旋
# （高倍速下单帧串行跑 N 个 SUS tick 把帧时拖到 200ms / 5FPS）。
# sim_frame_budget_ms：一帧用于"堆叠日级 tick"的墙钟时间盒。一帧 ~16.7ms@60fps，
#   留出 render/UI 余量，8ms 约可跑 2 个 ~4ms 的 tick。机器跑得动时根本撞不到，
#   只有过载（目标 > 可持续吞吐）时才生效，此时有效倍速平滑降级、FPS 保持。
@export_range(1.0, 33.0, 0.5) var sim_frame_budget_ms: float = 8.0
# max_sim_days_per_frame：单帧推进天数的硬上限（安全阀，兜住时间盒之外的极端）。
@export_range(1, 64, 1) var max_sim_days_per_frame: int = 8
# debug_step_log：临时诊断开关。开后每 ~120 帧打一行 [clock/step]，对比 _process
# 墙钟与 render-profile 的 sus_frame_avg，定位高倍速 FPS 跌的成本落在循环内还是 present。
@export var debug_step_log: bool = true

# ─── 运行时状态 ──────────────────────────────────────────────────────────
var current_day: float = 0.0   # 累积浮点天数 = _last_day(已模拟整数日) + _day_carry
# plan/best-effort-sim-stepping：不足 1 天的小数残留。低速（<1 天/帧）时累加到 1
# 再推进一日，并体现到 current_day 小数部分驱动 day_phase 平滑；过载丢弃整数部分。
var _day_carry: float = 0.0
var paused: bool = false
var speed_multiplier: float = 1.0
# [cylindrical-earth-daylight] 视觉昼夜相位 ∈ [0,1)：0=日出 0.25=正午 0.5=日落 0.75=午夜。
# 与 day_phase()(随倍速) 解耦，驱动 shader 的 day_phase uniform、TODProfile 与 UI 小时位。
var visual_day_phase: float = 0.25

# Phase 4：长期气候异常值（游戏内"全球温度偏移"），shader 直接读
var climate_anomaly: float = 0.0

# 任务 2：上次发射 day_phase_changed 时的 phase 值，用于节流判定。
# -1.0 是哨兵值，表示"从来没发射过"，第一次 _process 必发。
var _last_emit_day_phase: float = -1.0
# Fast-tick perf opt (D)：season_phase 同款哨兵。
var _last_emit_season_phase: float = -1.0
# Fast-tick perf opt (D)：用户是否在 Inspector 中显式手动指定了 phase 步长。
# _ready 时若检测到初始 emit_step != 0 则置 true，之后 _apply_phase_step_for_speed
# 跳过自动调档，避免覆盖用户意图。
var _user_overridden_phase_step: bool = false

# ─── 内部 ────────────────────────────────────────────────────────────────
var _last_day: int = -1
var _last_season: int = -1
var _last_year: int = -1
var _rng: RandomNumberGenerator
var _simulation_backpressure_sources: Dictionary = {}
const _MONTH_LENGTHS: Array[int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
const _MONTH_NAMES_SHORT: Array[String] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

func _ready() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.randomize()
	speed_multiplier = initial_speed
	paused = not auto_start
	# Fast-tick perf opt (D)：检测 Inspector 是否手动指定了 phase 节流步长。
	# 任一字段为非 0 即视为用户显式覆盖，此后自动调档逻辑尊重用户设定。
	_user_overridden_phase_step = (day_phase_emit_step != 0.0) or (season_phase_emit_step != 0.0)
	# 按当前 initial_speed 调一次，保证启动即生效。
	_apply_phase_step_for_speed(speed_multiplier)
	# 给订阅者一次"初始信号"，让 UI 立刻显示当前状态而不是等到下一日
	call_deferred("_emit_initial_signals")

func _emit_initial_signals() -> void:
	var d := day_index()
	var s := season_index()
	var y := year_index()
	_last_day = d
	_last_season = s
	_last_year = y
	# best-effort：current_day 现在派生自 _last_day + _day_carry，初始对齐到整日。
	_day_carry = current_day - float(_last_day)
	if _day_carry < 0.0:
		_day_carry = 0.0
	day_changed.emit(d)
	season_changed.emit(s)
	year_changed.emit(y)
	# 任务 2：首次把 day_phase 也推一次，让 shader/UI 立即拿到初始时相
	var dp := day_phase()
	_last_emit_day_phase = dp
	day_phase_changed.emit(dp)
	# Fast-tick perf opt (D)：season_phase 同样推一次初始值。
	var sp := season_phase()
	_last_emit_season_phase = sp
	season_phase_changed.emit(sp)
	# [cylindrical-earth-daylight] 初始视觉昼夜相位推送一次，让 shader/TOD 立即就位。
	visual_day_phase_changed.emit(visual_day_phase)

# best-effort-sim-stepping（plan/best-effort-sim-stepping）：推进"一个已模拟日"。
# 等价于旧 _process while 循环体：_last_day += 1、发 day_changed，并按需发
# season_changed / year rollover。注意 _last_day 始终连续 +1、不跳整数日——过载时
# 是"少推进几天"（有效倍速降级、日历推进变慢），而非跳过某天，所以 season/year
# 边界都会被精确命中。（intra-tick 的 sea_ice dt_days>1 来自各 job 自身 stride，与此无关。）
func _advance_one_sim_day() -> void:
	_last_day += 1
	day_changed.emit(_last_day)
	var day_season: int = season_index_for_day(_last_day)
	if day_season != _last_season:
		_last_season = day_season
		season_changed.emit(day_season)
	var day_year: int = year_index_for_day(_last_day)
	if day_year != _last_year:
		_last_year = day_year
		_apply_year_rollover(day_year)

func _process(delta: float) -> void:
	if paused or speed_multiplier <= 0.0:
		return
	# 自初始化兜底：_emit_initial_signals（call_deferred）可能晚于首帧 _process。
	# _last_day 仍是 -1 哨兵时，先对齐到当前整日，避免 current_day 派生出负值。
	if _last_day < 0:
		_last_day = int(floor(current_day))
		_day_carry = current_day - float(_last_day)
	# best-effort 吞吐模型（plan/best-effort-sim-stepping）：倍速 = 目标天/秒。
	# 本帧目标推进量先按硬上限封顶——即便上一帧卡顿导致 delta 巨大，也不会把
	# 成百天一次性灌进来点燃死亡螺旋。
	# Generic native backpressure clamps to x1 so ordinary continuations keep
	# receiving day ticks. The economy hard barrier is different: it is raised
	# only at a frozen cycle's settlement deadline, stops new days, and emits a
	# real-frame pulse so same-day catchup can finish without deadlock.
	var hard_day_barrier := _simulation_backpressure_sources.has(&"economy_day_barrier") or \
		_simulation_backpressure_sources.has(&"country_day_barrier")
	if hard_day_barrier:
		simulation_backpressure_pulse.emit(_last_day)
	var effective_speed := 0.0 if hard_day_barrier else (
		minf(speed_multiplier, 1.0) if has_simulation_backpressure() else speed_multiplier)
	var target: float = delta * effective_speed
	if target > float(max_sim_days_per_frame):
		target = float(max_sim_days_per_frame)
	_day_carry += target

	# 时间盒 + 硬上限：本帧最多推进 max_sim_days_per_frame 天，且至少跑满 1 天后
	# 一旦累计耗时超预算就停。每个 _advance_one_sim_day 会同步触发 _on_day_changed
	# → 一个完整 SUS tick，所以这里的墙钟测量天然涵盖当日全部模拟 + 渲染同步成本。
	var t0_us: int = Time.get_ticks_usec()
	var ran: int = 0
	while not hard_day_barrier and _day_carry >= 1.0 and ran < max_sim_days_per_frame:
		if ran > 0 and float(Time.get_ticks_usec() - t0_us) / 1000.0 >= sim_frame_budget_ms:
			break
		_day_carry -= 1.0
		_advance_one_sim_day()
		ran += 1

	# best-effort：本帧没追完的整数天直接丢弃，只保留 < 1 天的小数 carry。这是杜绝
	# spiral 的关键——债务永不累积，过载时有效倍速平滑降级、FPS 保持稳定。
	if _day_carry >= 1.0:
		_day_carry -= floor(_day_carry)

	# best-effort 诊断（临时，plan/best-effort-sim-stepping）：本帧推进了几天、
	# 日循环花了多久。和 render-profile 的 sus_frame_avg(~45ms) 对比即可定位：
	#   loop_ms ≈ proc_ms ≪ 45ms  → 35ms 在 _process 之外（渲染/present GPU 同步）。
	#   loop_ms ≈ 45ms            → 日循环本身超预算（budget 失效或单日 >预算）。
	var _loop_ms: float = float(Time.get_ticks_usec() - t0_us) / 1000.0

	# current_day 派生：已模拟整数日 + 小数 carry。低速（target<1）下 carry 平滑累加，
	# 驱动 day_phase/season_phase 连续过渡；高速下小数部分无实际意义但无害。
	# season/year 已在 _advance_one_sim_day 内逐日处理，这里不再重复检测。
	current_day = float(_last_day) + _day_carry
	# 任务 2：day_phase 节流发射
	var dp := day_phase()
	if _should_emit_day_phase(dp):
		_last_emit_day_phase = dp
		day_phase_changed.emit(dp)
	# Fast-tick perf opt (D)：season_phase 同款节流发射。
	var sp := season_phase()
	if _should_emit_season_phase(sp):
		_last_emit_season_phase = sp
		season_phase_changed.emit(sp)

	# [cylindrical-earth-daylight] 推进视觉昼夜（晨昏线）相位，按真实 delta 匀速绕圈，
	# 与 speed_multiplier 解耦 → 快进时晨昏线移动速度不变，杜绝全屏明暗闪烁。
	_advance_visual_day_phase(delta)

	# best-effort 诊断打印（临时）：每 ~120 个 _process 帧打一行，含 delta、目标天、
	# 实际推进天数 ran、日循环墙钟 _loop_ms、整个 _process 墙钟 proc_ms。
	if debug_step_log and Engine.get_process_frames() % 120 == 0:
		var _proc_ms: float = float(Time.get_ticks_usec() - t0_us) / 1000.0
		print("[clock/step] delta=%.1fms speed=%.0fx target=%.2fd ran=%d loop=%.2fms proc=%.2fms carry=%.2f"
			% [delta * 1000.0, speed_multiplier, delta * speed_multiplier, ran, _loop_ms, _proc_ms, _day_carry])

# ─── 派生查询 ────────────────────────────────────────────────────────────

func days_per_year() -> int:
	return max(1, days_per_year_count)

func day_index() -> int:
	return int(floor(current_day))

func day_in_year() -> int:
	return int(fposmod(current_day, float(days_per_year())))

# 1-based day-of-year for display.
func day_of_year() -> int:
	return day_in_year() + 1

# 北半球日历季节：0=冬 1=春 2=夏 3=秋。物理上南半球会自然反相，
# UI 顶栏只显示全局日历季节，不参与气候计算。
func season_index() -> int:
	return int(floor(season_phase())) & 3

func year_index() -> int:
	return int(floor(current_day / float(days_per_year())))

# 浮点季节相位 ∈ [0, 4)，给 shader 做平滑插值
func season_phase() -> float:
	var dpy := days_per_year()
	var day := fposmod(current_day, float(dpy))
	return (day / float(dpy)) * 4.0

func season_phase_for_day(day_idx: int) -> float:
	var dpy := days_per_year()
	var day := fposmod(float(day_idx), float(dpy))
	return (day / float(dpy)) * 4.0

func season_index_for_day(day_idx: int) -> int:
	return int(floor(season_phase_for_day(day_idx))) & 3

func year_index_for_day(day_idx: int) -> int:
	return int(floor(float(day_idx) / float(days_per_year())))

func _apply_year_rollover(year_idx: int) -> void:
	# Phase 4：年度气候漂移（pink-noise 风格随机游走）
	climate_anomaly = clampf(
		climate_anomaly + _rng.randf_range(-climate_random_drift, climate_random_drift),
		-climate_anomaly_max, climate_anomaly_max
	)
	year_changed.emit(year_idx)

# 任务 2：昼夜相位 ∈ [0, 1)
# 映射：0.0=日出, 0.25=正午, 0.5=日落, 0.75=午夜。
func day_phase() -> float:
	return fposmod(current_day, 1.0)

# [cylindrical-earth-daylight] 推进视觉昼夜相位。
# 解耦模式（默认）：按真实 delta 匀速绕圈，visual_daylen_seconds 一圈，与倍速无关 → 快进不闪。
# 跟随模式（visual_tod_follow_speed=true）：取 day_phase()，回退旧的随倍速行为。
func _advance_visual_day_phase(delta: float) -> void:
	if visual_tod_follow_speed:
		visual_day_phase = day_phase()
	else:
		var period: float = maxf(visual_daylen_seconds, 1.0)
		visual_day_phase = fposmod(visual_day_phase + delta / period, 1.0)
	visual_day_phase_changed.emit(visual_day_phase)

# 将 day_phase 映射为 0−24 小时（UI 仅用），精度到整小时。
# 与 day_phase 约定对齐：0.0=06:00（日出），0.25=12:00（正午），
# 0.5=18:00（日落），0.75=00:00（午夜）。
func hour_of_day() -> int:
	# [cylindrical-earth-daylight] 改读 visual_day_phase，让 UI 小时位与屏幕可见的太阳位置一致。
	return int(floor(fposmod(visual_day_phase - 0.75, 1.0) * 24.0)) % 24

# 任务 2：节流判定——默认每帧发射；当 day_phase_emit_step > 0 时，
# 累计变化 ≥ step 才发射。特別处理：phase 跳回 0 的跈变，应视为"必发"以避免突变时错过。
func _should_emit_day_phase(dp: float) -> bool:
	if _last_emit_day_phase < 0.0:
		return true
	if day_phase_emit_step <= 0.0:
		return true
	var diff: float = absf(dp - _last_emit_day_phase)
	# 跳回的临界情况：上次 0.99 + 这次 0.01，diff=0.98，仍会大于 step，正常发射
	return diff >= day_phase_emit_step

# Fast-tick perf opt (D)：season_phase 节流判定，语义同上。
# season_phase ∈ [0, 4)，回绕临界情况同样会 diff 很大，自动通过阈值。
func _should_emit_season_phase(sp: float) -> bool:
	if _last_emit_season_phase < 0.0:
		return true
	if season_phase_emit_step <= 0.0:
		return true
	var diff: float = absf(sp - _last_emit_season_phase)
	return diff >= season_phase_emit_step

func season_name(idx: int) -> String:
	match idx:
		0: return "Winter"
		1: return "Spring"
		2: return "Summer"
		_: return "Autumn"

func season_name_cn(idx: int) -> String:
	match idx:
		0: return "冬"
		1: return "春"
		2: return "夏"
		_: return "秋"

func calendar_date() -> Dictionary:
	var day0: int = day_in_year()
	var dpy: int = days_per_year()
	var display_days: int = 0
	for ml_display in _MONTH_LENGTHS:
		display_days += int(ml_display)
	var calendar_day0: int = clampi(
			int(floor((float(day0) / float(dpy)) * float(display_days))),
			0,
			display_days - 1)
	var month_idx: int = 0
	var day_rem: int = calendar_day0
	for i in range(_MONTH_LENGTHS.size()):
		var ml: int = int(_MONTH_LENGTHS[i])
		if day_rem < ml:
			month_idx = i
			break
		day_rem -= ml
	return {
		"month": month_idx + 1,
		"month_name": _MONTH_NAMES_SHORT[month_idx],
		"day_of_month": day_rem + 1,
		"day_of_year": day0 + 1,
		"days_per_year": dpy,
	}

# ─── 控制 ────────────────────────────────────────────────────────────────

func set_speed(s: float) -> void:
	var new_speed: float = maxf(s, 0.0)
	var changed: bool = not is_equal_approx(new_speed, speed_multiplier)
	speed_multiplier = new_speed
	if speed_multiplier > 0.0:
		paused = false
	# Fast-tick perf opt (D)：按速度档自动调 phase 节流步长（尊重 Inspector 覆盖）。
	_apply_phase_step_for_speed(speed_multiplier)
	if changed:
		speed_changed.emit(speed_multiplier)

# Fast-tick perf opt (D)：按速度档自动调 day_phase / season_phase emit step。
# 用户在 Inspector 中手动指定过步长时（_user_overridden_phase_step），跳过自动调档，尊重用户设定。
# 调整完后把哨兵重置为 -1.0，确保下一帧必发一次，避免节流临界导致视觉对齐滞后。
func _apply_phase_step_for_speed(s: float) -> void:
	if _user_overridden_phase_step:
		return
	var dps: float = 0.0
	var sps: float = 0.0
	if s >= 15.0:
		# x20 档
		dps = 0.02
		sps = 0.01
	elif s >= 3.0:
		# x5 档
		dps = 0.005
		sps = 0.002
	else:
		# x1 / 低速档：每帧发射，保留原行为
		dps = 0.0
		sps = 0.0
	day_phase_emit_step = dps
	season_phase_emit_step = sps
	_last_emit_day_phase = -1.0
	_last_emit_season_phase = -1.0

func toggle_pause() -> void:
	paused = not paused

func pause(v: bool) -> void:
	paused = v

func request_simulation_backpressure(source: StringName, active: bool) -> void:
	if String(source) == "":
		return
	var was_active := has_simulation_backpressure()
	if active:
		_simulation_backpressure_sources[source] = true
	else:
		_simulation_backpressure_sources.erase(source)
	var is_active := has_simulation_backpressure()
	if was_active != is_active:
		var sources := PackedStringArray()
		for key in _simulation_backpressure_sources.keys():
			sources.append(String(key))
		sources.sort()
		simulation_backpressure_changed.emit(is_active, sources)

func has_simulation_backpressure() -> bool:
	return not _simulation_backpressure_sources.is_empty()
