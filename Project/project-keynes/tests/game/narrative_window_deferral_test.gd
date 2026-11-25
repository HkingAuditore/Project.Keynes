extends SceneTree

const Flow = preload("res://scripts/narrative/narrative_event_flow.gd")


class PublishedStory extends RefCounted:
	var offer := {"offer_id": 31, "offer_generation": 4, "event_id": "evt.ages.first_seed",
		"default_option_index": 0, "options": [{"text": "继续"}]}

	func active_offer() -> Dictionary:
		return offer


class ControllerProbe extends Node:
	var requests: Array[Dictionary] = []
	var flow: NarrativeEventFlow

	func request_command(_command: StringName, args: Dictionary) -> Dictionary:
		requests.append(args)
		return {"ok": true}

	func recheck_narrative_popup() -> void:
		flow.try_present()


class DialogProbe extends RefCounted:
	var displayed: Array[Dictionary] = []
	var opened := false
	var workspace_open := true

	func is_player_workspace_open() -> bool: return workspace_open
	func is_narrative_event_modal_open() -> bool: return opened

	func show_narrative_event_offer(offer: Dictionary) -> void:
		displayed.append(offer)
		opened = true

	func close_narrative_event_offer() -> void:
		opened = false


class AudioProbe extends Node:
	var cues: Array[StringName] = []

	func play_event_cue(cue: StringName) -> void:
		cues.append(cue)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var audio := root.get_node_or_null("GameAudio")
	if audio != null:
		audio.name = "GameAudioUnderTest"
	var cue := AudioProbe.new()
	cue.name = "GameAudio"
	root.add_child(cue)

	var clock := WorldClock.new()
	clock.set_speed(5.0)
	var controller := ControllerProbe.new()
	var story := PublishedStory.new()
	var dialog := DialogProbe.new()
	var flow := Flow.new()
	controller.flow = flow
	root.add_child(controller)
	flow.configure(controller, null, clock, dialog, story)
	flow.try_present()
	flow.try_present()
	var held := flow.is_deferred() and not flow.is_locked() and dialog.displayed.is_empty() \
		and cue.cues == [Flow.DEFERRAL_CUE] and controller.requests.is_empty()

	clock.pause(true)
	dialog.workspace_open = false
	var overlays = load("res://scripts/ui/game_ui/overlays.gd").new()
	overlays.notify_workspace_closed({"_player_controller": controller})
	await process_frame
	var presented := dialog.displayed == [story.offer] and flow.is_locked() \
		and not flow.is_deferred() and controller.requests.is_empty()

	flow.set_popups_suppressed(true)
	flow.try_present()
	var suppressed: bool = not flow.is_open() and not dialog.opened and controller.requests.is_empty() \
		and story.active_offer().offer_id == 31 and clock.paused and clock.speed_multiplier == 5.0

	controller.flow = null
	controller.free()
	clock.free()
	cue.free()
	if audio != null:
		audio.name = "GameAudio"
	print("Narrative deferral: held=", held, " presented=", presented, " suppressed=", suppressed)
	quit(0 if held and presented and suppressed else 1)
