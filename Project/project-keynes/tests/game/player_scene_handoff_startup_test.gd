extends "res://tests/game/player_scene_handoff_probe.gd"


class QuietOverlay extends WorldLoadingOverlay:
	func _ready() -> void:
		pass

	func set_progress(_stage: String, _fraction: float) -> void:
		pass

	func show_failure_detailed(_summary: String, _detail: String) -> void:
		_failed = true


class FailedLoadFlow extends "res://scripts/game/game_flow_service.gd":
	func _ready() -> void:
		pass

	func _queue_player_scene() -> Error:
		var overlay := QuietOverlay.new()
		add_child(overlay)
		# Accept the transition, then let the real async handler reject a non-scene resource.
		var request := ResourceRequest.new("res://scripts/game/game_flow_service.gd", "Script")
		if request.start_error != OK:
			return request.start_error
		_transition_active = true
		_finish_player_scene_transition.call_deferred(_transition_id, overlay, _transition_frames, request)
		return OK


func _run() -> void:
	var previous := Node.new()
	root.add_child(previous)
	current_scene = previous
	var flow := FailedLoadFlow.new()
	root.add_child(flow)
	var config := NewGameConfig.create_default()
	var failure := await _start_player_scene(flow, config)
	var correct_failure: bool = failure.get("ok") == false and failure.get("code") == "player_scene_load_failed"
	var previous_retained := current_scene == previous and flow.session().is_empty() \
		and not flow.player_scene_transition_active()
	var output := OS.get_temp_dir().path_join("keynes-handoff-start-%d.jsonl" % OS.get_process_id())
	_record_start_failure(output, failure)
	var record = JSON.parse_string(FileAccess.get_file_as_string(output))
	var recorded: bool = record is Dictionary and record.get("end") == "startup_failed" \
		and record.get("failure") == failure and FileAccess.file_exists(output + ".days") \
		and FileAccess.get_file_as_string(output + ".days").is_empty()
	DirAccess.remove_absolute(output)
	DirAccess.remove_absolute(output + ".days")
	flow.free()
	print("handoff startup: scene_load_failed=%s previous_retained=%s recorded=%s" % [
		correct_failure, previous_retained, recorded])
	quit(0 if correct_failure and previous_retained and recorded else 1)
