extends SceneTree

const WorkspaceScene := preload("res://scenes/ui/technology_workspace.tscn")
const DialogScene := preload("res://scenes/ui/era_reward_dialog.tscn")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")

class PeerGenerator extends MapGenerator:
	var service_report: Dictionary = {"ok": true, "inspected": 0, "notified": 0}

	func get_runtime_thread_report() -> Dictionary:
		return {"simulation_thread_mode": "ACTIVE"}

	func service_country_worker_peer_adapter(_limit: int = 64,
			_shadow: bool = true) -> Dictionary:
		return service_report

class RewardFacade extends RefCounted:
	var reads := 0

	func era_reward_offer() -> Dictionary:
		reads += 1
		return {"ok": true, "status": "OPEN", "offer_generation": 7,
			"era_title": "石器时代", "alternatives": [
				{"title": "国家组织"}, {"title": "广域科研"}, {"title": "生产动员"}]}

var _failures := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_audit_era_label()
	var dialog := DialogScene.instantiate() as EraRewardDialog
	root.add_child(dialog)
	var ui := GameUIManager.new()
	ui.set("_era_reward_dialog", dialog)
	var facade := RewardFacade.new()
	var clock := WorldClock.new()
	clock.set_speed(50.0)
	clock.pause(false)
	var controller := PlayerController.new()
	controller.set("_country_facade", facade)
	controller.set("_world_clock", clock)
	controller.set("_ui_manager", ui)
	var generator := PeerGenerator.new()
	var host := WorldRuntimeHost.new()
	host.set("_generator", generator)
	host.set("_runtime_ready_for_ticks", true)
	host.country_peer_serviced.connect(controller._on_country_peer_serviced)

	host._service_country_worker_transport()
	_expect("idle peer service does not poll offers", facade.reads == 0)
	generator.service_report = {"ok": true, "inspected": 0, "notified": 1}
	host._service_country_worker_transport()
	_expect("notification-only service reaches PlayerController immediately", facade.reads == 1)
	_expect("notification-only milestone opens the real reward modal", dialog.is_offer_open())
	_expect("open offer pauses 50x play and retains resume intent",
		clock.paused and controller.era_reward_locked()
		and bool(controller.capture_view_state().get("era_reward_resume_running", false))
		and float(controller.capture_view_state().get("era_reward_previous_speed", 0.0)) == 50.0)
	generator.service_report = {"ok": true, "inspected": 1, "notified": 0}
	host._service_country_worker_transport()
	_expect("ordinary peer intents still refresh offers", facade.reads == 2)
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
