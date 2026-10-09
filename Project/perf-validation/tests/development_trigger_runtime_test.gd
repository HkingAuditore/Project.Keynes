extends SceneTree

const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")
const DevelopmentAchievementCatalogScript = preload(
	"res://scripts/research/development_achievement_catalog.gd")

var _failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures.append(label)


func _events(ids: PackedInt64Array, days: PackedInt64Array,
		countries: PackedInt64Array, values: PackedInt64Array,
		metric_index: int, coverage: PackedInt64Array) -> Dictionary:
	var count := ids.size()
	var source_ids := PackedInt32Array()
	var types := PackedInt32Array()
	var schemas := PackedInt32Array()
	var groups := PackedInt64Array()
	var p0 := PackedInt64Array()
	var p1 := PackedInt64Array()
	var zeros := PackedInt64Array()
	for index in range(count):
		source_ids.append(1)
		types.append(17)
		schemas.append(10)
		groups.append(index + 1)
		p0.append(metric_index)
		p1.append(int(coverage[index]) if index < coverage.size() else 1)
		zeros.append(0)
	return {"count": count, "event_ids": ids, "source_ids": source_ids,
		"days": days, "event_types": types, "payload_schemas": schemas,
		"entity_handles": countries, "group_handles": groups, "values": values,
		"payload_i0": p0, "payload_i1": p1, "payload_i2": zeros, "payload_i3": zeros}


func _progress(ext: Object, country: int, metric_index: int) -> Dictionary:
	var raw: Dictionary = ext.get_development_progress(country, 1)
	var ids: PackedInt32Array = raw.get("metric_ids", PackedInt32Array())
	var cursor := ids.find(metric_index)
	if cursor < 0:
		return {}
	return {
		"current": int((raw.get("current_values", PackedInt64Array()) as PackedInt64Array)[cursor]),
		"days": int((raw.get("consecutive_days", PackedInt64Array()) as PackedInt64Array)[cursor]),
		"target": int((raw.get("target_days", PackedInt32Array()) as PackedInt32Array)[cursor]),
		"completed": int((raw.get("completed", PackedInt32Array()) as PackedInt32Array)[cursor]),
	}


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("development-trigger-runtime: SKIP: DCWorldExt unavailable")
		quit(0)
		return
	var catalog := TriggerCatalogScript.new()
	var compiled: Dictionary = catalog.compile_native_catalog()
	_expect("default trigger catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		_finish()
		return
	var definitions: Array[Dictionary] = DevelopmentAchievementCatalogScript.definitions()
	var metric_index := -1
	for index in range(definitions.size()):
		if String(definitions[index].get("signal_id", "")) == "development.population.500_90d":
			metric_index = index
			break
	_expect("agrarian population metric exists", metric_index >= 0)
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("trigger catalog configures", bool(ext.configure_triggers(compiled).get("ok", false)))
	var country_a := int((1 << 32) | 101)
	var country_b := int((1 << 32) | 202)
	ext.submit_trigger_events(_events(PackedInt64Array([1]), PackedInt64Array([0]),
		PackedInt64Array([country_a]), PackedInt64Array([500]), metric_index,
		PackedInt64Array([90])))
	var first: Dictionary = ext.run_trigger_daily(0)
	_expect("threshold crossing evaluates", bool(first.get("ok", false)))
	var p0 := _progress(ext, country_a, metric_index)
	_expect("initial duration reaches target", int(p0.get("days", 0)) == 90)
	_expect("initial target fires one effect", int(ext.poll_trigger_effects(0, 16).get("count", 0)) == 1)
	# A second sample on the same committed day must not advance duration.
	ext.submit_trigger_events(_events(PackedInt64Array([2]), PackedInt64Array([0]),
		PackedInt64Array([country_a]), PackedInt64Array([500]), metric_index,
		PackedInt64Array([90])))
	ext.run_trigger_daily(0)
	var same_day := _progress(ext, country_a, metric_index)
	_expect("same-day sample is deduplicated", int(same_day.get("days", 0)) == 90)
	var saved: PackedByteArray = ext.capture_trigger_state()
	_expect("PKTR v6 header", saved.size() >= 8 and saved.decode_s32(4) == 6)
	var restored: Object = ClassDB.instantiate("DCWorldExt")
	_expect("restored trigger configures", bool(restored.configure_triggers(compiled).get("ok", false)))
	_expect("PKTR v6 round-trips", bool(restored.restore_trigger_state(saved).get("ok", false)))
	# A second country gets an independent state with the same metric.
	restored.submit_trigger_events(_events(PackedInt64Array([3]), PackedInt64Array([0]),
		PackedInt64Array([country_b]), PackedInt64Array([500]), metric_index,
		PackedInt64Array([90])))
	restored.run_trigger_daily(0)
	_expect("country states are isolated", int(_progress(restored, country_b, metric_index).get("days", 0)) == 90)
	# Dropping below the qualifier explicitly clears the continuous streak.
	restored.submit_trigger_events(_events(PackedInt64Array([4]), PackedInt64Array([1]),
		PackedInt64Array([country_a]), PackedInt64Array([400]), metric_index,
		PackedInt64Array([1])))
	restored.run_trigger_daily(1)
	_expect("below-threshold sample clears duration", int(_progress(restored, country_a, metric_index).get("days", -1)) == 0)
	restored.submit_trigger_events(_events(PackedInt64Array([5]), PackedInt64Array([3]),
		PackedInt64Array([country_a]), PackedInt64Array([500]), metric_index,
		PackedInt64Array([1])))
	restored.run_trigger_daily(3)
	_expect("qualifying streak restarts after reset", int(_progress(restored, country_a, metric_index).get("days", 0)) == 1)
	restored.submit_trigger_events(_events(PackedInt64Array([6]), PackedInt64Array([5]),
		PackedInt64Array([country_a]), PackedInt64Array([500]), metric_index,
		PackedInt64Array([1])))
	restored.run_trigger_daily(5)
	_expect("committed-day gap restarts the streak", int(_progress(restored, country_a, metric_index).get("days", 0)) == 1)
	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("development_trigger_runtime_test: PASS")
		quit(0)
		return
	for failure in _failures:
		push_error("development-trigger-runtime: FAIL: %s" % failure)
	quit(1)
