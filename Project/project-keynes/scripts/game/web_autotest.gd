extends Node

## Web 自动测试（autotest）入口：用 URL 查询参数驱动一次无人值守 soak，
## 取代"在画布上点 开始游戏"这种脆弱流程（点会 miss，且失败时没有任何错误细节）。
##
## 只在 `autotest=1` 时生效；没有该参数时本文件的每个入口都立刻返回，
## 主菜单 / 玩家场景的行为与今天完全一致（严格增量、普通玩家零影响）。
##
## 用法（Web 导出 + tools/serve_web.py）：
##   http://127.0.0.1:8060/?autotest=1&days=365&speed=10&seed=20260101&size=60x40
##
## 里程碑全部走 WebTelemetry（页面 POST /_log → tmp/web_events.jsonl）：
##   autotest_start / autotest_ready / autotest_progress / autotest_pass / autotest_fail
##   autotest_modal_dismissed（年鉴 / 纪元奖励 / 理念抽取 / 家族创立被 autotest 关掉或代选）
##
## 这些选择弹窗会硬暂停会话（无人值守的 365 天 soak 就停在这里）。autotest 只对
## 这几种"已知弹窗"做定向关闭，且每次都发 autotest_modal_dismissed —— 协调者据此
## 统计"这一轮跳过了多少玩家决策"，pass 事件本身不会掩盖这一点。
##
## 实测（headless, 40x28, seed 20260101, 10x）：年鉴在跨年时开卷并暂停时钟，而且
## 会挡住后续国家事务命令（"请先合卷，再处理国家事务"）；家族创立邀请在 day~1300
## 出现。两者都在下面处理；纪元奖励需要玩家自己排研究才会触发，无人值守一般不会出现。
##
## 本文件同时是"跟车节点"：player_game 把它 add_child 进场景，它每 100ms 轮询
## WorldClock 的天数 / 暂停态，不订阅任何别人的信号 —— 因此不会和
## WorldRuntimeHost 的并发编辑冲突，也不会改变既有信号时序。

const DEFAULT_DAYS: int = 365
const DEFAULT_SPEED: float = 10.0
const DEFAULT_SEED: int = 20260101
const DEFAULT_WIDTH: int = 60
const DEFAULT_HEIGHT: int = 40
# 每 30 个游戏日回报一次进度（需求固定值）。
const PROGRESS_STEP_DAYS: int = 30
# 轮询节流：看门狗阈值是 20s，100ms 采样精度绰绰有余，且几乎不吃帧预算。
const POLL_INTERVAL_MSEC: int = 100
# 暂停看门狗。取值理由：web 自动存档会 pause(true) 几秒（GameSaveCoordinator._save），
# 阈值必须远大于它才不会误报；同时又远小于"卡死 30 分钟才发现"的容忍度。
const PAUSE_FAIL_MSEC: int = 15000
# 日推进看门狗（需求：>20 墙钟秒天数不动即判失败）。
const STALL_FAIL_MSEC: int = 20000
# 建世界本身没有心跳：生成失败/卡在建图时只有超时能兜住，否则 soak 会静默挂住。
const WORLD_READY_FAIL_MSEC: int = 180000
# 弹窗关闭失败的重试上限与间隔。8 次 × 1s = 8s，必须小于 PAUSE_FAIL_MSEC(15s)：
# 这样"关不掉"会稳定报 modal_undismissable，而不是被暂停看门狗先报成 clock_paused。
const MODAL_ATTEMPT_CAP: int = 8
const MODAL_ATTEMPT_GAP_MSEC: int = 1000

# 参数只解析一次：主菜单读它来开局、player_game 里的跟车节点读它来跑 soak，
# 两处必须看到同一份值（同一页面生命周期内 URL 不会变）。
static var _params: Dictionary = {}
static var _params_parsed: bool = false
# autotest 起点（进程启动毫秒数）。跨场景保留，所以 autotest_ready 的 elapsed_ms
# 含建世界时间，而不是只算"进世界之后"。
static var _started_msec: int = 0
# 当前在树上的跟车节点。生成失败时 player_game 用它回报精确原因码。
static var _active_soak: Node = null


## 读取并解析 URL 查询参数；重复调用返回同一份缓存。
static func params() -> Dictionary:
	if not _params_parsed:
		_params_parsed = true
		_params = _parse_query(_raw_query())
		if bool(_params.get("enabled", false)):
			_started_msec = Time.get_ticks_msec()
	return _params.duplicate(true)


## 是否启用自动测试。所有"会不会影响普通玩家"的分支都只问这一个函数。
static func enabled() -> bool:
	return bool(params().get("enabled", false))


## 原始查询串。优先读 PK_AUTOTEST_QUERY 环境变量：桌面 / headless 下没有
## window.location，靠它复现同一条自动测试。
static func _raw_query() -> String:
	var override := OS.get_environment("PK_AUTOTEST_QUERY").strip_edges()
	if not override.is_empty():
		return override
	# 非 web 平台没有浏览器桥，直接当"没有参数"处理。
	if not OS.has_feature("web"):
		return ""
	if not Engine.has_singleton("JavaScriptBridge"):
		return ""
	var bridge: Object = Engine.get_singleton("JavaScriptBridge")
	if bridge == null:
		return ""
	var raw: Variant = bridge.call("eval", "String(window.location.search || '')")
	# eval 在桥不可用 / JS 异常时返回 null，必须判空后再转字符串。
	if raw == null:
		return ""
	return String(raw)


## 解析 ?a=1&b=2 形式的查询串。非法值一律退回默认值，不抛错（soak 不该因为一个
## 拼错的参数就整场失败）。
static func _parse_query(query: String) -> Dictionary:
	var out := {
		"enabled": false,
		"days": DEFAULT_DAYS,
		"speed": DEFAULT_SPEED,
		"seed": DEFAULT_SEED,
		"tier": "",
		"fog": "on",
		"worker": "0",
		"width": DEFAULT_WIDTH,
		"height": DEFAULT_HEIGHT,
	}
	var raw := query.strip_edges()
	# 去掉前导 ? 或 &：有的页面把 search 拼成 "?..."，有的拼成 "&..."。
	while raw.begins_with("?") or raw.begins_with("&"):
		raw = raw.substr(1)
	for pair in raw.split("&", false):
		if pair.strip_edges().is_empty():
			continue
		var eq := pair.find("=")
		var key := pair.uri_decode() if eq < 0 else pair.substr(0, eq).uri_decode()
		var value := "" if eq < 0 else pair.substr(eq + 1).uri_decode()
		key = key.strip_edges().to_lower()
		value = value.strip_edges()
		match key:
			"autotest":
				out["enabled"] = value.to_lower() in ["1", "true", "yes", "on"]
			"days":
				if value.is_valid_int():
					out["days"] = maxi(1, int(value))
			"speed":
				if value.is_valid_float():
					# 下限 1.0：0 速度会让时钟永远不动，那不是 soak 而是立即假失败。
					out["speed"] = clampf(float(value), 1.0, 1000.0)
			"seed":
				if value.is_valid_int():
					out["seed"] = clampi(int(value), 1, 2147483647)
			"tier":
				out["tier"] = String(value).strip_edges().to_lower()
			"fog":
				out["fog"] = String(value).strip_edges().to_lower()
			"worker":
				out["worker"] = String(value).strip_edges().to_lower()
			"size":
				_parse_size(value, out)
	return out


## 解析 size=60x40（也接受 60*40）。越界值交给 NewGameConfig.validate() 兜底。
static func _parse_size(value: String, out: Dictionary) -> void:
	var parts := value.to_lower().replace("*", "x").split("x", false)
	if parts.size() != 2:
		return
	var width_text := parts[0].strip_edges()
	var height_text := parts[1].strip_edges()
	if not width_text.is_valid_int() or not height_text.is_valid_int():
		return
	var width := int(width_text)
	var height := int(height_text)
	if width < 10 or height < 8:
		return
	out["width"] = mini(width, DCFeatureFlags.max_map_width())
	out["height"] = mini(height, DCFeatureFlags.max_map_height())


## 按参数构造 NewGameConfig。刻意与主菜单"开始游戏"的默认表单保持一致
## （two 大陆预设 + 同一批 world_controls），这样 URL 复现出来的世界和手动点
## 出来的世界可以直接对比。
static func build_config(p: Dictionary) -> NewGameConfig:
	var config := NewGameConfig.new()
	config.country.name = "自动测试"
	config.country.foreign_count = NewGameConfig.DEFAULT_FOREIGN_COUNT
	config.base.map_width = int(p.get("width", DEFAULT_WIDTH))
	config.base.map_height = int(p.get("height", DEFAULT_HEIGHT))
	config.base.initial_seed = int(p.get("seed", DEFAULT_SEED))
	config.base.map_source = NewGameConfig.MAP_SOURCE_PROCEDURAL
	config.base.pkmap_path = ""
	config.apply_land_layout(NewGameConfig.DEFAULT_LAND_LAYOUT)
	config.world_controls = {
		"continent_spacing": 92,
		"island_amount": 38,
		"wetness": 55,
		"lake_density": 45,
		"river_density": 55,
		"volcano_amount": 40,
	}
	return config


## 主菜单入口：参数启用时直接调 GameFlow.begin_new_game（与 %StartButton 回调
## 完全同一条路径，只是配置来自 URL），从而跳过整个菜单。
## flow 由调用方以节点传入，避免本文件出现 autoload 裸标识符
## （--check-only --script 模式下 autoload 不注册，裸标识符会编译失败）。
static func start_new_game(flow: Node) -> Dictionary:
	# 诊断/截图用：?fog=off 关掉全部战争迷雾。只读 Engine meta，不新增全局单例。
	# 取值来自 URL，玩家正常入口不带这个参数，行为不变。
	Engine.set_meta("pk_fog_off", String(_parse_query(_raw_query()).get("fog", "on")) == "off")
	# ?worker=1 让同一个包能做 worker / inline 的 A/B：浏览器里没有环境变量可设，
	# 而 runtime_web_worker 是导出项。见 world_runtime_host._web_worker_requested()。
	# 只有 URL 显式带 worker= 时才覆盖默认值（默认已改成 worker）；否则留空让
	# `_web_worker_requested()` 走默认链。
	var raw_q := _raw_query()
	if raw_q.contains("worker="):
		Engine.set_meta("pk_web_worker",
			String(_parse_query(raw_q).get("worker", "1")) == "1")
	var p := params()
	if not bool(p.get("enabled", false)):
		return {}
	if flow == null or not flow.has_method("begin_new_game"):
		_report("autotest_fail", {"reason": "game_flow_missing"})
		return {"ok": false, "code": "game_flow_missing", "message": "找不到 GameFlow。"}
	var result: Dictionary = flow.call("begin_new_game", build_config(p))
	_report("autotest_start", {
		"days": int(p.get("days", DEFAULT_DAYS)),
		"speed": float(p.get("speed", DEFAULT_SPEED)),
		"seed": int(p.get("seed", DEFAULT_SEED)),
		"w": int(p.get("width", DEFAULT_WIDTH)),
		"h": int(p.get("height", DEFAULT_HEIGHT)),
		"ok": bool(result.get("ok", false)),
		"code": String(result.get("code", "")),
	})
	if not bool(result.get("ok", false)):
		_report("autotest_fail", {
			"reason": "start_new_game_failed",
			"code": String(result.get("code", "")),
			"message": String(result.get("message", "")),
		})
	return result


## 供 player_game 的失败路径调用（会话配置失败 / 世界生成失败）。
## 有跟车节点时立刻失败并带上精确原因码；没有（非 autotest 会话）时是 no-op。
static func report_failure(reason: String, fields: Dictionary = {}) -> void:
	if _active_soak == null or not is_instance_valid(_active_soak):
		return
	var payload := fields.duplicate(true)
	payload["detail_from"] = "player_game"
	_active_soak.call("fail", reason, payload)


## 里程碑统一出口：Web 上走 WebTelemetry（→ tmp/web_events.jsonl）；同时 print
## 一行，让桌面 / headless 复现也有痕迹（WebTelemetry 在非 web 上是 no-op）。
static func _report(event_name: String, fields: Dictionary = {}) -> void:
	WebTelemetry.emit(event_name, fields)
	print("[autotest] %s %s" % [event_name, JSON.stringify(fields)])


# ─────────────────────────── 跟车节点（实例部分）───────────────────────────

var _host: Node = null
var _clock: WorldClock = null
# PlayerGame 下的 PlayerController（弹窗锁 / 公开关闭接口都在它身上）。
# 在 _ready 里按节点路径解析，不订阅信号、不改它的行为。
var _controller: Node = null
# PlayerGame 下的 GameUIManager（年鉴弹窗只有它有公开的"合卷"入口）。
var _ui: Node = null
var _running: bool = false
var _target_days: int = DEFAULT_DAYS
var _speed: float = DEFAULT_SPEED
var _world_in: bool = false
var _finished: bool = false
var _last_day: int = -1
var _last_day_msec_day: int = -999
var _last_day_msec: int = 0
var _paused_since_msec: int = 0
var _next_progress_day: int = PROGRESS_STEP_DAYS
var _next_poll_msec: int = 0
# 选择弹窗的关闭预算：kind → 连续失败次数（成功一次即清零）。
var _modal_attempts: Dictionary = {}
# 已经处理过的弹窗标识：kind → key。同一个 key 不再重复提交，只等运行时结算，
# 这样"选择已提交、正在等一天边界"不会被误当成"关不掉"而烧光尝试次数。
var _modal_done: Dictionary = {}
var _modal_next_msec: int = 0
# 最近一次"已成功提交、但还没结算完"的弹窗（kind/key/提交时刻）。只用于失败事件的
# 证据字段：协调者能看到"已代选、等结算、等了多久"，不用再猜。
var _modal_submitted: Dictionary = {}
# 最近一次关闭尝试的返回码/文案，modal_undismissable 时作为现场证据。
var _modal_last_error: Dictionary = {}


## player_game 在 add_child 之前注入宿主 / 时钟引用，本节点不自己去满树 find。
func configure(host: Node, clock: WorldClock) -> void:
	_host = host
	_clock = clock


func _ready() -> void:
	# 未启用时直接关掉 _process：普通玩家连一次轮询都不会有。
	_running = enabled()
	set_process(_running)
	if not _running:
		return
	var p := params()
	_target_days = maxi(1, int(p.get("days", DEFAULT_DAYS)))
	_speed = float(p.get("speed", DEFAULT_SPEED))
	# add_child 之后父节点已就位，按节点路径拿 PlayerController / UI（不依赖 autoload/信号）。
	var game := get_parent()
	_controller = game.get_node_or_null("PlayerController") if game != null else null
	_ui = game.get_node_or_null("UI") if game != null else null
	_active_soak = self


func _exit_tree() -> void:
	# 换场景后静态引用必须清掉，否则 report_failure 会打到一个已释放的节点。
	if _active_soak == self:
		_active_soak = null


func _process(_delta: float) -> void:
	if not _running or _finished:
		return
	var now_msec := Time.get_ticks_msec()
	if now_msec < _next_poll_msec:
		return
	_next_poll_msec = now_msec + POLL_INTERVAL_MSEC
	if not _world_in:
		_poll_world_entry(now_msec)
		return
	_poll_soak(now_msec)


## 等世界就绪。用 host.is_runtime_ready_for_ticks() 轮询而不是接 world_ready 信号：
## 重生成 / 读档路径上信号会重复发，轮询天然幂等。
## PROBE：autotest 下隐藏整个 UI，用来判断"整帧不返回"是否由 HUD/检查器的文本布局引起。
## PROBE：关闭弹窗轮询（判断 autotest 自身是否造成长帧）。
const PK_WEB_DISABLE_MODAL_POLLING := false
const PK_WEB_HIDE_UI_PROBE := false


## ?tier=low|mid|high：强制画质档，用来验证三档 shader 都能正常编译（web 上曾出现
## 只有 LOW 能编译、切 HIGH 就白屏的问题）。
func _apply_tier_probe() -> void:
	var tier := String(params().get("tier", ""))
	if tier == "":
		return
	var define := ""
	match tier:
		"low":
			define = "MOBILE_QUALITY_LOW"
		"high":
			define = "MOBILE_QUALITY_HIGH"
		"mid":
			define = "MOBILE_QUALITY_MID"
		_:
			return
	var renderer: Node = null
	# `_host` 是 RuntimeHost 节点本身；WorldRoot 与它是**兄弟**，所以原来的
	# `_host.get_node_or_null("WorldRoot/HexRenderer")` 恒为 null，探针从来没生效过。
	# 先用 host 自己的访问器，再退回父节点下的路径。
	if _host != null and _host.has_method("get_renderer"):
		renderer = _host.call("get_renderer")
	if renderer == null and _host != null and _host.get_parent() != null:
		renderer = _host.get_parent().get_node_or_null("WorldRoot/HexRenderer")
	if renderer != null and renderer.has_method("set_mobile_quality_tier"):
		renderer.set_mobile_quality_tier(define)
		WebTelemetry.emit("tier_probe", {"tier": tier, "define": define})


func _apply_ui_probe(host: Node) -> void:
	if not PK_WEB_HIDE_UI_PROBE or host == null:
		return
	# 逐层二分：先只隐藏 PanelLayer（右侧检查器），其余 UI 保留。
	var target := host.get_node_or_null("UI/UIRoot/PanelLayer")
	if target is CanvasItem:
		(target as CanvasItem).visible = false
		WebTelemetry.emit("ui_probe", {"hidden": "PanelLayer"})


func _poll_world_entry(now_msec: int) -> void:
	var ready := _host != null and _host.has_method("is_runtime_ready_for_ticks") \
		and bool(_host.call("is_runtime_ready_for_ticks"))
	if ready:
		_enter_world(now_msec)
		return
	if now_msec - _started_msec > WORLD_READY_FAIL_MSEC:
		fail("world_not_ready", {"waited_ms": now_msec - _started_msec})


## 世界进栈：解暂停 + 立倍速，然后回报 autotest_ready（带自 autotest 起点的毫秒数）。
func _enter_world(now_msec: int) -> void:
	_apply_ui_probe(_host)
	_apply_tier_probe()
	_world_in = true
	_last_day_msec = now_msec
	if _clock != null:
		# 先立倍速再解暂停：set_speed(>0) 自己会清 paused，pause(false) 是双保险。
		# worker FAULTED 时 WorldClock 的 fault hold 会拒绝 pause(false)，属预期，
		# 下一轮 _poll_soak 会以 runtime_fault 报出来。
		_clock.set_speed(_speed)
		_clock.pause(false)
		_last_day = _clock.day_index()
	_report("autotest_ready", {
		"day": _last_day,
		"speed": _clock.speed_multiplier if _clock != null else 0.0,
		"paused": _clock.paused if _clock != null else true,
		"elapsed_ms": now_msec - _started_msec,
	})


## 每 100ms 一次的验收循环：故障 → 已知弹窗 → 日推进看门狗 → 暂停看门狗 → pass → 进度。
func _poll_soak(now_msec: int) -> void:
	# 1) 运行时故障优先。WorldRuntimeHost 进 FAULTED 时会自己 pause(true)，
	#    这时若报 clock_paused 会掩盖真因，所以先查故障态并带上 fault_code。
	if _host != null and _host.has_method("is_runtime_fault_paused") \
			and bool(_host.call("is_runtime_fault_paused")):
		var diag: Dictionary = _host.call("get_runtime_fault_diagnostics") \
			if _host.has_method("get_runtime_fault_diagnostics") else {}
		fail("runtime_fault", {
			"fault_code": String(diag.get("fault_code", "")),
			"committed_day": int(diag.get("committed_day", -1)),
			"generation": int(diag.get("generation", 0)),
			"worker_fault_count": int(diag.get("worker_fault_count", 0)),
		})
		return
	var day := _clock.day_index() if _clock != null else -1
	var paused := _clock.paused if _clock != null else true
	# PROBE：暂时关闭弹窗轮询（每次都会查 native 的家庭/时代/意识形态 offer），
	# 用来判断那次 30-45s 长帧是否由 autotest 自己造成。
	if PK_WEB_DISABLE_MODAL_POLLING:
		if day != _last_day_msec_day:
			_last_day_msec = now_msec
			_last_day_msec_day = day
		return
	# 2) 已知选择弹窗：定向代选 / 关闭（见 _dismiss_open_modals）。
	#    这里不做"暂停就解暂停"——只处理指名道姓的三种弹窗，其余暂停仍由下面兜底。
	if _dismiss_open_modals(now_msec, day):
		return
	# 3) 日推进看门狗：权威日多久没动过。10x 下 20s 等于丢了 ~200 天。
	if day != _last_day:
		_last_day = day
		_last_day_msec = now_msec
	elif now_msec - _last_day_msec > STALL_FAIL_MSEC:
		fail("day_stall", {
			"day": day,
			"stalled_ms": now_msec - _last_day_msec,
			"paused": paused,
			"blocked_by": _blocked_by(),
		})
		return
	# 4) 暂停看门狗：持续暂停超过阈值即失败（阈值见 PAUSE_FAIL_MSEC 的取值理由）。
	if paused:
		if _paused_since_msec == 0:
			_paused_since_msec = now_msec
		elif now_msec - _paused_since_msec > PAUSE_FAIL_MSEC:
			fail("clock_paused", {
				"day": day,
				"paused_ms": now_msec - _paused_since_msec,
				"blocked_by": _blocked_by(),
			})
			return
	else:
		_paused_since_msec = 0
	# 5) 达标判定放在进度事件之前，避免最后一段 30 天事件排在 pass 后面。
	if day >= _target_days:
		pass_soak(day)
		return
	# 6) 每 30 游戏日一条进度，带墙钟秒数与实测吞吐（有效倍速会低于目标值）。
	while day >= _next_progress_day:
		_report("autotest_progress", {
			"day": day,
			"wall_s": _wall_seconds(now_msec),
			"days_per_s": _days_per_second(day, now_msec),
			"speed": _clock.speed_multiplier if _clock != null else 0.0,
			"paused": paused,
		})
		_next_progress_day += PROGRESS_STEP_DAYS


## 只对"会硬暂停会话的已知弹窗"做定向处理；返回 true 表示本轮已发起动作，
## 本轮不再做 pass / 进度判定（避免在弹窗刚关那一帧误判达标）。
## 关键：这不是"一暂停就解暂停"——_modal_target() 只认年鉴 / 纪元奖励 / 家族创立 /
## 理念抽取这几种状态，其它任何暂停仍然落到 clock_paused（需求：真正的异常不放过）。
func _dismiss_open_modals(now_msec: int, day: int) -> bool:
	# 年鉴只依赖 GameUIManager，所以两个引用都缺时才彻底跳过。
	if _controller == null and _ui == null:
		return false
	if now_msec < _modal_next_msec:
		return false
	var target := _modal_target()
	if target.is_empty():
		# 没有可处理的弹窗：清掉落败预算，下一次弹窗重新拿到完整重试次数。
		_modal_attempts.clear()
		return false
	var kind := String(target.get("kind", ""))
	var key := String(target.get("key", ""))
	# 同一个弹窗已提交过：运行时正在结算（如已选待跨日生效），不再重复提交。
	# 空 key 表示"可重复处理"的类型（理念抽取关掉后状态立刻自清）。
	if not key.is_empty() and String(_modal_done.get(kind, "")) == key:
		return false
	var attempt := int(_modal_attempts.get(kind, 0)) + 1
	_modal_attempts[kind] = attempt
	_modal_next_msec = now_msec + MODAL_ATTEMPT_GAP_MSEC
	if attempt > MODAL_ATTEMPT_CAP:
		# 关不掉就明确失败，而不是让暂停看门狗把它报成含糊的 clock_paused。
		fail("modal_undismissable", {
			"blocked_by": kind,
			"attempts": attempt - 1,
			"modal_key": key,
			"last_code": String(_modal_last_error.get("code", "")),
			"last_message": String(_modal_last_error.get("message", "")),
		})
		return true
	var outcome := _dismiss_modal(kind)
	if not bool(outcome.get("ok", false)):
		# 单次失败不当场判死：记下错误，由上面的重试上限兜住（8s < 15s 暂停阈值）。
		_modal_last_error = outcome
		return true
	_modal_attempts.clear()
	_modal_last_error.clear()
	if not key.is_empty():
		_modal_done[kind] = key
	_modal_submitted = {"kind": kind, "key": key, "msec": now_msec}
	_report("autotest_modal_dismissed", {
		"reason": kind,
		"day": day,
		"wall_s": _wall_seconds(now_msec),
		"dismissed_via": String(outcome.get("via", "")),
		"modal_key": key,
		"attempt": attempt,
	})
	# 需求要求一条人能读的痕迹；_report 打的是 JSON，这行专门写"跳过了什么"。
	print("[autotest] dismissed %s via %s at day %d (attempt %d)" % [
		kind, String(outcome.get("via", "")), day, attempt])
	return true


## 判定"现在是否有需要 autotest 介入的已知弹窗"，返回 {kind, key} 或 {}。
## 只认这几种确定会锁会话并 pause(true) 的状态；其它暂停一律留给 clock_paused。
func _modal_target() -> Dictionary:
	# 年鉴优先：跨年必开卷、会暂停时钟，而且它会挡住后续国家事务命令
	# （request_command 直接返回 annual_report_open），所以必须先合卷再处理别的弹窗。
	# 它挂在 GameUIManager 上，与 PlayerController 的锁相互独立。
	if _ui != null and _ui.has_method("is_annual_report_open") \
			and bool(_ui.call("is_annual_report_open")):
		return {"kind": "annual_report", "key": ""}
	if _controller == null:
		return {}
	if _ctrl_bool("era_reward_locked"):
		var era := _era_reward_offer()
		# SELECTED_PENDING = 已选待跨日结算，控制器自己会以 1x 推进并恢复，不能再动它。
		if String(era.get("status", "NONE")) in ["OPEN", "ERROR"]:
			return {"kind": "era_reward",
				"key": "era:%d" % int(era.get("offer_generation", 0))}
		return {}
	# 纪元奖励持锁时，家族创立命令会被 PlayerController.request_command 直接拒绝，
	# 所以只在没有纪元锁时处理，避免把重试预算浪费在必然失败的调用上。
	if _ctrl_bool("family_founding_locked"):
		var founding := _family_founding_offer()
		if not founding.is_empty():
			return {"kind": "family_founding",
				"key": "family:%d:%d" % [int(founding.get("offer_id", 0)),
					int(founding.get("generation", 0))]}
		return {}
	# 理念抽取只有 presenting 阶段暂停时钟，也只有这个阶段有公开关闭接口；
	# offer/choose/reroll 阶段由 PlayerController 自己按 IDEOLOGY_DRAW_TIMEOUT_DAYS 超时收尾。
	if _ctrl_str("ideology_draw_phase") == "presenting":
		return {"kind": "ideology_draw", "key": ""}
	return {}


## 分派到各弹窗"玩家自己点按钮"时走的同一条公开链路。
func _dismiss_modal(kind: String) -> Dictionary:
	match kind:
		"annual_report":
			return _close_annual_report()
		"era_reward":
			return _choose_era_reward()
		"family_founding":
			return _choose_family_founding()
		"ideology_draw":
			return _close_ideology_offer()
	return {"ok": false, "code": "modal_kind_unknown"}


## 年鉴：公开入口是 GameUIManager.dismiss_overlay_menu()（ESC / 关闭按钮走的同一条），
## 它内部就是让年鉴工作区走它自己的 _close()，再由 closed 信号触发
## AnnualReportFlow._on_closed → _restore_clock —— 与玩家点关闭完全同一条链路。
## 没有每卷不同的 key（关掉即消失），所以 key 为空、可重复处理。
func _close_annual_report() -> Dictionary:
	if _ui == null or not _ui.has_method("is_annual_report_open"):
		return {"ok": false, "code": "annual_report_api_missing"}
	if not bool(_ui.call("is_annual_report_open")):
		return {"ok": true, "via": "GameUIManager.dismiss_overlay_menu"}
	if not _ui.has_method("dismiss_overlay_menu"):
		return {"ok": false, "code": "annual_report_dismiss_api_missing"}
	_ui.call("dismiss_overlay_menu")
	# 复核：没关掉就不算成功（计入重试预算，最终由 modal_undismissable 报出来）。
	if bool(_ui.call("is_annual_report_open")):
		return {"ok": false, "code": "annual_report_still_open"}
	return {"ok": true, "via": "GameUIManager.dismiss_overlay_menu"}


## 纪元奖励：没有"永久关闭"的公开入口 —— dismiss_era_reward_offer() 只收起弹窗，
## native 侧仍是 OPEN，下一次 _sync_era_reward_offer 会再锁一次（对无人值守等于死循环）。
## 所以走选择：与 UI 的 era_reward_choice_requested → _on_era_reward_choice_requested
## 完全相同的公开命令入口，并如实记一条 autotest_modal_dismissed（跳过了一次玩家决策）。
func _choose_era_reward() -> Dictionary:
	var offer := _era_reward_offer()
	var generation := int(offer.get("offer_generation", 0))
	var alternatives: Array = offer.get("alternatives", [])
	if generation <= 0 or alternatives.is_empty():
		return {"ok": false, "code": "era_reward_offer_incomplete"}
	# 候选下标必须在有效范围内：优先沿用已选中的那个，否则取 0 号。
	var choice := int(offer.get("selected_choice", -1))
	if choice < 0 or choice >= alternatives.size():
		choice = 0
	# 命令名与 PlayerController.COMMAND_ERA_REWARD_CHOOSE 同值；用字面量保持松耦合，
	# 万一常量改名，这里只会在 last_code 里回报错误而不会编译失败。
	var result: Dictionary = _controller.call("request_command", &"era_reward.choose", {
		"offer_generation": generation,
		"choice_index": choice,
	})
	if not bool(result.get("ok", false)):
		return {"ok": false, "code": String(result.get("code", "")),
			"message": String(result.get("message", ""))}
	return {"ok": true, "via": "PlayerController.request_command(era_reward.choose)"}


## 家族创立：没有"关闭"入口，公开链路只有 COMMAND_FAMILY_FOUNDING_CHOOSE
## （UI 的 family_founding_choice_requested 走的就是它）。取第一个待玩家选择的 OPEN
## offer，选 0 号候选，同样如实记录跳过。
func _choose_family_founding() -> Dictionary:
	var offer := _family_founding_offer()
	if offer.is_empty():
		return {"ok": false, "code": "family_founding_offer_missing"}
	var result: Dictionary = _controller.call("request_command",
		&"family.founding.choose", {
			"offer_id": int(offer.get("offer_id", 0)),
			"generation": int(offer.get("generation", 0)),
			"choice_index": 0,
		})
	if not bool(result.get("ok", false)):
		return {"ok": false, "code": String(result.get("code", "")),
			"message": String(result.get("message", ""))}
	return {"ok": true, "via": "PlayerController.request_command(family.founding.choose)"}


## 理念抽取：dismiss_ideology_offer() 就是玩家点"稍后再说"调的那个公开方法。
## 它是 void，所以关完立刻回读 phase 复核，确实清空才算成功（否则计入重试预算）。
func _close_ideology_offer() -> Dictionary:
	if not _controller.has_method("dismiss_ideology_offer"):
		return {"ok": false, "code": "ideology_dismiss_api_missing"}
	_controller.call("dismiss_ideology_offer")
	if not _ctrl_str("ideology_draw_phase").is_empty():
		return {"ok": false, "code": "ideology_still_presenting"}
	return {"ok": true, "via": "PlayerController.dismiss_ideology_offer"}


## 纪元奖励状态（CountryFacade 的公开只读查询，PlayerController 自己也是这么读的）。
func _era_reward_offer() -> Dictionary:
	if _controller == null or not _controller.has_method("get_country_facade"):
		return {}
	var facade = _controller.call("get_country_facade")
	if facade == null or not facade.has_method("era_reward_offer"):
		return {}
	var offer: Dictionary = facade.call("era_reward_offer")
	return offer if bool(offer.get("ok", false)) else {}


## 当前待玩家选择的家族创立 offer（与 PlayerController._sync_family_founding_offer
## 使用同一套筛选规则：player_choice 且 status==OPEN 的第一个）。
func _family_founding_offer() -> Dictionary:
	if _controller == null or not _controller.has_method("get_economy_facade"):
		return {}
	var facade = _controller.call("get_economy_facade")
	if facade == null or not facade.has_method("family_founding_offers"):
		return {}
	var snapshot: Dictionary = facade.call("family_founding_offers", 0, 64)
	if not bool(snapshot.get("ok", false)):
		return {}
	for row in snapshot.get("offers", []):
		if bool(row.get("player_choice", false)) \
				and String(row.get("status", "")) == "OPEN":
			return row
	return {}


## 读 PlayerController 的既有公开布尔查询；缺方法一律当 false（不锁）。
func _ctrl_bool(method_name: String) -> bool:
	if _controller == null or not _controller.has_method(method_name):
		return false
	return bool(_controller.call(method_name))


## 读 PlayerController 的既有公开字符串查询；缺方法返回空串。
func _ctrl_str(method_name: String) -> String:
	if _controller == null or not _controller.has_method(method_name):
		return ""
	return String(_controller.call(method_name))


## 达成目标天数：打 autotest_pass 并停止跟车。不暂停时钟 —— 收尾动作留给协调者，
## 免得 soak 自己改变了它正在测量的运行时状态。
func pass_soak(day: int) -> void:
	if _finished:
		return
	_finished = true
	var now_msec := Time.get_ticks_msec()
	_report("autotest_pass", {
		"day": day,
		"target_days": _target_days,
		"wall_s": _wall_seconds(now_msec),
		"days_per_s": _days_per_second(day, now_msec),
	})
	set_process(false)


## 失败出口：reason 是给协调者机读的原因码，其余字段是当场现场。
## 只发一次后停止轮询，避免一个卡死把上千条事件灌进 jsonl。
func fail(reason: String, fields: Dictionary = {}) -> void:
	if _finished or not _running:
		return
	_finished = true
	var payload := fields.duplicate(true)
	payload["reason"] = reason
	payload["day"] = _last_day if _world_in else -1
	payload["wall_s"] = _wall_seconds(Time.get_ticks_msec())
	payload["world_in"] = _world_in
	# 若最近提交过弹窗代选却迟迟没结算，把"卡在哪一步、等了多久"一并写进失败事件。
	if not _modal_submitted.is_empty():
		payload["modal_submitted"] = String(_modal_submitted.get("kind", ""))
		payload["modal_submitted_key"] = String(_modal_submitted.get("key", ""))
		payload["modal_stuck_ms"] = Time.get_ticks_msec() \
			- int(_modal_submitted.get("msec", 0))
	_report("autotest_fail", payload)
	set_process(false)


## 自 autotest 起点（主菜单读数那一刻）起的墙钟秒数。
func _wall_seconds(now_msec: int) -> float:
	if _started_msec <= 0:
		return 0.0
	return float(now_msec - _started_msec) / 1000.0


## 平均吞吐（含建世界时间）。故意用平均值而不是瞬时值：soak 验收看的是总账。
func _days_per_second(day: int, now_msec: int) -> float:
	var wall_s := _wall_seconds(now_msec)
	if wall_s <= 0.01:
		return 0.0
	return float(day) / wall_s


## 暂停 / 停滞时尽力标出"是谁按住的"：纪元奖励、意识形态抽卡、家族创立这几个
## 选择弹窗都会 lock 会话并 pause(true)。只报 clock_paused 的话协调者还得再猜一轮。
func _blocked_by() -> String:
	if _clock != null and bool(_clock.authority_fault_hold):
		return "authority_fault_hold"
	# 年鉴排在最前：它与 PlayerController 的锁可以同时存在，且优先级更高
	# （GameUIManager.dismiss_overlay_menu 也是先处理年鉴）。
	if _ui != null and _ui.has_method("is_annual_report_open") \
			and bool(_ui.call("is_annual_report_open")):
		return "annual_report"
	if _controller == null:
		return "unknown"
	for pair in [
		["era_reward_locked", "era_reward_offer"],
		["ideology_draw_locked", "ideology_draw"],
		["family_founding_locked", "family_founding_offer"],
	]:
		# 这些 getter 属于 PlayerController 的既有公开查询面；缺任一方法都当"未锁"。
		if _ctrl_bool(String(pair[0])):
			return String(pair[1])
	# 经济日结撞到守恒致命错误时，EconomyDailySystem 会直接 pause(true)（没有弹窗、
	# 没有 UI 入口）。把它读出来，否则这里只能报一个含糊的 unknown。
	# 只在失败路径调用，取一次快照的成本可以接受。
	if _host != null and _host.has_method("generator"):
		var generator = _host.call("generator")
		if generator != null and generator.has_method("get_economy_report"):
			var report: Dictionary = generator.call("get_economy_report")
			var fatal := String(report.get("fatal_reason", ""))
			if not fatal.is_empty() and fatal != "missing" and fatal != "ok":
				return "economy_fatal:%s" % fatal
	return "unknown"
