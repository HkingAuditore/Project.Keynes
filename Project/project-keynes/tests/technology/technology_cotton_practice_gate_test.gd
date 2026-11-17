extends SceneTree

## 棉花经验门槛的标定回归测试。
##
## 设计意图：`development.cotton_practice_700_180d` 的阈值必须**卡在**「寒带单座
## 野生棉丛的地板产出」和「寒带两座」之间——即寒带靠气候地板硬撑的规模凑不满
## 180 天，一旦真的把种植规模做起来才能过。
##
## 断言不写死 415/830，而是从建筑与气候档资源里现算：
##   单座地板产出 = 额定日产出 × floor_q16
## 这样以后调 wild_cotton_stand 的额定或 foraging_plants 的地板，测试会跟着变，
## 只有「阈值落在 (1 座, 2 座] 区间」这个约定被破坏时才会红。
##
## 触发器运行时约束：事件 id 必须按 source 全局单调递增（submit 里按
## `_source_cursor` 去重），所以这里所有国家的 id 共用同一个递增序列。

const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")
const DevelopmentAchievementCatalogScript = preload(
	"res://scripts/research/development_achievement_catalog.gd")

const SIGNAL := "development.cotton_practice_700_180d"
const BUILDING_PATH := "res://data/economy/buildings/wild_cotton_stand.tres"
const CLIMATE_PATH := "res://data/economy/production_climates/foraging_plants.tres"
const ERA_AGRARIAN := 1

var _failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures.append(label)


func _batch(days: PackedInt64Array, countries: PackedInt64Array,
		values: PackedInt64Array, metric_index: int, id_base: int) -> Dictionary:
	var count := countries.size()
	var ids := PackedInt64Array()
	var source_ids := PackedInt32Array()
	var types := PackedInt32Array()
	var schemas := PackedInt32Array()
	var groups := PackedInt64Array()
	var p0 := PackedInt64Array()
	var p1 := PackedInt64Array()
	var zeros := PackedInt64Array()
	for index in range(count):
		ids.append(id_base + index)
		source_ids.append(1)
		types.append(17)
		schemas.append(10)
		groups.append(index + 1)
		p0.append(metric_index)
		p1.append(1)
		zeros.append(0)
	return {"count": count, "event_ids": ids, "source_ids": source_ids,
		"days": days, "event_types": types, "payload_schemas": schemas,
		"entity_handles": countries, "group_handles": groups, "values": values,
		"payload_i0": p0, "payload_i1": p1, "payload_i2": zeros, "payload_i3": zeros}


func _completed(ext: Object, country: int, metric_index: int) -> int:
	var raw: Dictionary = ext.get_development_progress(country, ERA_AGRARIAN)
	var ids: PackedInt32Array = raw.get("metric_ids", PackedInt32Array())
	var cursor := ids.find(metric_index)
	if cursor < 0:
		return -1
	return int((raw.get("completed", PackedInt32Array()) as PackedInt32Array)[cursor])


func _run() -> void:
	var definitions: Array[Dictionary] = DevelopmentAchievementCatalogScript.definitions()
	var metric_index := -1
	var qualifier := -1
	var duration := -1
	for index in range(definitions.size()):
		if String(definitions[index].get("signal_id", "")) == SIGNAL:
			metric_index = index
			qualifier = int(definitions[index].get("qualifier_threshold", -1))
			duration = int(definitions[index].get("duration_days", -1))
			break
	_expect("cotton practice definition exists", metric_index >= 0)
	if metric_index < 0:
		_finish()
		return

	var building = load(BUILDING_PATH)
	var climate = load(CLIMATE_PATH)
	_expect("wild cotton stand resource loads", building != null)
	_expect("foraging climate resource loads", climate != null)
	if building == null or climate == null:
		_finish()
		return
	var nameplate := int(building.output_quantities_per_day[0])
	var floor_ratio := float(climate.floor_q16) / 65536.0
	var one_building := int(nameplate * floor_ratio)
	var two_buildings := int(nameplate * 2.0 * floor_ratio)
	print("  nameplate=%d floor=%.3f -> one=%d two=%d qualifier=%d duration=%d" % [
		nameplate, floor_ratio, one_building, two_buildings, qualifier, duration])

	_expect("single cold-climate building cannot clear the qualifier",
		one_building < qualifier)
	_expect("two cold-climate buildings clear the qualifier",
		qualifier <= two_buildings)

	var compiled: Dictionary = TriggerCatalogScript.new().compile_native_catalog()
	_expect("trigger catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		_finish()
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("triggers configure", bool(ext.configure_triggers(compiled).get("ok", false)))
	var countries := PackedInt64Array([
		int((1 << 32) | 71), int((1 << 32) | 72), int((1 << 32) | 73)])
	var values := PackedInt64Array([one_building, two_buildings, nameplate])
	for day in range(duration):
		var days := PackedInt64Array()
		for _slot in range(countries.size()):
			days.append(day)
		ext.submit_trigger_events(_batch(days, countries, values, metric_index,
			day * 10 + 1))
		ext.run_trigger_daily(day)

	_expect("one cold building never completes",
		_completed(ext, int(countries[0]), metric_index) == 0)
	_expect("two cold buildings complete on schedule",
		_completed(ext, int(countries[1]), metric_index) == 1)
	_expect("one full-capacity building completes",
		_completed(ext, int(countries[2]), metric_index) == 1)
	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("technology cotton practice gate: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("technology cotton practice gate: FAIL: %s" % failure)
	quit(1)
