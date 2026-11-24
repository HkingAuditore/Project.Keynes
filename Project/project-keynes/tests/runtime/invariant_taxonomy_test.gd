extends SceneTree

## R1-10：断言台账 + 构建标识验收。
## 依据：docs/plans/runtime-fault-infrastructure-plan.md §4.6 / checklist R1-10。
##
## 判据（两条都要成立，缺一条就 exit 1）：
##   * `build_id` 非空且包含 `+`：构建脚本按 `<git 短 sha>+<utc 时间戳>` 注入，
##     没有 git 时退化为 `nogit+<utc 时间戳>`。没有 `+` 说明读到的是占位串或
##     另一个字段，不能当成通过。
##   * `assert_id` 非空：`fault_taxonomy.h` 的 reason→id 表能把一个已登记的
##     fatal reason 反查到台账 ID。
##
## 用法：
##   godot --headless --path Project/project-keynes \
##     --script res://tests/runtime/invariant_taxonomy_test.gd
## 退出码：0 = 两条 ID 都读到；1 = 缺一条或缺失绑定。
##
## 为什么允许多条取值路径：`build_id` / `assert_id` 由 C++ 侧并行落地，暴露位置
## 可能先从 `fatal_context_report()` 出现，也可能先挂到 `get_economy_report()`。
## 这里按「已 boot 的 world_ext → 冷 world_ext」逐条探测，读到即记录来源；输出里的
## `source` / `attempts` 写明是哪条路径读到的，否则下一个人还得重猜一遍。
## **缺绑定就如实报 missing_binding 并 exit 1，不假绿。**

## 台账已登记、必须能反查到 assert_id 的一个 reason（fault_taxonomy.h INV-ECON-0042）。
const PROBE_REASON := "building_construction_preflight_funds_drift"
const PROBE_ASSERT_ID := "INV-ECON-0042"

## 读取路径的候选顺序。方法不存在就跳过，方法存在但返回空同样记录后继续。
const REPORT_PROBES := [
	"get_economy_report",
	"get_runtime_thread_report",
	"fatal_context_report",
	"get_economy_fatal_context_report",
	"get_fault_taxonomy_report",
	"get_economy_diagnostics_report",
	"get_runtime_diagnostics_report",
	"get_build_info",
]

var _failures := PackedStringArray()
var _result := {
	"build_id": "",
	"assert_id": "",
	"ok": false,
	"reason": "",
	"source": {},
	"attempts": [],
}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("missing_binding:DCWorldExt")
		_finish()
		return
	var ext: Object = DCWorldExt.new()

	# 冷 world_ext：只用来确认 report 形状，真实取值放在 boot 之后 —— worker 起来后
	# report 才带诊断段（build_id 属于「哪个二进制在跑」，不在模拟状态里）。
	var cold_report: Dictionary = _report(ext, "get_economy_report")
	_result["cold_economy_report_keys"] = cold_report.keys()

	var booted := _boot(ext)
	_result["booted"] = booted
	if not booted:
		_failures.append("world_ext_worker_boot_failed")

	var build := _probe_id(ext, "build_id")
	var assert_probe := _probe_id(ext, "assert_id")
	_result["build_id"] = String(build.get("value", ""))
	_result["assert_id"] = String(assert_probe.get("value", ""))
	_result["source"] = {
		"build_id": String(build.get("source", "")),
		"assert_id": String(assert_probe.get("source", "")),
	}
	if String(build.get("value", "")).is_empty():
		_failures.append("missing_binding:build_id")
	elif not String(build.get("value", "")).contains("+"):
		# 只断言「非空」会放过硬编码占位串，`+` 是构建脚本契约的一部分。
		_failures.append("build_id_missing_utc_suffix")
	if String(assert_probe.get("value", "")).is_empty():
		_failures.append("missing_binding:assert_id")
	elif String(assert_probe.get("value", "")) != PROBE_ASSERT_ID:
		# fault_taxonomy.h 把该 reason 固定映射到 INV-ECON-0042；不一致说明
		# C++ 表和台账已经漂移，属于必须拦住的问题，不是「换了个好 ID」。
		_failures.append("assert_id_mismatch:%s" % String(assert_probe.get("value", "")))

	_stop(ext)
	_result["ok"] = _failures.is_empty()
	_result["reason"] = "" if _failures.is_empty() else ",".join(_failures)
	print("[invariant-taxonomy] build_id=%s assert_id=%s booted=%s" % [
		_result["build_id"], _result["assert_id"], booted])
	for attempt in _result["attempts"]:
		print("[invariant-taxonomy/probe] %s" % JSON.stringify(attempt))
	_finish()


## 返回 {value, source}；value 为空串表示这次没读到。
func _probe_id(ext: Object, key: String) -> Dictionary:
	for method in REPORT_PROBES:
		if not ext.has_method(method):
			_result["attempts"].append({"source": "%s.%s" % [method, key],
				"present": false})
			continue
		var report: Dictionary = _report(ext, method)
		var value := String(report.get(key, ""))
		_result["attempts"].append({"source": "%s.%s" % [method, key],
			"present": true, "value": value})
		if not value.is_empty():
			return {"value": value, "source": "%s.%s" % [method, key]}
	# `assert_id` 还可以从台账反查得到：给 replay 探针/反查绑定一个已登记 reason。
	if key == "assert_id":
		var replay := _probe_assert_id_via_replay(ext)
		if not String(replay.get("value", "")).is_empty():
			return replay
		var direct := _probe_assert_id_direct(ext)
		if not String(direct.get("value", "")).is_empty():
			return direct
	if key == "build_id":
		var scalar := _probe_scalar(ext, key,
			["pk_build_id", "get_build_id", "build_id"])
		if not String(scalar.get("value", "")).is_empty():
			return scalar
	return {"value": "", "source": ""}


## 不包在 report 里、直接返回字符串的出口（例如 `pk_build_id()`）。
func _probe_scalar(ext: Object, key: String, methods: Array) -> Dictionary:
	for method in methods:
		if not ext.has_method(method):
			_result["attempts"].append({"source": "%s()" % method,
				"present": false})
			continue
		var outcome: Variant = ext.call(method)
		var value := ""
		if outcome is String or outcome is StringName:
			value = String(outcome)
		_result["attempts"].append({"source": "%s()" % method,
			"present": true, "value": value})
		if not value.is_empty():
			return {"value": value, "source": "%s()" % method}
	return {"value": "", "source": ""}


## R3 的 `economy_replay_incident`：即使看不懂 witness，它也是 C++ 常量表的一条
## 现成出口。绑定还没落地时记录 present=false 并继续，不报错。
func _probe_assert_id_via_replay(ext: Object) -> Dictionary:
	var method := "economy_replay_incident"
	if not ext.has_method(method):
		_result["attempts"].append({"source": "%s.assert_id" % method,
			"present": false})
		return {"value": "", "source": ""}
	var outcome: Variant = ext.call(method, {"reason": PROBE_REASON})
	var report: Dictionary = outcome if outcome is Dictionary else {}
	var value := String(report.get("assert_id", ""))
	_result["attempts"].append({"source": "%s.assert_id" % method,
		"present": true, "value": value})
	return {"value": value, "source": "%s.assert_id" % method} \
		if not value.is_empty() else {"value": "", "source": ""}


## 最直接的出口：一个只做 reason→assert_id 反查的绑定（如果有）。
func _probe_assert_id_direct(ext: Object) -> Dictionary:
	for method in ["fault_assert_id", "get_fault_assert_id",
			"assert_id_for_reason"]:
		if not ext.has_method(method):
			continue
		var outcome: Variant = ext.call(method, PROBE_REASON)
		var value := String(outcome) if outcome is String or outcome is StringName else ""
		_result["attempts"].append({"source": "%s(%s)" % [method, PROBE_REASON],
			"present": true, "value": value})
		if not value.is_empty():
			return {"value": value, "source": "%s(%s)" % [method, PROBE_REASON]}
	return {"value": "", "source": ""}


func _report(ext: Object, method: String) -> Dictionary:
	if not ext.has_method(method):
		return {}
	var outcome: Variant = ext.call(method)
	return outcome if outcome is Dictionary else {}


## SHADOW worker 足够把 report 拉到「已 boot」形态，且不推进任何模拟日。
func _boot(ext: Object) -> bool:
	if not ext.has_method("start_runtime_worker"):
		return false
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	return bool(started.get("ok", false))


func _stop(ext: Object) -> void:
	if not ext.has_method("request_runtime_stop"):
		return
	ext.call("request_runtime_stop")
	# 不等 simulation_executor_exited：这个测试只读常量，进程退出即可；
	# 但给 worker 一点时间落地，避免 shutdown 阶段打一堆无关告警。
	OS.delay_msec(20)


func _fail(reason: String) -> void:
	_failures.append(reason)
	push_error("[invariant-taxonomy] %s" % reason)


func _finish() -> void:
	if not _result["ok"]:
		_result["ok"] = _failures.is_empty()
		_result["reason"] = "" if _failures.is_empty() else ",".join(_failures)
	# 单行机读结果。前缀不要改，验收命令按这个前缀解析。
	print("[invariant-taxonomy/result] %s" % JSON.stringify(_result))
	quit(0 if _failures.is_empty() else 1)
