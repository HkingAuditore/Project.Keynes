extends RefCounted

## Owns diagnostic day-cost buckets and payload emission. It cannot advance or pause the clock.

const DAY_COST_PAYLOAD_MAX_BYTES := 200

const _DAY_COST_CORE_TAGS: Array[StringName] = [
	&"clk", &"host", &"inl", &"cmt", &"pc", &"pcui", &"s1", &"s2",
]

const _DAY_COST_DETAIL_TAGS: Array[StringName] = [
	&"rep", &"wb", &"pcr", &"cap", &"pub", &"fin", &"res", &"vis", &"wait", &"dup",
]

const _DAY_COST_MAIN_TAGS: Array[StringName] = [
	&"main", &"lab", &"sph", &"ren", &"mui", &"ovl", &"rec",
]

var _dcp_seg: Dictionary = {}
var _dcp_day: int = -1
var _dcp_dispatch_usec: int = 0
var _dcp_jobs: Dictionary = {}
var _dcp_last: Dictionary = {}
var _dcp_last_seg: Dictionary = {}
var _dcp_last_main: Dictionary = {}
var _dcp_last_sus: Dictionary = {}
var _dcp_emitted: int = 0
var _dcp_console: bool = false
var day_cost_probe_on: bool = false

func day_cost_probe_enabled() -> bool:
	return day_cost_probe_on


func day_cost_add(tag: StringName, ms: float) -> void:
	if not day_cost_probe_on:
		return
	_dcp_seg[tag] = float(_dcp_seg.get(tag, 0.0)) + ms


func day_cost_job(job_id: String, ms: float) -> void:
	if not day_cost_probe_on:
		return
	_dcp_jobs[job_id] = float(_dcp_jobs.get(job_id, 0.0)) + ms


func day_cost_jobs_from(report: Dictionary) -> void:
	if not day_cost_probe_on or report.is_empty():
		return
	for job_id in report.keys():
		var job_report = report[job_id]
		if job_report is Dictionary:
			var ms: float = float((job_report as Dictionary).get("elapsed_ms", 0.0))
			if ms > 0.0:
				day_cost_job(String(job_id), ms)


func day_cost_last() -> Dictionary:
	return _dcp_last.duplicate(true)


func day_cost_last_main() -> Dictionary:
	return _dcp_last_main.duplicate(true)


func day_cost_last_seg() -> Dictionary:
	return _dcp_last_seg.duplicate(true)


func day_cost_last_sus() -> Dictionary:
	return _dcp_last_sus.duplicate(true)


func day_cost_emitted_count() -> int:
	return _dcp_emitted


func day_cost_flush() -> void:
	if not day_cost_probe_on or (_dcp_seg.is_empty() and _dcp_jobs.is_empty()):
		return
	# 派生段：派发总时长 − host 自身 = 其余监听者（当前生产场景只有
	# PlayerController）。用两个**各自只测一次**的 epoch 相减，不是重复计时。
	var host_ms: float = float(_dcp_seg.get(&"host", 0.0))
	var clk_ms: float = float(_dcp_seg.get(&"clk", 0.0))
	if host_ms > 0.0 and clk_ms >= host_ms:
		_dcp_seg[&"pc"] = clk_ms - host_ms
	var core: Dictionary = _dcp_group_payload(_DAY_COST_CORE_TAGS)
	var detail: Dictionary = _dcp_group_payload(_DAY_COST_DETAIL_TAGS)
	var detail_any: bool = _dcp_group_any(_DAY_COST_DETAIL_TAGS)
	var main_payload: Dictionary = _dcp_group_payload(_DAY_COST_MAIN_TAGS)
	var main_any: bool = _dcp_group_any(_DAY_COST_MAIN_TAGS)
	var jobs: Dictionary = _dcp_jobs.duplicate()
	_dcp_seg.clear()
	_dcp_jobs.clear()
	_dcp_emitted += 1
	_dcp_last = core
	_dcp_last_seg = detail if detail_any else {}
	_dcp_last_main = main_payload if main_any else {}
	WebTelemetry.emit("day_cost", core)
	if _dcp_console:
		print("[day_cost] t=%d %s" % [Time.get_ticks_msec(), JSON.stringify(core)])
	# host 细分：cmt 的子项（pub/fin/res/vis）与 host 前段（rep/wb/pcr/cap/wait）。
	# 生产 web 路径几乎每天都有值（wb/pcr/cap 总要跑），所以这是第 2 条事件。
	if detail_any:
		WebTelemetry.emit("day_cost_seg", detail)
		if _dcp_console:
			print("[day_cost_seg] t=%d %s" % [Time.get_ticks_msec(), JSON.stringify(detail)])
	# main.tscn 那套监听者才有值的段：生产 web 路径恒不发送。
	if main_any:
		WebTelemetry.emit("day_cost_main", main_payload)
		if _dcp_console:
			print("[day_cost_main] t=%d %s" % [Time.get_ticks_msec(), JSON.stringify(main_payload)])
	# 逐 Job 拆解只在 GDScript SUS 日 tick 真的跑过时才有意义（生产 web 内联
	# 路径 s1=s2=0、jobs 为空，这条事件整天不出现，本身就是证据）。
	if jobs.is_empty():
		return
	var parts := PackedStringArray()
	var ids: Array = jobs.keys()
	ids.sort_custom(func(a, b): return float(jobs[a]) > float(jobs[b]))
	for i in mini(ids.size(), 8):
		parts.append("%s=%d" % [String(ids[i]), int(round(float(jobs[ids[i]])))])
	var sus_payload: Dictionary = {
		"d": _dcp_day,
		"n": ids.size(),
		"j": " ".join(parts),
	}
	WebTelemetry.emit("day_cost_sus", sus_payload)
	if _dcp_console:
		print("[day_cost_sus] t=%d %s" % [Time.get_ticks_msec(), JSON.stringify(sus_payload)])
	_dcp_last_sus = sus_payload


func _dcp_group_payload(tags: Array[StringName]) -> Dictionary:
	var payload: Dictionary = {"d": _dcp_day}
	for tag in tags:
		payload[String(tag)] = int(round(float(_dcp_seg.get(tag, 0.0))))
	if JSON.stringify(payload).length() <= DAY_COST_PAYLOAD_MAX_BYTES - 40:
		return payload
	var values := PackedStringArray()
	for tag in tags:
		values.append(str(int(round(float(_dcp_seg.get(tag, 0.0))))))
	return {"d": _dcp_day, "v": " ".join(values)}


func _dcp_group_any(tags: Array[StringName]) -> bool:
	for tag in tags:
		if int(round(float(_dcp_seg.get(tag, 0.0)))) != 0:
			return true
	return false


func _dcp_elapsed_ms(started_usec: int) -> float:
	if started_usec <= 0:
		return 0.0
	return float(Time.get_ticks_usec() - started_usec) / 1000.0
