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
		return sim_frame_budget_ms
	return clampf(sim_frame_budget_ms * maxf(1.0, speed_multiplier * 0.5),
		sim_frame_budget_ms, 60.0)


# ─── 运行时状态 ──────────────────────────────────────────────────────────
var current_day: float = 0.0   # 累积浮点天数 = _last_day(已模拟整数日) + _day_carry
# plan/best-effort-sim-stepping：不足 1 天的小数残留。低速（<1 天/帧）时累加到 1
# 再推进一日，并体现到 current_day 小数部分驱动 day_phase 平滑；过载丢弃整数部分。
var _day_carry: float = 0.0
var paused: bool = false
## Latched when the native runtime enters FAULTED. Blocks day advance and
## refuses unpause so the calendar cannot drift ahead of a dead Economy.
var authority_fault_hold: bool = false
var speed_multiplier: float = 1.0
# [cylindrical-earth-daylight] 视觉昼夜相位 ∈ [0,1)：0=日出 0.25=正午 0.5=日落 0.75=午夜。
# 与 day_phase()(随倍速) 解耦，驱动 shader 的 day_phase uniform、TODProfile 与 UI 小时位。
var visual_day_phase: float = 0.25
# GM 截图预览钉住视觉相位。不写入存档：读档后继续按实时晨昏线走。
var visual_day_phase_held: bool = false

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
# ─── worker 领先量限流（P3：屏障降级为限流）────────────────────────────────
# 语义：`_lead_days` = worker 已提交日 − 本机日历日。`_max_lead_days` = 允许的
# 领先上限；0 = 关闭。
#
# 这条通道与 `_has_hard_day_barrier()` / `needs_continuation_pulse()` **并行**，
# 不改它们一字：默认 `_max_lead_days == 0` ⇒ 限额恒不触发 ⇒ 桌面行为逐表达式
# 不变（`hard_day_barrier` 的每个操作数都与改动前一致）。
#
# 为什么需要它：`climate_input_capacity_day_barrier` 的语义是"不许推进这一天"，
# 而 worker 一旦被赋予 Climate 权威、环境帧又由主线程按帧产出，环满 → 停日 →
# 更不可能腾空，就形成自维持的停止条件。领先量限流把判据换成"worker 跑得太远
# 就先等一帧"——它只是一个数字上限，不会自我维持。
var _lead_days: int = 0
var _max_lead_days: int = 0
var _lead_blocked_frames: int = 0
# 反方向的安全网：worker **落后**日历太多时也要停日历。
#
# 为什么必须有：日历由 `delta*speed` 驱动，worker 由环境帧驱动。两者一旦脱钩
# （worker 卡在某个域、或帧没喂上），日历会自顾自往前跑 —— 实测出现过
# 「日历 365 天、worker 提交 1 天」：UI 上的日期是假的，模拟其实停着，只有
# `simulation_day_stalled` 看门狗在喊。领先量限流管不到这个方向（那里的 lead
# 是负数，恒被 clamp 成 0）。
#
# 同样默认关闭（0），所以桌面逐表达式不变。
var _worker_lag_days: int = 0
var _max_worker_lag_days: int = 0
var _lag_blocked_frames: int = 0
## 预发布天数 K（0 = 没有预发布器）。见 `_prefetch_throttled_by_lead()`。
var _prefetch_days: int = 0
## 因"预发布暂停"而豁免屏障的帧数（诊断用）。
var _barrier_released_frames: int = 0
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
const DAY_COST_PAYLOAD_MAX_BYTES := 200
var day_cost_probe_on: bool = false
var _dcp_seg: Dictionary = {}
var _dcp_day: int = -1
var _dcp_dispatch_usec: int = 0
var _dcp_jobs: Dictionary = {}
var _dcp_last: Dictionary = {}
var _dcp_last_seg: Dictionary = {}
var _dcp_last_main: Dictionary = {}
var _dcp_last_sus: Dictionary = {}
var _dcp_emitted: int = 0
var _dcp_console: bool = false
# day_cost 事件的**核心**段：每段即使为 0 也发，好让"没有跑"成为**正面证据**
# （s1/s2 = 0 就是"GDScript SUS 日 tick 一次都没被调"）。
const _DAY_COST_CORE_TAGS: Array[StringName] = [
	&"clk", &"host", &"inl", &"cmt", &"pc", &"pcui", &"s1", &"s2",
]
# day_cost_seg 事件的 host 细分段（cmt 的子项 + host 前段）。全为 0 时整条不发。
# `dup` 不是毫秒而是**次数**：单日单推进声明被第二个人撞上的次数（正常恒 0）。
const _DAY_COST_DETAIL_TAGS: Array[StringName] = [
	&"rep", &"wb", &"pcr", &"cap", &"pub", &"fin", &"res", &"vis", &"wait", &"dup",
]
# 只有在 main.tscn（调试场景）那套 day_changed 监听者真的跑过时才有值；
# 全为 0 时整条 day_cost_main 事件不发送，生产 web 路径因此每天只有 2 条事件。
const _DAY_COST_MAIN_TAGS: Array[StringName] = [
	&"main", &"lab", &"sph", &"ren", &"mui", &"ovl", &"rec",
]
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

# best-effort-sim-stepping（plan/best-effort-sim-stepping）：推进"一个已模拟日"。
# 等价于旧 _process while 循环体：_last_day += 1、发 day_changed，并按需发
# season_changed / year rollover。注意 _last_day 始终连续 +1、不跳整数日——过载时
# 是"少推进几天"（有效倍速降级、日历推进变慢），而非跳过某天，所以 season/year
# 边界都会被精确命中。（intra-tick 的 sea_ice dt_days>1 来自各 job 自身 stride，与此无关。）
func _advance_one_sim_day() -> void:
	# Web 单日成本探针：上一天的桶到这里一定已经跑完（day_changed 是同步派发），
	# 先把它发出去，再为新的一天开桶并记下派发起点。桌面恒 false → 两行都不执行。
	if day_cost_probe_on:
		day_cost_flush()
		_dcp_day = _last_day + 1
		_dcp_dispatch_usec = Time.get_ticks_usec()
	_last_day += 1
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
	return day_cost_probe_on


## 累加一段墙钟（毫秒）。tag 见 _DAY_COST_PRIMARY_TAGS / _DAY_COST_MAIN_TAGS。
## 契约：**一段只调一次**。同一天同一 tag 的两次调用会被求和，等于重复计数。
func day_cost_add(tag: StringName, ms: float) -> void:
	if not day_cost_probe_on:
		return
	_dcp_seg[tag] = float(_dcp_seg.get(tag, 0.0)) + ms


## SUS 日级 Job 分项。只在该 Job 真的跑过的那条路径上调用。
func day_cost_job(job_id: String, ms: float) -> void:
	if not day_cost_probe_on:
		return
	_dcp_jobs[job_id] = float(_dcp_jobs.get(job_id, 0.0)) + ms


## 用 sus_report_last_tick() 的原始报告累计每个 Job 的 elapsed_ms。
## 只在探针开启时由调用点调用，桌面不会为它多读一次 SUS 报告。
func day_cost_jobs_from(report: Dictionary) -> void:
	if not day_cost_probe_on or report.is_empty():
		return
	for job_id in report.keys():
		var job_report = report[job_id]
		if job_report is Dictionary:
			var ms: float = float((job_report as Dictionary).get("elapsed_ms", 0.0))
			if ms > 0.0:
				day_cost_job(String(job_id), ms)


func day_cost_last() -> Dictionary:
	return _dcp_last.duplicate(true)


func day_cost_last_main() -> Dictionary:
	return _dcp_last_main.duplicate(true)


func day_cost_last_seg() -> Dictionary:
	return _dcp_last_seg.duplicate(true)


func day_cost_last_sus() -> Dictionary:
	return _dcp_last_sus.duplicate(true)


func day_cost_emitted_count() -> int:
	return _dcp_emitted


## 把当前桶发成事件并清空。调用点只有两处：_advance_one_sim_day 开头、
## _process 结尾——两者合起来保证"每天恰好 flush 一次"。
func day_cost_flush() -> void:
	if not day_cost_probe_on or (_dcp_seg.is_empty() and _dcp_jobs.is_empty()):
		return
	# 派生段：派发总时长 − host 自身 = 其余监听者（当前生产场景只有
	# PlayerController）。用两个**各自只测一次**的 epoch 相减，不是重复计时。
	var host_ms: float = float(_dcp_seg.get(&"host", 0.0))
	var clk_ms: float = float(_dcp_seg.get(&"clk", 0.0))
	if host_ms > 0.0 and clk_ms >= host_ms:
		_dcp_seg[&"pc"] = clk_ms - host_ms
	var core: Dictionary = _dcp_group_payload(_DAY_COST_CORE_TAGS)
	var detail: Dictionary = _dcp_group_payload(_DAY_COST_DETAIL_TAGS)
	var detail_any: bool = _dcp_group_any(_DAY_COST_DETAIL_TAGS)
	var main_payload: Dictionary = _dcp_group_payload(_DAY_COST_MAIN_TAGS)
	var main_any: bool = _dcp_group_any(_DAY_COST_MAIN_TAGS)
	var jobs: Dictionary = _dcp_jobs.duplicate()
	_dcp_seg.clear()
	_dcp_jobs.clear()
	_dcp_emitted += 1
	_dcp_last = core
	_dcp_last_seg = detail if detail_any else {}
	_dcp_last_main = main_payload if main_any else {}
	WebTelemetry.emit("day_cost", core)
	if _dcp_console:
		print("[day_cost] t=%d %s" % [Time.get_ticks_msec(), JSON.stringify(core)])
	# host 细分：cmt 的子项（pub/fin/res/vis）与 host 前段（rep/wb/pcr/cap/wait）。
	# 生产 web 路径几乎每天都有值（wb/pcr/cap 总要跑），所以这是第 2 条事件。
	if detail_any:
		WebTelemetry.emit("day_cost_seg", detail)
		if _dcp_console:
			print("[day_cost_seg] t=%d %s" % [Time.get_ticks_msec(), JSON.stringify(detail)])
	# main.tscn 那套监听者才有值的段：生产 web 路径恒不发送。
	if main_any:
		WebTelemetry.emit("day_cost_main", main_payload)
		if _dcp_console:
			print("[day_cost_main] t=%d %s" % [Time.get_ticks_msec(), JSON.stringify(main_payload)])
	# 逐 Job 拆解只在 GDScript SUS 日 tick 真的跑过时才有意义（生产 web 内联
	# 路径 s1=s2=0、jobs 为空，这条事件整天不出现，本身就是证据）。
	if jobs.is_empty():
		return
	var parts := PackedStringArray()
	var ids: Array = jobs.keys()
	ids.sort_custom(func(a, b): return float(jobs[a]) > float(jobs[b]))
	for i in mini(ids.size(), 8):
		parts.append("%s=%d" % [String(ids[i]), int(round(float(jobs[ids[i]])))])
	var sus_payload: Dictionary = {
		"d": _dcp_day,
		"n": ids.size(),
		"j": " ".join(parts),
	}
	WebTelemetry.emit("day_cost_sus", sus_payload)
	if _dcp_console:
		print("[day_cost_sus] t=%d %s" % [Time.get_ticks_msec(), JSON.stringify(sus_payload)])
	_dcp_last_sus = sus_payload


## 一组段 → {d, tag: int(ms), ...}。字节超限时退化成 {d, v:"m1 m2 ..."}，
## v 的顺序就是传入 tags 的顺序（极端尖峰才会走到，正常稳态用带键形态）。
func _dcp_group_payload(tags: Array[StringName]) -> Dictionary:
	var payload: Dictionary = {"d": _dcp_day}
	for tag in tags:
		payload[String(tag)] = int(round(float(_dcp_seg.get(tag, 0.0))))
	if JSON.stringify(payload).length() <= DAY_COST_PAYLOAD_MAX_BYTES - 40:
		return payload
	var values := PackedStringArray()
	for tag in tags:
		values.append(str(int(round(float(_dcp_seg.get(tag, 0.0))))))
	return {"d": _dcp_day, "v": " ".join(values)}


func _dcp_group_any(tags: Array[StringName]) -> bool:
	for tag in tags:
		if int(round(float(_dcp_seg.get(tag, 0.0)))) != 0:
			return true
	return false


func _dcp_elapsed_ms(started_usec: int) -> float:
	if started_usec <= 0:
		return 0.0
	return float(Time.get_ticks_usec() - started_usec) / 1000.0

func _process(delta: float) -> void:
	if authority_fault_hold:
		paused = true
		return
	if paused or speed_multiplier <= 0.0:
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
	# 限额是**并行**通道：`_has_hard_day_barrier()` 一字未改，只是 or 上它。
	# 两个上限都为 0（默认）时 `_worker_budget_exhausted()` 恒 false。
	var worker_budget_hit := _worker_budget_exhausted()
	if worker_budget_hit:
		_lead_blocked_frames += 1
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
	# 钉住时不推进、不发信号，避免实时晨昏线把 GM 太阳预览冲掉。
	if visual_day_phase_held:
		return
	if visual_tod_follow_speed:
		visual_day_phase = day_phase()
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
	pause(not paused)

func pause(v: bool) -> void:
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
		or _simulation_backpressure_sources.has(&"annual_report_day_barrier") \
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


# ─── 限额 API（P3）────────────────────────────────────────────────────────
# 外部（WorldRuntimeHost）每帧写入：
#   lead = worker.committed_day - day_index()   （worker 领先多少天）
#   lag  = day_index() - worker.committed_day   （worker 落后多少天）
# 两个上限默认都是 0 ⇒ `_worker_budget_exhausted()` 恒 false ⇒ 桌面逐表达式
# 等价于改动前（既有 barrier source 的语义一个字都没改）。
func report_worker_lead_days(lead: int) -> void:
	_lead_days = maxi(lead, 0)


func set_max_worker_lead_days(value: int) -> void:
	_max_lead_days = maxi(value, 0)


func report_worker_lag_days(lag: int) -> void:
	_worker_lag_days = maxi(lag, 0)


func set_max_worker_lag_days(value: int) -> void:
	_max_worker_lag_days = maxi(value, 0)


func get_worker_lead_days() -> int:
	return _lead_days


func get_max_worker_lead_days() -> int:
	return _max_lead_days


func get_worker_lag_days() -> int:
	return _worker_lag_days


func get_max_worker_lag_days() -> int:
	return _max_worker_lag_days


func get_lead_blocked_frame_count() -> int:
	return _lead_blocked_frames


func get_lag_blocked_frame_count() -> int:
	return _lag_blocked_frames


func _lead_over_budget() -> bool:
	return _max_lead_days > 0 and _lead_days >= _max_lead_days


func _worker_lag_over_budget() -> bool:
	return _max_worker_lag_days > 0 and _worker_lag_days >= _max_worker_lag_days


## 只有**一个方向**该拦日历：worker 落后太多（日历不能跑到它前面去）。
##
## 反方向曾经也拦，那是错的，而且会和预发布器的上限撞成死锁：
##   worker 领先 10 天（lead = max_lead）⇒ 日历被拦；日历不动 ⇒ lead 不变；
##   预发布器又因 lead ≥ lead_cap(=10) 不发布 ⇒ 双方都停在 10 上，日历冻住。
## 正确语义：worker 领先时日历**追上去**才是消解领先的方式，拦它只会让领先永远存在。
## 记忆体上界由预发布器一侧的 `lead_cap` 负责（那是发布闸，不是日历闸）。
func _worker_budget_exhausted() -> bool:
	return _worker_lag_over_budget()


# ─── P3 补完：预发布暂停时，日历必须能走 ──────────────────────────────────
#
# 浏览器实测的互锁（`?worker=1`）：
#     clk=1（日历停）、cd=4（worker 已提交 4）、lead=3 ≥ k=2
# 成因链条完全对称、而且每一环都"按设计"：
#   1) 预发布器看到 lead ≥ K，按防自激的不变量**暂停发布**（正确）；
#   2) worker 因此缺下一帧，抬着 `native_daily_day_barrier` 等输入（正确）；
#   3) `_has_hard_day_barrier()` 于是钉住日历（**这里错了**）；
#   4) 日历不动 ⇒ `clk` 不变 ⇒ `lead` 不变 ⇒ 预发布器继续暂停。闭环。
#
# 语义上的修正：`lead ≥ K` 意味着"worker 已经跑在日历前面"，此时**唯一能解开
# 闭环的一方是日历** —— 所以"等 worker / 等输入"这一类屏障不得再拦日。
# 真正该拦日的只剩两种：
#   * `annual_report_*`：不依赖 worker，且有自己的 pulse 语义；
#   * 领先/落后额度真正用尽（`_worker_budget_exhausted()`，上限 = K + 8）。
#
# 关闭态完全不变：`_prefetch_days == 0` 时 `_prefetch_throttled_by_lead()` 恒 false，
# `_day_advance_blocked_by_barrier()` 逐表达式等于
# `_has_hard_day_barrier() or _worker_budget_exhausted()`。
func report_worker_prefetch_days(k: int) -> void:
	_prefetch_days = maxi(k, 0)


func get_worker_prefetch_days() -> int:
	return _prefetch_days


func get_barrier_released_frame_count() -> int:
	return _barrier_released_frames


## 预发布器此刻是否正因为"领先额度用完"而暂停发布。
func _prefetch_throttled_by_lead() -> bool:
	return _prefetch_days > 0 and _lead_days >= _prefetch_days


func _annual_report_barrier_active() -> bool:
	return _simulation_backpressure_sources.has(&"annual_report_day_barrier") \
		or _simulation_backpressure_sources.has(&"annual_report_commit_barrier")


## 本帧"不许推进新的一天"的唯一判定。`_process` 的三处（首判 / pulse 后重读 /
## 日循环内重读）必须共用它，否则三处会给出不同答案。
func _day_advance_blocked_by_barrier() -> bool:
	var barrier_blocks := _has_hard_day_barrier()
	if barrier_blocks and _prefetch_throttled_by_lead() \
			and not _annual_report_barrier_active():
		# 豁免：预发布暂停中，日历必须能追上来（见上面长注释）。
		barrier_blocks = false
		_barrier_released_frames += 1
	return barrier_blocks or _worker_budget_exhausted()


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
