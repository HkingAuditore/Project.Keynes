extends SceneTree

# K2-A black-box coverage for the Country -> Effect/Modifier peer bridge.
# The test deliberately drives only the exported DCWorldExt contract: the
# Country core owns intent identity and retry state, while this script acts as
# the peer adapter and returns typed results.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const EffectFacadeScript = preload("res://scripts/effect/effect_facade.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

const PEER_EFFECT_EXISTS := 1
const PEER_EFFECT_FIRE_ACKED := 2
const RESULT_READY := 0
const RESULT_PENDING := 1
const RESULT_APPLIED := 2
const RESULT_REJECTED := 3
const RESULT_STALE := 4

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("runtime country peer bridge: %d checks, %d failures" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return

	_run_valid_ack_flow(compiled)
	_run_real_adapter_flow(compiled)
	_run_rejection_retry_flow(compiled)


func _run_valid_ack_flow(compiled: Dictionary) -> void:
	var fixture: Dictionary = _make_fixture(compiled, 9044, "peer-valid")
	if fixture.is_empty():
		return
	var prepared: Dictionary = _prepare_async_pending(fixture, "valid")
	if prepared.is_empty():
		return

	var ext: Object = fixture.ext
	var country: Object = fixture.country
	var handle := int(fixture.handle)
	var technology := int(fixture.technology)
	var intent: Dictionary = prepared.intent
	var day_one: Dictionary = prepared.research
	var consumed_once := int(day_one.get("consumed_total", -1))
	_expect("pending technology is not completed before peer ACK",
		int(day_one.technology_states[technology]) == 4
		and not (country.snapshot(handle).technology_ids as PackedStringArray).has(
			"tech.animal_husbandry"))
	_expect("peer intent has complete identity",
		int(intent.get("protocol_version", 0)) == 1
		and int(intent.get("opcode", 0)) == 1
		and int(intent.get("request_id", 0)) != 0
		and int(intent.get("session_epoch", 0)) != 0
		and int(intent.get("country_generation", 0)) != 0
		and int(intent.get("day", -1)) == 1
		and int(intent.get("continuation_index", -1)) >= 0
		and int(intent.get("country_slot", -1)) == 0
		and int(intent.get("technology", -1)) == technology
		and int(intent.get("target_handle", 0)) == handle
		and int(intent.get("effect_instance_id", 0)) != 0
		and int(intent.get("effect_generation", 0)) != 0
		and int(intent.get("idempotency_key", 0)) != 0)

	var save_worker := _start_paused_save_worker(ext, 1, "valid")
	var pending_save: Dictionary = ext.request_runtime_save(9101)
	_expect("pending peer intent blocks runtime save",
		not bool(pending_save.get("ok", true))
		and String(pending_save.get("code", "")) ==
			"country_checkpoint_peer_pending")
	_stop_save_worker(ext, save_worker)

	var wrong_session := _result_for(intent, RESULT_READY)
	wrong_session["session_epoch"] = int(intent.get("session_epoch", 0)) + 1
	var wrong_session_result: Dictionary = ext.submit_country_peer_result(wrong_session)
	_expect("wrong session ACK is rejected",
		not bool(wrong_session_result.get("ok", true))
		and String(wrong_session_result.get("code", "")) ==
			"country_peer_result_identity_mismatch")

	var wrong_country_generation := _result_for(intent, RESULT_READY)
	wrong_country_generation["country_generation"] = int(
		intent.get("country_generation", 0)) + 1
	var wrong_country_result: Dictionary = ext.submit_country_peer_result(
		wrong_country_generation)
	_expect("wrong Country generation ACK is rejected",
		not bool(wrong_country_result.get("ok", true))
		and String(wrong_country_result.get("code", "")) ==
			"country_peer_result_identity_mismatch")

	var wrong_peer_generation := _result_for(intent, RESULT_READY)
	wrong_peer_generation["peer_generation"] = int(
		intent.get("peer_generation", 0)) + 1
	var wrong_peer_result: Dictionary = ext.submit_country_peer_result(
		wrong_peer_generation)
	_expect("wrong peer generation ACK is rejected",
		not bool(wrong_peer_result.get("ok", true))
		and String(wrong_peer_result.get("code", "")) ==
			"country_peer_result_identity_mismatch")

	var unknown_request := _result_for(intent, RESULT_READY)
	unknown_request["request_id"] = int(intent.get("request_id", 0)) + 1
	var unknown_request_result: Dictionary = ext.submit_country_peer_result(
		unknown_request)
	_expect("unknown request ACK is rejected",
		not bool(unknown_request_result.get("ok", true))
		and String(unknown_request_result.get("code", "")) ==
			"country_peer_result_request_unknown")

	var stale_result := _result_for(intent, RESULT_STALE)
	var stale_submit: Dictionary = ext.submit_country_peer_result(stale_result)
	_expect("terminal STALE result is rejected without mutation",
		not bool(stale_submit.get("ok", true))
		and String(stale_submit.get("code", "")) ==
			"country_peer_result_stale_terminal_invalid")

	var peer_generation := int(intent.get("peer_generation", 0))
	if peer_generation > 0:
		var invalid_commit_generation := _result_for(intent, RESULT_READY)
		invalid_commit_generation["committed_peer_generation"] = peer_generation - 1
		var invalid_generation_result: Dictionary = ext.submit_country_peer_result(
			invalid_commit_generation)
		_expect("ACK below captured peer generation is rejected",
			not bool(invalid_generation_result.get("ok", true))
			and String(invalid_generation_result.get("code", "")) ==
				"country_peer_result_generation_invalid")

	var waiting_ack := _result_for(intent, RESULT_PENDING)
	waiting_ack["reason"] = "peer_adapter_waiting"
	waiting_ack["committed_peer_generation"] = int(
		intent.get("peer_generation", 0))
	var waiting_submit: Dictionary = ext.submit_country_peer_result(waiting_ack)
	var waiting_status: Dictionary = ext.get_country_peer_protocol_status()
	_expect("PENDING ACK keeps the intent outstanding",
		bool(waiting_submit.get("ok", false))
		and int(waiting_status.get("pending_intents", 0)) == 1)

	var ack := _result_for(intent, RESULT_READY)
	ack["committed_peer_generation"] = peer_generation
	ack["technology_flags"] = PEER_EFFECT_EXISTS | PEER_EFFECT_FIRE_ACKED
	var ack_submit: Dictionary = ext.submit_country_peer_result(ack)
	_expect("valid Effect ACK is accepted",
		bool(ack_submit.get("ok", false)))
	var duplicate_submit: Dictionary = ext.submit_country_peer_result(ack)
	_expect("identical ACK retry is idempotent",
		bool(duplicate_submit.get("ok", false)))

	var mismatch_ack := ack.duplicate(true)
	mismatch_ack["technology_flags"] = PEER_EFFECT_EXISTS
	var mismatch_submit: Dictionary = ext.submit_country_peer_result(mismatch_ack)
	_expect("different duplicate ACK is rejected",
		not bool(mismatch_submit.get("ok", true))
		and String(mismatch_submit.get("code", "")) ==
			"country_peer_result_duplicate_mismatch")

	var status_after_ack: Dictionary = ext.get_country_peer_protocol_status()
	_expect("valid ACK closes the pending protocol item",
		int(status_after_ack.get("pending_intents", -1)) == 0
		and int(status_after_ack.get("queued_intents", -1)) == 0
		and int(status_after_ack.get("rejected_intents", -1)) == 0
		and not bool(status_after_ack.get("has_save_barrier", true)))

	var saw_reward := false
	var saw_economy := false
	var completed := false
	for continuation in range(6):
		var step: Dictionary = ext.run_country_slice({"day_index": 1})
		_expect("same-day continuation %d runs" % continuation,
			bool(step.get("ok", false)))
		var drained: Dictionary = _drain_peer_intents(ext,
			"valid continuation %d" % continuation)
		saw_reward = saw_reward or bool(drained.get("saw_reward", false))
		saw_economy = saw_economy or bool(drained.get("saw_economy", false))
		var snapshot: Dictionary = country.research_snapshot(handle)
		completed = int(snapshot.get("technology_states", PackedInt32Array())[
			technology]) == 5
		var bridge_status: Dictionary = ext.get_country_peer_protocol_status()
		if completed and int(bridge_status.get("pending_intents", 0)) == 0:
			break

	var final_snapshot: Dictionary = country.research_snapshot(handle)
	var final_ids: PackedStringArray = country.snapshot(handle).get(
		"technology_ids", PackedStringArray())
	_expect("same-day continuation activates the technology",
		completed and int(final_snapshot.technology_states[technology]) == 5
		and final_ids.has("tech.animal_husbandry"))
	_expect("same-day continuation does not consume research twice",
		int(final_snapshot.get("consumed_total", -1)) == consumed_once
		and int(final_snapshot.get("last_research_day", -1)) == 1)
	_expect("Effect reward intent is emitted after activation", saw_reward)
	# Economy is not configured in this isolated K2-A fixture. Keep the flag in
	# the evidence so a future Economy bridge fixture can assert the same path.
	_expect("unconfigured Economy does not fabricate a milestone intent",
		not saw_economy)
	var final_status: Dictionary = ext.get_country_peer_protocol_status()
	_expect("valid bridge flow leaves no peer save barrier",
		int(final_status.get("pending_intents", -1)) == 0
		and int(final_status.get("rejected_intents", -1)) == 0
		and not bool(final_status.get("has_save_barrier", true)))
	_expect("modifier peer day is quiescent before checkpoint",
		bool(ext.run_modifier_daily(1).get("ok", false)))
	var checkpoint: Dictionary = ext.capture_country_reference_checkpoint()
	_expect("valid bridge flow remains synchronously saveable",
		bool(checkpoint.get("ok", false)))


func _run_rejection_retry_flow(compiled: Dictionary) -> void:
	var fixture: Dictionary = _make_fixture(compiled, 9045, "peer-reject")
	if fixture.is_empty():
		return
	var prepared: Dictionary = _prepare_async_pending(fixture, "rejection")
	if prepared.is_empty():
		return

	var ext: Object = fixture.ext
	var country: Object = fixture.country
	var handle := int(fixture.handle)
	var technology := int(fixture.technology)
	var intent: Dictionary = prepared.intent
	var generation_before_rejection := int(ext.get_country_report().get(
		"generation", -1))

	var rejected := _result_for(intent, RESULT_REJECTED)
	rejected["reason"] = "peer_rejected_for_test"
	var rejected_submit: Dictionary = ext.submit_country_peer_result(rejected)
	var rejected_status: Dictionary = ext.get_country_peer_protocol_status()
	_expect("peer rejection is durably recorded",
		bool(rejected_submit.get("ok", false))
		and int(rejected_status.get("rejected_intents", 0)) == 1
		and bool(rejected_status.get("has_unreported_rejection", false))
		and int(rejected_status.get("retry_day", -1)) == 2
		and bool(rejected_status.get("has_save_barrier", false)))

	var save_worker := _start_paused_save_worker(ext, 1, "rejection")
	var rejected_save: Dictionary = ext.request_runtime_save(9102)
	_expect("rejected peer retry barrier blocks runtime save",
		not bool(rejected_save.get("ok", true))
		and String(rejected_save.get("code", "")) ==
			"country_checkpoint_peer_rejected_retry_pending")
	_stop_save_worker(ext, save_worker)

	var service: Dictionary = ext.run_country_slice({"day_index": 1})
	_expect("rejection is surfaced as a terminal Country step",
		not bool(service.get("ok", true))
		and String(service.get("core_status", "")) == "rejected"
		and String(service.get("fatal_reason", "")) == "peer_rejected_for_test")
	var after_service_status: Dictionary = ext.get_country_peer_protocol_status()
	_expect("rejection reporting does not advance Country generation",
		int(ext.get_country_report().get("generation", -1)) ==
			generation_before_rejection
		and not bool(after_service_status.get("has_unreported_rejection", true))
		and int(after_service_status.get("retry_day", -1)) == 2)

	var same_day: Dictionary = ext.run_country_slice({"day_index": 1})
	var same_day_poll: Dictionary = ext.poll_country_peer_intent()
	var held_snapshot: Dictionary = country.research_snapshot(handle)
	_expect("same-day rejection barrier holds pending activation",
		bool(same_day.get("ok", false))
		and not bool(same_day_poll.get("available", false))
		and int(held_snapshot.technology_states[technology]) == 4)

	var retry_step: Dictionary = ext.run_country_slice({"day_index": 2})
	_expect("next-day retry boundary runs",
		bool(retry_step.get("ok", false)))
	var retry_poll: Dictionary = ext.poll_country_peer_intent()
	var retry_intent: Dictionary = retry_poll if bool(retry_poll.get(
		"available", false)) else {}
	_expect("next-day retry emits a new request identity",
		bool(retry_poll.get("available", false))
		and int(retry_intent.get("day", -1)) == 2
		and int(retry_intent.get("request_id", 0)) != int(
			intent.get("request_id", 0)))
	var retry_status: Dictionary = ext.get_country_peer_protocol_status()
	_expect("new retry clears the old rejection barrier",
		int(retry_status.get("rejected_intents", -1)) == 0
		and int(retry_status.get("pending_intents", -1)) == 1
		and bool(retry_status.get("has_save_barrier", false)))
	if retry_intent.is_empty():
		return

	var retry_ack := _result_for(retry_intent, RESULT_READY)
	retry_ack["committed_peer_generation"] = int(
		retry_intent.get("peer_generation", 0))
	retry_ack["technology_flags"] = PEER_EFFECT_EXISTS | PEER_EFFECT_FIRE_ACKED
	_expect("next-day retry ACK is accepted",
		bool(ext.submit_country_peer_result(retry_ack).get("ok", false)))

	var completed := false
	for continuation in range(6):
		var step: Dictionary = ext.run_country_slice({"day_index": 2})
		_expect("retry continuation %d runs" % continuation,
			bool(step.get("ok", false)))
		_drain_peer_intents(ext, "retry continuation %d" % continuation)
		var snapshot: Dictionary = country.research_snapshot(handle)
		completed = int(snapshot.technology_states[technology]) == 5
		var status: Dictionary = ext.get_country_peer_protocol_status()
		if completed and int(status.get("pending_intents", 0)) == 0:
			break

	var final_snapshot: Dictionary = country.research_snapshot(handle)
	_expect("rejected technology completes after next-day retry",
		completed and int(final_snapshot.technology_states[technology]) == 5
		and (country.snapshot(handle).technology_ids as PackedStringArray).has(
			"tech.animal_husbandry"))
	var final_status: Dictionary = ext.get_country_peer_protocol_status()
	_expect("retry flow ends without a protocol barrier",
		int(final_status.get("pending_intents", -1)) == 0
		and int(final_status.get("rejected_intents", -1)) == 0
		and not bool(final_status.get("has_save_barrier", true)))
	_expect("retry modifier peer day is quiescent before checkpoint",
		bool(ext.run_modifier_daily(2).get("ok", false)))
	_expect("retry flow can capture a Country checkpoint",
		bool(ext.capture_country_reference_checkpoint().get("ok", false)))


func _run_real_adapter_flow(compiled: Dictionary) -> void:
	var fixture: Dictionary = _make_fixture(compiled, 9046, "peer-real")
	if fixture.is_empty():
		return
	var prepared: Dictionary = _prepare_async_pending(fixture, "real adapter")
	if prepared.is_empty():
		return

	var ext: Object = fixture.ext
	var country: Object = fixture.country
	var modifiers: Object = fixture.modifiers
	var handle := int(fixture.handle)
	var technology := int(fixture.technology)
	var intent: Dictionary = prepared.intent
	var effect_before: Dictionary = ext.get_effect_report()
	var modifier_before: Dictionary = modifiers.list_for_target(1, handle)
	var effect_instances_before := int(effect_before.get("instances", 0))
	var modifier_count_before := int(
		(modifier_before.get("handles", PackedInt64Array()) as PackedInt64Array).size())

	var first_service: Dictionary = ext.service_country_peer_adapter(64)
	var first_status: Dictionary = ext.get_country_peer_protocol_status()
	var first_effect_report: Dictionary = ext.get_effect_report()
	_expect("real adapter service accepts the Country Effect intent",
		bool(first_service.get("ok", false))
		and int(first_service.get("inspected", 0)) == 1
		and int(first_service.get("effect_intents", 0)) == 1
		and int(first_service.get("pending", 0)) == 1
		and int(first_status.get("pending_intents", 0)) == 1)
	_expect("real adapter creates exactly one Effect instance",
		int(first_effect_report.get("instances", 0)) == effect_instances_before + 1)
	_expect("real adapter first pass reports an unacked Effect",
		not bool(ext.effect_instance_fire_acked(
			int(intent.get("effect_instance_id", 0)),
			int(intent.get("effect_generation", 0)))))

	var effect_day: Dictionary = ext.run_effect_daily(1)
	_expect("real Effect daily evaluates the Country-created instance",
		bool(effect_day.get("ok", false)))
	var transaction_dispatch: Dictionary = ext.dispatch_effect_native_modifier()
	_expect("real Effect dispatches its Modifier transaction",
		bool(transaction_dispatch.get("ok", false))
		and int(transaction_dispatch.get("submitted_transactions", 0)) >= 1)
	var modifier_day: Dictionary = ext.run_modifier_daily(1)
	_expect("real Modifier safe boundary commits the transaction",
		bool(modifier_day.get("ok", false)))
	var modifier_ack: Dictionary = ext.ack_effect_native_modifier()
	_expect("real Modifier ACK reaches Effect",
		bool(modifier_ack.get("ok", false))
		and int(modifier_ack.get("acknowledged", 0)) >= 1)
	var gameplay_dispatch: Dictionary = ext.dispatch_effect_native_gameplay()
	_expect("real Effect dispatches its publication transaction",
		bool(gameplay_dispatch.get("ok", false))
		and int(gameplay_dispatch.get("submitted_transactions", 0)) >= 1)
	var gameplay_day: Dictionary = ext.run_gameplay_effects(1)
	_expect("real gameplay adapter commits the publication event",
		bool(gameplay_day.get("ok", false)))
	var gameplay_ack: Dictionary = ext.ack_effect_native_gameplay()
	_expect("real publication ACK reaches Effect",
		bool(gameplay_ack.get("ok", false))
		and int(gameplay_ack.get("acknowledged", 0)) >= 1)

	var first_modifier_snapshot: Dictionary = modifiers.list_for_target(1, handle)
	var first_modifier_count := int((first_modifier_snapshot.get(
		"handles", PackedInt64Array()) as PackedInt64Array).size())
	_expect("real adapter applies one Country technology Modifier",
		first_modifier_count == modifier_count_before + 1)
	var service_after_peer_commit: Dictionary = ext.service_country_peer_adapter(64)
	var status_after_peer_commit: Dictionary = ext.get_country_peer_protocol_status()
	_expect("real adapter closes the Effect intent after peer ACK",
		bool(service_after_peer_commit.get("ok", false))
		and int(service_after_peer_commit.get("completed", 0)) == 1
		and int(status_after_peer_commit.get("pending_intents", 0)) == 0)

	var generation_before_continuation := int(ext.get_country_report().get(
		"generation", -1))
	var activated := false
	for continuation in range(8):
		var step: Dictionary = ext.run_country_slice({"day_index": 1})
		_expect("real adapter same-day continuation %d runs" % continuation,
			bool(step.get("ok", false)))
		var follow_up: Dictionary = ext.service_country_peer_adapter(64)
		_expect("real adapter follow-up service %d succeeds" % continuation,
			bool(follow_up.get("ok", false)))
		var snapshot: Dictionary = country.research_snapshot(handle)
		activated = int(snapshot.technology_states[technology]) == 5
		var protocol: Dictionary = ext.get_country_peer_protocol_status()
		if activated and int(protocol.get("pending_intents", 0)) == 0:
			break

	var final_snapshot: Dictionary = country.research_snapshot(handle)
	var final_effect_report: Dictionary = ext.get_effect_report()
	var final_modifier_snapshot: Dictionary = modifiers.list_for_target(1, handle)
	var final_modifier_count := int((final_modifier_snapshot.get(
		"handles", PackedInt64Array()) as PackedInt64Array).size())
	_expect("real adapter same-day continuation activates technology",
		activated and int(final_snapshot.technology_states[technology]) == 5
		and (country.snapshot(handle).technology_ids as PackedStringArray).has(
			"tech.animal_husbandry"))
	_expect("real adapter does not duplicate the Effect instance",
		int(final_effect_report.get("instances", 0)) == effect_instances_before + 1)
	_expect("real adapter does not duplicate the Modifier",
		final_modifier_count == first_modifier_count)
	_expect("real adapter preserves one-time research consumption",
		int(final_snapshot.get("consumed_total", -1)) ==
			int(prepared.research.get("consumed_total", -2))
		and int(final_snapshot.get("last_research_day", -1)) == 1)
	_expect("real adapter generation remains monotonic",
		int(ext.get_country_report().get("generation", -1)) >=
			generation_before_continuation)
	var final_status: Dictionary = ext.get_country_peer_protocol_status()
	_expect("real adapter flow leaves no peer or save barrier",
		int(final_status.get("pending_intents", -1)) == 0
		and int(final_status.get("rejected_intents", -1)) == 0
		and not bool(final_status.get("has_save_barrier", true)))
	_expect("real adapter flow remains checkpointable",
		bool(ext.capture_country_reference_checkpoint().get("ok", false)))


func _make_fixture(compiled: Dictionary, seed: int, suffix: String) -> Dictionary:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("%s DCWorldExt instantiates" % suffix, ext != null)
	if ext == null:
		return {}
	ext.create_entities(1)

	var modifiers = ModifierFacadeScript.new()
	_expect("%s modifier catalog configures" % suffix,
		bool(modifiers.configure(ext, 4).get("ok", false)))
	var effect = EffectFacadeScript.new()
	_expect("%s effect catalog configures" % suffix,
		bool(effect.configure(ext, null, EffectDomainCatalogScript.build()).get(
			"ok", false)))
	var country = CountryFacadeScript.new()
	_expect("%s country configures" % suffix,
		bool(country.configure(ext, 1, seed,
			load("res://data/country/default_country.tres"), compiled).get(
			"ok", false)))
	effect.register_domain_adapters(modifiers, country, null)

	var ids: PackedStringArray = compiled.get("technology_ids", PackedStringArray())
	var goods: PackedStringArray = compiled.get("good_ids", PackedStringArray())
	var points_good := goods.find("technology_points")
	var hunting := ids.find("tech.hunting")
	var early_knowledge := ids.find("tech.early_knowledge_institution")
	var animal_husbandry := ids.find("tech.animal_husbandry")
	_expect("%s peer research catalog entries exist" % suffix,
		points_good >= 0 and hunting >= 0 and early_knowledge >= 0
		and animal_husbandry >= 0)
	if points_good < 0 or hunting < 0 or early_knowledge < 0 \
			or animal_husbandry < 0:
		return {}

	var packet := {
		"country_ids": PackedStringArray(["country.%s" % suffix]),
		"country_names": PackedStringArray([suffix]),
		"country_cash": PackedInt64Array([0]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 2]),
		"technology_indices": PackedInt32Array([hunting, early_knowledge]),
		"treasury_offsets": PackedInt32Array([0, 1]),
		"treasury_good_indices": PackedInt32Array([points_good]),
		"treasury_quantities": PackedInt64Array([10000000]),
	}
	var boot: Dictionary = country.bootstrap(PackedByteArray([0]), packet)
	_expect("%s country bootstraps" % suffix, bool(boot.get("ok", false)))
	if not bool(boot.get("ok", false)):
		return {}
	var handle := int(country.cell_summary(0).get("country_handle", 0))
	_expect("%s exposes a valid Country handle" % suffix, handle != 0)
	if handle == 0:
		return {}
	return {
		"ext": ext,
		"country": country,
		"effect": effect,
		"modifiers": modifiers,
		"handle": handle,
		"technology": animal_husbandry,
	}


func _prepare_async_pending(fixture: Dictionary, label: String) -> Dictionary:
	var ext: Object = fixture.ext
	var country: Object = fixture.country
	var handle := int(fixture.handle)
	_expect("%s queues sheep evidence" % label,
		bool(country.discover_research_signal(handle, &"bio.sheep", 0, 1, 0,
			1).get("ok", false)))
	_expect("%s commits evidence boundary" % label,
		bool(ext.run_country_slice({"day_index": 0}).get("ok", false)))
	var async_mode: Dictionary = ext.set_country_peer_async_mode(true)
	_expect("%s enables async peer mode" % label,
		bool(async_mode.get("ok", false))
		and bool(async_mode.get("async_mode", false)))
	_expect("%s queues research weights" % label,
		bool(country.set_research_weights(handle,
			PackedInt32Array([10000, 0, 0, 0]), 1, 10).get("ok", false)))
	_expect("%s queues animal husbandry" % label,
		bool(country.enqueue_research(handle, &"tech.animal_husbandry",
			0, -1, 1, 11).get("ok", false)))
	var day_one: Dictionary = ext.run_country_slice({"day_index": 1})
	_expect("%s completion boundary runs" % label,
		bool(day_one.get("ok", false)))
	var polled: Dictionary = ext.poll_country_peer_intent()
	_expect("%s emits a peer intent" % label,
		bool(polled.get("available", false)))
	if not bool(polled.get("available", false)):
		return {}
	return {
		"intent": polled,
		"research": country.research_snapshot(handle),
	}


func _result_for(intent: Dictionary, code: int) -> Dictionary:
	return {
		"protocol_version": int(intent.get("protocol_version", 1)),
		"code": code,
		"opcode": int(intent.get("opcode", 0)),
		"request_id": int(intent.get("request_id", 0)),
		"session_epoch": int(intent.get("session_epoch", 0)),
		"country_generation": int(intent.get("country_generation", 0)),
		"committed_peer_generation": 0,
		"peer_generation": int(intent.get("peer_generation", 0)),
		"day": int(intent.get("day", -1)),
		"continuation_index": int(intent.get("continuation_index", 0)),
		"country_slot": int(intent.get("country_slot", -1)),
		"technology": int(intent.get("technology", -1)),
		"target_handle": int(intent.get("target_handle", 0)),
		"technology_flags": 0,
		"reason": "",
	}


func _drain_peer_intents(ext: Object, label: String) -> Dictionary:
	var count := 0
	var saw_reward := false
	var saw_economy := false
	while count < 16:
		var intent: Dictionary = ext.poll_country_peer_intent()
		if not bool(intent.get("available", false)):
			break
		var opcode := int(intent.get("opcode", 0))
		_expect("%s intent opcode is known" % label, opcode >= 1 and opcode <= 5)
		if opcode == 4:
			saw_reward = true
		if opcode == 5:
			saw_economy = true
		var result_code := RESULT_READY if opcode == 1 or opcode == 2 \
			else RESULT_APPLIED
		var result := _result_for(intent, result_code)
		result["committed_peer_generation"] = int(
			intent.get("peer_generation", 0))
		if opcode == 1 or opcode == 2:
			result["technology_flags"] = PEER_EFFECT_EXISTS | PEER_EFFECT_FIRE_ACKED
		var submitted: Dictionary = ext.submit_country_peer_result(result)
		_expect("%s ACK %d is accepted" % [label, count],
			bool(submitted.get("ok", false)))
		count += 1
	return {"count": count, "saw_reward": saw_reward, "saw_economy": saw_economy}


func _start_paused_save_worker(ext: Object, day: int, label: String) -> Dictionary:
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": true,
		"day": day,
		"speed_days_per_second": 1.0,
		"paused": true,
	})
	_expect("%s paused save worker starts" % label,
		bool(started.get("ok", false)))
	return started


func _stop_save_worker(ext: Object, started: Dictionary) -> void:
	if not bool(started.get("ok", false)):
		return
	ext.request_runtime_stop()
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		if String(ext.get_runtime_thread_report().get(
			"simulation_host_state", "")) == "STOPPED":
			return
		OS.delay_msec(2)
	_expect("paused save worker stops", false)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] " + label)
