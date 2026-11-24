extends SceneTree

## 「招募目标」滑条的提交契约。
##
## 回归的缺陷（2026-11-20 玩家存档复盘）：目标滑条**只在 `drag_ended` 提交**，
## 而面板每 200ms 用原生快照重画一次，于是
##   * 键盘 / 点击轨道 / 无障碍调整根本没有提交入口；
##   * 任何没有以「拖动松手」结束的调整都会在下一帧被写回旧值；
## 玩家看到的就是「拖了没用、永远招不到兵」，而原生侧的 `target_value` 一直是 0，
## 招募算式 `plan = min(目标 − 现役, 空额)` 恒为 0，配额与入伍就都不发生。
##
## 这个测试钉住四条：
##   1. 非拖动来源的改动会防抖提交一次（mode/value 都要对）；
##   2. 快照还没追上时，把手**不能**被写回旧值；
##   3. 快照追上后释放本地覆盖，此后完全跟随原生；
##   4. 拖动路径仍然「松手即提交」，重复点当前模式不再发命令（旧实现会顺手把
##      目标写成滑条当前值，滑条停在 0 时等于清零）。

const ControllerScript = preload("res://scripts/game/player_controller.gd")
const FacadeScript = preload("res://scripts/military/military_facade.gd")
const WorkspaceScene = preload("res://scenes/ui/military_workspace.tscn")

const TARGET_VALUE := 300.0
const DRAG_VALUE := 500.0

var _failures := 0


class NativeStub extends RefCounted:
	var batches: Array = []

	func get_military_country_snapshot(_country: int) -> Dictionary:
		return {"ok": true, "config_share_bp": PackedInt32Array()}

	func submit_military_commands(batch: Array) -> Dictionary:
		batches.append(batch.duplicate(true))
		return {"ok": true, "accepted": batch.size()}


class ControllerStub extends RefCounted:
	var facade

	func request_command(id: StringName, args: Dictionary) -> Dictionary:
		var entry: Dictionary = ControllerScript._military_command_entry(id, args)
		entry["country"] = 42
		var result: Dictionary = facade.submit([entry])
		if bool(result.get("ok", false)):
			result["message"] = "命令已下达"
		return result


func _init() -> void:
	call_deferred("_run")


func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures += 1
		push_error(label)


## 面板能用的一份最小军事模型：只有兵力页要读的字段。
static func _model(target_mode: int, target_value: int) -> Dictionary:
	return {
		"country_handle": 42,
		"cell_names": {},
		"military": {
			"available": true,
			"reason": "",
			"facade": null,
			"country_handle": 42,
			"generator": null,
			"map": null,
			"tech_gate_known": false,
			"catalog": {"units": [], "categories": [], "militia_unit": -1,
				"display_names": {}, "category_names": {}},
			"armies": [],
			"snapshot": {
				"ok": true, "has_policy": true, "country_slot": 0,
				"target_mode": target_mode, "target_value": target_value,
				"effective_target": target_value, "per_soldier_cost": 5462,
				"daily_wage": 5462, "soldiers_total": 0, "soldiers_training": 0,
				"post_count": 0, "config_share_bp": PackedInt32Array(),
				"barracks": [], "training": [], "quality_policy": 0,
				"auto_retrain": true, "levy_enabled": true, "auto_discharge": false,
			},
		},
	}


func _run() -> void:
	var native := NativeStub.new()
	var facade := FacadeScript.new()
	facade._world_ext = native
	facade._configured = true
	facade._catalog = {"units": []}
	var controller := ControllerStub.new()
	controller.facade = facade

	var workspace = WorkspaceScene.instantiate()
	workspace._player_controller = controller
	root.add_child(workspace)
	await process_frame
	workspace.set_model(_model(0, 0))
	workspace.select_chapter("forces")
	await process_frame
	_expect("forces chapter mounted", String(workspace.current_chapter()) == "forces")

	# ---- 1. 非拖动来源（键盘 / 点击轨道）：防抖后必须提交一次 ----
	workspace._target_slider.value = TARGET_VALUE
	_expect("value change alone does not submit immediately", native.batches.is_empty())
	await create_timer(0.5).timeout
	_expect("debounced commit reaches the native command lane", native.batches.size() == 1)
	if native.batches.size() == 1:
		var row: Dictionary = native.batches[0][0]
		_expect("commit carries force.set_target", String(row.get("op", "")) == "force.set_target")
		_expect("commit carries the headcount mode", int(row.get("count", -1)) == 0)
		_expect("commit carries the dragged headcount",
			int(row.get("value", -1)) == int(TARGET_VALUE))
	_expect("panel tells the player the order is queued",
		workspace._status_label.visible
			and workspace._status_label.text == "命令已下达")

	# ---- 2. 快照还没追上：把手不能被写回旧值 ----
	workspace.set_model(_model(0, 0))
	_expect("stale snapshot does not snap the grabber back",
		is_equal_approx(workspace._target_slider.value, TARGET_VALUE))
	_expect("pending target is still held", int(workspace._target_pending_mode) == 0)

	# ---- 3. 快照追上：释放覆盖，之后完全跟随原生 ----
	workspace.set_model(_model(0, int(TARGET_VALUE)))
	_expect("committed snapshot releases the local override",
		int(workspace._target_pending_mode) == -1)
	_expect("grabber keeps the committed value",
		is_equal_approx(workspace._target_slider.value, TARGET_VALUE))

	# ---- 4. 拖动路径：松手即提交，不等防抖 ----
	var before := native.batches.size()
	workspace._target_slider.drag_started.emit()
	workspace._target_slider.value = DRAG_VALUE
	_expect("dragging does not submit mid-gesture", native.batches.size() == before)
	workspace._target_slider.drag_ended.emit(true)
	_expect("releasing the grabber submits immediately", native.batches.size() == before + 1)
	if native.batches.size() == before + 1:
		var dragged: Dictionary = native.batches[-1][0]
		_expect("drag commit carries the released headcount",
			int(dragged.get("value", -1)) == int(DRAG_VALUE))

	# ---- 5. 重复点当前模式：不发命令（旧实现会把目标写成滑条当前值） ----
	var after_drag := native.batches.size()
	workspace._on_target_mode(0)
	_expect("clicking the active mode does not resubmit", native.batches.size() == after_drag)

	# ---- 6. 切到预算模式：换算后按预算模式提交一次 ----
	workspace._on_target_mode(1)
	_expect("switching to budget mode submits once", native.batches.size() == after_drag + 1)
	if native.batches.size() == after_drag + 1:
		var budget: Dictionary = native.batches[-1][0]
		_expect("budget commit uses the budget mode", int(budget.get("count", -1)) == 1)
		_expect("budget commit is a positive daily amount", int(budget.get("value", 0)) > 0)
	_expect("budget mode is reflected on the toggle",
		workspace._mode_budget.button_pressed and not workspace._mode_headcount.button_pressed)

	# 面板提示的 4 秒回调会持有本节点，等它释放后再卸载。
	await create_timer(4.2).timeout
	workspace.queue_free()
	await process_frame
	await process_frame
	print("military target commit: %d failures" % _failures)
	quit(0 if _failures == 0 else 1)
