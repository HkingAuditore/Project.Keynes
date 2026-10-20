extends SceneTree

var _failures := 0

func _init() -> void:
	var compiled := EconomyCatalog.compile_native_catalog()
	var ext := DCWorldExt.new()
	ext.create_entities(1)
	var facade := CountryFacade.new()
	_expect(bool(facade.configure(ext, 1, 17, null, compiled).get("ok", false)), "configure Country")
	_expect(bool(facade.bootstrap(PackedByteArray([0]), {
		"country_ids": PackedStringArray(["country.delivery"]),
		"country_names": PackedStringArray(["交付测试"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}).get("ok", false)), "bootstrap Country")
	var handle := int(facade.cell_summary(0).country_handle)
	var original_country := PackedByteArray()
	_expect(bool(facade.begin_save().get("ok", false)), "capture Country before evidence")
	while true:
		var chunk := facade.read_save_chunk()
		if chunk.is_empty(): break
		original_country.append_array(chunk)
	_expect(bool(facade.end_save().get("ok", false)), "finish Country checkpoint")
	var effects := preload("res://scripts/effect/effect_domain_catalog.gd").build()
	_expect(bool(ext.configure_effects(effects.compile_native_catalog()).get("ok", false)), "configure Effect")
	var triggers := preload("res://scripts/trigger/trigger_catalog.gd").load_default()
	var trigger_ir: Dictionary = triggers.compile_native_catalog()
	_expect(bool(ext.configure_triggers(trigger_ir).get("ok", false)), "configure Trigger")
	var metrics := preload("res://scripts/research/development_achievement_catalog.gd").compile_native_catalog(compiled.research_signal_ids)
	var agriculture := (metrics.development_metric_ids as PackedStringArray).find("development.employment.agriculture.10_90d")
	var manufacturing := (metrics.development_metric_ids as PackedStringArray).find("development.employment.manufacturing.10_90d")
	# Ingress order assigns manufacturing id 1, agriculture id 2. Canonical
	# delivery order sorts agriculture first, so a numeric high-water ACK of 2
	# must not discard the still-undelivered manufacturing effect with id 1.
	var submitted: Dictionary = ext.submit_trigger_events({
		"event_ids": PackedInt64Array([1, 2]), "source_ids": PackedInt32Array([1, 1]),
		"days": PackedInt64Array([0, 0]), "event_types": PackedInt32Array([17, 17]),
		"payload_schemas": PackedInt32Array([10, 10]),
		"entity_handles": PackedInt64Array([handle, handle]), "group_handles": PackedInt64Array([0, 0]),
		"values": PackedInt64Array([1000, 1000]),
		"payload_i0": PackedInt64Array([manufacturing, agriculture]),
		"payload_i1": PackedInt64Array([90, 90]),
		"payload_i2": PackedInt64Array([0, 0]), "payload_i3": PackedInt64Array([0, 0]),
	})
	_expect(int(submitted.get("accepted", 0)) == 2, "accept two development samples")
	_expect(bool(ext.run_trigger_daily(0).get("ok", false)), "complete two one-shot achievements")
	var before: Dictionary = ext.poll_trigger_effects(0, 10)
	print("[development-delivery] initial_ids=", before.get("effect_ids"))
	_expect(int(before.get("count", 0)) == 2, "both achievements emit evidence effects")
	var first: Dictionary = ext.handoff_trigger_effects(1)
	_expect(int(first.get("handed_off", 0)) == 1, "first bounded batch hands off one effect")
	var after: Dictionary = ext.poll_trigger_effects(0, 10)
	_expect(int(after.get("count", 0)) == 1, "first ACK retains the other undelivered achievement")
	var second: Dictionary = ext.handoff_trigger_effects(1)
	_expect(int(second.get("handed_off", 0)) == 1, "second batch hands off the remaining effect")
	_expect(int(ext.dispatch_effect_native_country().get("submitted_commands", 0)) == 2, "both Country commands are submitted")
	_expect(bool(ext.run_country_slice({"day_index": 1}).get("ok", false)), "Country boundary commits evidence")
	_expect(int(ext.ack_effect_native_country().get("acknowledged", 0)) == 2, "both Country receipts complete")
	var evidence: Dictionary = facade.research_signal_snapshot(handle)
	var signal_ids: PackedInt32Array = evidence.signal_ids
	for metric in [agriculture, manufacturing]:
		_expect(signal_ids.has(metrics.development_metric_signal_indices[metric]), "completed achievement has permanent evidence: %s" % metrics.development_metric_ids[metric])
	_expect(int(ext.reconcile_completed_research_signals().get("submitted", -1)) == 0,
		"already recorded achievements need no recovery")
	# Restore only the old Country checkpoint to reproduce the historical split:
	# the two Trigger achievements remain completed, but their evidence is gone.
	_expect(bool(facade.restore_bytes(original_country).get("ok", false)), "restore missing-evidence checkpoint")
	var recovered: Dictionary = ext.reconcile_completed_research_signals()
	_expect(bool(recovered.get("complete", false)) and int(recovered.get("submitted", 0)) == 2,
		"automatic reconciliation replays exactly the two completed missing signals")
	_expect(int(ext.reconcile_completed_research_signals().get("submitted", -1)) == 0,
		"pending recovery effects are not duplicated")
	_expect(int(ext.handoff_trigger_effects(8).get("handed_off", 0)) == 2, "recovery follows normal Trigger handoff")
	_expect(int(ext.dispatch_effect_native_country().get("submitted_commands", 0)) == 2, "recovery follows normal Effect dispatch")
	_expect(bool(ext.run_country_slice({"day_index": 1}).get("ok", false)), "recovery commits at Country boundary")
	_expect(int(ext.ack_effect_native_country().get("acknowledged", 0)) == 2, "recovery has real Country receipts")
	var repaired: Dictionary = facade.research_signal_snapshot(handle)
	for metric in [agriculture, manufacturing]:
		_expect((repaired.signal_ids as PackedInt32Array).has(metrics.development_metric_signal_indices[metric]), "automatic recovery restores permanent evidence")
	_expect(int(ext.reconcile_completed_research_signals().get("submitted", -1)) == 0,
		"a second session reconciliation is idempotent")
	print("technology_development_delivery_test: %s" % ("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)

func _expect(condition: bool, label: String) -> void:
	if not condition:
		_failures += 1
		push_error(label)
