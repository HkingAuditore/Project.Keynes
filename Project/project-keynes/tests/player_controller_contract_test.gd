extends SceneTree

const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")

var _failures := 0


func _init() -> void:
	var controller = PlayerControllerScript.new()
	_expect("PlayerController has no frame polling", not controller.has_method("_process"))
	_expect("unknown player command is rejected", _code(controller.request_command(&"gm.teleport")) == "unsupported_command")
	_expect("known player command is session gated",
		_code(controller.request_command(PlayerControllerScript.COMMAND_RESEARCH_SET_BUDGET)) == "runtime_unavailable")
	_expect("construction command is session gated",
		_code(controller.request_command(PlayerControllerScript.COMMAND_CONSTRUCTION_BUILD, {
			"cell_idx": 0,
			"building_id": &"coal_mine",
			"ownership_policy": &"treasury_sponsored_private",
		})) == "runtime_unavailable")
	_expect("treasury-sponsored construction is a formal player command",
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"construction.build") and
		controller.has_signal(&"command_settled"))
	_expect("family colonization start and cancel are formal player commands",
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"family.colonization.start")
		and PlayerControllerScript.SUPPORTED_COMMANDS.has(&"family.colonization.cancel")
		and _code(controller.request_command(&"family.colonization.start", {
			"family_handle": 1, "source_cell": 0, "target_cell": 1,
			"population": 1, "quote_token": 1,
		})) == "runtime_unavailable")
	_expect("national and cell tax commands are formal player commands",
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.set_default") and
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.set_override") and
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.clear_override") and
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.cell.set_default") and
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.cell.clear_default") and
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.cell.set_override") and
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.cell.clear_override") and
		PlayerControllerScript.SUPPORTED_COMMANDS.has(&"country.tax.cell.clear_all"))
	controller.restore_view_state(null, {"next_command_sequence": 41})
	_expect("player view round-trips the next unified command sequence",
		int(controller.capture_view_state().get("next_command_sequence", 0)) == 41)
	var canal_rejected: Dictionary = controller.request_command(
		&"infrastructure.canal.build", {"quote_token": 7})
	_expect("canal command remains API-only and unsupported by PlayerController",
		_code(canal_rejected) == "unsupported_command"
		and int(canal_rejected.get("effective_day", -2)) == -1
		and int(canal_rejected.get("sequence", -2)) == -1
		and not PlayerControllerScript.SUPPORTED_COMMANDS.has(
			&"infrastructure.canal.build"))
	_expect("rejected canal command does not consume unified sequence",
		int(controller.capture_view_state().get("next_command_sequence", 0)) == 41)
	_expect("player pause action is registered", InputMap.has_action(&"player_pause"))
	_expect("player cancel action is registered", InputMap.has_action(&"player_cancel"))
	_expect("player fit action is registered", InputMap.has_action(&"player_fit_view"))
	_expect("player zoom actions are registered",
		InputMap.has_action(&"player_zoom_in") and InputMap.has_action(&"player_zoom_out"))
	var packed := load("res://scenes/player_game.tscn") as PackedScene
	var scene := packed.instantiate() if packed != null else null
	var player = scene if scene != null else null
	_expect("player scene mounts the unified controller",
		player != null and player.get_node_or_null("PlayerController") != null)
	_expect("legacy controller nodes are absent",
		player != null and player.get_node_or_null("Controllers") == null)
	_expect("player scene mounts one shared colonization planner and Node2D route layer",
		player != null
		and player.get_node_or_null("UI/UIRoot/ModalLayer/ColonizationPlannerPanel") != null
		and player.get_node_or_null("WorldRoot/ColonizationRouteLayer") is Node2D)
	_expect("player scene mounts one full-screen era reward modal",
		player != null
		and player.get_node_or_null("UI/UIRoot/ModalLayer/EraRewardDialog") is EraRewardDialog)
	if scene != null:
		scene.free()
	print("=== player controller contract: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _code(result: Dictionary) -> String:
	return String(result.get("code", ""))


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)
