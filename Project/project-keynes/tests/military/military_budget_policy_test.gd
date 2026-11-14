## 军事预算信封的 GDScript 侧契约（任务 6 / 需求 5.1, 5.5, 9.1, 9.3）。
##
## 三层各测一半，互不重复：
##
##  1. 命令翻译层（PlayerController -> 原生 batch）：只验证 `int_pairs` 的
##     形态和 -1 的「本次不改」语义，不碰原生。
##  2. facade 出口层：`set_budget` 必须把 -1 原样送到桥接，不能被 GDScript
##     的默认参数吞掉。
##  3. 原生 op 注册层：`policy.set_budget` 必须出现在 op 表里，未配置的核心
##     必须明确拒绝而不是静默接受。
##
## 为什么不用完整的世界：`configure_military` 需要经济/科技/军事三份目录同时
## 就位，任何一份在工作区漂移都会让测试红掉，而它和预算信封无关。所以这里只
## 检查「桥接层把参数翻译对了没有」，切分算术交给原生自检
## （military_native_binding_test.gd 里的 budget envelope 段落）。
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
	_test_saved_shares_are_repushed_after_load()
	print("=== military budget policy: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


## 军事预算份额是 transient（需求 9.3）：原生不持久化，读档后归零就是退回
## 「无信封、按现金与需求直接结算」。会话必须自己留一份并重推，否则玩家存档
## 里的预算控制会静默消失，面板显示的份额也与原生真实政策对不上。
##
## 这里只验会话边界的三件事：记什么、什么时候重推、重推的参数形态。
## 原生那侧的份额语义已由 facade 用例与原生自检覆盖。
class _MilitaryFacadeStub:
	var batches: Array = []

	func submit(batch: Array) -> Dictionary:
		batches.append(batch)
		return {"ok": true, "accepted": batch.size(), "rejected": []}


class _GeneratorStub:
	var facade := _MilitaryFacadeStub.new()

	func get_military_facade():
		return facade


class _RuntimeHostStub:
	var generated := _GeneratorStub.new()

	func generator():
		return generated


func _test_saved_shares_are_repushed_after_load() -> void:
	var controller = ControllerScript.new()
	var host := _RuntimeHostStub.new()
	controller.set("_runtime_host", host)
	controller.set("_player_country_handle", 77)

	# 1) 没设过预算的会话读档不应该发任何命令：原生保持无信封，
	#    这正是存档前的行为，多发一条 0 会把「本来没有」变成「显式暂停」。
	controller.call("_restore_military_budget", {})
	_expect("a session that never set a budget repushes nothing",
		host.generated.facade.batches.is_empty())
	_expect("the saved envelope defaults to unset",
		int((controller.capture_view_state().get("military_budget", {}) as Dictionary)
			.get("total_bp", 0)) == -1)

	# 2) 记下玩家真正改过的项。`-1` 的项必须保留旧值：玩家拖一次军饷滑条
	#    不该顺带把维护与采购份额清成 -1（那会让原生沿用当前值而不是玩家设定）。
	controller.set("_military_budget_state", {
		"total_bp": 2500, "wage_bp": 5000, "upkeep_bp": 3000,
		"procurement_bp": 2000,
	})
	controller.call("_remember_military_budget", {"total_bp": 3000, "wage_bp": 6000})
	var remembered: Dictionary = controller.capture_view_state().get(
		"military_budget", {})
	_expect("an untouched channel keeps the share the player set earlier",
		int(remembered.get("upkeep_bp", 0)) == 3000
			and int(remembered.get("procurement_bp", 0)) == 2000)
	_expect("a touched channel takes the new share",
		int(remembered.get("wage_bp", 0)) == 6000
			and int(remembered.get("total_bp", 0)) == 3000)

	# 3) 读档重推：一份命令、原样份额、带玩家国家句柄。
	host.generated.facade.batches.clear()
	controller.call("_restore_military_budget", {
		"total_bp": 2500, "wage_bp": 5000, "upkeep_bp": 3000,
		"procurement_bp": 2000,
	})
	_expect("loading a saved budget repushes exactly once",
		host.generated.facade.batches.size() == 1)
	if host.generated.facade.batches.size() == 1:
		var batch: Array = host.generated.facade.batches[0]
		_expect("the repush is a single command", batch.size() == 1)
		var command: Dictionary = batch[0] if batch.size() == 1 else {}
		_expect("the repush uses the documented op",
			String(command.get("op", "")) == "policy.set_budget")
		_expect("the repush names the player country",
			int(command.get("country", 0)) == 77)
		_expect("the repush restores the envelope share",
			int(command.get("value", -1)) == 2500)
		var pairs := command.get("int_pairs", PackedInt32Array()) as PackedInt32Array
		_expect("the repush restores all three channel shares in order",
			pairs.size() == 3 and pairs[0] == 5000 and pairs[1] == 3000
				and pairs[2] == 2000, str(pairs))
	_expect("the restored shares survive a capture round trip",
		int((controller.capture_view_state().get("military_budget", {}) as Dictionary)
			.get("procurement_bp", 0)) == 2000)
	_run_repush_without_native()


## 旧原生 DLL 缺席（或加载的是没有 `policy.set_budget` 的旧版本）时，读档重推
## 必须安静失败而不是崩掉，也不能把自己标成「已推」——否则绑定真接上之后就
## 再也没有第二次机会，玩家读档后还是丢了预算控制。
class _GeneratorWithoutMilitary:
	func get_country_facade():
		return null


class _HostWithoutMilitary:
	var generated := _GeneratorWithoutMilitary.new()

	func generator():
		return generated


class _RejectingFacade:
	func submit(_batch: Array) -> Dictionary:
		return {"ok": false, "accepted": 0,
			"rejected": [{"index": 0, "reason": "unknown_op"}]}


class _GeneratorWithRejectingFacade:
	var facade := _RejectingFacade.new()

	func get_military_facade():
		return facade


class _HostWithRejectingFacade:
	var generated := _GeneratorWithRejectingFacade.new()

	func generator():
		return generated


func _run_repush_without_native() -> void:
	var saved := {
		"total_bp": 2500, "wage_bp": 5000, "upkeep_bp": 3000,
		"procurement_bp": 2000,
	}
	# 1) 军事 runtime 整块缺席：读档不崩，份额仍被记住，重推留在待办状态。
	var bare = ControllerScript.new()
	bare.set("_runtime_host", _HostWithoutMilitary.new())
	bare.set("_player_country_handle", 77)
	bare.call("_restore_military_budget", saved)
	_expect("a load without a military runtime does not crash",
		not bool(bare.call("_repush_military_budget")))
	_expect("the shares are still remembered when the native side is absent",
		int((bare.capture_view_state().get("military_budget", {}) as Dictionary)
			.get("wage_bp", 0)) == 5000)

	# 2) 旧 DLL 不认这个 op：拒绝原样浮上来，但会话不崩，也不标记已推，
	#    这样换成新 DLL 再绑定时还能补一次。
	var rejecting = ControllerScript.new()
	rejecting.set("_runtime_host", _HostWithRejectingFacade.new())
	rejecting.set("_player_country_handle", 77)
	rejecting.call("_restore_military_budget", saved)
	_expect("a native that rejects the op leaves the repush pending",
		not bool(rejecting.call("_repush_military_budget")))
	_expect("a rejected repush keeps the player's shares intact",
		int((rejecting.capture_view_state().get("military_budget", {}) as Dictionary)
			.get("total_bp", 0)) == 2500)


## Facade 是 UI 的唯一出口：set_budget 必须把 -1 原样送到桥接，不能被
## GDScript 的默认参数吞掉，也不能把 0（暂停）当成缺失值。
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
