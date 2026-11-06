extends RefCounted

## Stateless validation and per-call command assembly; host owns admission and sequence.
const HostValueHelpers = preload("res://scripts/game/world_runtime_host_values.gd")
const GM_SPEED_PRESETS: Array[float] = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0]
const GM_CASH_SCALE: int = 10000
const GM_GOODS_SCALE: int = 1000

static func _gm_command_specs(technologies: PackedStringArray = PackedStringArray(),
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


static func _gm_validate_args(spec: Dictionary, raw_args: Dictionary) -> Dictionary:
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


static func _gm_convert_arg(value, spec: Dictionary) -> Dictionary:
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


static func _gm_scaled_positive(value, scale: int) -> int:
	var scaled := float(value) * float(scale)
	if not is_finite(scaled) or scaled > 9.22e18:
		return -1
	return int(round(scaled))


static func _gm_execute_country_command(command_id: String, args: Dictionary,
		effective_day: int, sequence: int, _generator: Object,
		selected_country: Callable, resolve_cell: Callable) -> Dictionary:
	var facade = _generator.get_country_facade() if _generator.has_method("get_country_facade") else null
	if facade == null:
		return {"ok": false, "reason": "country_facade_unavailable"}
	var handle := int(args.get("country_handle", int(selected_country.call())))
	match command_id:
		"country.rename":
			return facade.rename_country(handle, String(args.name), effective_day, sequence)
		"country.grant_technology":
			return facade.grant_technology(handle, StringName(args.technology_id), effective_day, sequence)
		"country.reveal_all_technologies":
			return facade.reveal_all_technologies(handle, effective_day, sequence)
		"country.transfer_territory":
			return facade.transfer_territory(int(resolve_cell.call(args)), handle, effective_day, sequence)
	return {"ok": false, "reason": "unsupported_country_command"}


static func _gm_execute_economy_command(command_id: String, args: Dictionary,
		effective_day: int, sequence: int, _generator: Object,
		resolve_country: Callable, resolve_start: Callable, resolve_cell: Callable) -> Dictionary:
	var facade = _generator.get_economy_facade() if _generator.has_method("get_economy_facade") else null
	if facade == null:
		return {"ok": false, "reason": "economy_facade_unavailable"}
	match command_id:
		"economy.mint_to_treasury":
			var minted := _gm_scaled_positive(args.amount, GM_CASH_SCALE)
			var handle := int(resolve_country.call())
			var cell := int(resolve_start.call())
			if minted <= 0 or handle == 0 or cell < 0:
				return {"ok": false, "reason": "player_treasury_unavailable"}
			return facade.mint_to_treasury(handle, cell, minted, effective_day, sequence)
		"economy.add_stock":
			var quantity := _gm_scaled_positive(args.quantity, GM_GOODS_SCALE)
			if quantity <= 0:
				return {"ok": false, "reason": "scaled_quantity_zero"}
			return facade.add_stock(int(resolve_cell.call(args)), StringName(args.good_id),
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
			return facade.build(int(resolve_cell.call(args)), StringName(args.building_id), int(args.count),
				int(args.owner_handle), effective_day, sequence)
		"economy.demolish":
			return facade.demolish(int(resolve_cell.call(args)), StringName(args.building_id), int(args.count),
				int(args.owner_handle), effective_day, sequence)
	return {"ok": false, "reason": "unsupported_economy_command"}


static func _gm_arg(name: String, type: String, required: bool) -> Dictionary:
	return HostValueHelpers._gm_arg(name, type, required)


static func _gm_choice_arg(name: String, choices) -> Dictionary:
	return HostValueHelpers._gm_choice_arg(name, choices)


static func _gm_positive_arg(name: String, type: String = "float") -> Dictionary:
	return HostValueHelpers._gm_positive_arg(name, type)


static func _gm_day_arg() -> Dictionary:
	return HostValueHelpers._gm_day_arg()


static func _gm_error(code: String, message: String, data: Dictionary = {}) -> Dictionary:
	return HostValueHelpers._gm_error(code, message, data)


