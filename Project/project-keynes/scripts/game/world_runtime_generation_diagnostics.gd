extends RefCounted

# ─── 地图生成失败诊断（mapgen-diagnostics）───────────────────────────────
# generate_world 失败时把 MapGenerator.last_generation_error 整块留在 host 上，
# 由 player_game 交给 WorldLoadingOverlay 展示/复制/落盘。

static func last_world_generation_error_text(host) -> String:
	if host.last_world_generation_error.is_empty():
		return ""
	var detail = String(host.last_world_generation_error.get("detail_text", ""))
	if not detail.is_empty():
		return detail
	# 兜底：没有 detail_text 时用 JSON，但必须先剔除原始 native report——
	# 它带 10+ 个 n_cells 级 PackedArray，直接 stringify 会产出几 MB 文本。
	var safe = host.last_world_generation_error.duplicate()
	safe.erase("native_report_raw")
	return JSON.stringify(safe, "  ", true)


## 生成失败归因：把 MapGenerator 的结构化错误压成"一句中文 + 阶段 + 原因 + 排查建议"。
## 传 preflight_override 时表示失败发生在 generate() 之前（自检拦下）。

static func _report_world_generation_failure(host, preflight_override: Dictionary = {}) -> void:
	var err: Dictionary = {}
	if host._generator != null:
		# 浅拷贝：只复制顶层键，native_report_raw 仍指向同一份原始字典（不重复分配）。
		err = host._generator.last_generation_error.duplicate()
	if err.is_empty() and not preflight_override.is_empty():
		var first_issue = ""
		var issues: Array = preflight_override.get("issues", [])
		if not issues.is_empty() and issues[0] is Dictionary:
			first_issue = String((issues[0] as Dictionary).get("message", ""))
		err = {
			"stage": "preflight",
			"reason": "preflight_failed",
			"summary": "生成前自检未通过：%s" % first_issue,
			"hint": "按下面 preflight 里点名的缺失项处理；安卓一般是原生库缺失/过旧。",
			"preflight": preflight_override,
			"env": preflight_override.get("env", {}),
			"native_report": {},
			"superseded": false,
		}
	if err.is_empty():
		err = {
			"stage": "unknown",
			"reason": "map_generator_failed",
			"summary": "地图生成器返回空结果，且未留下任何诊断信息。",
			"hint": "这是 MapGenerator 之外的调用层问题；请附完整 logcat/godot.log。",
			"preflight": {},
			"env": {},
			"native_report": {},
			"superseded": false,
		}
	# 被新一轮 generate 取代：不弹失败面板，否则会盖住新一轮的进度条。
	if bool(err.get("superseded", false)):
		print("[mapgen] generation superseded at stage=%s (no failure UI)"
			% String(err.get("stage", "?")))
		return
	if host._generator != null:
		err["detail_text"] = host._generator.last_generation_error_text()
	host.last_world_generation_error = err
	var summary = host._world_generation_failure_summary(err)
	# 同一行同时 print + push_error：print 给 adb logcat，push_error 给编辑器/错误面板。
	print("[mapgen][fatal] %s" % summary)
	push_error("[mapgen][fatal] %s" % summary)
	host.world_generation_failed.emit(summary)


## 非 MapGenerator 来源的失败（开局初始化 / 存档恢复）：自建诊断记录后统一上报。
## 走同一条 print+push_error+signal 通道，保证 UI/日志/文件三处看到的是同一段文本。

static func _emit_world_generation_failure(host, stage: String, reason: String, summary: String, hint: String) -> void:
	host.last_world_generation_error = {
		"stage": stage,
		"reason": reason,
		"summary": summary,
		"hint": hint,
		"preflight": {},
		"env": {},
		"native_report": {},
		"superseded": false,
		"detail_text": host._format_world_generation_detail(stage, reason, summary, hint),
	}
	var line = host._world_generation_failure_summary(host.last_world_generation_error)
	print("[mapgen][fatal] %s" % line)
	push_error("[mapgen][fatal] %s" % line)
	host.world_generation_failed.emit(line)


## 非 MapGenerator 来源失败的多行详情（结构与 MapGenerator 的保持同构，便于统一复制）。

static func _format_world_generation_detail(host, stage: String, reason: String, summary: String, hint: String) -> String:
	var timestamp = Time.get_datetime_string_from_system(true)
	return host.HostValueHelpers._format_world_generation_detail(
		stage, reason, summary, hint, timestamp)


## 一句话摘要：含 stage + reason + 一句排查建议（玩家能看懂、开发者能定位）。

static func _world_generation_failure_summary(host, err: Dictionary) -> String:
	return host.HostValueHelpers._world_generation_failure_summary(err)
