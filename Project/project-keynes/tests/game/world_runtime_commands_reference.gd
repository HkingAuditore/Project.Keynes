extends WorldRuntimeHost

## Frozen S13-before bodies; do not update to match the extracted implementation.

func _gm_command_specs(technologies: PackedStringArray = PackedStringArray(),
		goods: PackedStringArray = PackedStringArray(),
		buildings: PackedStringArray = PackedStringArray()) -> Array:
	return [
		{"id": "diagnostics.dump_atlas_river_probe", "label": "Export Atlas river probe", "category": "diagnostics", "destructive": false, "args": []},
		{"id": "time.pause", "label": "暂停/继续模拟", "category": "时间", "destructive": false,
			"args": [{"name": "state", "type": "enum", "required": false,
				"default": "toggle", "choices": PackedStringArray(["toggle", "on", "off"])}]},
		{"id": "time.speed", "label": "设置模拟速度", "category": "时间", "destructive": false,
			"args": [{"name": "value", "type": "float", "required": true,
				"choices": PackedFloat32Array(GM_SPEED_PRESETS)}]},
		{"id": "country.rename", "label": "重命名国家", "category": "国家", "destructive": true,
			"args": [_gm_arg("country_handle", "int", false), _gm_arg("name", "string", true), _gm_day_arg()]},
		{"id": "country.grant_technology", "label": "授予科技", "category": "国家", "destructive": true,
			"args": [_gm_arg("country_handle", "int", false), _gm_choice_arg("technology_id", technologies), _gm_day_arg()]},
		{"id": "country.reveal_all_technologies", "label": "揭示全部未来科技", "category": "国家", "destructive": true,
			"args": [_gm_arg("country_handle", "int", false), _gm_day_arg()]},
		{"id": "country.transfer_territory", "label": "转移领土", "category": "国家", "destructive": true,
			"args": [_gm_arg("cell", "int", false), _gm_arg("country_handle", "int", true), _gm_day_arg()]},
		{"id": "economy.add_stock", "label": "增加本地库存", "category": "经济", "destructive": true,
			"args": [_gm_arg("cell", "int", false), _gm_choice_arg("good_id", goods), _gm_positive_arg("quantity"), _gm_day_arg()]},
		{"id": "economy.mint_to_cohort", "label": "向阶层铸币", "category": "经济", "destructive": true,
			"args": [_gm_arg("cohort_handle", "int", true), _gm_positive_arg("amount"), _gm_day_arg()]},
		{"id": "economy.mint_to_treasury", "label": "刷钱到玩家国库", "category": "经济", "destructive": true,
			"args": [_gm_positive_arg("amount"), _gm_day_arg()]},
		{"id": "economy.burn_from_cohort", "label": "从阶层销毁货币", "category": "经济", "destructive": true,
			"args": [_gm_arg("cohort_handle", "int", true), _gm_positive_arg("amount"), _gm_day_arg()]},
		{"id": "economy.add_population", "label": "增加阶层人口", "category": "经济", "destructive": true,
			"args": [_gm_arg("cohort_handle", "int", true), _gm_positive_arg("amount", "int"), _gm_day_arg()]},
		{"id": "economy.build", "label": "建造建筑", "category": "经济", "destructive": true,
			"args": [_gm_arg("cell", "int", false), _gm_choice_arg("building_id", buildings),
				_gm_positive_arg("count", "int"), _gm_arg("owner_handle", "int", true), _gm_day_arg()]},
		{"id": "economy.demolish", "label": "拆除建筑", "category": "经济", "destructive": true,
			"args": [_gm_arg("cell", "int", false), _gm_choice_arg("building_id", buildings),
				_gm_positive_arg("count", "int"), _gm_arg("owner_handle", "int", true), _gm_day_arg()]},
	]

func _gm_validate_args(spec: Dictionary, raw_args: Dictionary) -> Dictionary:
	var parsed := {}
	for raw_spec in spec.get("args", []):
		var arg: Dictionary = raw_spec
		var name := String(arg.get("name", ""))
		var has_value := raw_args.has(name)
		if not has_value and arg.has("default"):
			parsed[name] = arg.default
			continue
		if not has_value:
			if bool(arg.get("required", false)):
				return _gm_error("missing_argument", "缺少参数：%s" % name)
			continue
		var converted := _gm_convert_arg(raw_args[name], arg)
		if not bool(converted.get("ok", false)):
			return _gm_error("invalid_argument", "参数 %s：%s" % [name, converted.get("message", "格式错误")])
		parsed[name] = converted.value
	for key in raw_args.keys():
		var known := false
		for raw_spec in spec.get("args", []):
			if String((raw_spec as Dictionary).get("name", "")) == String(key):
				known = true
				break
		if not known:
			return _gm_error("unknown_argument", "未知参数：%s" % String(key))
	return {"ok": true, "args": parsed}

func _gm_convert_arg(value, spec: Dictionary) -> Dictionary:
	var type := String(spec.get("type", "string"))
	var converted = value
	if type == "int":
		var text := str(value)
		if not text.is_valid_int():
			return {"ok": false, "message": "必须是整数"}
		converted = text.to_int()
	elif type == "float":
		var text := str(value)
		if not text.is_valid_float():
			return {"ok": false, "message": "必须是数字"}
		converted = text.to_float()
	else:
		converted = String(value)
	if spec.has("min") and float(converted) < float(spec.min):
		return {"ok": false, "message": "不能小于 %s" % str(spec.min)}
	var choices: Array = Array(spec.get("choices", []))
	if not choices.is_empty():
		var found := false
		for choice in choices:
			if str(choice) == str(converted):
				converted = choice
				found = true
				break
		if not found:
			var labels := PackedStringArray()
			for choice in choices:
				labels.append(str(choice))
			return {"ok": false, "message": "可选值：%s" % ", ".join(labels)}
	return {"ok": true, "value": converted}

func _gm_scaled_positive(value, scale: int) -> int:
	var scaled := float(value) * float(scale)
	if not is_finite(scaled) or scaled > 9.22e18:
		return -1
	return int(round(scaled))

func _gm_execute_country_command(command_id: String, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	var facade = _generator.get_country_facade() if _generator.has_method("get_country_facade") else null
	if facade == null:
		return {"ok": false, "reason": "country_facade_unavailable"}
	var handle := int(args.get("country_handle", _gm_selected_country_handle()))
	match command_id:
		"country.rename":
			return facade.rename_country(handle, String(args.name), effective_day, sequence)
		"country.grant_technology":
			return facade.grant_technology(handle, StringName(args.technology_id), effective_day, sequence)
		"country.reveal_all_technologies":
			return facade.reveal_all_technologies(handle, effective_day, sequence)
		"country.transfer_territory":
			return facade.transfer_territory(_gm_resolve_cell(args), handle, effective_day, sequence)
	return {"ok": false, "reason": "unsupported_country_command"}

func _gm_execute_economy_command(command_id: String, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	var facade = _generator.get_economy_facade() if _generator.has_method("get_economy_facade") else null
	if facade == null:
		return {"ok": false, "reason": "economy_facade_unavailable"}
	match command_id:
		"economy.mint_to_treasury":
			var minted := _gm_scaled_positive(args.amount, GM_CASH_SCALE)
			var handle := _resolve_player_country_handle()
			var cell := _resolve_player_start_cell()
			if minted <= 0 or handle == 0 or cell < 0:
				return {"ok": false, "reason": "player_treasury_unavailable"}
			return facade.mint_to_treasury(handle, cell, minted, effective_day, sequence)
		"economy.add_stock":
			var quantity := _gm_scaled_positive(args.quantity, GM_GOODS_SCALE)
			if quantity <= 0:
				return {"ok": false, "reason": "scaled_quantity_zero"}
			return facade.add_stock(_gm_resolve_cell(args), StringName(args.good_id),
				quantity, effective_day, sequence)
		"economy.mint_to_cohort":
			var minted := _gm_scaled_positive(args.amount, GM_CASH_SCALE)
			if minted <= 0:
				return {"ok": false, "reason": "scaled_amount_zero"}
			return facade.mint_to_cohort(int(args.cohort_handle),
				minted, effective_day, sequence)
		"economy.burn_from_cohort":
			var burned := _gm_scaled_positive(args.amount, GM_CASH_SCALE)
			if burned <= 0:
				return {"ok": false, "reason": "scaled_amount_zero"}
			return facade.burn_from_cohort(int(args.cohort_handle),
				burned, effective_day, sequence)
		"economy.add_population":
			return facade.add_population(int(args.cohort_handle), int(args.amount), effective_day, sequence)
		"economy.build":
			return facade.build(_gm_resolve_cell(args), StringName(args.building_id), int(args.count),
				int(args.owner_handle), effective_day, sequence)
		"economy.demolish":
			return facade.demolish(_gm_resolve_cell(args), StringName(args.building_id), int(args.count),
				int(args.owner_handle), effective_day, sequence)
	return {"ok": false, "reason": "unsupported_economy_command"}

func _gm_one_recorder_state(recorder: RefCounted) -> Dictionary:
	if recorder == null:
		return {"available": false, "recording": false, "rows": 0}
	return {"available": true,
		"recording": bool(recorder.call("is_recording")) if recorder.has_method("is_recording") else false,
		"rows": int(recorder.call("row_count")) if recorder.has_method("row_count") else 0}

func _recorder_ready(recorder: RefCounted) -> bool:
	if recorder == null or not recorder.has_method("on_fast_tick"):
		return false
	if recorder.has_method("is_recording") and not bool(recorder.call("is_recording")):
		return false
	return true

func execute_gm_command(command_id: String, raw_args: Dictionary) -> Dictionary:
	var spec := _gm_find_command_spec(command_id)
	if spec.is_empty():
		return _gm_error("unknown_command", "未知指令：%s" % command_id)
	var validated := _gm_validate_args(spec, raw_args)
	if not bool(validated.get("ok", false)):
		return validated
	var args: Dictionary = validated.get("args", {})
	if command_id == "diagnostics.dump_atlas_river_probe":
		var probe_baker = _gm_map_baker()
		if probe_baker == null or not probe_baker.has_method("dump_river_atlas_probe"):
			return _gm_error("baker_unavailable", "MapBaker 尚未就绪，无法导出采样。")
		return probe_baker.dump_river_atlas_probe()
	if _world_clock == null and command_id.begins_with("time."):
		return _gm_error("clock_unavailable", "时钟尚未就绪。")
	if command_id == "time.pause":
		var state := String(args.get("state", "toggle"))
		var paused := not _world_clock.paused if state == "toggle" else state == "on"
		if _runtime_worker_fault_paused and not paused:
			return _gm_error("runtime_faulted",
				"运行时已故障（%s），禁止继续推进日历。" % String(
					_runtime_last_fault_diagnostics.get("fault_code", "faulted")))
		_world_clock.pause(paused)
		on_clock_running_changed(not paused)
		gm_toggle_changed.emit("simulation.paused", paused)
		return _gm_ok("模拟已%s。" % ("暂停" if paused else "继续"), false, -1)
	if command_id == "time.speed":
		if _runtime_worker_fault_paused:
			return _gm_error("runtime_faulted",
				"运行时已故障（%s），禁止改速推进。" % String(
					_runtime_last_fault_diagnostics.get("fault_code", "faulted")))
		var speed := float(args.get("value", 1.0))
		_world_clock.set_speed(speed)
		on_clock_running_changed(true)
		return _gm_ok("速度已设为 %d 倍。" % int(speed), false, -1)

	if _generator == null or _world_clock == null:
		return _gm_error("world_not_ready", "世界尚未生成，无法提交该指令。")
	var effective_day := int(args.get("day", _world_clock.day_index() + 1))
	if effective_day <= _world_clock.day_index():
		return _gm_error("effective_day_invalid", "生效日必须晚于当前游戏日。")
	var sequence := _gm_sequence
	_gm_sequence += 2 if command_id == "economy.mint_to_treasury" else 1
	var result: Dictionary
	if command_id.begins_with("country."):
		result = _gm_execute_country_command(command_id, args, effective_day, sequence)
	else:
		result = _gm_execute_economy_command(command_id, args, effective_day, sequence)
	if not bool(result.get("ok", false)):
		return _gm_error(String(result.get("reason", "command_rejected")),
			"指令被运行时拒绝：%s" % String(result.get("reason", "unknown")), result)
	var response := _gm_ok("指令已排入第 %d 日的权威命令队列。" % effective_day, true, effective_day)
	response["data"] = result
	return response

func annual_report_status() -> Dictionary:
	return _annual_reports.status()

func annual_report_snapshot(report_id: int) -> Dictionary:
	return _annual_reports.snapshot(report_id)

func annual_report_history(offset: int = 0, limit: int = 64) -> Dictionary:
	return _annual_reports.history(offset, limit)

func mark_annual_report_presented(report_id: int) -> void:
	_annual_reports.mark_presented(report_id)

func annual_reports_waiting_for_year(year: int) -> bool:
	return _annual_reports.waiting_for_year(year)


func _reference_tile_result(tile_result, out: Dictionary) -> void:
	if tile_result is Dictionary:
		var tile_dict := tile_result as Dictionary
		out["tile_recorded"] = bool(tile_dict.get("recorded", false))
		out["tile_rows"] = int(tile_dict.get("rows", 0))
		out["tile_reason"] = str(tile_dict.get("reason", ""))
		for key in [
			"collect_ms", "stats_ms", "format_ms", "flush_ms", "encoder_path",
			"tick_stride", "cell_stride",
		]:
			if tile_dict.has(key):
				out["tile_%s" % str(key)] = tile_dict[key]

func _reference_economy_result(economy_result, out: Dictionary) -> void:
	if economy_result is Dictionary:
		var economy_dict := economy_result as Dictionary
		out["economy_recorded"] = bool(economy_dict.get("recorded", false))
		out["economy_rows"] = int(economy_dict.get("rows", 0))
		out["economy_reason"] = str(economy_dict.get("reason", ""))
		out["economy_epoch_id"] = int(economy_dict.get("epoch_id", -1))
