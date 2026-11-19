extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

const Achievements = preload("res://scripts/research/development_achievement_catalog.gd")

func _run() -> void:
	OS.set_environment("PK_GOLDEN_DOMAINS", "1")
	await _run_world(false)
	print("technology_signal_delivery_test: %s" % ("PASS" if _failures == 0 else "FAIL"))
	_finish()


func _sample_world(host: WorldRuntimeHost, clock: WorldClock, _stall: bool) -> Dictionary:
	var generator := host.get_generator()
	var economy = generator.get_economy_facade()
	var country = generator.get_country_facade()
	var ext: Object = generator.get_data_core_world_ext()
	var map := host.current_map()
	var cell := -1
	for candidate in map.cell_count():
		if map.country_slot_arr[candidate] >= 0:
			cell = candidate
			break
	_expect("the frozen world has an owned cell", cell >= 0)
	if cell < 0:
		return {}
	var handle := int(country.cell_summary(cell).get("country_handle", 0))
	clock.set_speed(1.0)
	_publish_day(host, clock, 1)
	if not await _wait_golden_read_boundary(host, economy, 1):
		_expect("day 1 commits", false)
		return {}
	var catalog := EconomyCatalog.compile_native_catalog()
	var metrics: Dictionary = Achievements.compile_native_catalog(catalog.research_signal_ids)
	var ids: PackedStringArray = metrics.development_metric_ids
	var agriculture := ids.find("development.employment.agriculture.10_90d")
	var manufacturing := ids.find("development.employment.manufacturing.10_90d")
	_expect("both achievement metric IDs resolve", agriculture >= 0 and manufacturing >= 0)
	if agriculture < 0 or manufacturing < 0:
		return {}
	var source: Dictionary = ext.get_trigger_report()
	var ingress := int(source.source_cursors[1]) + 10000
	# The event order is the reverse of the canonical delivery order.
	var submitted: Dictionary = ext.submit_trigger_events({
		"event_ids": PackedInt64Array([ingress, ingress + 1]), "source_ids": PackedInt32Array([1, 1]),
		"days": PackedInt64Array([2, 2]), "event_types": PackedInt32Array([17, 17]),
		"payload_schemas": PackedInt32Array([10, 10]),
		"entity_handles": PackedInt64Array([handle, handle]), "group_handles": PackedInt64Array([cell, cell]),
		"values": PackedInt64Array([1000, 1000]), "payload_i0": PackedInt64Array([manufacturing, agriculture]),
		"payload_i1": PackedInt64Array([90, 90]),
	})
	_expect("both observations enter the executor", int(submitted.get("accepted", 0)) == 2)
	var signals := PackedInt32Array([
		metrics.development_metric_signal_indices[agriculture], metrics.development_metric_signal_indices[manufacturing]])
	# After day 1's tail, the shared seal admits the samples on day 3. Trigger
	# first emits its requests on day 3, commits with the Effect ACK on day 4,
	# and delivers the resulting Country commands for day 5.
	for day in range(2, 6):
		_publish_day(host, clock, day)
		if not await _wait_golden_read_boundary(host, economy, day):
			_expect("signal test day %d commits" % day, false)
			return {}
		var evidence: Dictionary = country.research_signal_snapshot(handle)
		var received: PackedInt32Array = evidence.get("signal_ids", PackedInt32Array())
		print("SIGNAL_DELIVERY_DAY ", day, " signals=", received, " expected=", signals)
		for signal_id in signals:
			_expect("signal %d is committed on day 5, observed on day %d" % [signal_id, day],
				received.count(signal_id) == (1 if day == 5 else 0))
		var steps: Dictionary = generator.get_runtime_thread_report().get("main_simulation_steps_by_day", {}).get(day, {})
		for step in ["trigger_country_delivery", "trigger_effect_handoff", "research_signal_reconcile"]:
			_expect("%s stays in the executor on day %d" % [step, day], int(steps.get(step, 0)) == 0)
	return {}
