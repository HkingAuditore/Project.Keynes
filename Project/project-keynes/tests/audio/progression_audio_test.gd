extends SceneTree

const Catalog = preload("res://scripts/economy/technology_catalog.gd")
const ToastScene = preload("res://scenes/ui/research_toast.tscn")

class QuietUI extends GameUIManager:
	func _ready() -> void:
		set_process(false)

class ResearchView extends CountryViewModel:
	var test_states := PackedInt32Array()
	func player_research_states() -> PackedInt32Array:
		return test_states

var failed := false
var heard: Array[StringName] = []

func _init() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("[progression-audio] ", "PASS " if ok else "FAIL ", message)
	failed = failed or not ok

func _run() -> void:
	await process_frame
	var audio := root.get_node("GameAudio")
	check(audio.status == "ready", "FMOD backend ready")
	if audio.status != "ready":
		quit(1)
		return
	audio.event_sound_played.connect(func(cue: StringName): heard.append(cue))
	var ui := QuietUI.new()
	root.add_child(ui)
	var controller := PlayerController.new()
	root.add_child(controller)
	ui.set_player_controller(controller)
	ui.set_player_controller(controller)
	controller._complete_command(&"research.enqueue", {"ok": false})
	check(heard.is_empty(), "rejected research is silent")
	controller._complete_command(&"research.enqueue", {"ok": true})
	check(heard == [&"tech_start"], "accepted research plays once after repeated binding")
	controller._complete_command(&"research.remove", {"ok": true})
	controller._complete_command(&"ideology.offer", {"ok": true})
	controller._complete_command(&"ideology.reroll", {"ok": true})
	controller._complete_command(&"ideology.choose", {"ok": true})
	check(heard.slice(1) == [&"tech_cancel", &"ideology_draw", &"ideology_reroll", &"ideology_choose"],
		"cancel, draw, reroll and choice have distinct immediate cues")
	var before := heard.size()
	controller._on_ideology_command_settled({"ok": true, "opcode": 3})
	controller._on_ideology_command_settled({"ok": true, "opcode": 4})
	controller._on_ideology_command_settled({"ok": true, "opcode": 10})
	controller._on_ideology_command_settled({"ok": false, "opcode": 7})
	check(heard.size() == before, "draw settlement does not replay; rejected promotion is silent")
	for entry in [[5, &"ideology_use"], [6, &"ideology_unequip"], [7, &"ideology_promote"]]:
		controller._complete_command(&"ideology.equip", {"ok": true})
		check(heard.size() == before, "queued equipment has no premature success sound")
		controller._on_ideology_command_settled({"ok": true, "opcode": entry[0]})
		check(heard.back() == entry[1] and heard.size() == before + 1, "settled cue " + String(entry[1]))
		before = heard.size()

	var view := ResearchView.new()
	var definitions: Array = Catalog.public_definitions()
	view.test_states.resize(definitions.size())
	var technology := -1
	for i in definitions.size():
		if not bool(definitions[i].get("is_application", false)) and not String(definitions[i].get("id", "")).begins_with("app."):
			technology = i
			break
	check(technology >= 0, "research catalog available")
	var toast := ToastScene.instantiate()
	root.add_child(toast)
	ui.set("_research_toast", toast)
	ui.set("_country_view_model", view)
	view.test_states[technology] = 5
	ui._poll_research_completion_toasts()
	check(heard.size() == before, "loaded completed research is silent")
	view.test_states[technology] = 3
	ui._poll_research_completion_toasts()
	view.test_states[technology] = 4
	ui.set("_next_research_toast_poll_ms", 0)
	ui._on_country_committed({"generation": 2})
	check(heard.size() == before + 1 and heard.back() == &"tech_research", "completion sounds on pending activation edge")
	check(bool(ui.get("_research_toast_bootstrapped")), "generation-only worker commit observes completion with panel closed")
	before = heard.size()
	view.test_states[technology] = 5
	ui._poll_research_completion_toasts()
	ui._poll_research_completion_toasts()
	check(heard.size() == before, "activation and repeated refresh do not replay completion")
	paused = true
	check(audio.play_event_cue(&"ideology_reveal"), "reveal plays while game paused")
	check(not audio.play_event_cue(&"ideology_reveal"), "reveal burst is throttled")
	paused = false
	await create_timer(2.8).timeout
	for cue in audio.EVENT_CUES:
		check(audio.play_event_cue(cue), "bank resolves " + String(cue))
	await create_timer(3.0).timeout
	for description in audio.get("_event_descriptions").values():
		check(int(ClassDB.class_call_static("StudioEventDescription", "get_instance_count", description)) == 0,
			"event instances released")
	ui.set_player_controller(null)
	ui.free()
	controller.free()
	toast.free()
	print("PROGRESSION_AUDIO_TEST_OK=", not failed)
	quit(1 if failed else 0)
