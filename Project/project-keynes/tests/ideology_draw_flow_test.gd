extends SceneTree

## PlayerController ideology draw flow against stubs: preview gate, pause +
## single-day step, offer presentation, choose/reroll settlement, rejection,
## timeout and player_view persistence. No native runtime required.

const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")


class ClockStub:
	signal day_changed(day: int)
	signal season_changed(season: int)
	signal year_changed(year: int)
	signal visual_day_phase_changed(phase: float)
	signal speed_changed(speed: float)
	var paused := true
	var speed_multiplier := 4.0
	var day := 10

	func day_index() -> int:
		return day

	func pause(value: bool) -> void:
		paused = value

	func set_speed(value: float) -> void:
		speed_multiplier = value


class CountryFacadeStub:
	func cell_summary(_cell: int) -> Dictionary:
		return {"ok": true, "owned": true, "country_handle": 77}

	func bind_era_reward_player_country(_handle: int) -> Dictionary:
		return {"ok": true}


class GeneratorStub:
	var country := CountryFacadeStub.new()

	func gameplay_start_report() -> Dictionary:
		return {"ok": true, "cell": 3}

	func get_country_facade():
		return country


class HostStub:
	var gen := GeneratorStub.new()

	func generator():
		return gen

	func on_clock_running_changed(_running: bool) -> void:
		pass


class IdeologyStub:
	var points := 0
	var offer_active := false
	var generation := 0
	var pool := 6
	var requests: Array = []

	func preview_offer_eligibility(_handle: int) -> Dictionary:
		var reason := ""
		if offer_active:
			reason = "ideology_offer_pending"
		elif points < 131072:
			reason = "ideology_points_insufficient"
		return {"ok": true, "can_draw": reason.is_empty(), "reason": reason,
			"can_reroll": offer_active and points >= 65536, "offer_active": offer_active,
			"pool_size": pool, "cost_q16": 131072}

	func snapshot(_handle: int) -> Dictionary:
		return {"ok": true, "offer_active": offer_active, "offer_generation": generation,
			"offer_ids": PackedInt32Array([0, 1, 2]) if offer_active else PackedInt32Array()}

	func request_offer(_handle: int, day: int, sequence: int) -> Dictionary:
		requests.append(["offer", day, sequence])
		return {"ok": true, "sequence": sequence, "effective_day": day}

	func choose_offer(_handle: int, gen: int, choice: int, day: int, sequence: int) -> Dictionary:
		requests.append(["choose", gen, choice, day, sequence])
		return {"ok": true, "sequence": sequence, "effective_day": day}

	func reroll_offer(_handle: int, gen: int, day: int, sequence: int) -> Dictionary:
		requests.append(["reroll", gen, day, sequence])
		return {"ok": true, "sequence": sequence, "effective_day": day}

	func equip(_handle: int, _idea: int, day: int, sequence: int) -> Dictionary:
		return {"ok": true, "sequence": sequence, "effective_day": day}


var _failures := 0
var _checks := 0


func _init() -> void:
	var fixture := _fixture()
	var controller = fixture.controller
	var clock: ClockStub = fixture.clock
	var ideology: IdeologyStub = fixture.ideology
	var ready_events: Array = []
	var phases: Array = []
	controller.ideology_offer_ready.connect(func(snapshot: Dictionary) -> void:
		ready_events.append(snapshot))
	controller.ideology_draw_state_changed.connect(func(phase: String, detail: Dictionary) -> void:
		phases.append([phase, detail]))

	# 1. Insufficient points: rejected without touching the clock.
	var rejected: Dictionary = controller.request_command(
		PlayerControllerScript.COMMAND_IDEOLOGY_OFFER)
	_expect("draw without points is rejected by the preview gate",
		not bool(rejected.get("ok", true))
		and String(rejected.get("code", "")) == "ideology_points_insufficient")
	_expect("rejected draw never advances time",
		clock.paused and is_equal_approx(clock.speed_multiplier, 4.0)
		and ideology.requests.is_empty())

	# 2. Paused draw: submit, run at 1x, lock other commands.
	ideology.points = 196608
	var drawn: Dictionary = controller.request_command(
		PlayerControllerScript.COMMAND_IDEOLOGY_OFFER)
	_expect("draw is accepted", bool(drawn.get("ok", false)))
	_expect("draw steps the paused clock at 1x",
		not clock.paused and is_equal_approx(clock.speed_multiplier, 1.0))
	_expect("draw locks other player commands", controller.ideology_draw_locked()
		and String(controller.request_command(
			PlayerControllerScript.COMMAND_IDEOLOGY_EQUIP, {"ideology_id": 1}).get("code", "")) \
			== "ideology_draw_in_progress")
	var state: Dictionary = controller.capture_view_state()
	_expect("player_view captures the in-flight draw",
		String(state.get("ideology_draw_phase", "")) == "offer"
		and bool(state.get("ideology_draw_clock_saved", false))
		and not bool(state.get("ideology_draw_resume_running", true)))

	# 3. Settlement publishes the offer: pause and present.
	clock.day = 11
	ideology.offer_active = true
	ideology.generation = 1
	controller._sync_ideology_draw()
	_expect("settled offer pauses the clock and emits offer_ready",
		clock.paused and ready_events.size() == 1
		and controller.ideology_draw_phase() == "presenting"
		and not controller.ideology_draw_locked())

	# 4. Reroll: same pause+step flow, new generation re-presents.
	var reroll: Dictionary = controller.request_command(
		PlayerControllerScript.COMMAND_IDEOLOGY_REROLL, {"offer_generation": 1})
	_expect("reroll is accepted and steps time",
		bool(reroll.get("ok", false)) and not clock.paused
		and controller.ideology_draw_phase() == "reroll")
	clock.day = 12
	ideology.generation = 2
	controller._sync_ideology_draw()
	_expect("rerolled offer is presented again",
		ready_events.size() == 2 and clock.paused)

	# 5. Choose: step one day, finish once the offer is consumed, restore clock.
	var chosen: Dictionary = controller.request_command(
		PlayerControllerScript.COMMAND_IDEOLOGY_CHOOSE,
		{"offer_generation": 2, "choice_index": 1})
	_expect("choose is accepted and steps time",
		bool(chosen.get("ok", false)) and not clock.paused
		and controller.ideology_draw_phase() == "choose")
	clock.day = 13
	ideology.offer_active = false
	controller._sync_ideology_draw()
	_expect("choosing restores the original paused clock and speed",
		controller.ideology_draw_phase().is_empty() and clock.paused
		and is_equal_approx(clock.speed_multiplier, 4.0))

	# 6. Running clock: restored to running after the draw.
	clock.paused = false
	clock.speed_multiplier = 2.0
	ideology.points = 196608
	controller.request_command(PlayerControllerScript.COMMAND_IDEOLOGY_OFFER)
	clock.day = 14
	ideology.offer_active = true
	ideology.generation = 3
	controller._sync_ideology_draw()
	controller.dismiss_ideology_offer()
	_expect("dismissing a presented offer restores the running clock",
		not clock.paused and is_equal_approx(clock.speed_multiplier, 2.0)
		and controller.ideology_draw_phase().is_empty())

	# 7. Rejection settlement unlocks with a reason.
	ideology.offer_active = false
	clock.paused = true
	clock.speed_multiplier = 4.0
	var seq_result: Dictionary = controller.request_command(
		PlayerControllerScript.COMMAND_IDEOLOGY_OFFER)
	controller._on_ideology_command_settled({"country_handle": 77, "opcode": 3,
		"sequence": int(seq_result.get("sequence", -1)), "ok": false,
		"reason": "ideology_offer_pool_insufficient"})
	var last: Array = phases[phases.size() - 1]
	_expect("native rejection unlocks, restores the clock and reports why",
		not controller.ideology_draw_locked() and clock.paused
		and String((last[1] as Dictionary).get("reason", "")) == "ideology_offer_pool_insufficient"
		and not String((last[1] as Dictionary).get("message", "")).is_empty())

	# 8. Timeout after three unsettled days.
	controller.request_command(PlayerControllerScript.COMMAND_IDEOLOGY_OFFER)
	clock.day += 4
	controller._sync_ideology_draw()
	last = phases[phases.size() - 1]
	_expect("an unsettled draw times out after three days",
		not controller.ideology_draw_locked() and clock.paused
		and String((last[1] as Dictionary).get("reason", "")) == "ideology_draw_timeout")

	# 9. Restore an in-flight draw from player_view and complete it.
	var restored_fixture := _fixture()
	var restored = restored_fixture.controller
	var restored_clock: ClockStub = restored_fixture.clock
	var restored_ideology: IdeologyStub = restored_fixture.ideology
	restored_clock.day = 11
	restored_ideology.offer_active = true
	restored_ideology.generation = 1
	restored.restore_view_state(null, state)
	_expect("restored draw resumes and presents the settled offer",
		restored.ideology_draw_phase() == "presenting" and restored_clock.paused)
	restored_ideology.offer_active = false
	restored._sync_ideology_draw()
	_expect("restored draw releases its saved clock once resolved",
		restored.ideology_draw_phase().is_empty()
		and is_equal_approx(restored_clock.speed_multiplier, 4.0))

	print("ideology draw flow: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _fixture() -> Dictionary:
	var controller = PlayerControllerScript.new()
	var clock := ClockStub.new()
	var ideology := IdeologyStub.new()
	controller.set("_runtime_host", HostStub.new())
	controller.set("_world_clock", clock)
	controller.set("_ideology_facade", ideology)
	controller.set("_player_country_handle", 77)
	return {"controller": controller, "clock": clock, "ideology": ideology}


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
