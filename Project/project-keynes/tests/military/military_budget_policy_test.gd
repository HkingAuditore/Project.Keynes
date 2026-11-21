extends SceneTree

const FacadeScript = preload("res://scripts/military/military_facade.gd")
const ControllerScript = preload("res://scripts/game/player_controller.gd")

var _failures := 0


## 记录送进桥接的批次，不做任何原生工作。
class ExtStub:
	var batches: Array = []

	func submit_military_commands(batch: Array) -> Dictionary:
		batches.append(batch)
		return {"ok": true, "accepted": batch.size(), "rejected": []}


func _expect(label: String, condition: bool, detail := "") -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s %s" % [label, detail])


func _init() -> void:
	_test_facade_sends_the_documented_shape()
	_test_native_op_is_registered()
	_test_budget_is_not_saved_in_the_player_view()
	print("=== military budget policy: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _test_budget_is_not_saved_in_the_player_view() -> void:
	var controller = ControllerScript.new()
	var view: Dictionary = controller.capture_view_state()
	_expect("military budget is saved with the military core",
		not view.has("military_budget"))
	controller.free()


func _test_facade_sends_the_documented_shape() -> void:
	var stub := ExtStub.new()
	var facade = FacadeScript.new()
	facade._world_ext = stub
	facade._configured = true

	var result: Dictionary = facade.set_budget(77, 2500, 5000, 3000, 2000)
	_expect("set_budget reports success", bool(result.get("ok", false)))
	_expect("set_budget sends exactly one command", stub.batches.size() == 1)
	if stub.batches.size() == 1:
		var command: Dictionary = (stub.batches[0] as Array)[0]
		_expect("the command names the native op",
			String(command.get("op", "")) == "policy.set_budget")
		_expect("the command carries the country handle",
			int(command.get("country", 0)) == 77)
		_expect("the command carries the envelope share",
			int(command.get("value", -1)) == 2500)
		var pairs := command.get("int_pairs", PackedInt32Array()) as PackedInt32Array
		_expect("the command carries the three channel shares in order",
			pairs.size() == 3 and pairs[0] == 5000 and pairs[1] == 3000
				and pairs[2] == 2000, str(pairs))

	# 默认参数必须一路走到桥接：少传两个通道就是两个 -1。
	stub.batches.clear()
	facade.set_budget(77, 0)
	if stub.batches.size() == 1:
		var command: Dictionary = (stub.batches[0] as Array)[0]
		var pairs := command.get("int_pairs",
			PackedInt32Array()) as PackedInt32Array
		_expect("defaulted channels reach the bridge as -1",
			pairs.size() == 3 and pairs[0] == -1
				and pairs[1] == -1 and pairs[2] == -1, str(pairs))
		# 总份额 0 是合法输入（关闭预算控制），不能被当成缺失值丢掉。
		_expect("a zero total is forwarded verbatim, not treated as missing",
			int(command.get("value", -1)) == 0)
	else:
		_expect("set_budget sends the defaulted call too",
			stub.batches.size() == 1)

	# facade 只推一条命令：UI 拖一次滑条不该顺手改别的通道。
	_expect("set_budget does not fan out into extra commands",
		stub.batches.size() == 1
			and (stub.batches[0] as Array).size() == 1)


## 原生 op 注册：`policy.set_budget` 必须被 op 表认出来。不认识的 op 会让
## 整批被拒，而 UI 只看到一坨 rejected，很难定位。
func _test_native_op_is_registered() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt unavailable in this build")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null or not ext.has_method("submit_military_commands"):
		print("  [SKIP] military bindings missing in loaded dots_ext")
		return
	var result: Dictionary = ext.submit_military_commands([
		{"op": "policy.set_budget", "country": 1, "value": 1000,
			"int_pairs": PackedInt32Array([6000, 2000, 2000])}])
	# 未配置的核心必须拒绝（military_not_configured 一类），但绝不能是因为
	# op 名字不认识 —— 后者说明 kMilitaryOps 漏登记了。
	var rejected: Array = result.get("rejected", [])
	var reason := String(result.get("reason", ""))
	if rejected.size() > 0:
		reason = String((rejected[0] as Dictionary).get("reason", reason))
	_expect("policy.set_budget is a known op",
		not reason.contains("unknown_op") and not reason.contains("bad_op"),
		reason)
	_expect("an unconfigured core refuses the command instead of accepting it",
		not bool(result.get("ok", true))
			or int(result.get("accepted", 1)) == 0,
		str(result))
