extends SceneTree

const REGIME_SCENE := "res://scenes/ui/regime_workspace.tscn"

var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var workspace := (load(REGIME_SCENE) as PackedScene).instantiate() as Control
	get_root().add_child(workspace)
	workspace.set_model({
		"regime": {
			"available": true,
			"current_id": "early_clan",
			"current_name": "早期氏族",
			"current_detail": "允许以国库资源发起营造。",
			"current_capabilities": [{"label": "国库建造"}],
			"options": [
				{"id": "early_clan", "display_name": "早期氏族", "detail": "允许建造"},
				{"id": "local_council", "display_name": "地方议会", "detail": "暂不开放国库建造"},
			],
		},
	})
	await process_frame
	_expect("current regime title renders", workspace.get_node("Root/Current/Body/Column/Title").text == "早期氏族")
	_expect("two regime options render", workspace.get_node("Root/OptionsScroll/Options").get_child_count() == 2)
	_expect("current regime is disabled", workspace.get_node("Root/OptionsScroll/Options").get_child(0).disabled)
	_expect("alternative regime is focusable", workspace.get_node("Root/OptionsScroll/Options").get_child(1).focus_mode == Control.FOCUS_ALL)
	print("politics workspace: %d failures" % _failures)
	quit(0 if _failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)
