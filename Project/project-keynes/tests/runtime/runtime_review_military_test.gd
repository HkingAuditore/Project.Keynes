extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

func _run() -> void:
	await _run_world(false, true)
	_finish()


func _sample_military_world(host: WorldRuntimeHost, clock: WorldClock) -> Dictionary:
	var scenario := MilitaryScenario.new(host, _expect)
	if not await scenario.ready(MAX_SLICES_PER_DAY):
		return {}
	var generator := host.get_generator()
	var military: MilitaryFacade = generator.get_military_facade()
	var player := PlayerController.new()
	root.add_child(player)
	player.configure(null, null, host, clock, null)
	player.refresh_country_binding()
	var handle := player.get_player_country_handle()
	var capital := int(generator.gameplay_start_report().cell)
	var results := {}
	player.command_settled.connect(func(_id: StringName, reply: Dictionary) -> void:
		results[int(reply.get("sequence", -1))] = reply)
	clock.set_speed(SPEED)
	clock.current_day = 1.0
	var no_garrison := player.request_command(&"military.train", {
		"cell": capital, "from": "militia", "to": "militia", "count": 1})
	var zero_budget := military.submit([{"op": "policy.set_budget", "country": handle,
		"value": 10000, "int_pairs": PackedInt32Array([0, 0, 0]), "caller_sequence": 7100}])
	print("REVIEW_OPENING train=", no_garrison, " budget=", zero_budget)
	_expect("zero-garrison training and empty budget are dated", no_garrison.get("admitted") == true
		and zero_budget.get("effective_day") == no_garrison.get("effective_day"))
	for day in range(1, 21):
		scenario.issue_for_day(day)
		_publish_day(host, clock, day)
		if not await _wait_golden_read_boundary(host, scenario.economy, day):
			_expect("military fixture settles day %d" % day, false)
			break
		await scenario.collect_day(day, MAX_SLICES_PER_DAY)
		if day == int(no_garrison.get("effective_day", -1)):
			var terminal: Dictionary = results.get(no_garrison.sequence, {})
			print("REVIEW_TRAIN_TERMINAL=", terminal)
			_expect("available garrison zero produces a dated terminal rejection",
				terminal.get("code") == "command_no_training_garrison"
				and terminal.get("settled_day") == day
				and terminal.get("message") == "当地没有可用于训练的驻军。")
		if day != 20:
			continue
		clock.current_day = float(day + 1)
		var wage := military.submit([{"op": "policy.set_budget", "country": handle,
			"value": 10000, "int_pairs": PackedInt32Array([6000, -1, -1]), "caller_sequence": 7101}])
		var upkeep := military.submit([{"op": "policy.set_budget", "country": handle,
			"value": 10000, "int_pairs": PackedInt32Array([-1, 6000, -1]), "caller_sequence": 7102}])
		var armies: Array = military.armies(handle)
		_expect("formal military fixture created the field army", armies.size() == 1)
		var army := int(armies[0].handle) if armies.size() == 1 else 0
		var began := player.begin_military_arm_order(army, "explore", 1)
		var target := scenario._find_march_target()
		_expect("the UI arms exploration and selects a center",
			began.get("ok") == true and target >= 0 and player.military_arm_order_click(target))
		var explore := player.confirm_military_arm_order()
		print("REVIEW_BUDGET_TICKETS wage=", wage, " upkeep=", upkeep, " explore=", explore)
		var next_day := day + 1
		_expect("all three UI requests admitted with the same date", wage.get("effective_day") == next_day
			and upkeep.get("effective_day") == next_day and explore.get("effective_day") == next_day)
		_publish_day(host, clock, next_day)
		_expect("the day settles", await _wait_golden_read_boundary(host, scenario.economy, next_day))
		var task: Dictionary = military.army(army).get("exploration", {})
		print("REVIEW_EXPLORE ticket=", explore, " terminal=", results.get(explore.get("sequence", -1), {}),
			" task=", task)
		_expect("center plus radius produces a native exploration task on the admitted day",
			int(task.get("started_day", -1)) == next_day and int(task.get("selected", 0)) > 1)
		var policy: Dictionary = military.country_snapshot(handle)
		var refusal: Dictionary = results.get(7102, {})
		print("REVIEW_BUDGET wage=", policy.get("budget_wage_bp"), " upkeep=", policy.get("budget_upkeep_bp"),
			" terminal=", refusal)
		_expect("same-day 60% + 60% keeps the first edit and rejects only the second",
			policy.get("budget_wage_bp") == 6000 and policy.get("budget_upkeep_bp") == 0
			and refusal.get("code") == "command_budget_channels_exceed_10000")
		break
	player.free()
	return {}
