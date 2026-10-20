extends Node

# 临时探针：走真实 `GameFlowService.begin_new_game()` → 玩家场景，然后纯泵帧，
# 每秒打一次 worker 的日等待/缺口/park 与各域 POD 状态，用来在 headless 下复现
# 「新开局日历冻结」。不驱动时钟：游戏自己会以 1x 跑。

const RUN_SECONDS := 150
const REPORT_EVERY := 120

var _generator: Object = null
var _frame := 0
var _reported_mask := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	await get_tree().process_frame
	var flow := get_node_or_null("/root/GameFlow")
	if flow == null:
		print("[autoplay] GameFlowService missing")
		get_tree().quit(1)
		return
	var config := NewGameConfig.create_default()
	var result: Dictionary = flow.begin_new_game(config)
	print("[autoplay] begin_new_game ok=%s code=%s" % [
		str(result.get("ok", false)), str(result.get("code", ""))])
	if not bool(result.get("ok", false)):
		get_tree().quit(2)
		return
	var deadline := Time.get_ticks_msec() + RUN_SECONDS * 1000
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		_frame += 1
		if _generator == null:
			_generator = _find_generator()
			if _generator != null:
				print("[autoplay] generator found at frame %d" % _frame)
		if _frame % REPORT_EVERY == 0:
			if _generator == null:
				print("[autoplay] waiting for world frame=%d" % _frame)
			else:
				_report()
	print("[autoplay] done frames=%d" % _frame)
	get_tree().quit(0)


func _find_generator() -> Object:
	# MapGenerator 是 RefCounted，不在场景树里；从 WorldRuntimeHost 拿。
	var scene := get_tree().current_scene
	if scene != null:
		var host = scene.get("_world_runtime_host")
		if host == null and scene.has_method("get_world_runtime_host"):
			host = scene.call("get_world_runtime_host")
		if host != null and host.has_method("get_generator"):
			var generator = host.call("get_generator")
			if generator != null:
				return generator
		var direct = scene.get("_generator")
		if direct != null and direct.has_method("get_runtime_thread_report"):
			return direct
	for node in get_tree().root.find_children("*", "", true, false):
		if node.has_method("get_generator"):
			var via_host = node.call("get_generator")
			if via_host != null and via_host.has_method("get_runtime_thread_report"):
				return via_host
	return null


func _domain_names(mask: int) -> String:
	if mask == 0:
		return "none"
	const NAMES := [
		"input_capture", "climate", "country", "trigger", "ideology", "effect",
		"modifier", "gameplay_effect", "economy", "events", "visual", "commit",
	]
	var parts := PackedStringArray()
	for bit in NAMES.size():
		if (mask & (1 << bit)) != 0:
			parts.append(String(NAMES[bit]))
	return "|".join(parts) if not parts.is_empty() else "0x%x" % mask


func _report() -> void:
	var host: Dictionary = _generator.get_runtime_thread_report()
	var clock = null
	for node in get_tree().root.find_children("*", "", true, false):
		if node.has_method("season_phase") and node.has_method("set_speed"):
			clock = node
			break
	var day := -1
	if clock != null:
		day = int(clock.call("current_day")) if clock.has_method("current_day") else -1
	print("[autoplay] t=%ds day=%s committed=%s inflight=%s missing=%s park=%s:%s effect_ready=%s effect_reason=%s econ=%s/%s"
		% [_frame / 60,
			str(day),
			str(host.get("simulation_committed_day", "?")),
			str(host.get("worker_day_inflight", "?")),
			_domain_names(int(host.get("day_wait_missing_mask", 0))),
			_domain_names(int(host.get("day_park_domain_mask", 0))),
			str(host.get("day_park_reason", "")),
			str(host.get("effect_pod_ready", "?")),
			str(host.get("effect_pod_fallback_reason", "")),
			str(host.get("economy_stage_name", "?")),
			str(host.get("economy_yield_reason", ""))])
