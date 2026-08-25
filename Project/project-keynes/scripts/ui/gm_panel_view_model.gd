extends RefCounted
class_name GMPanelViewModel

const MAX_REPORT_ROWS := 14
const MAX_COHORT_ROWS := 12
const MAX_MARKET_ROWS := 18
const MAX_BUILDING_ROWS := 12
const MAX_HISTORY := 50
const COUNTRY_PINNED_REPORT_KEYS := [
	"country_day_barrier", "stage", "last_committed_day",
]
const ECONOMY_PINNED_REPORT_KEYS := [
	"fatal", "fatal_reason", "stage", "epoch_active", "epoch_id",
	"current_day", "last_completed_sample_day", "newest_state_day",
	"population_error", "money_error", "goods_error",
]


static func parse_command(line: String) -> Dictionary:
	var tokenized := _tokenize(line)
	if not bool(tokenized.get("ok", false)):
		return tokenized
	var tokens: PackedStringArray = tokenized.get("tokens", PackedStringArray())
	if tokens.is_empty():
		return {"ok": false, "code": "empty_command", "message": "请输入指令。"}
	var args := {}
	for i in range(1, tokens.size()):
		var token := String(tokens[i])
		var split_at := token.find("=")
		if split_at <= 0:
			return {"ok": false, "code": "argument_syntax",
				"message": "参数必须使用 key=value：%s" % token}
		var key := token.substr(0, split_at).strip_edges()
		if args.has(key):
			return {"ok": false, "code": "duplicate_argument", "message": "参数重复：%s" % key}
		args[key] = token.substr(split_at + 1)
	return {"ok": true, "command_id": String(tokens[0]), "args": args}


static func command_suggestions(line: String, commands: Array) -> PackedStringArray:
	var trimmed := line.strip_edges()
	var suggestions := PackedStringArray()
	if trimmed.find(" ") < 0:
		for raw in commands:
			var command: Dictionary = raw
			var command_id := String(command.get("id", ""))
			if command_id.begins_with(trimmed):
				suggestions.append(command_id)
			if suggestions.size() >= 8:
				break
		return suggestions
	var first_space := trimmed.find(" ")
	var command_id := trimmed.substr(0, first_space)
	var tail := trimmed.substr(first_space + 1)
	var last_space := tail.rfind(" ")
	var fragment := tail.substr(last_space + 1) if last_space >= 0 else tail
	var spec := _find_command(commands, command_id)
	if spec.is_empty():
		return suggestions
	var equals := fragment.find("=")
	if equals < 0:
		for raw_arg in spec.get("args", []):
			var arg: Dictionary = raw_arg
			var name := String(arg.get("name", ""))
			if name.begins_with(fragment):
				suggestions.append("%s=" % name)
		return suggestions
	var arg_name := fragment.substr(0, equals)
	var value_prefix := fragment.substr(equals + 1)
	for raw_arg in spec.get("args", []):
		var arg: Dictionary = raw_arg
		if String(arg.get("name", "")) != arg_name:
			continue
		for choice in arg.get("choices", []):
			var value := str(choice)
			if value.begins_with(value_prefix):
				suggestions.append("%s=%s" % [arg_name, value])
			if suggestions.size() >= 8:
				break
		break
	return suggestions


static func describe_command(command: Dictionary) -> String:
	var parts := PackedStringArray([String(command.get("id", ""))])
	for raw_arg in command.get("args", []):
		var arg: Dictionary = raw_arg
		var token := "%s=<%s>" % [String(arg.get("name", "")), String(arg.get("type", "string"))]
		if not bool(arg.get("required", false)):
			token = "[%s]" % token
		parts.append(token)
	return " ".join(parts)


static func validate_command(parsed: Dictionary, commands: Array) -> Dictionary:
	if not bool(parsed.get("ok", false)):
		return parsed
	var command_id := String(parsed.get("command_id", ""))
	var spec := _find_command(commands, command_id)
	if spec.is_empty():
		return {"ok": false, "code": "unknown_command", "message": "未知指令：%s" % command_id}
	var raw_args: Dictionary = parsed.get("args", {})
	var converted := {}
	for raw_spec in spec.get("args", []):
		var arg: Dictionary = raw_spec
		var name := String(arg.get("name", ""))
		if not raw_args.has(name):
			if arg.has("default"):
				converted[name] = arg.get("default")
			elif bool(arg.get("required", false)):
				return {"ok": false, "code": "missing_argument", "message": "缺少参数：%s" % name}
			continue
		var value_result := _convert_value(raw_args[name], arg)
		if not bool(value_result.get("ok", false)):
			return {"ok": false, "code": "invalid_argument", "message": "参数 %s：%s" % [
				name, value_result.get("message", "格式错误")]}
		converted[name] = value_result.get("value")
	for key in raw_args.keys():
		var known := false
		for raw_spec in spec.get("args", []):
			if String((raw_spec as Dictionary).get("name", "")) == String(key):
				known = true
				break
		if not known:
			return {"ok": false, "code": "unknown_argument", "message": "未知参数：%s" % key}
	return {"ok": true, "command_id": command_id, "args": converted, "spec": spec}


static func push_history(history: Array, line: String, limit: int = MAX_HISTORY) -> Array:
	var result := history.duplicate()
	var normalized := line.strip_edges()
	if normalized == "":
		return result
	if not result.is_empty() and String(result.back()) == normalized:
		return result
	result.append(normalized)
	while result.size() > maxi(limit, 1):
		result.pop_front()
	return result


static func history_entry(history: Array, cursor: int) -> String:
	if history.is_empty() or cursor < 0 or cursor >= history.size():
		return ""
	return String(history[cursor])


static func format_snapshot(section: String, snapshot: Dictionary) -> Array:
	if not bool(snapshot.get("ok", false)):
		return [{"title": "状态", "rows": [{"label": "结果",
			"value": String(snapshot.get("message", "数据不可用"))}]}]
	var data: Dictionary = snapshot.get("data", {})
	return _format_overview(data) if section == "overview" else _format_selected(data)


static func _format_overview(data: Dictionary) -> Array:
	var world: Dictionary = data.get("world", {})
	var clock: Dictionary = data.get("clock", {})
	var runtime: Dictionary = data.get("runtime", {})
	var sections := [
		{"title": "世界", "rows": [
			{"label": "状态", "value": "已就绪" if bool(world.get("ready", false)) else "未生成"},
			{"label": "种子", "value": str(world.get("seed", 0))},
			{"label": "地图", "value": "%s × %s · %s 格" % [world.get("width", 0), world.get("height", 0), world.get("cells", 0)]},
		]},
		{"title": "时间", "rows": [
			{"label": "日期", "value": "第%s年 %s月%s日" % [clock.get("year", 0), clock.get("month", 0), clock.get("day", 0)]},
			{"label": "游戏日", "value": str(clock.get("day_index", -1))},
			{"label": "状态", "value": "暂停" if bool(clock.get("paused", false)) else "运行中"},
			{"label": "速度", "value": "%sx" % clock.get("speed", 0)},
		]},
		{"title": "运行时", "rows": [
			{"label": "Fast tick", "value": str(runtime.get("fast_tick", 0))},
			{"label": "最近耗时", "value": "%s ms" % runtime.get("last_tick_ms", 0)},
		]},
	]
	_append_scalar_report(sections, "国家运行时", data.get("country", {}),
		COUNTRY_PINNED_REPORT_KEYS)
	_append_scalar_report(sections, "经济运行时", data.get("economy", {}),
		ECONOMY_PINNED_REPORT_KEYS)
	var recorders: Dictionary = data.get("recorders", {})
	var recorder_rows := []
	for key in ["performance", "tiles", "economy"]:
		var item: Dictionary = recorders.get(key, {})
		recorder_rows.append({"label": key, "value": "%s · %s 行" % [
			"录制中" if bool(item.get("recording", false)) else "停止", item.get("rows", 0)]})
	sections.append({"title": "记录器", "rows": recorder_rows})
	return sections


static func _format_selected(data: Dictionary) -> Array:
	var cell: Dictionary = data.get("cell", {})
	var country: Dictionary = data.get("country_summary", {})
	var sections := [
		{"title": "地块", "rows": [
			{"label": "索引", "value": str(cell.get("index", -1))},
			{"label": "Cube 坐标", "value": "%s, %s" % [cell.get("q", 0), cell.get("r", 0)]},
			{"label": "地形 / 地貌", "value": "%s / %s" % [cell.get("terrain", 0), cell.get("landform", 0)]},
			{"label": "温度", "value": "%.4f" % float(cell.get("temperature", 0.0))},
			{"label": "湿度", "value": "%.4f" % float(cell.get("moisture", 0.0))},
			{"label": "高程", "value": "%.4f" % float(cell.get("elevation", 0.0))},
		]},
		{"title": "国家", "rows": [
			{"label": "名称", "value": String(country.get("country_name", "无主之地"))},
			{"label": "Stable ID", "value": String(country.get("country_id", ""))},
			{"label": "Handle", "value": str(country.get("country_handle", 0))},
			{"label": "国库", "value": _money(int(country.get("cash", 0)))},
			{"label": "科技", "value": str(country.get("technology_count", 0))},
		]},
	]
	_append_country_detail(sections, data.get("country", {}), data.get("treasury", {}))
	_append_population(sections, data.get("population", {}))
	_append_market(sections, data.get("market", {}))
	_append_buildings(sections, data.get("buildings", {}))
	var resource_rows := []
	for raw in data.get("resources", []):
		var resource: Dictionary = raw
		resource_rows.append({"label": String(resource.get("name", resource.get("id", "资源"))),
			"value": UITokens.format_compact_number_cn(float(resource.get("reserve", 0.0)), 2)})
	sections.append({"title": "自然资源", "rows": resource_rows if not resource_rows.is_empty() else [
		{"label": "储量", "value": "无非零资源"}]})
	return sections


static func _append_country_detail(sections: Array, country: Dictionary, treasury: Dictionary) -> void:
	if country.is_empty():
		return
	var rows := []
	var technologies: PackedStringArray = country.get("technology_ids", PackedStringArray())
	rows.append({"label": "已解锁科技", "value": ", ".join(technologies) if not technologies.is_empty() else "无"})
	var good_ids: PackedStringArray = treasury.get("good_ids", PackedStringArray())
	var quantities: PackedInt64Array = treasury.get("quantities", PackedInt64Array())
	for i in range(mini(good_ids.size(), quantities.size())):
		rows.append({"label": String(good_ids[i]), "value": _goods(int(quantities[i]))})
	sections.append({"title": "国家详情", "rows": rows})


static func _append_population(sections: Array, snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	var rows := [
		{"label": "总人口", "value": UITokens.format_compact_number_cn(float(snapshot.get("population", 0)), 1)},
		{"label": "阶层数", "value": str(snapshot.get("cohort_count", 0))},
		{"label": "总资金", "value": _money(int(snapshot.get("funds", 0)))},
		{"label": "快照", "value": String(snapshot.get("snapshot_source", "unknown"))},
	]
	var handles: PackedInt64Array = snapshot.get("handles", PackedInt64Array())
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var funds: PackedInt64Array = snapshot.get("funds_by_cohort", PackedInt64Array())
	for i in range(mini(handles.size(), MAX_COHORT_ROWS)):
		rows.append({"label": "Cohort %s" % handles[i], "value": "%s 人 · %s" % [
			populations[i] if i < populations.size() else 0,
			_money(int(funds[i]) if i < funds.size() else 0)]})
	sections.append({"title": "人口与阶层", "rows": rows})


static func _append_market(sections: Array, snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	var rows := []
	var ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var stock: PackedInt64Array = snapshot.get("stock", PackedInt64Array())
	var prices: PackedInt32Array = snapshot.get("prices", PackedInt32Array())
	for i in range(mini(ids.size(), stock.size())):
		if int(stock[i]) == 0:
			continue
		rows.append({"label": String(ids[i]), "value": "%s · 价格 %s" % [
			_goods(int(stock[i])), _money(int(prices[i]) if i < prices.size() else 0)]})
		if rows.size() >= MAX_MARKET_ROWS:
			break
	sections.append({"title": "本地市场", "rows": rows if not rows.is_empty() else [
		{"label": "库存", "value": "无非零库存"}]})


static func _append_buildings(sections: Array, snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	var rows := []
	var ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var counts: PackedInt64Array = snapshot.get("building_counts", PackedInt64Array())
	for i in range(mini(ids.size(), counts.size())):
		if int(counts[i]) <= 0:
			continue
		rows.append({"label": String(ids[i]), "value": str(counts[i])})
		if rows.size() >= MAX_BUILDING_ROWS:
			break
	if rows.is_empty():
		if snapshot.has("committed") and snapshot.has("busy") \
				and not bool(snapshot.get("committed", true)) \
				and not bool(snapshot.get("busy", false)):
			rows.append({"label": "经济图", "value": "已暂停 · committed=false busy=false"})
		_append_scalar_rows(rows, snapshot, MAX_BUILDING_ROWS)
	sections.append({"title": "建筑", "rows": rows if not rows.is_empty() else [
		{"label": "建筑", "value": "无"}]})


static func _append_scalar_report(sections: Array, title: String, report,
		pinned: PackedStringArray = PackedStringArray()) -> void:
	if not (report is Dictionary) or report.is_empty():
		return
	var rows := []
	if title == "经济运行时" and bool(report.get("fatal", false)):
		rows.append({"label": "状态", "value": "已暂停 · %s" % String(
			report.get("fatal_reason", "unknown"))})
	_append_scalar_rows(rows, report, MAX_REPORT_ROWS, pinned)
	if not rows.is_empty():
		sections.append({"title": title, "rows": rows})


static func _append_scalar_rows(rows: Array, data: Dictionary, limit: int,
		pinned: PackedStringArray = PackedStringArray()) -> void:
	var seen := {}
	for raw_key in pinned:
		var pinned_key := String(raw_key)
		if not data.has(pinned_key) or seen.has(pinned_key):
			continue
		if _try_append_scalar_row(rows, pinned_key, data[pinned_key]):
			seen[pinned_key] = true
		if rows.size() >= limit:
			return
	var keys := data.keys()
	keys.sort()
	for key in keys:
		var label := String(key)
		if seen.has(label):
			continue
		if _try_append_scalar_row(rows, label, data[key]):
			seen[label] = true
		if rows.size() >= limit:
			return


static func _try_append_scalar_row(rows: Array, label: String, value) -> bool:
	if value is bool or value is int or value is float or value is String \
			or value is StringName:
		rows.append({"label": label, "value": str(value)})
		return true
	return false


static func _tokenize(line: String) -> Dictionary:
	var tokens := PackedStringArray()
	var current := ""
	var quote := ""
	var escaped := false
	for i in range(line.length()):
		var ch := line.substr(i, 1)
		if escaped:
			current += ch
			escaped = false
			continue
		if ch == "\\":
			escaped = true
			continue
		if quote != "":
			if ch == quote:
				quote = ""
			else:
				current += ch
			continue
		if ch == "\"" or ch == "'":
			quote = ch
		elif ch == " " or ch == "\t":
			if current != "":
				tokens.append(current)
				current = ""
		else:
			current += ch
	if escaped:
		current += "\\"
	if quote != "":
		return {"ok": false, "code": "unterminated_quote", "message": "引号未闭合。"}
	if current != "":
		tokens.append(current)
	return {"ok": true, "tokens": tokens}


static func _find_command(commands: Array, command_id: String) -> Dictionary:
	for raw in commands:
		var command: Dictionary = raw
		if String(command.get("id", "")) == command_id:
			return command
	return {}


static func _convert_value(value, spec: Dictionary) -> Dictionary:
	var type := String(spec.get("type", "string"))
	var converted = value
	if type == "int":
		var int_text := String(value)
		if not int_text.is_valid_int():
			return {"ok": false, "message": "必须是整数"}
		converted = int_text.to_int()
	elif type == "float":
		var float_text := String(value)
		if not float_text.is_valid_float():
			return {"ok": false, "message": "必须是数字"}
		converted = float_text.to_float()
	else:
		converted = String(value)
	if spec.has("min") and float(converted) < float(spec.get("min", 0.0)):
		return {"ok": false, "message": "不能小于 %s" % spec.get("min")}
	var choice_values := []
	for raw_choice in spec.get("choices", []):
		choice_values.append(raw_choice)
	if not choice_values.is_empty():
		var found := false
		for choice in choice_values:
			if str(choice) == str(converted):
				converted = choice
				found = true
				break
		if not found:
			var labels := PackedStringArray()
			for choice in choice_values:
				labels.append(str(choice))
			return {"ok": false, "message": "可选值：%s" % ", ".join(labels)}
	return {"ok": true, "value": converted}


static func _money(value: int) -> String:
	return "%.2f" % (float(value) / 10000.0)


static func _goods(value: int) -> String:
	return "%.3f" % (float(value) / 1000.0)
