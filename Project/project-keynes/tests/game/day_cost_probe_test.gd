extends SceneTree

## Web 单日成本探针（WorldClock.day_cost_*）的离线契约测试。
##
## 这个探针的目标不是"跑得快"，而是**不撒谎**：day_cost 事件必须能用来判定
## "一个模拟日的钱花在谁身上"。所以这里锁死的是契约，不是数字：
##
##   1. 桌面默认关闭：不开探针时累加器不收数据、不 flush、不产事件。
##   2. epoch 累加器语义：同一天同一 tag 的多次 add 是**求和**（代表不同段），
##      flush 后桶清空，下一天不会把上一天的数字再算一遍——这是"重复计数"
##      最容易踩的坑，见 tmp/next/day_cost_IMPL.md §2。
##   3. 每天恰好 flush 一次：N 次 _advance_one_sim_day → N 组事件，
##      且事件里的 d 是**刚跑完的那一天**。
##   4. 事件体积：带 WebTelemetry 信封的 JSON 必须 < 200 字节（core / seg /
##      main 三条各自独立判定）；极端尖峰（单段 >999ms）退化成紧凑 v 形态后
##      仍 < 200。
##   5. 派生段 pc = clk − host（两个各自只测一次的 epoch 相减）。
##   6. WorldRuntimeHost._dcp_on() 跟随 clock 的开关，桌面因此恒假。
##
## 运行：
##   Godot --headless --path Project/project-keynes \
##       --script res://tests/game/day_cost_probe_test.gd

const WorldClockScript = preload("res://scripts/geography/world_clock.gd")
const CORE_TAGS: Array[StringName] = [
	&"clk", &"host", &"inl", &"cmt", &"pc", &"pcui", &"s1", &"s2",
]
const DETAIL_TAGS: Array[StringName] = [
	&"rep", &"wb", &"pcr", &"cap", &"pub", &"fin", &"res", &"vis", &"wait", &"dup",
]
const MAIN_TAGS: Array[StringName] = [
	&"main", &"lab", &"sph", &"ren", &"mui", &"ovl", &"rec",
]
const PAYLOAD_BUDGET_BYTES := 200

var _failures := 0
var _checks := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_desktop_default_off()
	_test_epoch_accumulator_semantics()
	_test_one_flush_per_day()
	_test_payload_budget()
	_test_compact_fallback()
	_test_derived_player_controller_segment()
	_test_host_gate_follows_clock()
	_test_day_advance_claim()
	_test_daily_tick_executors_are_scene_exclusive()
	_finish()


# ─── 1. 桌面默认关闭 ─────────────────────────────────────────────────────

func _test_desktop_default_off() -> void:
	var clock = WorldClockScript.new()
	_expect("headless 不是 web feature", not OS.has_feature("web"))
	_expect("探针默认关闭（未进树，_ready 未跑）", not clock.day_cost_probe_on)
	clock.day_cost_add(&"clk", 12.5)
	clock.day_cost_job("economy_daily", 9.0)
	clock.day_cost_flush()
	_expect("关闭时累加器不收数据", clock.day_cost_last().is_empty())
	_expect("关闭时 seg/main/sus 都是空", clock.day_cost_last_seg().is_empty()
		and clock.day_cost_last_main().is_empty() and clock.day_cost_last_sus().is_empty())
	_expect("关闭时不产生任何 day_cost 事件", clock.day_cost_emitted_count() == 0)
	clock.free()


# ─── 2. epoch 累加器语义 ──────────────────────────────────────────────────

func _test_epoch_accumulator_semantics() -> void:
	var clock := _make_clock(10)
	# 第 10 天：两段不同的墙钟（不同产出方）→ 求和，不是覆盖。
	clock.day_cost_add(&"clk", 4.0)
	clock.day_cost_add(&"clk", 6.0)
	clock.day_cost_add(&"s1", 3.0)
	clock._advance_one_sim_day()  # flush d=10
	_expect("一天内的多段 add 求和", int(clock.day_cost_last()["clk"]) == 10)
	_expect("flush 后事件属于刚跑完的那一天", int(clock.day_cost_last()["d"]) == 10)
	# 第 11 天：必须从 0 起算，不能把第 10 天的 10ms 再算一遍。
	clock.day_cost_add(&"clk", 7.0)
	clock._advance_one_sim_day()  # flush d=11
	_expect("flush 后桶清空，下一天不重复计入", int(clock.day_cost_last()["clk"]) == 7)
	_expect("s1 只在第 10 天出现", int(clock.day_cost_last()["s1"]) == 0)
	# 细分段同理：第 10 天的 wb 不能漏到第 11 天，也不能在第 11 天为 0 时还发事件。
	clock.day_cost_add(&"wb", 5.0)
	clock._advance_one_sim_day()  # flush d=12
	_expect("细分段跟着自己那天 flush", int(clock.day_cost_last_seg()["wb"]) == 5)
	clock.day_cost_add(&"clk", 1.0)
	clock._advance_one_sim_day()  # flush d=13，细分全 0
	_expect("细分全 0 时不发 day_cost_seg", clock.day_cost_last_seg().is_empty())
	clock.free()


# ─── 3. 每天恰好一组 ─────────────────────────────────────────────────────

func _test_one_flush_per_day() -> void:
	var clock := _make_clock(100)
	var days := 5
	for i in range(days):
		clock.day_cost_add(&"host", 20.0)
		clock._advance_one_sim_day()
	_expect("N 次日推进 → N 条 day_cost", clock.day_cost_emitted_count() == days)
	_expect("最后一条事件的 d = 最后跑完的那一天",
		int(clock.day_cost_last()["d"]) == 100 + days - 1)
	# 推进循环本身会给"新的一天"记一个 clk（它在 day_changed 派发之后才 add），
	# 所以桶里还剩那一段。它只应该被发一次；再 flush 必须是空桶 no-op。
	var before := clock.day_cost_emitted_count()
	clock.day_cost_flush()
	var after_first := clock.day_cost_emitted_count()
	clock.day_cost_flush()
	_expect("残留的 clk 只发一次", after_first == before + 1)
	_expect("空桶 flush 不重复发事件", clock.day_cost_emitted_count() == after_first)
	clock.free()


# ─── 4. 事件体积 ─────────────────────────────────────────────────────────

func _test_payload_budget() -> void:
	var clock := _make_clock(1)
	# 实测稳态量级：单日各段落在三位数毫秒以内（这是最容易顶到上限的档）。
	for tag in CORE_TAGS:
		clock.day_cost_add(tag, 123.0)
	for tag in DETAIL_TAGS:
		clock.day_cost_add(tag, 123.0)
	for tag in MAIN_TAGS:
		clock.day_cost_add(tag, 123.0)
	clock._advance_one_sim_day()
	var core: Dictionary = clock.day_cost_last()
	var seg: Dictionary = clock.day_cost_last_seg()
	var main: Dictionary = clock.day_cost_last_main()
	_expect("core 段数量与常量一致", core.size() == CORE_TAGS.size() + 1)
	_expect("seg 段数量与常量一致", seg.size() == DETAIL_TAGS.size() + 1)
	_expect("main 段数量与常量一致", main.size() == MAIN_TAGS.size() + 1)
	_expect("core/seg/main 都是带键形态（未触发紧凑退化）",
		not core.has("v") and not seg.has("v") and not main.has("v"))
	var b_core := _wire_bytes("day_cost", core)
	var b_seg := _wire_bytes("day_cost_seg", seg)
	var b_main := _wire_bytes("day_cost_main", main)
	print("[day-cost-probe] core=%dB seg=%dB main=%dB" % [b_core, b_seg, b_main])
	print("[day-cost-probe] core: ", JSON.stringify(core))
	print("[day-cost-probe] seg : ", JSON.stringify(seg))
	print("[day-cost-probe] main: ", JSON.stringify(main))
	_expect("core payload < 200 字节（含信封）", b_core < PAYLOAD_BUDGET_BYTES)
	_expect("seg payload < 200 字节（含信封）", b_seg < PAYLOAD_BUDGET_BYTES)
	_expect("main payload < 200 字节（含信封）", b_main < PAYLOAD_BUDGET_BYTES)
	clock.free()


# ─── 5. 极端尖峰走紧凑形态 ───────────────────────────────────────────────

func _test_compact_fallback() -> void:
	var clock := _make_clock(1)
	# 只有真正病态的单段才顶得动 core 的 200 字节上限（1e12ms 量级仍刚好放得下，
	# 1e15 才会退化）。这条断言守的是"绝不会因为一次异常长帧把事件撑爆"。
	for tag in CORE_TAGS:
		clock.day_cost_add(tag, 1.0e15)
	clock._advance_one_sim_day()
	var core: Dictionary = clock.day_cost_last()
	_expect("尖峰退化为紧凑 v 形态", core.has("v") and not core.has("clk"))
	var bytes := _wire_bytes("day_cost", core)
	print("[day-cost-probe] 尖峰 core=%dB: %s" % [bytes, JSON.stringify(core)])
	_expect("尖峰 payload 仍 < 200 字节", bytes < PAYLOAD_BUDGET_BYTES)
	_expect("紧凑形态保留全部 core 段",
		String(core.get("v", "")).split(" ").size() == CORE_TAGS.size())
	clock.free()


# ─── 6. 派生段 pc = clk − host ────────────────────────────────────────────

func _test_derived_player_controller_segment() -> void:
	var clock := _make_clock(7)
	clock.day_cost_add(&"host", 30.0)
	clock.day_cost_add(&"clk", 80.0)
	clock._advance_one_sim_day()
	_expect("pc = clk − host", int(clock.day_cost_last()["pc"]) == 50)
	# host 缺失（main.tscn 那套监听者）时不得瞎算。
	var clock2 := _make_clock(8)
	clock2.day_cost_add(&"clk", 80.0)
	clock2._advance_one_sim_day()
	_expect("host 缺席时 pc 不做减法", int(clock2.day_cost_last()["pc"]) == 0)
	clock.free()
	clock2.free()


# ─── 7. host 侧门跟随 clock ──────────────────────────────────────────────

func _test_host_gate_follows_clock() -> void:
	var host_script = load("res://scripts/game/world_runtime_host.gd")
	if host_script == null:
		_expect("world_runtime_host.gd 可加载", false)
		return
	var clock = WorldClockScript.new()
	var host = host_script.new()
	_expect("host 无 clock 时探针门关闭", not bool(host.call("_dcp_on")))
	host.set("_world_clock", clock)
	_expect("host 探针门跟随 clock（默认关）", not bool(host.call("_dcp_on")))
	clock.day_cost_probe_on = true
	_expect("host 探针门跟随 clock（开启后为真）", bool(host.call("_dcp_on")))
	host.free()
	clock.free()


# ─── 8. 单日单推进声明 ───────────────────────────────────────────────────

func _test_day_advance_claim() -> void:
	var clock = WorldClockScript.new()
	_expect("首个执行者拿到当天声明", clock.claim_day_advance(&"native_inline", 5))
	_expect("同一 day 的第二个人拿不到", not clock.claim_day_advance(&"main_sus", 5))
	_expect("声明所有者仍是第一个执行者", clock.day_advance_owner() == &"native_inline")
	_expect("撞车计数 = 1", clock.day_advance_duplicate_count() == 1)
	_expect("跨日后重新开放", clock.claim_day_advance(&"main_sus", 6))
	_expect("跨日后所有者更新", clock.day_advance_owner() == &"main_sus")
	clock.free()


# ─── 9. 日级执行者在场景上是互斥的（根因证据）────────────────────────────

func _test_daily_tick_executors_are_scene_exclusive() -> void:
	# 生产玩家场景只有 WorldRuntimeHost（+ PlayerController），调试场景只有
	# main.gd。两者不可能同时监听同一个 WorldClock —— 这是"sus_tick_daily 被调
	# 两次"这一假设不成立的根因，锁成测试以免将来被静默改坏。
	var player_scene := FileAccess.get_file_as_string("res://scenes/player_game.tscn")
	var main_scene := FileAccess.get_file_as_string("res://scenes/main.tscn")
	_expect("player_game.tscn 存在", not player_scene.is_empty())
	_expect("main.tscn 存在", not main_scene.is_empty())
	_expect("player_game.tscn 有 RuntimeHost 节点", player_scene.contains("[node name=\"RuntimeHost\""))
	_expect("main.tscn 没有 RuntimeHost 节点", not main_scene.contains("RuntimeHost"))
	_expect("player_game.tscn 不挂 main.gd", not player_scene.contains("main.gd"))
	_expect("main.tscn 挂的是 main.gd", main_scene.contains("res://scripts/main.gd"))
	# 生产入口只能是 player_game.tscn：GameFlowService 的 PLAYER_GAME_SCENE。
	var flow_src := FileAccess.get_file_as_string("res://scripts/game/game_flow_service.gd")
	_expect("GameFlow 只加载 player_game.tscn",
		flow_src.contains("PLAYER_GAME_SCENE := \"res://scenes/player_game.tscn\""))


# ─── 工具 ────────────────────────────────────────────────────────────────
## 一个不在场景树里的 WorldClock：_ready 不跑，所以探针开关与 RNG 显式给。
func _make_clock(start_day: int) -> WorldClock:
	var clock := WorldClock.new()
	clock.day_cost_probe_on = true
	clock._rng = RandomNumberGenerator.new()
	clock._last_day = start_day
	clock._last_season = clock.season_index_for_day(start_day)
	clock._last_year = clock.year_index_for_day(start_day)
	clock._dcp_day = start_day
	return clock


## 复刻 WebTelemetry.emit 的信封，量出真正上线的字节数。
func _wire_bytes(event_name: String, payload: Dictionary) -> int:
	var wire: Dictionary = {"e": event_name, "ms": 1793000000000}
	for key in payload.keys():
		wire[String(key)] = payload[key]
	return JSON.stringify(wire).to_utf8_buffer().size()


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("[day-cost-probe] PASS: %s" % label)
		return
	_failures += 1
	push_error("[day-cost-probe] FAIL: %s" % label)


func _finish() -> void:
	print("[day-cost-probe] %d checks, %d failure(s)" % [_checks, _failures])
	quit(_failures)
