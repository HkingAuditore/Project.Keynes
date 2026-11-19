extends SceneTree

const WorkspaceScene := preload("res://scenes/ui/technology_workspace.tscn")
const DialogScene := preload("res://scenes/ui/era_reward_dialog.tscn")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")

class CeremonyUI extends GameUIManager:
	var ceremony := false

	func is_era_ceremony_playing() -> bool:
		return ceremony

class RewardFacade extends RefCounted:
	var reads := 0
	var status := "OPEN"
	var settles_on_day_advance := false

	func era_reward_offer() -> Dictionary:
		reads += 1
		return {"ok": true, "status": status, "offer_generation": 7,
			"settles_on_day_advance": settles_on_day_advance,
			"era_title": "石器时代", "alternatives": [
				{"title": "国家组织"}, {"title": "广域科研"}, {"title": "生产动员"}]}

var _failures := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_audit_era_label()
	var dialog := DialogScene.instantiate() as EraRewardDialog
	root.add_child(dialog)
	var ui := CeremonyUI.new()
	ui.set("_era_reward_dialog", dialog)
	var facade := RewardFacade.new()
	var clock := WorldClock.new()
	clock.set_speed(50.0)
	clock.pause(false)
	var controller := PlayerController.new()
	controller.set("_country_facade", facade)
	controller.set("_world_clock", clock)
	controller.set("_ui_manager", ui)
	ui.era_reward_dismiss_requested.connect(controller.dismiss_era_reward_offer)
	dialog.dismiss_requested.connect(ui._on_era_popup_dismissed)
	var host := WorldRuntimeHost.new()
	controller.set("_runtime_host", host)
	controller._connect_runtime()

	_expect("before the first published day the offer is unread", facade.reads == 0)
	ui.ceremony = true
	host.simulation_committed.emit(0, 1, 1)
	_expect("day commit delivers the offer immediately", facade.reads > 0)
	_expect("offer yields while the ascension ceremony plays", not dialog.is_offer_open()
		and not controller.era_reward_locked() and not clock.paused)
	ui.ceremony = false
	host.simulation_committed.emit(1, 2, 2)
	_expect("next sync after the ceremony opens the offer directly", dialog.is_offer_open())
	_expect("open offer pauses 50x play and retains resume intent",
		clock.paused and controller.era_reward_locked()
		and bool(controller.capture_view_state().get("era_reward_resume_running", false))
		and float(controller.capture_view_state().get("era_reward_previous_speed", 0.0)) == 50.0)
	controller._on_pause_toggled(false)
	controller._on_speed_selected(10.0)
	_expect("compact reward keeps clock controls from bypassing the choice lock", clock.paused
		and clock.speed_multiplier == 50.0)
	var reads_before := facade.reads
	host.simulation_committed.emit(2, 3, 3)
	_expect("each committed day refreshes the published offer", facade.reads > reads_before)
	dialog.dismiss_requested.emit()
	await create_timer(0.14).timeout
	_expect("dismiss closes the modal and restores previous speed", not dialog.is_offer_open()
		and not controller.era_reward_locked() and not clock.paused and clock.speed_multiplier == 50.0)
	clock.pause(true)
	controller._sync_era_reward_offer()
	_expect("offer also opens directly from paused play", dialog.is_offer_open()
		and controller.era_reward_locked())
	controller.dismiss_era_reward_offer()
	_expect("dismissing from paused play preserves the paused state", clock.paused)
	clock.pause(false)
	controller._sync_era_reward_offer()
	facade.status = "SELECTED_PENDING"
	facade.settles_on_day_advance = true
	controller._sync_era_reward_offer()
	controller.dismiss_era_reward_offer()
	# Worker-owned Modifier commits only land on a simulated day, so the
	# pending choice advances one day at a time instead of staying paused.
	_expect("submitted reward cannot dismiss before ACK and uses settlement speed",
		controller.era_reward_locked() and dialog.is_offer_open()
		and not clock.paused and clock.speed_multiplier == 1.0)
	var saved_view := controller.capture_view_state()
	controller.restore_view_state(null, saved_view)
	_expect("restore keeps submitted reward locked until ACK", controller.era_reward_locked())
	facade.status = "RESOLVED"
	controller._sync_era_reward_offer()
	_expect("ACK closes modal and restores the original 50x running state",
		not controller.era_reward_locked() and not dialog.is_offer_open()
		and not clock.paused and clock.speed_multiplier == 50.0)
	host.free()
	controller.free()
	clock.free()
	ui.free()
	dialog.free()
	print("era_reward_notification_regression_test: %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)

func _audit_era_label() -> void:
	var compiled: Dictionary = TechnologyCatalogScript.compile_native_catalog()
	_expect("technology catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var workspace := WorkspaceScene.instantiate() as TechnologyWorkspace
	var definitions: Array = TechnologyCatalogScript.public_definitions(compiled)
	var eras: Array = TechnologyCatalogScript.public_era_metadata()
	var names := {}
	for era: Dictionary in eras:
		names[String(era.id)] = String(era.display_name)
	workspace.set("_definitions", definitions)
	workspace.set("_eras", eras)
	workspace.set("_era_names", names)
	var ids: PackedStringArray = compiled.technology_ids
	var states := PackedInt32Array()
	states.resize(ids.size())
	_expect("starting country displays Stone Age without a completed milestone",
		workspace._current_era_label(states) == "石器时代")
	for index in range(definitions.size()):
		if not bool(definitions[index].get("is_milestone", false)):
			states[index] = 5
	_expect("ordinary technology completion never advances the current era",
		workspace._current_era_label(states) == "石器时代")
	states[ids.find("tech.settled_knowledge")] = 5
	states[ids.find("tech.agrarian_society")] = 4
	_expect("pending milestone does not advance the current era before ACK",
		workspace._current_era_label(states) == "石器时代")
	states[ids.find("tech.agrarian_society")] = 5
	_expect("completed agrarian milestone advances the current era",
		workspace._current_era_label(states) == "农耕时代")
	states[ids.find("tech.kingdom_administration")] = 5
	_expect("highest completed milestone determines the current era",
		workspace._current_era_label(states) == "王国时代")
	workspace.free()

func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
