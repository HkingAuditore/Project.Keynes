extends SceneTree

const Values = preload("res://scripts/game/world_runtime_host_values.gd")
const Reference = preload("res://tests/game/world_runtime_host_values_reference.gd")
var failures := 0
var checks := 0

func _init() -> void:
	var host := WorldRuntimeHost.new()
	var helper := Values.new()
	var reference := Reference.new()
	var cases: Array = []
	for error in [{}, {"summary": "失败", "stage": "bake", "reason": "", "hint": ""},
			{"summary": "错误", "stage": "prepare", "reason": "资源缺失", "hint": "重试"}]:
		cases.append(["_world_generation_failure_summary", [error]])
	for detail in [["prepare", "missing", "资源缺失", "重试", "2026-11-04T00:00:00"],
		["unknown", "", "失败", "", ""]]:
		var expected: String = reference.callv("_format_world_generation_detail", detail)
		_check("failure detail fixed timestamp", helper.callv("_format_world_generation_detail", detail) == expected)
		var actual: String = host.callv("_format_world_generation_detail", detail.slice(0, 4))
		var lines := actual.split("\n")
		_check("host samples a timestamp", lines[1].length() > "时间 timestamp : ".length())
		lines[1] = "时间 timestamp : %s" % detail[4]
		_check("host detail forwarding", "\n".join(lines) == expected)
	for values in [PackedFloat32Array(), PackedFloat32Array([-1, 0, 0.0001, 0.70, 1]),
			PackedFloat32Array([NAN, INF, -INF]), PackedFloat32Array([NAN, 2, INF, -3])]:
		cases.append(["_flow_buffer_stats", [values, 17]])
	var large := PackedFloat32Array()
	large.resize(131073)
	for i in range(large.size()):
		large[i] = float(i % 7) / 7.0
	cases.append(["_flow_buffer_stats", [large, large.size()]])
	for format in [-1, Image.FORMAT_L8, Image.FORMAT_R8, Image.FORMAT_RG8, Image.FORMAT_RGBA8, Image.FORMAT_RF, 999]:
		cases.append(["_flow_format_descriptor", [format]])
	for required in [true, false]:
		cases.append(["_gm_arg", ["参数", "int", required]])
	cases.append(["_gm_choice_arg", ["mode", ["a", "b"]]])
	cases.append(["_gm_choice_arg", ["mode", PackedStringArray(["a", "b"])]])
	for type in ["float", "int", "string"]:
		cases.append(["_gm_positive_arg", ["amount", type]])
	cases.append(["_gm_positive_arg", ["amount"]])
	cases.append(["_gm_day_arg", []])
	cases.append(["_gm_ok", ["完成", true, 7]])
	cases.append(["_gm_ok", ["", false, -1]])
	cases.append(["_gm_error", ["bad", "错误"]])
	cases.append(["_gm_error", ["bad", "错误", {"nested": [1, 2]}]])
	for item in cases:
		var args: Array = item[1]
		var untouched := args.duplicate(true)
		var expected: Variant = reference.callv(item[0], args)
		_check(item[0] + " helper", _same(helper.callv(item[0], args), expected))
		_check(item[0] + " host", _same(host.callv(item[0], args), expected))
		_check(item[0] + " input unchanged", _same(args, untouched))
	for object in [reference, helper, host]:
		var choices := ["before"]
		var choice: Dictionary = object.call("_gm_choice_arg", "x", choices)
		choices.append("after")
		_check("choices retain borrowed reference", choice.choices.size() == 2)
		var data := {"count": 1}
		var error: Dictionary = object.call("_gm_error", "x", "y", data)
		data.count = 2
		_check("error data retains borrowed reference", error.data.count == 2)
		var first: Dictionary = object.call("_gm_error", "x", "y")
		first.data["probe"] = true
		_check("default data remains fresh", not object.call("_gm_error", "x", "y").data.has("probe"))
	host.free()
	print("host values: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _same(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is float:
		return (is_nan(a) and is_nan(b)) or a == b
	if a is Dictionary:
		if a.keys() != b.keys():
			return false
		for key in a:
			if not _same(a[key], b[key]):
				return false
		return true
	if a is Array or a is PackedFloat32Array:
		if a.size() != b.size():
			return false
		for i in range(a.size()):
			if not _same(a[i], b[i]):
				return false
		return true
	return a == b

func _check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("[FAIL] " + label)
