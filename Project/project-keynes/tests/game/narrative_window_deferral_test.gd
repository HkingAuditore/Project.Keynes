extends SceneTree

## [popup-deferral 2026-11-20] 玩家正在读自己的窗口（科技 / 经济(税收) / 军事 / 政治 /
## 外交国家卷宗，营造、家族档案、军务档案、派遣、议和、史册、GM、时代纸笺）时，
## 叙事事件不再关掉窗口抢焦点：时钟先停下、响一声提示，弹窗留到窗口关闭那一刻。
## 这里守住四件事：
##   1) 窗口开着 → 不弹、不锁、时钟停下，offer 留在服务里；
##   2) 窗口关掉 → 同一份 offer 立刻展开，锁与暂停快照接得上；
##   3) 关闭弹窗后回到「静置前那一刻」的暂停/倍速，而不是停在暂停；
##   4) 静置期间打开 GM 屏蔽 → 自动确认并释放时钟，不留残余暂停。

const Flow = preload("res://scripts/narrative/narrative_event_flow.gd")
const Service = preload("res://scripts/narrative/narrative_event_service.gd")
const Catalog = preload("res://scripts/narrative/narrative_event_catalog.gd")
const GameAudioScript = preload("res://scripts/audio/game_audio_service.gd")

var failures := 0
var checks := 0
var audio_stub = null
var renamed_autoload = null

class ControllerStub extends Node:
	var service
	var flow
	var busy := false
	func era_reward_locked() -> bool: return busy
	func family_founding_locked() -> bool: return false
	func ideology_draw_locked() -> bool: return false
	func ideology_draw_phase() -> String: return ""
	func sync_ui() -> void: flow.try_present()
	func clear_cell_highlights() -> void: pass
	func request_command(_id: StringName, args: Dictionary) -> Dictionary:
		return service.choose_option(args.offer_id, args.offer_generation, args.option_index, 21)

class UiStub extends RefCounted:
	var opened := 0
	var is_open := false
	var workspace_open := false
	func show_narrative_event_offer(_offer: Dictionary) -> void:
		opened += 1
		is_open = true
	func show_narrative_event_outcome(_resolution: Dictionary) -> void: pass
	func close_narrative_event_offer() -> void: is_open = false
	func is_narrative_event_modal_open() -> bool: return is_open
	func is_player_workspace_open() -> bool: return workspace_open
	func is_annual_report_open() -> bool: return false
	func is_era_ceremony_playing() -> bool: return false

class AudioStub extends Node:
	var cues: Array[StringName] = []
	func play_event_cue(cue: StringName, _world_pos: Vector2 = Vector2.INF) -> bool:
		cues.append(cue)
		return true

func _init() -> void:
	call_deferred("_run")

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)

func _build() -> Dictionary:
	var clock := WorldClock.new()
	clock.set_speed(5.0)
	var catalog = Catalog.build_default_catalog()
	var service = Service.new()
	service.configure(null, null, null, clock, 1, 877972513, catalog)
	var controller := ControllerStub.new()
	controller.name = "ControllerStub"
	controller.service = service
	var ui := UiStub.new()
	var flow = Flow.new()
	controller.flow = flow
	flow.configure(controller, null, clock, ui, service)
	get_root().add_child(controller)
	return {"clock": clock, "catalog": catalog, "service": service,
		"controller": controller, "ui": ui, "flow": flow}

func _enqueue(ctx: Dictionary) -> void:
	ctx.service.enqueue_event_offer(
		ctx.catalog.get_event(&"evt.climate.severe_drought"), 3, 20, &"", true,
		{"cell_idx": 3, "population": 40})

func _teardown(ctx: Dictionary) -> void:
	ctx.flow.set_popups_suppressed(false)
	ctx.controller.flow = null
	ctx.controller.get_parent().remove_child(ctx.controller)
	ctx.controller.free()
	ctx.clock.free()

## 静置提示音走 /root/GameAudio。无头跑时那个名字是 autoload（status=headless_disabled），
## 会吞掉一切 cue，测不出「响了一声」，所以测试期间临时改名，让桩接管这个路径。
func _install_audio_stub() -> bool:
	var root := get_root()
	var existing := root.get_node_or_null("GameAudio")
	if existing != null:
		renamed_autoload = existing
		renamed_autoload.name = "GameAudioUnderTest"
	audio_stub = AudioStub.new()
	audio_stub.name = "GameAudio"
	root.add_child(audio_stub)
	return true


func _restore_autoload() -> void:
	if audio_stub != null:
		get_root().remove_child(audio_stub)
		audio_stub.free()
		audio_stub = null
	if renamed_autoload != null:
		renamed_autoload.name = "GameAudio"
		renamed_autoload = null

func _run() -> void:
	var cue_ready := _install_audio_stub()
	_expect("deferral cue key is a baked event cue",
		GameAudioScript.EVENT_CUES.has(Flow.DEFERRAL_CUE))
	for initial_paused in [false, true]:
		var ctx := _build()
		var clock = ctx.clock
		var flow = ctx.flow
		var ui = ctx.ui
		clock.pause(initial_paused)
		ui.workspace_open = true
		if audio_stub != null:
			audio_stub.cues.clear()

		# ── 1) 窗口开着：静置而不是抢窗口 ──
		_enqueue(ctx)
		flow.try_present()
		_expect("workspace open keeps the modal closed", ui.opened == 0 and not ui.is_open)
		_expect("deferred offer stays pending in the service",
			flow.is_deferred() and ctx.service.has_active_offer())
		_expect("deferred offer does not take the modal lock", not flow.is_locked())
		_expect("deferring pauses the running clock", clock.paused)
		_expect("deferring registers one pause snapshot", bool(flow.capture().restore_pending))
		_expect("deferral arms the safety retry", bool(flow._deferred_retry_scheduled))
		if cue_ready:
			_expect("deferring plays exactly one cue",
				audio_stub.cues.size() == 1 and audio_stub.cues[0] == Flow.DEFERRAL_CUE)
			# 重复自查不能把提示音刷成噪音。
			flow.try_present()
			_expect("repeat checks do not replay the cue", audio_stub.cues.size() == 1)

		# ── 2) 窗口关掉：同一份 offer 立刻展开 ──
		ui.workspace_open = false
		flow.try_present()
		_expect("closing the workspace presents the held offer",
			ui.opened == 1 and ui.is_open and flow.is_locked() and not flow.is_deferred())
		_expect("presented deferral keeps the clock paused", clock.paused)

		# ── 3) 关闭弹窗回到静置前的现场 ──
		var offer: Dictionary = ctx.service.active_offer()
		flow.on_option_chosen(int(offer.offer_id), int(offer.offer_generation), 0)
		flow.on_outcome_acknowledged()
		_expect("resolving returns to the pre-deferral pause state",
			clock.paused == initial_paused and clock.speed_multiplier == 5.0)
		_expect("resolving clears the modal lock and the deferral",
			not flow.is_locked() and not flow.is_deferred()
			and not bool(flow.capture().restore_pending))
		_teardown(ctx)

	# ── 4) 静置期间玩家自己改了速度：关窗后仍按玩家最新速度继续 ──
	var resumed := _build()
	resumed.ui.workspace_open = true
	_enqueue(resumed)
	resumed.flow.try_present()
	resumed.clock.pause(false)
	resumed.clock.set_speed(2.0)
	# 静置期间玩家自己按了继续：兜底重试不能把他按回暂停。
	resumed.flow.try_present()
	_expect("holding does not override a manual resume", not resumed.clock.paused)
	resumed.ui.workspace_open = false
	resumed.flow.try_present()
	_expect("manual resume during the hold still presents the event",
		resumed.ui.opened == 1 and resumed.flow.is_locked())
	var resumed_offer: Dictionary = resumed.service.active_offer()
	resumed.flow.on_option_chosen(
		int(resumed_offer.offer_id), int(resumed_offer.offer_generation), 0)
	resumed.flow.on_outcome_acknowledged()
	_expect("post-hold resolution honours the player's latest speed",
		not resumed.clock.paused and resumed.clock.speed_multiplier == 2.0)
	_teardown(resumed)

	# ── 5) 静置期间打开 GM 屏蔽：自动确认并释放时钟，不留残余暂停 ──
	var suppressed := _build()
	suppressed.ui.workspace_open = true
	_enqueue(suppressed)
	suppressed.flow.try_present()
	suppressed.flow.set_popups_suppressed(true)
	# 真机上屏蔽开关由 GM 触发并顺带 sync_ui；测试不跑帧，这里显式重查一次。
	suppressed.flow.try_present()
	_expect("popup suppression resolves a deferred offer without a modal",
		suppressed.ui.opened == 0 and not suppressed.flow.is_locked()
		and not suppressed.flow.is_deferred()
		and suppressed.service.chronicle_total_count() == 1)
	_expect("suppression releases the held pause",
		not suppressed.clock.paused and not bool(suppressed.flow.capture().restore_pending))
	_teardown(suppressed)

	if audio_stub != null:
		_restore_autoload()
	print("narrative_window_deferral_test: %d checks, %d failures (cue=%s)" % [
		checks, failures, str(cue_ready)])
	quit(0 if failures == 0 else 1)
