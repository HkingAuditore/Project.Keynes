extends Node

@onready var root: Window = get_tree().root

var _failures: int = 0

func _ready() -> void:
	call_deferred("_run")

func _expect(label: String, passed: bool) -> void:
	print("[%s] %s" % ["PASS" if passed else "FAIL", label])
	if not passed:
		_failures += 1

func _run() -> void:
	root.size = Vector2i(1280, 720)
	root.content_scale_factor = 1.0
	var worker: bool = not OS.get_cmdline_user_args().has("sync")
	var game := (load("res://scenes/player_game.tscn") as PackedScene).instantiate()
	var runtime: WorldRuntimeHost = game.get_node("RuntimeHost")
	var clock: WorldClock = game.get_node("WorldClock")
	clock.days_per_year_count = 24
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("year="):
			clock.days_per_year_count = int(argument.trim_prefix("year="))
	clock.auto_start = false
	runtime.runtime_shadow_on_generate = worker
	var saves = root.get_node("GameSave")
	var previous_autosave: bool = bool(saves.get("_autosave_enabled"))
	saves.set("_autosave_enabled", false)
	root.add_child(game)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("mask="):
			runtime.runtime_authority_domain_mask = int(arg.trim_prefix("mask="))
	await runtime.world_ready
	await get_tree().process_frame
	var controller = game.get_node("PlayerController")
	var ui: GameUIManager = game.get_node("UI")
	var ext = runtime.generator().get_data_core_world_ext()
	_expect("formal annual authority configured", bool(runtime.annual_report_status().get("ok", false)))
	clock.set_speed(50)
	clock.pause(false)
	var deadline: int = Time.get_ticks_msec() + 120000
	while not ui.is_annual_report_open() and Time.get_ticks_msec() < deadline:
		if runtime.is_runtime_fault_paused():
			break
		await get_tree().process_frame
	var state: Dictionary = runtime.annual_report_status()
	print("[annual-runtime] worker=%s clock=%d state=%s" % [str(worker), clock.day_index(), JSON.stringify(state)])
	_expect("one report at the first new year", int(state.get("report_count", 0)) == 1)
	var report: Dictionary = runtime.annual_report_snapshot(1)
	_expect("first complete new-game year graded", bool(report.get("complete", false)))
	_expect("annual grant committed before presentation", bool(report.get("reward_settled", false)))
	_expect("report automatically opens and pauses", ui.is_annual_report_open() and clock.paused)
	if bool(report.get("ok", false)):
		var totals: Dictionary = report.get("totals", {})
		print("[annual-runtime] grade=%s reward=%d totals=%s opening=%s" % [String(report.get("grade", "")), int(report.get("reward_q16", 0)), JSON.stringify(totals), JSON.stringify(report.get("opening", {}))])
		_expect("opening census is the formal 20-person start", int(report.get("opening", {}).get("population", 0)) == 20)
		_expect("actual committed GDP is positive", int(totals.get("gdp", 0)) > 0)
		_expect("GDP accounting identity is exact", int(totals.get("gdp", 0)) == int(totals.get("revenue", 0)) - int(totals.get("input_cost", 0)) - int(totals.get("maintenance", 0)))
		_expect("no bootstrap technology counted as new", report.get("new_technologies", PackedInt64Array()).size() < int(totals.get("technologies", 0)))
	var bytes: PackedByteArray = ext.capture_annual_report_state()
	_expect("PKAR contains persistent records", bytes.size() > 100)
	var restored = ClassDB.instantiate("DCWorldExt")
	_expect("PKAR roundtrip", bool(restored.restore_annual_report_state(bytes).get("ok", false)))
	_expect("unread and settled state survives restore", int(restored.get_annual_report_status().get("ready_report_id", 0)) == 1 and bool(restored.get_annual_report_snapshot(1).get("reward_settled", false)))
	var bad: PackedByteArray = bytes.duplicate()
	if bad.size() > 16:
		bad[12] = bad[12] ^ 1
		_expect("damaged PKAR rejected without repair", not bool(restored.restore_annual_report_state(bad).get("ok", true)))
	var facade = runtime.generator().get_ideology_facade()
	var handle: int = int(controller.get_player_country_handle())
	var before: int = int(facade.snapshot(handle).get("ideology_points_q16", 0))
	var workspace = ui.get("_annual_report_workspace")
	workspace.call("finish_opening")
	workspace.call("_close")
	_expect("closing restores 50x running mode", not clock.paused and is_equal_approx(clock.speed_multiplier, 50.0))
	clock.pause(true)
	ui.get_node("UIRoot/HUDLayer/PlayerTopBar/Margin/Row/DateBlock").pressed.emit()
	_expect("history reopens without paying again", ui.is_annual_report_open() and before == int(facade.snapshot(handle).get("ideology_points_q16", 0)))
	workspace.call("_copy_report")
	workspace.call("_close")
	clock.pause(true)
	var save_result: Dictionary = await saves.request_manual_save("manual_3")
	_expect("formal PKSV save accepts annual provider", bool(save_result.get("ok", false)))
	if not bool(save_result.get("ok", false)):
		print(save_result)
	saves.set("_autosave_enabled", previous_autosave)
	await runtime._stop_previous_runtime_worker()
	game.queue_free()
	await get_tree().process_frame
	print("annual_report_runtime_test: %d failures" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)
