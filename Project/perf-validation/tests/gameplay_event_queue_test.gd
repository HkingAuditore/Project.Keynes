extends SceneTree

var failures := 0


func _init() -> void:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("native gameplay event bus is available", ext != null)
	if ext == null:
		quit(1)
		return
	var published: Dictionary = ext.publish_gameplay_events({
		"max_events": 3,
		"count": 5,
		"tick_scalar": 7,
		"phase_scalar": 9,
		"source_scalar": 1,
		"type": PackedInt32Array([1, 2, 3, 4, 5]),
		"value_i64": PackedInt64Array([10, 20, 30, 40, 50]),
	})
	var report: Dictionary = ext.get_gameplay_event_bus_report()
	var polled: Dictionary = ext.poll_gameplay_events({
		"consumer_id": &"queue_test",
		"after_event_id": 0,
		"max_events": 16,
	})
	var ids: PackedInt64Array = polled.get("event_id", PackedInt64Array())
	var types: PackedInt32Array = polled.get("type", PackedInt32Array())
	var values: PackedInt64Array = polled.get("value_i64", PackedInt64Array())
	_expect("bounded queue retains the newest events in stable order",
		int(published.get("published", 0)) == 5
		and int(report.get("event_count", 0)) == 3
		and int(report.get("dropped_event_count", 0)) == 2
		and int(report.get("oldest_event_id", 0)) == 3
		and int(report.get("newest_event_id", 0)) == 5
		and ids == PackedInt64Array([3, 4, 5])
		and types == PackedInt32Array([3, 4, 5])
		and values == PackedInt64Array([30, 40, 50]))

	print("=== gameplay event queue %s ===" % [
		"PASS" if failures == 0 else "FAIL"])
	quit(0 if failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1
