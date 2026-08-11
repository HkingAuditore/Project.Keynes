extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")

var _failures := 0

func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("technology_breakthrough_trigger_test: SKIP")
		quit(0)
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_require(bool(compiled.get("ok", false)), "economy catalog compiles")
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	_require(effect_catalog != null, "effect domain catalog builds")
	_require(bool(ext.configure_effects(
		effect_catalog.compile_native_catalog()).get("ok", false)),
		"effect runtime configures")
	var trigger_catalog: Resource = TriggerCatalogScript.load_default()
	var trigger_ir: Dictionary = trigger_catalog.compile_native_catalog()
	_require(bool(trigger_ir.get("ok", false)), "trigger catalog compiles")
	_require(int(trigger_ir.trigger_keys.size()) >= 14,
		"default catalog includes breakthrough definitions")
	for trigger_key in ["technology.practice.maritime_operations",
			"technology.practice.watershed_management",
			"technology.practice.forest_management",
			"technology.practice.chemical_process_control",
			"technology.practice.energy_control"]:
		_require((trigger_ir.trigger_keys as PackedStringArray).has(trigger_key),
			"new practice trigger compiles: %s" % trigger_key)
	_require(bool(ext.configure_triggers(trigger_ir).get("ok", false)),
		"trigger runtime configures")

	var facade := CountryFacadeScript.new()
	var profile: Resource = load("res://data/country/default_country.tres")
	_require(bool(facade.configure(ext, 1, 17, profile, compiled).get("ok", false)),
		"country runtime configures")
	_require(bool(facade.bootstrap(PackedByteArray([0]), {
		"country_ids": PackedStringArray(["country.practice"]),
		"country_names": PackedStringArray(["实践国"]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"treasury_offsets": PackedInt32Array([0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}).get("ok", false)), "country runtime bootstraps")
	var handle := int(facade.cell_summary(0).country_handle)
	_require(handle != 0, "country handle exists")

	var practice_event := {
		"event_ids": PackedInt64Array([1]),
		"source_ids": PackedInt32Array([1]),
		"days": PackedInt64Array([0]),
		"event_types": PackedInt32Array([14]),
		"payload_schemas": PackedInt32Array([7]),
		"entity_handles": PackedInt64Array([handle]),
		"group_handles": PackedInt64Array([0]),
		"values": PackedInt64Array([365]),
		"payload_i0": PackedInt64Array([0]),
		"payload_i1": PackedInt64Array([1]),
		"payload_i2": PackedInt64Array([0]),
		"payload_i3": PackedInt64Array([1]),
	}
	_require(int(ext.submit_trigger_events(practice_event).get("accepted", 0)) == 1,
		"practice event accepted")
	_require(int(ext.submit_trigger_events(practice_event).get("deduplicated", 0)) == 1,
		"duplicate event is ignored")
	_require(bool(ext.run_trigger_daily(0).get("ok", false)),
		"trigger threshold evaluates")
	var handoff: Dictionary = ext.handoff_trigger_effects(32)
	_require(int(handoff.get("handed_off", 0)) == 1,
		"breakthrough hands off to EffectRuntime: %s" % str(handoff))
	var dispatch: Dictionary = ext.dispatch_effect_native_country()
	_require(int(dispatch.get("submitted_transactions", 0)) == 1,
		"EffectRuntime submits one Country transaction: %s" % str(dispatch))
	var country_commit: Dictionary = ext.run_country_slice({"day_index": 1})
	_require(bool(country_commit.get("ok", false)) and
		bool(country_commit.get("done", false)), "Country safe boundary commits")
	var ack: Dictionary = ext.ack_effect_native_country()
	_require(int(ack.get("acknowledged", 0)) == 1,
		"Country domain ACK completes: %s" % str(ack))

	var evidence: Dictionary = facade.research_signal_snapshot(handle)
	var catalog_signal_ids: PackedStringArray = compiled.get(
		"research_signal_ids", PackedStringArray())
	var expected_signal := catalog_signal_ids.find("breakthrough.maize_selection")
	var signal_ids: PackedInt32Array = evidence.get("signal_ids", PackedInt32Array())
	var signal_index := signal_ids.find(expected_signal)
	_require(signal_index >= 0, "maize-selection breakthrough discovered")
	if signal_index >= 0:
		var first_cells: PackedInt32Array = evidence.get(
			"first_cells", PackedInt32Array())
		var counts: PackedInt32Array = evidence.get("counts", PackedInt32Array())
		_require(int(first_cells[signal_index]) == 0 and int(counts[signal_index]) == 1,
			"first practice cell and provenance count persist")

	var contact_event := {
		"event_ids": PackedInt64Array([2]),
		"source_ids": PackedInt32Array([1]),
		"days": PackedInt64Array([2]),
		"event_types": PackedInt32Array([16]),
		"payload_schemas": PackedInt32Array([7]),
		"entity_handles": PackedInt64Array([handle]),
		"group_handles": PackedInt64Array([0]),
		"values": PackedInt64Array([1]),
		"payload_i0": PackedInt64Array([0]),
		"payload_i1": PackedInt64Array([1]),
		"payload_i2": PackedInt64Array([0]),
		"payload_i3": PackedInt64Array([1]),
	}
	_require(int(ext.submit_trigger_events(contact_event).get("accepted", 0)) == 1,
		"actual-import contact event accepted")
	var contact_run: Dictionary = ext.run_trigger_daily(2)
	_require(bool(contact_run.get("ok", false)),
		"contact threshold evaluates: %s" % str(contact_run))
	var contact_handoff: Dictionary = ext.handoff_trigger_effects(32)
	_require(int(contact_handoff.get("handed_off", 0)) == 1,
		"contact discovery hands off to EffectRuntime: run=%s handoff=%s" % [
			str(contact_run), str(contact_handoff)])
	_require(int(ext.dispatch_effect_native_country().get(
		"submitted_transactions", 0)) == 1,
		"contact effect submits one Country transaction")
	_require(bool(ext.run_country_slice({"day_index": 3}).get("ok", false)),
		"contact signal commits at the Country boundary")
	_require(int(ext.ack_effect_native_country().get("acknowledged", 0)) == 1,
		"contact Country ACK completes")
	var contact_evidence: Dictionary = facade.research_signal_snapshot(handle)
	var contact_signal := catalog_signal_ids.find("contact.maize")
	var contact_signal_ids: PackedInt32Array = contact_evidence.get(
		"signal_ids", PackedInt32Array())
	_require(contact_signal_ids.has(contact_signal),
		"maize contact is discovered only through the contact event path")

	var maritime_event := {
		"event_ids": PackedInt64Array([3]),
		"source_ids": PackedInt32Array([1]),
		"days": PackedInt64Array([4]),
		"event_types": PackedInt32Array([14]),
		"payload_schemas": PackedInt32Array([7]),
		"entity_handles": PackedInt64Array([handle]),
		"group_handles": PackedInt64Array([0]),
		"values": PackedInt64Array([360]),
		"payload_i0": PackedInt64Array([23]),
		"payload_i1": PackedInt64Array([1]),
		"payload_i2": PackedInt64Array([0]),
		"payload_i3": PackedInt64Array([1]),
	}
	_require(int(ext.submit_trigger_events(maritime_event).get("accepted", 0)) == 1,
		"maritime practice event accepted")
	_require(bool(ext.run_trigger_daily(4).get("ok", false)),
		"maritime practice threshold evaluates")
	_require(int(ext.handoff_trigger_effects(32).get("handed_off", 0)) == 1,
		"maritime breakthrough hands off to EffectRuntime")
	_require(int(ext.dispatch_effect_native_country().get(
		"submitted_transactions", 0)) == 1,
		"maritime breakthrough submits a Country transaction")
	_require(bool(ext.run_country_slice({"day_index": 5}).get("ok", false)),
		"maritime breakthrough commits at the Country boundary")
	_require(int(ext.ack_effect_native_country().get("acknowledged", 0)) == 1,
		"maritime breakthrough Country ACK completes")
	var final_evidence: Dictionary = facade.research_signal_snapshot(handle)
	var maritime_signal := catalog_signal_ids.find("breakthrough.maritime_operations")
	_require((final_evidence.get("signal_ids", PackedInt32Array()) as PackedInt32Array).has(
		maritime_signal), "maritime operations breakthrough is discoverable")

	print("technology_breakthrough_trigger_test: %s" %
		("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)

func _require(condition: bool, label: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[FAIL] %s" % label)
