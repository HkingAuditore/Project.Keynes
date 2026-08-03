extends SceneTree

const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

var _failures: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures.append(label)


func _near(a: float, b: float) -> bool:
	return absf(a - b) <= 0.0000001


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[modifier-runtime] SKIP: DCWorldExt unavailable")
		quit(0)
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	var facade = ModifierFacadeScript.new()
	var configured: Dictionary = facade.configure(ext, 16)
	_expect("catalog configures", bool(configured.get("ok", false)))
	if not bool(configured.get("ok", false)):
		_finish()
		return

	var climate_target := {"domain": 0, "scope": 2, "entity_handle": 3, "group_handle": 0}
	var source := {"type": 7, "id": 11}
	var request: int = facade.queue_apply(&"climate.radiative_warming",
		climate_target, source, 2, 1, 0)
	_expect("apply request allocated", request > 0)
	var day0: Dictionary = ext.run_modifier_daily(0)
	_expect("day zero applies", bool(day0.get("ok", false)))
	var result: Dictionary = facade.get_command_result(request)
	var handle := int(result.get("modifier_handle", 0))
	_expect("apply returns handle", bool(result.get("ok", false)) and handle != 0)
	var explain: Dictionary = facade.explain_stat(0, 3, 0,
		&"climate.cell.radiative_target", 0.5)
	_expect("add formula", _near(float(explain.get("effective_value", -1.0)), 0.55))

	var stacked_request: int = facade.queue_apply(&"climate.radiative_warming",
		climate_target, source, 2, 1, 1)
	ext.run_modifier_daily(1)
	var stacked: Dictionary = facade.get_command_result(stacked_request)
	_expect("stack refresh keeps handle", int(stacked.get("modifier_handle", 0)) == handle)
	_expect("stack formula", _near(float(facade.explain_stat(0, 3, 0,
		&"climate.cell.radiative_target", 0.5).get("effective_value", -1.0)), 0.6))

	var remove_request: int = facade.queue_remove(handle, 0, 2)
	ext.run_modifier_daily(2)
	_expect("single handle removes", bool(facade.get_command_result(remove_request).get("ok", false)))
	_expect("remove recomputes from base", _near(float(facade.explain_stat(0, 3, 0,
		&"climate.cell.radiative_target", 0.5).get("effective_value", -1.0)), 0.5))

	var expiring_request: int = facade.queue_apply(&"climate.radiative_warming",
		climate_target, {"type": 7, "id": 12}, 1, 1, 3)
	ext.run_modifier_daily(3)
	_expect("duration active on apply day", bool(facade.get_command_result(expiring_request).get("ok", false)) \
		and _near(float(facade.explain_stat(0, 3, 0,
		&"climate.cell.radiative_target", 0.5).get("effective_value", -1.0)), 0.55))
	ext.run_modifier_daily(4)
	_expect("duration expires before consumers", _near(float(facade.explain_stat(0, 3, 0,
		&"climate.cell.radiative_target", 0.5).get("effective_value", -1.0)), 0.5))

	var building_handle := int(ext.ensure_modifier_building_handle(2, 4, 6))
	_expect("building identity allocated", building_handle != 0)
	var scope_requests: Array[int] = []
	scope_requests.append(facade.queue_apply(&"economy.building.productivity_boost",
		{"domain": 2, "scope": 0}, {"type": 20, "id": 1}, -1, 1, 5))
	scope_requests.append(facade.queue_apply(&"economy.building.productivity_boost",
		{"domain": 2, "scope": 1, "group_handle": 2},
		{"type": 20, "id": 2}, -1, 1, 5))
	scope_requests.append(facade.queue_apply(&"economy.building.productivity_boost",
		{"domain": 2, "scope": 2, "entity_handle": building_handle,
			"group_handle": 2}, {"type": 20, "id": 3}, -1, 1, 5))
	ext.run_modifier_daily(5)
	var expected_scope_factor := 1.15 * 1.15 * 1.15
	_expect("global group entity compose", _near(float(ext.evaluate_modifier_stat(
		2, building_handle, 2, "economy.building.output_factor", 1.0)),
		expected_scope_factor))
	var global_handle := int(facade.get_command_result(scope_requests[0]).get(
		"modifier_handle", 0))
	var remove_global := facade.queue_remove(global_handle, 2, 6)
	ext.run_modifier_daily(6)
	_expect("scope handle removes exactly one bucket",
		bool(facade.get_command_result(remove_global).get("ok", false)) and
		_near(float(ext.evaluate_modifier_stat(2, building_handle, 2,
			"economy.building.output_factor", 1.0)), 1.15 * 1.15))
	var stale_remove := facade.queue_remove(global_handle, 2, 7)
	ext.run_modifier_daily(7)
	_expect("stale handle rejected", not bool(facade.get_command_result(
		stale_remove).get("ok", true)))

	var unique_target := {"domain": 1, "scope": 2, "entity_handle": 77}
	var unique_source := {"type": 30, "id": 9}
	var unique_a := facade.queue_apply(&"country.economic_mobilization",
		unique_target, unique_source, 10, 1, 8)
	ext.run_modifier_daily(8)
	var unique_handle := int(facade.get_command_result(unique_a).get(
		"modifier_handle", 0))
	var unique_b := facade.queue_apply(&"country.economic_mobilization",
		unique_target, unique_source, 20, 1, 9)
	ext.run_modifier_daily(9)
	_expect("unique source replaces in place", unique_handle != 0 and
		int(facade.get_command_result(unique_b).get("modifier_handle", 0)) == unique_handle)
	_expect("unique source does not double factor", _near(float(
		ext.evaluate_modifier_stat(1, 77, 0,
			"country.economy_output_factor", 1.0)), 1.1))

	var gameplay_handle := int(ext.register_gameplay_modifier_object("test-archetype"))
	_expect("gameplay identity allocated", gameplay_handle != 0)
	_expect("gameplay base accepted", bool(ext.set_gameplay_modifier_base(
		gameplay_handle, "gameplay.generic.value", 10.0).get("ok", false)))
	var gameplay_request: int = facade.queue_apply(&"gameplay.generic.bonus",
		{"domain": 3, "scope": 2, "entity_handle": gameplay_handle},
		{"type": 9, "id": 1}, -1, 3, 10)
	ext.run_modifier_daily(10)
	_expect("gameplay modifier applies", bool(facade.get_command_result(gameplay_request).get("ok", false)))
	_expect("gameplay effective base separated", _near(float(ext.get_gameplay_modifier_effective(
		gameplay_handle, 0, "gameplay.generic.value").get("effective_value", -1.0)), 13.0))

	var half_request: int = facade.queue_apply(&"climate.radiative_warming",
		{"domain": 0, "scope": 2, "entity_handle": 4}, {"type": 7, "id": 99},
		-1, 1, 11, 100, 32768)
	ext.run_modifier_daily(11)
	var half_handle := int(facade.get_command_result(half_request).get("modifier_handle", 0))
	_expect("half magnitude scales additive term", half_handle != 0 and _near(float(
		facade.explain_stat(0, 4, 0, &"climate.cell.radiative_target", 0.5).get(
			"effective_value", -1.0)), 0.525))
	var double_request := facade.queue_set_magnitude(half_handle, 0, 131072, 12)
	ext.run_modifier_daily(12)
	var magnitude_explain := facade.explain_stat(0, 4, 0,
		&"climate.cell.radiative_target", 0.5)
	_expect("set magnitude updates in place", bool(facade.get_command_result(
		double_request).get("ok", false)) and _near(float(magnitude_explain.get(
			"effective_value", -1.0)), 0.6) and
		(magnitude_explain.get("magnitude_q16", PackedInt32Array()) as PackedInt32Array)[0] == 131072)

	var saved: PackedByteArray = ext.capture_modifier_domain(3)
	_expect("gameplay save captures", not saved.is_empty())
	var ext_restored: Object = ClassDB.instantiate("DCWorldExt")
	var restored_facade = ModifierFacadeScript.new()
	_expect("restore runtime configures", bool(restored_facade.configure(ext_restored, 16).get("ok", false)))
	_expect("gameplay save restores", bool(ext_restored.restore_modifier_domain(3, saved).get("ok", false)))
	_expect("restored effective value", _near(float(ext_restored.get_gameplay_modifier_effective(
		gameplay_handle, 0, "gameplay.generic.value").get("effective_value", -1.0)), 13.0))
	for domain in [0, 1, 2]:
		var domain_save: PackedByteArray = ext.capture_modifier_domain(domain)
		_expect("domain %d save captures" % domain, not domain_save.is_empty())
		_expect("domain %d save restores" % domain, bool(ext_restored.restore_modifier_domain(
			domain, domain_save).get("ok", false)))

	var zero_catalog: Dictionary = ModifierCatalogScript.load_default().compile_native_catalog()
	zero_catalog.erase("ok")
	var definition_keys: PackedStringArray = zero_catalog.definition_keys
	var definition_versions: PackedInt32Array = zero_catalog.definition_versions
	var definition_domains: PackedInt32Array = zero_catalog.definition_domains
	var definition_policies: PackedInt32Array = zero_catalog.definition_policies
	var definition_max_stacks: PackedInt32Array = zero_catalog.definition_max_stacks
	var definition_durations: PackedInt32Array = zero_catalog.definition_default_duration
	var definition_offsets: PackedInt32Array = zero_catalog.definition_term_offsets
	var term_stats: PackedInt32Array = zero_catalog.term_stat_ids
	var term_operations: PackedInt32Array = zero_catalog.term_operations
	var term_values: PackedFloat64Array = zero_catalog.term_values
	definition_keys.append("test.zero.factor")
	definition_versions.append(1)
	definition_domains.append(2)
	definition_policies.append(0)
	definition_max_stacks.append(1)
	definition_durations.append(-1)
	term_stats.append(2)
	term_operations.append(2)
	term_values.append(0.0)
	definition_offsets.append(term_values.size())
	zero_catalog.definition_keys = definition_keys
	zero_catalog.definition_versions = definition_versions
	zero_catalog.definition_domains = definition_domains
	zero_catalog.definition_policies = definition_policies
	zero_catalog.definition_max_stacks = definition_max_stacks
	zero_catalog.definition_default_duration = definition_durations
	zero_catalog.definition_term_offsets = definition_offsets
	zero_catalog.term_stat_ids = term_stats
	zero_catalog.term_operations = term_operations
	zero_catalog.term_values = term_values
	var zero_ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("zero-factor catalog configures", bool(zero_ext.configure_modifiers(
		zero_catalog, 4).get("ok", false)))
	var zero_building := int(zero_ext.ensure_modifier_building_handle(0, 0, 0))
	var zero_submit: Dictionary = zero_ext.submit_modifier_commands({
		"protocol_version": 2,
		"opcodes": PackedInt32Array([1]),
		"producer_ids": PackedInt32Array([1]),
		"sequences": PackedInt64Array([1]),
		"effective_days": PackedInt64Array([0]),
		"definition_keys": PackedStringArray(["test.zero.factor"]),
		"domains": PackedInt32Array([2]),
		"scopes": PackedInt32Array([2]),
		"entity_handles": PackedInt64Array([zero_building]),
		"group_handles": PackedInt64Array([0]),
		"source_types": PackedInt64Array([1]),
		"source_ids": PackedInt64Array([1]),
		"duration_days": PackedInt32Array([-1]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([32768]),
		"modifier_handles": PackedInt64Array([0]),
	})
	zero_ext.run_modifier_daily(0)
	_expect("zero factor remains queryable", bool(zero_submit.get("ok", false)) and
		_near(float(zero_ext.evaluate_modifier_stat(2, zero_building, 0,
			"economy.building.output_factor", 1.0)), 0.5))

	var events: Dictionary = ext.poll_modifier_events(0, 128)
	_expect("journal traces mutations", (events.get("event_ids", PackedInt64Array()) as PackedInt64Array).size() >= 6)
	_expect("journal v2 publishes complete target columns",
		int(events.get("journal_version", 0)) == 2 and
		(events.get("group_handles", PackedInt64Array()) as PackedInt64Array).size() ==
			(events.get("event_ids", PackedInt64Array()) as PackedInt64Array).size() and
		(events.get("scopes", PackedInt32Array()) as PackedInt32Array).size() ==
			(events.get("event_ids", PackedInt64Array()) as PackedInt64Array).size() and
		(events.get("new_magnitude_q16", PackedInt32Array()) as PackedInt32Array).size() ==
			(events.get("event_ids", PackedInt64Array()) as PackedInt64Array).size())
	var report: Dictionary = facade.report()
	var error_reasons: PackedStringArray = report.get("error_reasons", PackedStringArray())
	var memory_by_domain: PackedInt64Array = report.get(
		"estimated_memory_bytes_by_domain", PackedInt64Array())
	_expect("report publishes bucket timings and memory",
		float(report.get("bucket_update_ms", -1.0)) >= 0.0 and
		float(report.get("bucket_rebuild_ms", -1.0)) >= 0.0 and
		memory_by_domain.size() == 4 and memory_by_domain[0] > 0)
	_expect("report counts stale handle rejection",
		error_reasons.has("modifier_handle_stale") and
		(report.get("reject_events_by_domain", PackedInt64Array()) as PackedInt64Array)[2] > 0)
	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("[modifier-runtime] PASS")
		quit(0)
	else:
		for failure in _failures:
			push_error("[modifier-runtime] FAIL: %s" % failure)
		quit(1)
