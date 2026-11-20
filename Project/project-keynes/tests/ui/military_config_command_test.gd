extends SceneTree

const FacadeScript = preload("res://scripts/military/military_facade.gd")
const ControllerScript = preload("res://scripts/game/player_controller.gd")
const WorkspaceScene = preload("res://scenes/ui/military_workspace.tscn")

var _failures := 0

class NativeStub extends RefCounted:
	var batches: Array = []
	var shares := PackedInt32Array([0, 2000, 0])
	func get_military_country_snapshot(_country: int) -> Dictionary:
		return {"ok": true, "config_share_bp": shares}
	func submit_military_commands(batch: Array) -> Dictionary:
		batches.append(batch.duplicate(true))
		return {"ok": true, "accepted": batch.size()}

class ControllerStub extends RefCounted:
	var facade
	func request_command(id: StringName, args: Dictionary) -> Dictionary:
		var entry: Dictionary = ControllerScript._military_command_entry(id, args)
		entry["country"] = 42
		return facade.submit([entry])

func _init() -> void:
	call_deferred("_run")

func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures += 1
		push_error(label)

func _run() -> void:
	var native := NativeStub.new()
	var facade := FacadeScript.new()
	facade._world_ext = native
	facade._configured = true
	facade._catalog = {"units": [{"id": "tribal"}, {"id": "archer"}, {"id": "militia"}]}
	var controller := ControllerStub.new()
	controller.facade = facade
	var workspace = WorkspaceScene.instantiate()
	workspace._player_controller = controller
	root.add_child(workspace)
	workspace._forces = {"share_total": 2000, "units": [
		{"id": "tribal", "bp": 0}, {"id": "archer", "bp": 2000},
		{"id": "militia", "bp": 8000, "is_militia_row": true}]}
	workspace._on_roster_step("tribal", 500)
	_expect("plus reaches native with 5% and preserves other units",
		native.batches.size() == 1 and native.batches[0][0].int_pairs ==
		PackedInt32Array([0, 500, 1, 2000, 2, 0]))
	workspace._forces.units[0].bp = 1000
	workspace._forces.units[2].bp = 7000
	workspace._forces.share_total = 3000
	native.shares[0] = 1000
	workspace._on_roster_step("tribal", -500)
	_expect("minus lowers by 5% without clearing other units",
		native.batches[-1][0].int_pairs == PackedInt32Array([0, 500, 1, 2000, 2, 0]))
	workspace._on_share_bar_clicked("tribal", 0.5)
	_expect("share bar ignores implicit militia remainder",
		native.batches.size() == 3 and native.batches[-1][0].int_pairs ==
		PackedInt32Array([0, 500, 1, 2000, 2, 0]))
	var result: Dictionary = facade.submit([{"op": "config.set", "country": 42,
		"shares": {"missing": 500}}])
	_expect("unknown stable unit is explicitly rejected",
		result.get("rejected_local", 0) == 1 and native.batches[-1].is_empty())
	# 等面板提示的 4 秒回调释放自身引用后再卸载场景。
	await create_timer(4.1).timeout
	workspace.queue_free()
	await process_frame
	await process_frame
	print("military config command: %d failures" % _failures)
	quit(0 if _failures == 0 else 1)
