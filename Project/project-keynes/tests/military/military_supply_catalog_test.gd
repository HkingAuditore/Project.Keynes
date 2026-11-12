extends SceneTree

## 补给候选表的作者期回归测试。
##
## 曾经 `supply.ammunition` 被写成 Dictionary、`supply.upkeep` 被写成
## `"primary_equipment_slot"`，编译器 `_compile_supply` 对这两种类型直接
## `continue`，于是两类候选 goods 为空：采购侧与消费侧都跳过，24 个兵种的
## 维护数值与 16 个兵种的弹药消耗永远不结算，却仍计入 `use.need` 拉低补给率。
## 这里把「候选非空」和「非法值必须报错」钉死，防止再次静默退化。
##
##   godot --headless --path Project/project-keynes \
##       -s res://tests/military/military_supply_catalog_test.gd

const CompilerScript = preload("res://scripts/military/military_catalog_compiler.gd")

const CATALOG_PATH := "res://data/military/military_catalog.json"
const SUPPLY_FODDER := 1
const SUPPLY_AMMUNITION := 2
const SUPPLY_FUEL := 3
const SUPPLY_UPKEEP := 4
const SUPPLY_EQUIPMENT := 5

var _failures := PackedStringArray()


func _init() -> void:
	_check_shipped_supply_rows()
	_check_unsupported_marker_is_rejected()
	_check_bad_type_is_rejected()
	_check_empty_demand_row_is_rejected()
	if _failures.is_empty():
		print("=== military supply catalog: ok ===")
		quit(0)
		return
	for failure in _failures:
		push_error(failure)
	print("=== military supply catalog: %d failures ===" % _failures.size())
	quit(1)


func _expect(label: String, condition: bool, detail: String = "") -> void:
	if not condition:
		_failures.append("%s%s" % [label, "" if detail.is_empty() else " :: " + detail])


func _raw_catalog() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG_PATH))
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}


func _economy_catalog() -> Dictionary:
	return EconomyCatalog.compile_native_catalog()


func _technology_catalog() -> Dictionary:
	return TechnologyCatalog.compile_native_catalog()


func _compile(raw: Dictionary) -> Dictionary:
	return CompilerScript.compile_from_data(raw, _economy_catalog(), _technology_catalog())


func _with_supply(raw: Dictionary, key: String, value: Variant) -> Dictionary:
	var copy := raw.duplicate(true)
	var supply: Dictionary = (copy.get("supply", {}) as Dictionary).duplicate(true)
	supply[key] = value
	copy["supply"] = supply
	return copy


## 正式目录：四类有需求的补给类都要有候选；equipment 类走装备槽路径，
## 允许为空；validate() 也必须放行。
func _check_shipped_supply_rows() -> void:
	var raw := _raw_catalog()
	_expect("shipped catalog is readable", not raw.is_empty())
	if raw.is_empty():
		return
	var compiled := _compile(raw)
	_expect("shipped catalog compiles", bool(compiled.get("ok", false)),
		String(compiled.get("reason", "")))
	if not bool(compiled.get("ok", false)):
		return
	var rows: Array = compiled.get("supply_goods", [])
	_expect("supply_goods has 6 rows", rows.size() == 6, str(rows.size()))
	if rows.size() != 6:
		return
	for supply_class in [SUPPLY_FODDER, SUPPLY_AMMUNITION, SUPPLY_FUEL, SUPPLY_UPKEEP]:
		var row: PackedInt32Array = rows[supply_class]
		_expect("supply class %d has candidate goods" % supply_class,
			not row.is_empty(), str(row))
	var equipment_row: PackedInt32Array = rows[SUPPLY_EQUIPMENT]
	_expect("equipment class intentionally has no candidate row",
		equipment_row.is_empty())
	var validated := CompilerScript.validate(raw, _economy_catalog(), _technology_catalog())
	_expect("validate() accepts the shipped catalog", bool(validated.get("ok", false)),
		String(validated.get("reason", "")) + " " + str(validated.get("problems", [])))


## 未实现的字符串标记不能再被静默跳过。
func _check_unsupported_marker_is_rejected() -> void:
	var raw := _raw_catalog()
	if raw.is_empty():
		return
	var compiled := _compile(_with_supply(raw, "upkeep", "primary_equipment_slot"))
	_expect("unsupported supply marker is rejected", not bool(compiled.get("ok", false)),
		String(compiled.get("reason", "")))
	_expect("rejection names the class",
		String(compiled.get("reason", "")).contains("upkeep"),
		String(compiled.get("reason", "")))


## Dictionary 形式（原本的 ammunition）同样必须报错，而不是产出空候选。
func _check_bad_type_is_rejected() -> void:
	var raw := _raw_catalog()
	if raw.is_empty():
		return
	var compiled := _compile(_with_supply(raw, "ammunition",
		{"category": "ammunition", "min_quality": 1}))
	_expect("Dictionary supply value is rejected", not bool(compiled.get("ok", false)),
		String(compiled.get("reason", "")))
	_expect("rejection names the class",
		String(compiled.get("reason", "")).contains("ammunition"),
		String(compiled.get("reason", "")))


## 即使类型合法（空 Array），「有单位需求却无候选」也必须在 validate 阶段失败。
func _check_empty_demand_row_is_rejected() -> void:
	var raw := _raw_catalog()
	if raw.is_empty():
		return
	var validated := CompilerScript.validate(
		_with_supply(raw, "upkeep", []), _economy_catalog(), _technology_catalog())
	_expect("empty upkeep row with demand is rejected", not bool(validated.get("ok", false)),
		str(validated.get("problems", [])))
	var found := false
	for problem in validated.get("problems", []):
		if String(problem).contains("upkeep has demand but no candidate goods"):
			found = true
	_expect("validation names the empty demanded class", found,
		str(validated.get("problems", [])))
