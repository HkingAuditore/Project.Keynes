# world_clock.gd
# 实时时间核心：游戏内时间持续推进，提供日/季/年三层信号 + 速度/暂停控制
#
# 设计：
#   1 day = 1 game second × speed_multiplier。所以 x1 速度下，1 现实秒 = 1 游戏天。
#   年历长度由 days_per_year_count 决定；season_phase 由 day_in_year / days_per_year
#   映射到 [0, 4)，供气候/日照使用。
#   x5/x20 加速倍率简化等比缩放。
#
# 每过一日发出 day_changed。跨季和跨年另有信号，绘制按帧读取连续相位。

class_name WorldClock
extends Node

const WorldDayCostProbe = preload("res://scripts/diagnostics/world_day_cost_probe.gd")
var _day_cost_probe = WorldDayCostProbe.new()

signal day_changed(day_idx: int)
signal season_changed(season_idx: int)
signal year_changed(year_idx: int)
signal season_phase_changed(season_phase: float)
# 任务 2：昼夜相位信号。由 _process 默认逐帧发射；day_phase_emit_step > 0 时可选节流。
# 与年历一致：current_day 的小数部分是一日内时刻。
signal day_phase_changed(day_phase: float)
# [cylindrical-earth-daylight] 视觉昼夜相位信号：驱动 shader 的日内太阳相位。
# 默认跟随游戏日相位，玩家加速时太阳与阴影同步加速。
signal visual_day_phase_changed(visual_day_phase: float)
# Fast-tick perf opt (D)：速度倍率变更通知，供 MapGenerator / main.gd 等订阅，
# 实现 stride 自动调档、phase 节流自动调档等。
signal speed_changed(new_speed: float)
signal control_changed(paused: bool, speed: float)
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

# [cylindrical-earth-daylight] 视觉昼夜（晨昏线）时钟参数。
# visual_daylen_seconds：仅供不跟随游戏日历的独立真实时间模式使用。
# visual_tod_follow_speed：true（默认）按游戏日历映射，一个游戏年完成两个 Shader 日；
#   false 时才按 visual_daylen_seconds 使用独立的真实时间速度。
@export_range(8.0, 1200.0, 1.0) var visual_daylen_seconds: float = 30.0
@export var visual_tod_follow_speed: bool = true
# Resident visual configuration supplied by HexRenderer on session binding.
var _visual_shader_days_per_year: float = 2.0

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

## [web sim budget] 浏览器上的单帧模拟预算（墙钟毫秒）。
##
## 为什么必须自适应：桌面 60 fps 下一帧 16.7 ms，8 ms 的预算刚好"用一半帧、留一半渲染"。
## 浏览器里帧率本来就只有 10–30 fps，8 ms 的预算意味着**每帧都撞天花板** —— 实测
## `day_cost` 探针给出单日 49 ms（p50）/ 66（p90），于是有效速度被压成
##   fps × 8/49 ≈ 10 fps × 0.16 ≈ 1.8 天/秒，
## 而 ×10 期望的是 10 天/秒。快进档下把预算按倍速放大，让"一天一帧"成为可能：
##   ×1 → 8 ms（交互优先，和桌面一致）
##   ×5 → 20 ms
##   ×10 → 40 ms
## 上限 60 ms：再高就会让单帧超过 100 ms，浏览器开始接近"无响应"的观感。
func sim_budget_ms() -> float:
	if not OS.has_feature("web"):
		# 手机与桌面都给输入/绘制保留同一份帧预算；倍速只提高目标天数。
		# 不把 8ms 随快进放大到 60ms。单日调用仍不可抢占，过载时降低
		# 实际推进速度；日期顺序、同日继续与结算屏障保持原样。
		return sim_frame_budget_ms
	return clampf(sim_frame_budget_ms * maxf(1.0, speed_multiplier * 0.5),
		sim_frame_budget_ms, 60.0)


# ─── 运行时状态 ──────────────────────────────────────────────────────────
var current_day: float = 0.0   # 累积浮点天数 = _last_day(已模拟整数日) + _day_carry
# plan/best-effort-sim-stepping：不足 1 天的小数残留。低速（<1 天/帧）时累加到 1
# 再推进一日，并体现到 current_day 小数部分驱动 day_phase 平滑；过载丢弃整数部分。
var _day_carry: float = 0.0
var paused: bool = false:
	set(value):
		var next := value or authority_fault_hold
		if paused == next:
			return
		paused = next
		control_changed.emit(paused, speed_multiplier)
## Latched when the native runtime enters FAULTED. Blocks day advance and
## refuses unpause so the calendar cannot drift ahead of a dead Economy.
var authority_fault_hold: bool = false
## 最近一次主动暂停的调用点，仅用于 GM 诊断，不参与模拟逻辑或存档。
var last_pause_source: String = ""
var last_pause_day: int = -1
var speed_multiplier: float = 1.0:
	set(value):
		var next := maxf(value, 0.0)
		if speed_multiplier == next:
			return
		speed_multiplier = next
		control_changed.emit(paused, speed_multiplier)
# [cylindrical-earth-daylight] 视觉昼夜相位 ∈ [0,1)：0=日出 0.25=正午 0.5=日落 0.75=午夜。
# 与 day_phase()(随倍速) 解耦，驱动 shader 的 day_phase uniform、TODProfile 与 UI 小时位。
var visual_day_phase: float = 0.25
# GM 截图预览钉住视觉相位。不写入存档：读档后继续按实时晨昏线走。
var visual_day_phase_held: bool = false

# Phase 4：长期气候异常值（游戏内"全球温度偏移"），shader 直接读
var climate_anomaly: float = 0.0
var _native_climate_calendar := false
var _runtime_calendar_admit: Callable
var _runtime_calendar_through := -1
var _runtime_calendar_fraction := 0.0
var _publishing_runtime_date := false
var _native_climate_year := -1

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
# 帧内分解诊断：continuation 脉冲段 / 日推进循环段 / 整个 _process 的最近一帧墙钟。
# pulse 段在 loop 计时之前运行（economy/country 跨日结算 drain），是 fast_ms 与
# loop_ms 都看不到的盲区；三者之和应 ≈ render-profile 的 sus_frame_avg。
var _last_fat_slice_diag: Dictionary = {}
var _last_pulse_ms: float = 0.0
var _last_loop_ms: float = 0.0
var _last_full_proc_ms: float = 0.0
# 单日模拟墙钟成本的 EMA。夹速按 sim_frame_budget_ms / 单日成本 推导每帧推进天数
# 上限，使有效吞吐随成本连续下降，而不是在"超预算"处跳到固定倍速。
var _day_cost_ms_ema: float = 0.0
var _last_throughput_cap: float = 0.0
var _last_advanced_days: int = 0
## [clock rate probe] 每 ~2 秒聚合一次"为什么没推进"：被硬屏障挡住的帧数 / 撞时间盒
## 提前退出的帧数 / 实际推进天数 / 平均单帧 delta。没有这三个数就只能猜 —— 实测
## 10× 下只有 1.78 天/秒，而 cap 已经是 0.68 天/帧，说明大部分帧根本没在跑日循环。
var _rate_frames: int = 0
var _rate_blocked: int = 0
var _rate_budget_break: int = 0
var _rate_days: int = 0
var _rate_delta_sum: float = 0.0
var _rate_next_msec: int = 0
var _rng: RandomNumberGenerator
var _simulation_backpressure_sources: Dictionary = {}
# Keep the visible calendar close to the background commit.
var _worker_lag_days: int = 0
var _max_worker_lag_days: int = 0
var _lag_blocked_frames: int = 0
# ─── Web 单日成本探针（按日聚合的 epoch 累加器）──────────────────────────
# 目的：回答"inline_day 只报 30–50ms，为什么 _day_cost_ms_ema 是 ~100ms"——
# 把**一个模拟日**的主线程墙钟按监听者/段落拆开，逐日从事件流读出。
#
# 累加器契约（详见 tmp/next/day_cost_IMPL.md §2）：
#   * 产出方在**自己那一段结束时**只调用一次 day_cost_add(tag, ms)。
#   * 同一天同一 tag 的多次 add 是**求和**（代表不同段）。因此调用点必须保证
#     "一段只 add 一次"；禁止"开始一次、读多次"——那会把同一段重复计入。
#   * 一天的段在**下一天开始前**或**本帧 _process 结束时**统一 flush 成一条
#     事件，flush 后桶清空，所以不会被下一天重复计入。
#
# 桌面零成本：day_cost_probe_on 只在 web（或显式 PK_DAY_COST_PROBE=1 的 A/B
# 开关）为真。为假时 day_cost_add/day_cost_flush 首行返回，所有调用点都包在
# `if day_cost_probe_on:` 里，桌面既有语句一条不改。
const PK_DAY_COST_PROBE_ENV := "PK_DAY_COST_PROBE"
## 单条 day_cost 事件的目标上限（字节）。超了就退化成紧凑 v/k 形式。
const DAY_COST_PAYLOAD_MAX_BYTES = WorldDayCostProbe.DAY_COST_PAYLOAD_MAX_BYTES
var day_cost_probe_on: bool:
	get: return _day_cost_probe.day_cost_probe_on
	set(value): _day_cost_probe.day_cost_probe_on = value
var _dcp_seg: Dictionary:
	get: return _day_cost_probe._dcp_seg
	set(value): _day_cost_probe._dcp_seg = value
var _dcp_day: int:
	get: return _day_cost_probe._dcp_day
	set(value): _day_cost_probe._dcp_day = value
var _dcp_dispatch_usec: int:
	get: return _day_cost_probe._dcp_dispatch_usec
	set(value): _day_cost_probe._dcp_dispatch_usec = value
var _dcp_jobs: Dictionary:
	get: return _day_cost_probe._dcp_jobs
	set(value): _day_cost_probe._dcp_jobs = value
var _dcp_last: Dictionary:
	get: return _day_cost_probe._dcp_last
	set(value): _day_cost_probe._dcp_last = value
var _dcp_last_seg: Dictionary:
	get: return _day_cost_probe._dcp_last_seg
	set(value): _day_cost_probe._dcp_last_seg = value
var _dcp_last_main: Dictionary:
	get: return _day_cost_probe._dcp_last_main
	set(value): _day_cost_probe._dcp_last_main = value
var _dcp_last_sus: Dictionary:
	get: return _day_cost_probe._dcp_last_sus
	set(value): _day_cost_probe._dcp_last_sus = value
var _dcp_emitted: int:
	get: return _day_cost_probe._dcp_emitted
	set(value): _day_cost_probe._dcp_emitted = value
var _dcp_console: bool:
	get: return _day_cost_probe._dcp_console
	set(value): _day_cost_probe._dcp_console = value
# day_cost 事件的**核心**段：每段即使为 0 也发，好让"没有跑"成为**正面证据**
# （s1/s2 = 0 就是"GDScript SUS 日 tick 一次都没被调"）。
const _DAY_COST_CORE_TAGS = WorldDayCostProbe._DAY_COST_CORE_TAGS
# day_cost_seg 事件的 host 细分段（cmt 的子项 + host 前段）。全为 0 时整条不发。
# `dup` 不是毫秒而是**次数**：单日单推进声明被第二个人撞上的次数（正常恒 0）。
const _DAY_COST_DETAIL_TAGS = WorldDayCostProbe._DAY_COST_DETAIL_TAGS
# 只有在 main.tscn（调试场景）那套 day_changed 监听者真的跑过时才有值；
# 全为 0 时整条 day_cost_main 事件不发送，生产 web 路径因此每天只有 2 条事件。
const _DAY_COST_MAIN_TAGS = WorldDayCostProbe._DAY_COST_MAIN_TAGS
const _DAY_COST_EMA_ALPHA: float = 0.2
# 单日成本发散时的吞吐下限：保证最坏情况仍每 8 帧推进一天。没有这个下限，
# 一次异常尖峰进入 EMA 就能把吞吐压到比固定 1x 更差。
const _MIN_THROUGHPUT_DAYS_PER_FRAME: float = 0.125
const _MONTH_LENGTHS: Array[int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
const _MONTH_NAMES_SHORT: Array[String] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

func _ready() -> void:
	# Web 单日成本探针的开关。显式 env 只给 headless A/B 用（桌面默认关）。
	day_cost_probe_on = OS.has_feature("web") \
		or OS.get_environment(PK_DAY_COST_PROBE_ENV) == "1"
	_dcp_console = day_cost_probe_on and not OS.has_feature("web")
	if _rng == null:
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
	# Web 构建：日历每前进一步都推到本地事件通道，agent 侧可以实时确认
	# "第 N 天有没有在走"，不必截图轮询。
	WebTelemetry.emit("day", {"day": d})
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

func _advance_one_sim_day() -> void:
	if day_cost_probe_on:
		day_cost_flush()
		_dcp_day = _last_day + 1
		_dcp_dispatch_usec = Time.get_ticks_usec()
	_last_day += 1
	if _max_worker_lag_days > 0:
		_worker_lag_days += 1
	day_changed.emit(_last_day)
	if day_cost_probe_on:
		day_cost_add(&"clk", _dcp_elapsed_ms(_dcp_dispatch_usec))
	var day_season: int = season_index_for_day(_last_day)
	if day_season != _last_season:
		_last_season = day_season
		season_changed.emit(day_season)
	var day_year: int = year_index_for_day(_last_day)
	if day_year != _last_year:
		_last_year = day_year
		_apply_year_rollover(day_year)


# ─── 单日单推进声明（day advance claim）──────────────────────────────────
# 一个 (day) 只允许**一个执行者**真正推进模拟。
#
# 现状：生产玩家场景 scenes/player_game.tscn 的 day_changed 监听者只有
# WorldRuntimeHost 与 PlayerController，其中只有 host 推进模拟；调试场景
# scenes/main.tscn 只有 main.gd。两者互斥，所以这条声明在当前所有场景上恒
# 成立、行为不变。它的价值是把"一天只跑一次"从**约定**变成**结构**：
# 权威（inline / worker）已经接管当日时，main.gd 的 GDScript SUS 日 tick 会
# 让位，不会再出现"两套日级 job 各跑一遍"。
#
# 它**不是互斥锁**：只登记，谁让位由调用点决定。WorldRuntimeHost 不让位，
# 因为它在 capacity barrier 下会对同一个 day 再次进入本函数（同日重试），
# 那是有意的再入，不是重复推进。
# 按 day 记，跨日自动失效；撞车次数进 day_cost_seg 的 `dup`（正常恒 0）。
var _day_advance_day: int = -1
var _day_advance_owner: StringName = &""
var _day_advance_dups: int = 0

func claim_day_advance(owner: StringName, day_idx: int) -> bool:
	if _day_advance_day == day_idx:
		_day_advance_dups += 1
		if day_cost_probe_on:
			_dcp_seg[&"dup"] = float(_day_advance_dups)
		return false
	_day_advance_day = day_idx
	_day_advance_owner = owner
	return true


func day_advance_owner() -> StringName:
	return _day_advance_owner


func day_advance_claim_day() -> int:
	return _day_advance_day


func day_advance_duplicate_count() -> int:
	return _day_advance_dups


# ─── Web 单日成本探针 ────────────────────────────────────────────────────
# 见文件头 _dcp_seg 上方的契约说明与 tmp/next/day_cost_IMPL.md。
# 所有入口首行判 day_cost_probe_on，桌面（非 web、未开 PK_DAY_COST_PROBE）
# 只多一次 bool 读取。

func day_cost_probe_enabled() -> bool:
	return _day_cost_probe.day_cost_probe_enabled()


## 累加一段墙钟（毫秒）。tag 见 _DAY_COST_PRIMARY_TAGS / _DAY_COST_MAIN_TAGS。
## 契约：**一段只调一次**。同一天同一 tag 的两次调用会被求和，等于重复计数。
func day_cost_add(tag: StringName, ms: float) -> void:
	_day_cost_probe.day_cost_add(tag, ms)


## SUS 日级 Job 分项。只在该 Job 真的跑过的那条路径上调用。
func day_cost_job(job_id: String, ms: float) -> void:
	_day_cost_probe.day_cost_job(job_id, ms)


## 用 sus_report_last_tick() 的原始报告累计每个 Job 的 elapsed_ms。
## 只在探针开启时由调用点调用，桌面不会为它多读一次 SUS 报告。
func day_cost_jobs_from(report: Dictionary) -> void:
	_day_cost_probe.day_cost_jobs_from(report)


func day_cost_last() -> Dictionary:
	return _day_cost_probe.day_cost_last()


func day_cost_last_main() -> Dictionary:
	return _day_cost_probe.day_cost_last_main()


func day_cost_last_seg() -> Dictionary:
	return _day_cost_probe.day_cost_last_seg()


func day_cost_last_sus() -> Dictionary:
	return _day_cost_probe.day_cost_last_sus()


func day_cost_emitted_count() -> int:
	return _day_cost_probe.day_cost_emitted_count()


## 把当前桶发成事件并清空。调用点只有两处：_advance_one_sim_day 开头、
## _process 结尾——两者合起来保证"每天恰好 flush 一次"。
func day_cost_flush() -> void:
	_day_cost_probe.day_cost_flush()


## 一组段 → {d, tag: int(ms), ...}。字节超限时退化成 {d, v:"m1 m2 ..."}，
## v 的顺序就是传入 tags 的顺序（极端尖峰才会走到，正常稳态用带键形态）。
func _dcp_group_payload(tags: Array[StringName]) -> Dictionary:
	return _day_cost_probe._dcp_group_payload(tags)


func _dcp_group_any(tags: Array[StringName]) -> bool:
	return _day_cost_probe._dcp_group_any(tags)


func _dcp_elapsed_ms(started_usec: int) -> float:
	return _day_cost_probe._dcp_elapsed_ms(started_usec)

func bind_runtime_calendar(admit: Callable) -> void:
	_runtime_calendar_admit = admit
	_runtime_calendar_through = day_index() - 1
	_runtime_calendar_fraction = 0.0


func publish_runtime_date(committed: int) -> void:
	if not _runtime_calendar_admit.is_valid() or committed + 1 <= _last_day:
		return
	_last_day = committed + 1
	current_day = float(_last_day) + _runtime_calendar_fraction
	_runtime_calendar_through = maxi(_runtime_calendar_through, committed)
	_publishing_runtime_date = true
	day_changed.emit(_last_day)
	var season := season_index_for_day(_last_day)
	if season != _last_season:
		_last_season = season
		season_changed.emit(season)
	var year := year_index_for_day(_last_day)
	if year != _last_year:
		_last_year = year
		_apply_year_rollover(year)
	_publishing_runtime_date = false


func _process_runtime_calendar(delta: float) -> void:
	_runtime_calendar_fraction += delta * speed_multiplier
	var elapsed_days := int(_runtime_calendar_fraction)
	_runtime_calendar_fraction -= elapsed_days
	if elapsed_days > 0:
		_runtime_calendar_through = int(_runtime_calendar_admit.call(
			_runtime_calendar_through + elapsed_days + 1))
	current_day = float(_last_day) + _runtime_calendar_fraction
	var dp := day_phase()
	if _should_emit_day_phase(dp):
		_last_emit_day_phase = dp
		day_phase_changed.emit(dp)
	var sp := season_phase()
	if _should_emit_season_phase(sp):
		_last_emit_season_phase = sp
		season_phase_changed.emit(sp)
	_advance_visual_day_phase(delta)


func _process(delta: float) -> void:
	if authority_fault_hold:
		paused = true
		return
	if paused or speed_multiplier <= 0.0:
		return
	if _runtime_calendar_admit.is_valid():
		_process_runtime_calendar(delta)
		return
	var proc_start_us: int = Time.get_ticks_usec()
	# 自初始化兜底：_emit_initial_signals（call_deferred）可能晚于首帧 _process。
	# _last_day 仍是 -1 哨兵时，先对齐到当前整日，避免 current_day 派生出负值。
	if _last_day < 0:
		_last_day = int(floor(current_day))
		_day_carry = current_day - float(_last_day)
	# best-effort 吞吐模型（plan/best-effort-sim-stepping）：倍速 = 目标天/秒。
	# 本帧目标推进量先按硬上限封顶——即便上一帧卡顿导致 delta 巨大，也不会把
	# 成百天一次性灌进来点燃死亡螺旋。
	# 软 backpressure（非 *_day_barrier 的来源）只是诊断信号，不参与限流。它只能由
	# 日推进本身清除，一旦拿来砍倍速就会自锁：降速 → 更少日推进 → 更晚清除。
	# 硬 barrier 不同：它只在冻结周期的结算截止点抬起，必须停下新的一天，并发一次
	# 真实帧 pulse 让同日 catchup 收尾。
	var simulation_budget_start_us: int = Time.get_ticks_usec()
	if _worker_lag_over_budget():
		_lag_blocked_frames += 1
	var hard_day_barrier := _day_advance_blocked_by_barrier()
	var pulse_start_us: int = Time.get_ticks_usec()
	# climate_input_capacity_day_barrier parks day advance only. Capacity is
	# freed by the worker draining the environment ring while WorldRuntimeHost
	# pumps peers and retries the retained day — NOT by MapGenerator's economy
	# graph pulse. Emitting pulse here re-ran capture_economy_day_inputs every
	# frame (often 20–30ms) and starved the capacity retry, permanently nailing
	# the calendar at 50x with a full ring.
	if hard_day_barrier and needs_continuation_pulse():
		simulation_backpressure_pulse.emit(_last_day)
		# 重读必须走同一个判定：pulse 只清 continuation 那一类 source，
		# 限额打满（或限流模式下的豁免）仍必须生效。
		hard_day_barrier = _day_advance_blocked_by_barrier()
	_last_pulse_ms = float(Time.get_ticks_usec() - pulse_start_us) / 1000.0
	# pulse 已经吃满帧预算时才把新的一天让给下一帧，避免 pulse + 完整日 tick 叠成
	# 尖峰。pulse 很便宜时当帧继续推进，不再为"曾经有过 barrier"额外罚一帧。
	var sim_budget := sim_budget_ms()
	var blocked := hard_day_barrier or _last_pulse_ms >= sim_budget
	# 连续限流：每帧推进天数上限 = 帧预算 / 实测单日成本。单日 8ms 以内不封顶，
	# 单日 80ms 时降到 0.1 天/帧——吞吐平滑下降而帧率守住，代替旧的倍速悬崖。
	var throughput_cap := float(max_sim_days_per_frame)
	if _day_cost_ms_ema > 0.0:
		throughput_cap = clampf(sim_budget / _day_cost_ms_ema,
			_MIN_THROUGHPUT_DAYS_PER_FRAME, float(max_sim_days_per_frame))
	_last_throughput_cap = throughput_cap
	var target: float = 0.0 if blocked else minf(delta * speed_multiplier, throughput_cap)
	_day_carry += target

	# 时间盒 + 硬上限：本帧最多推进 max_sim_days_per_frame 天，且至少跑满 1 天后
	# 一旦累计耗时超预算就停。每个 _advance_one_sim_day 会同步触发 _on_day_changed
	# → 一个完整 SUS tick，所以这里的墙钟测量天然涵盖当日全部模拟 + 渲染同步成本。
	var t0_us: int = Time.get_ticks_usec()
	var ran: int = 0
	while not paused and not blocked and _day_carry >= 1.0 and ran < max_sim_days_per_frame:
		# 时间盒从 continuation pulse 之前开始计时；无 pulse 的普通帧仍保证至少推进
		# 一天，保持低倍速/轻负载吞吐行为不变。
		if ran > 0 and float(Time.get_ticks_usec() - simulation_budget_start_us) / 1000.0 \
				>= sim_budget:
			break
		_day_carry -= 1.0
		_advance_one_sim_day()
		ran += 1
		# A day_changed handler may have raised a country/economy settlement
		# barrier. Re-read it before this render frame advances another day.
		# 限额同理：一天推完之后 worker 的提交水位可能已经变化，同一帧内
		# 保守地一起重读，避免一帧里把领先量拉过上限。
		blocked = _day_advance_blocked_by_barrier()

	# best-effort：本帧没追完的整数天直接丢弃，只保留 < 1 天的小数 carry。这是杜绝
	# spiral 的关键——债务永不累积，过载时有效倍速平滑降级、FPS 保持稳定。
	if _day_carry >= 1.0:
		_day_carry -= floor(_day_carry)

	# best-effort 诊断（临时，plan/best-effort-sim-stepping）：本帧推进了几天、
	# 日循环花了多久。和 render-profile 的 sus_frame_avg(~45ms) 对比即可定位：
	#   loop_ms ≈ proc_ms ≪ 45ms  → 35ms 在 _process 之外（渲染/present GPU 同步）。
	#   loop_ms ≈ 45ms            → 日循环本身超预算（budget 失效或单日 >预算）。
	_rate_frames += 1
	_rate_delta_sum += delta
	_rate_days += ran
	if blocked:
		_rate_blocked += 1
	if ran > 0 and float(Time.get_ticks_usec() - simulation_budget_start_us) / 1000.0 >= sim_budget:
		_rate_budget_break += 1
	if _rate_next_msec == 0:
		_rate_next_msec = Time.get_ticks_msec() + 2000
	elif Time.get_ticks_msec() >= _rate_next_msec:
		var span_s := maxf(0.001, float(_rate_frames) * (_rate_delta_sum / float(maxi(1, _rate_frames))))
		# [clock/rate] 每 2 秒一行实测吞吐：天数/秒、日成本、节流上限、平均帧率。
		# 排查"×10 到底有没有 10 天/秒"直接看这一行，不用再心算 heartbeat 差值。
		print("[clock/rate] dps=%.2f speed=%.0fx cap=%.2fd/f cost=%.0fms fps=%.1f blocked=%d budget_break=%d"
			% [float(_rate_days) / span_s, speed_multiplier, _last_throughput_cap,
				_day_cost_ms_ema, float(_rate_frames) / span_s, _rate_blocked, _rate_budget_break])
		WebTelemetry.emit("clock_rate", {
			"frames": _rate_frames,
			"days": _rate_days,
			"blocked": _rate_blocked,
			"budget_break": _rate_budget_break,
			"cap": snappedf(_last_throughput_cap, 0.01),
			"cost": int(_day_cost_ms_ema),
			"dps": snappedf(float(_rate_days) / span_s, 0.01),
			"speed": speed_multiplier,
		})
		WebTelemetry.flush()
		_rate_frames = 0
		_rate_blocked = 0
		_rate_budget_break = 0
		_rate_days = 0
		_rate_delta_sum = 0.0
		_rate_next_msec = Time.get_ticks_msec() + 2000
	_last_advanced_days = ran
	_last_loop_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	# 单日成本 EMA 的样本 = 本帧模拟总墙钟（含 continuation pulse）/ 实际推进天数。
	# 只在真正推进过日子的帧采样；纯 barrier 帧没有可归属的天数。
	if ran > 0:
		var per_day_ms := float(Time.get_ticks_usec() - simulation_budget_start_us) \
			/ 1000.0 / float(ran)
		_day_cost_ms_ema = per_day_ms if _day_cost_ms_ema <= 0.0 else \
			_day_cost_ms_ema + _DAY_COST_EMA_ALPHA * (per_day_ms - _day_cost_ms_ema)

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
	# 实际推进天数 ran、continuation 脉冲段墙钟 pulse、日循环墙钟 loop、
	# 整个 _process 墙钟 full（含 pulse + loop + 相位信号）。
	_last_full_proc_ms = float(Time.get_ticks_usec() - proc_start_us) / 1000.0
	if debug_step_log and Engine.get_process_frames() % 120 == 0:
		var barrier_names := PackedStringArray()
		for key in _simulation_backpressure_sources.keys():
			barrier_names.append(String(key))
		barrier_names.sort()
		print("[clock/step] delta=%.1fms speed=%.0fx target=%.2fd cap=%.2fd/f cost=%.2fms ran=%d pulse=%.2fms loop=%.2fms full=%.2fms carry=%.2f barrier=%s"
			% [delta * 1000.0, speed_multiplier, delta * speed_multiplier,
				_last_throughput_cap, _day_cost_ms_ema, ran,
				_last_pulse_ms, _last_loop_ms, _last_full_proc_ms, _day_carry,
				",".join(barrier_names)])
		if ran > 0 and _last_loop_ms >= sim_budget and not _last_fat_slice_diag.is_empty():
			print("[clock/fat-day] loop=%.2fms largest=%.2fms job=%s stage=%s over_budget=%s native_stage=%s"
				% [_last_loop_ms,
					float(_last_fat_slice_diag.get("largest_slice_ms", 0.0)),
					str(_last_fat_slice_diag.get("largest_slice_job", "")),
					str(_last_fat_slice_diag.get("largest_slice_stage", "")),
					str(_last_fat_slice_diag.get("commit_over_budget", false)),
					str(_last_fat_slice_diag.get("native_stage", ""))])
	# Web 单日成本探针：本帧最后一个日桶到这里一定已跑完（day_changed 同步派发），
	# 帧尾补发一次。已经在 _advance_one_sim_day 开头发过的桶是空的，不会重复。
	if day_cost_probe_on:
		day_cost_flush()

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

func season_index() -> int:
	return int(floor(season_phase())) & 3

func year_index() -> int:
	return int(floor(current_day / float(days_per_year())))

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

func seed_annual_climate(world_seed: int) -> void:
	if _rng == null:
		_rng = RandomNumberGenerator.new()
	_rng.seed = world_seed
	_native_climate_year = -1

func climate_anomaly_for_day(day_idx: int) -> float:
	if _rng == null or _last_year < 0 or year_index_for_day(day_idx) <= _last_year:
		return climate_anomaly
	# The next year's input can be frozen before the calendar emits year_changed.
	var rng_state := _rng.state
	var anomaly := _sample_annual_climate_anomaly()
	_rng.state = rng_state
	return anomaly

func _apply_year_rollover(year_idx: int) -> void:
	if not _native_climate_calendar:
		climate_anomaly = _sample_annual_climate_anomaly()
	year_changed.emit(year_idx)


func set_native_climate_calendar(active: bool) -> void:
	_native_climate_calendar = active


func apply_native_climate_calendar(view: Dictionary) -> void:
	if not view.has("climate_rng_year"):
		return
	_native_climate_year = int(view.climate_rng_year)
	_rng.state = int(view.climate_rng_state)
	climate_anomaly = float(view.climate_anomaly)

func _sample_annual_climate_anomaly() -> float:
	return clampf(
		climate_anomaly + _rng.randf_range(-climate_random_drift, climate_random_drift),
		-climate_anomaly_max, climate_anomaly_max)

# 任务 2：昼夜相位 ∈ [0, 1)
# 映射：0.0=日出, 0.25=正午, 0.5=日落, 0.75=午夜。
func day_phase() -> float:
	return fposmod(current_day, 1.0)

# [cylindrical-earth-daylight] 推进视觉昼夜相位。
# 跟随模式（默认）：一个游戏年完成两个 Shader 日，开局正午。
# 使用实际日历进度，自动跟随倍速、暂停和仿真背压，不另积视觉秒数。
# 解耦模式（visual_tod_follow_speed=false）：按真实 delta 匀速绕圈。
func set_visual_shader_days_per_year(value: float) -> void:
	_visual_shader_days_per_year = maxf(value, 0.0)
	_advance_visual_day_phase(0.0)


func _advance_visual_day_phase(delta: float) -> void:
	# 钉住时不推进、不发信号，避免实时晨昏线把 GM 太阳预览冲掉。
	if visual_day_phase_held:
		return
	if visual_tod_follow_speed:
		var year_days := float(days_per_year())
		var year_progress := current_day / year_days
		visual_day_phase = fposmod(0.25 + year_progress * _visual_shader_days_per_year, 1.0)
	else:
		var period: float = maxf(visual_daylen_seconds, 1.0)
		visual_day_phase = fposmod(visual_day_phase + delta / period, 1.0)
	visual_day_phase_changed.emit(visual_day_phase)


func hold_visual_day_phase(phase: float) -> void:
	var next := fposmod(phase, 1.0)
	var entered := not visual_day_phase_held
	visual_day_phase_held = true
	var changed := not is_equal_approx(visual_day_phase, next)
	visual_day_phase = next
	if entered or changed:
		visual_day_phase_changed.emit(visual_day_phase)


func release_visual_day_phase() -> void:
	if not visual_day_phase_held:
		return
	visual_day_phase_held = false
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
	return calendar_date_for_day(day_index())

## 按任意日索引反推日历。事件弹窗按「发生日」显示年月日，
## 不能用 calendar_date()（那是「现在」）。
func calendar_date_for_day(day_idx: int) -> Dictionary:
	var dpy: int = days_per_year()
	var day0: int = int(fposmod(float(day_idx), float(dpy)))
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
	pause(not paused)

func pause(v: bool) -> void:
	if v:
		last_pause_day = day_index()
		var stack: Array = get_stack()
		if stack.size() > 1 and stack[1] is Dictionary:
			var caller: Dictionary = stack[1]
			last_pause_source = "%s:%s" % [
				String(caller.get("function", "?")), int(caller.get("line", 0))]
	if authority_fault_hold and not v:
		paused = true
		return
	paused = v


func latch_authority_fault_hold() -> void:
	authority_fault_hold = true
	paused = true


func clear_authority_fault_hold() -> void:
	authority_fault_hold = false


func export_state() -> Dictionary:
	return {
		"schema": "WorldClock",
		"version": 1,
		"current_day": current_day,
		"day_carry": _day_carry,
		"paused": paused,
		"speed_multiplier": speed_multiplier,
		"visual_day_phase": visual_day_phase,
		"climate_anomaly": climate_anomaly,
		"last_day": _last_day,
		"last_season": _last_season,
		"last_year": _last_year,
		"climate_rng_year": _native_climate_year if _native_climate_year >= 0 else _last_year,
		"last_emit_day_phase": _last_emit_day_phase,
		"last_emit_season_phase": _last_emit_season_phase,
		"rng_seed": _rng.seed if _rng != null else 0,
		"rng_state": _rng.state if _rng != null else 0,
	}


func restore_state(state: Dictionary) -> Dictionary:
	if String(state.get("schema", "")) != "WorldClock" or int(state.get("version", -1)) != 1:
		return {"ok": false, "code": "clock_schema_incompatible", "message": "时钟存档版本不兼容。"}
	current_day = float(state.get("current_day", 0.0))
	_day_carry = clampf(float(state.get("day_carry", 0.0)), 0.0, 0.999999)
	paused = bool(state.get("paused", true))
	speed_multiplier = maxf(float(state.get("speed_multiplier", 1.0)), 0.0)
	visual_day_phase = fposmod(float(state.get("visual_day_phase", 0.25)), 1.0)
	visual_day_phase_held = false
	climate_anomaly = clampf(float(state.get("climate_anomaly", 0.0)),
		-climate_anomaly_max, climate_anomaly_max)
	_last_day = int(state.get("last_day", int(floor(current_day))))
	_last_season = int(state.get("last_season", season_index_for_day(_last_day)))
	_last_year = int(state.get("last_year", year_index_for_day(_last_day)))
	_native_climate_year = int(state.get("climate_rng_year", -1))
	if _rng == null:
		_rng = RandomNumberGenerator.new()
	_rng.seed = int(state.get("rng_seed", 0))
	_rng.state = int(state.get("rng_state", _rng.state))
	_apply_phase_step_for_speed(speed_multiplier)
	# Applying the speed tier resets the publication cursors. Restore them after
	# the tier thresholds so the next emitted phases match the saved timeline.
	_last_emit_day_phase = float(state.get("last_emit_day_phase", day_phase()))
	_last_emit_season_phase = float(state.get("last_emit_season_phase", season_phase()))
	day_phase_changed.emit(day_phase())
	season_phase_changed.emit(season_phase())
	visual_day_phase_changed.emit(visual_day_phase)
	speed_changed.emit(speed_multiplier)
	return {"ok": true, "code": "ok", "message": ""}

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


func _has_hard_day_barrier() -> bool:
	return _simulation_backpressure_sources.has(&"climate_input_capacity_day_barrier") \
		or _simulation_backpressure_sources.has(&"annual_report_commit_barrier") \
		or needs_continuation_pulse()


## Barriers that need same-day MapGenerator / SUS continuation catchup.
## climate_input_capacity is intentionally excluded: Host capacity retry owns it.
func needs_continuation_pulse() -> bool:
	if _simulation_backpressure_sources.has(&"annual_report_commit_barrier"):
		return true
	return _simulation_backpressure_sources.has(&"economy_day_barrier") \
		or _simulation_backpressure_sources.has(&"country_day_barrier") \
		or _simulation_backpressure_sources.has(&"ideology_day_barrier") \
		or _simulation_backpressure_sources.has(&"bio_occupancy_day_barrier") \
		or _simulation_backpressure_sources.has(&"native_daily_day_barrier")

func has_simulation_backpressure() -> bool:
	return not _simulation_backpressure_sources.is_empty()


func report_worker_lag_days(lag: int) -> void:
	_worker_lag_days = maxi(lag, 0)


func set_max_worker_lag_days(value: int) -> void:
	_max_worker_lag_days = maxi(value, 0)


func get_worker_lag_days() -> int:
	return _worker_lag_days


func get_max_worker_lag_days() -> int:
	return _max_worker_lag_days


func get_lag_blocked_frame_count() -> int:
	return _lag_blocked_frames


func _worker_lag_over_budget() -> bool:
	return _max_worker_lag_days > 0 and _worker_lag_days >= _max_worker_lag_days


func _day_advance_blocked_by_barrier() -> bool:
	return _has_hard_day_barrier() or _worker_lag_over_budget()


# ─── 帧内分解诊断查询 ────────────────────────────────────────────────────
# 最近一帧的 continuation 脉冲段 / 日推进循环段 / 整个 _process 墙钟（毫秒）。
# render-profile dump 按帧采样这些值，把 sus_frame_avg 拆成 pulse + loop + 帧尾。

func note_sim_slice_diag(diag: Dictionary) -> void:
	_last_fat_slice_diag = diag.duplicate(false)


func get_last_pulse_ms() -> float:
	return _last_pulse_ms


func get_last_loop_ms() -> float:
	return _last_loop_ms


func get_last_full_proc_ms() -> float:
	return _last_full_proc_ms


# 连续限流的两个可观测量：实测单日成本 EMA，以及由它推导的每帧推进天数上限。
# 验收"日间隔双峰是否收敛为单峰"时对着 CSV 看这两列。

func get_day_cost_ms_ema() -> float:
	return _day_cost_ms_ema


func get_throughput_cap_days_per_frame() -> float:
	return _last_throughput_cap


func get_last_advanced_days() -> int:
	return _last_advanced_days
