extends RefCounted

# Passive value helpers. Sampling, signals and world state stay in the host.

static func _world_generation_failure_summary(err: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	parts.append(String(err.get("summary", "地图生成失败。")))
	parts.append("阶段=%s" % String(err.get("stage", "?")))
	var reason := String(err.get("reason", ""))
	if not reason.is_empty():
		parts.append("原因=%s" % reason)
	var hint := String(err.get("hint", ""))
	if not hint.is_empty():
		parts.append(hint)
	return " ".join(parts)


static func _format_world_generation_detail(stage: String, reason: String,
		summary: String, hint: String, timestamp: String) -> String:
	var lines: PackedStringArray = PackedStringArray()
	lines.append("=== 世界准备失败 / mapgen fatal ===")
	lines.append("时间 timestamp : %s" % timestamp)
	lines.append("阶段 stage     : %s" % stage)
	lines.append("原因 reason    : %s" % reason)
	lines.append("摘要 summary   : %s" % summary)
	if not hint.is_empty():
		lines.append("排查 hint      : %s" % hint)
	lines.append("说明           : 该失败发生在 MapGenerator 之外（地图本身可能已生成成功）。")
	return "\n".join(lines)


static func _flow_buffer_stats(buffer: PackedFloat32Array, expected: int) -> Dictionary:
	var n := buffer.size()
	if n <= 0:
		return {"size": 0, "expected": expected, "samples": 0}
	var stride := maxi(1, n / 65536)
	var min_value := INF
	var max_value := -INF
	var sum := 0.0
	var high := 0
	var nonzero := 0
	var nonfinite := 0
	var samples := 0
	var i := 0
	while i < n:
		var value := float(buffer[i])
		if not is_finite(value):
			nonfinite += 1
		else:
			min_value = minf(min_value, value)
			max_value = maxf(max_value, value)
			sum += value
			if value >= 0.70:
				high += 1
			if value > 0.0001:
				nonzero += 1
		samples += 1
		i += stride
	return {"size": n, "expected": expected, "samples": samples, "stride": stride,
		"min": min_value, "max": max_value, "mean": sum / float(maxi(samples, 1)),
		"hi_frac": float(high) / float(maxi(samples, 1)),
		"nonzero_frac": float(nonzero) / float(maxi(samples, 1)), "nonfinite": nonfinite}


static func _flow_format_descriptor(format: int) -> Dictionary:
	var name := "unknown"
	match format:
		Image.FORMAT_L8:
			name = "L8"
		Image.FORMAT_R8:
			name = "R8"
		Image.FORMAT_RG8:
			name = "RG8"
		Image.FORMAT_RGBA8:
			name = "RGBA8"
	return {"id": format, "name": name}


static func _gm_arg(name: String, type: String, required: bool) -> Dictionary:
	return {"name": name, "type": type, "required": required}


static func _gm_choice_arg(name: String, choices) -> Dictionary:
	return {"name": name, "type": "string", "required": true, "choices": choices}


static func _gm_positive_arg(name: String, type: String = "float") -> Dictionary:
	return {"name": name, "type": type, "required": true, "min": 0.000001 if type == "float" else 1}


static func _gm_day_arg() -> Dictionary:
	return {"name": "day", "type": "int", "required": false, "min": 0}


static func _gm_ok(message: String, queued: bool, effective_day: int) -> Dictionary:
	return {"ok": true, "code": "ok", "message": message,
		"queued": queued, "effective_day": effective_day, "data": {}}


static func _gm_error(code: String, message: String, data: Dictionary = {}) -> Dictionary:
	return {"ok": false, "code": code, "message": message,
		"queued": false, "effective_day": -1, "data": data}
