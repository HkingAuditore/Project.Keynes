extends SceneTree

const Q16_ONE := 65536
const PLANNED := 1
const PREFLIGHTED := 2
const COMMITTED := 3
const ACKED := 4

var adapter_phases: Array[String] = []

func _test_effect_adapter(command: Dictionary) -> Dictionary:
	adapter_phases.append(String(command.get("phase", "")))
	var domain := int(command.get("domain", -1))
	return {"ok": true, "ack_mask": (1 << domain) if domain >= 0 else 0}

func _assert_ok(result: Dictionary, label: String) -> void:
	assert(bool(result.get("ok", false)), "%s: %s" % [label, str(result)])

func _poll(ext: Object, cursor: int = 0) -> Dictionary:
	return ext.poll_effect_transactions(cursor, 8)

func _init() -> void:
	var domain_catalog: Resource = EffectDomainCatalog.build()
	assert(domain_catalog != null, "domain effect catalog build failed")
	var domain_compiled: Dictionary = domain_catalog.compile_native_catalog()
	_assert_ok(domain_compiled, "domain effect catalog compile")
	assert(int(domain_compiled.get("effect_keys", PackedStringArray()).size()) > 0,
		"domain effect catalog contains no technology/family/person programs")
	var ext = ClassDB.instantiate("DCWorldExt")
	assert(ext != null)

	var catalog := EffectCatalog.new()
	catalog.metric_keys = PackedStringArray(["workshop_count"])
	catalog.max_work_per_slice = 4
	var definition := EffectDefinition.new()
	definition.key = &"test.workshop_conversion"
	definition.cadence_days = 1
	definition.max_work = 6

	var condition := EffectCondition.new()
	condition.op = 2 # METRIC_GTE
	condition.arg0 = 0
	condition.value_q16 = 3 * Q16_ONE
	definition.conditions = [condition]

	var read := EffectInstruction.new()
	read.op = 2 # READ_METRIC
	read.arg0 = 0
	var divisor := EffectInstruction.new()
	divisor.op = 1 # CONST
	divisor.value_q16 = 2 * Q16_ONE
	var divide := EffectInstruction.new()
	divide.op = 7 # DIV_FLOOR
	var emit_modifier := EffectInstruction.new()
	emit_modifier.op = 11 # EMIT_COMMAND
	emit_modifier.arg0 = 0
	var emit_country := EffectInstruction.new()
	emit_country.op = 11 # EMIT_COMMAND
	emit_country.arg0 = 1
	definition.instructions = [read, divisor, divide, emit_modifier, emit_country]

	var modifier_command := EffectCommand.new()
	modifier_command.action = 1
	modifier_command.domain = 3
	modifier_command.opcode = 1
	modifier_command.target_resolver = 1
	modifier_command.value_mode = 1
	modifier_command.command_key = &"test.modifier"
	modifier_command.definition_key = &"test.modifier.definition"
	var country_command := EffectCommand.new()
	country_command.action = 2
	country_command.domain = 1
	country_command.opcode = 7
	country_command.target_resolver = 1
	country_command.value_mode = 1
	country_command.command_key = &"test.country"
	country_command.definition_key = &"test.country.definition"
	definition.commands = [modifier_command, country_command]
	catalog.definitions = [definition]

	var configured: Dictionary = ext.configure_effects(catalog.compile_native_catalog())
	_assert_ok(configured, "catalog compile/configure")

	var submitted: Dictionary = ext.submit_effect_instances({
		"instance_ids": PackedInt64Array([42, 43]),
		"program_keys": PackedStringArray(["test.workshop_conversion", "test.workshop_conversion"]),
		"generations": PackedInt32Array([1, 1]),
		"target_handles": PackedInt64Array([9001, 9002]),
		"target_generations": PackedInt32Array([7, 8]),
		"next_due_days": PackedInt64Array([0, 0]),
	})
	_assert_ok(submitted, "submit instances")
	assert(int(submitted.get("accepted", 0)) == 2, str(submitted))

	var snapshot: Dictionary = ext.submit_effect_snapshots({
		"instance_ids": PackedInt64Array([42, 43]),
		"revisions": PackedInt64Array([1, 1]),
		"metric_offsets": PackedInt32Array([0, 1, 2]),
		"metric_ids": PackedInt32Array([0, 0]),
		"metric_values_q16": PackedInt64Array([5 * Q16_ONE, 1 * Q16_ONE]),
	})
	_assert_ok(snapshot, "submit snapshots")

	# max_work charges six units, while the slice budget is four. The first
	# instance still runs once and yields done=false; the second slice completes.
	var first_slice: Dictionary = ext.run_effect_daily(0)
	_assert_ok(first_slice, "first daily slice")
	assert(not bool(first_slice.get("done", true)), str(first_slice))
	var second_slice: Dictionary = ext.run_effect_daily(0)
	_assert_ok(second_slice, "second daily slice")
	assert(bool(second_slice.get("done", false)), str(second_slice))

	var transactions := _poll(ext)
	assert(int(transactions.get("count", 0)) == 1, str(transactions))
	assert(int(transactions.command_values_q16[0]) == 2 * Q16_ONE, str(transactions))
	assert(int(transactions.command_target_generations[0]) == 7, str(transactions))
	assert(int(transactions.command_idempotency_keys[0]) != 0, str(transactions))
	var tx_id := int(transactions.transaction_ids[0])
	var required := int(transactions.required_ack_masks[0])
	assert(required == ((1 << 1) | (1 << 3)), str(transactions))
	assert(int(transactions.statuses[0]) == PLANNED, str(transactions))

	# ACK cannot bypass preflight and commit.
	var early_ack: Dictionary = ext.ack_effect_transactions({
		"transaction_ids": PackedInt64Array([tx_id]),
		"ack_masks": PackedInt32Array([required]),
	})
	assert(not bool(early_ack.get("ok", true)), str(early_ack))

	_assert_ok(ext.preflight_effect_transactions({
		"transaction_ids": PackedInt64Array([tx_id]),
		"ack_masks": PackedInt32Array([required]),
	}), "preflight")
	transactions = _poll(ext)
	assert(int(transactions.statuses[0]) == PREFLIGHTED, str(transactions))
	_assert_ok(ext.commit_effect_transactions({
		"transaction_ids": PackedInt64Array([tx_id]),
		"ack_masks": PackedInt32Array([required]),
	}), "commit")

	# Multi-domain ACK can arrive in separate safe-boundary commits.
	_assert_ok(ext.ack_effect_transactions({
		"transaction_ids": PackedInt64Array([tx_id]),
		"ack_masks": PackedInt32Array([1 << 1]),
	}), "partial ACK")
	transactions = _poll(ext)
	assert(int(transactions.statuses[0]) == COMMITTED, str(transactions))
	_assert_ok(ext.ack_effect_transactions({
		"transaction_ids": PackedInt64Array([tx_id]),
		"ack_masks": PackedInt32Array([1 << 3]),
	}), "final ACK")
	var duplicate_ack: Dictionary = ext.ack_effect_transactions({
		"transaction_ids": PackedInt64Array([tx_id]),
		"ack_masks": PackedInt32Array([required]),
	})
	_assert_ok(duplicate_ack, "duplicate ACK")
	assert(int(duplicate_ack.get("acknowledged", 0)) == 0, str(duplicate_ack))
	assert(int(ext.get_effect_report().get("transactions_acked", 0)) == 1,
		str(ext.get_effect_report()))

	# A stale input revision must not replace the committed snapshot.
	var stale: Dictionary = ext.submit_effect_snapshots({
		"instance_ids": PackedInt64Array([42]),
		"revisions": PackedInt64Array([0]),
		"metric_offsets": PackedInt32Array([0, 1]),
		"metric_ids": PackedInt32Array([0]),
		"metric_values_q16": PackedInt64Array([1 * Q16_ONE]),
	})
	_assert_ok(stale, "stale snapshot")

	# A newer frozen snapshot can re-evaluate an already completed day. This is
	# required for event-driven metrics; unchanged revisions still obey cadence.
	var dirty_ext = ClassDB.instantiate("DCWorldExt")
	_assert_ok(dirty_ext.configure_effects(catalog.compile_native_catalog()),
		"same-day dirty catalog")
	_assert_ok(dirty_ext.submit_effect_instances({
		"instance_ids": PackedInt64Array([601]),
		"program_keys": PackedStringArray(["test.workshop_conversion"]),
		"target_handles": PackedInt64Array([9601]),
		"target_generations": PackedInt32Array([1]),
		"next_due_days": PackedInt64Array([0]),
	}), "same-day dirty instance")
	_assert_ok(dirty_ext.submit_effect_snapshots({
		"instance_ids": PackedInt64Array([601]),
		"revisions": PackedInt64Array([1]),
		"metric_offsets": PackedInt32Array([0, 1]),
		"metric_ids": PackedInt32Array([0]),
		"metric_values_q16": PackedInt64Array([Q16_ONE]),
	}), "same-day initial snapshot")
	_assert_ok(dirty_ext.run_effect_daily(0), "same-day initial evaluation")
	assert(int(_poll(dirty_ext).get("count", 0)) == 0, str(_poll(dirty_ext)))
	_assert_ok(dirty_ext.submit_effect_snapshots({
		"instance_ids": PackedInt64Array([601]),
		"revisions": PackedInt64Array([2]),
		"metric_offsets": PackedInt32Array([0, 1]),
		"metric_ids": PackedInt32Array([0]),
		"metric_values_q16": PackedInt64Array([5 * Q16_ONE]),
	}), "same-day updated snapshot")
	var same_day_replay: Dictionary = dirty_ext.run_effect_daily(0)
	_assert_ok(same_day_replay, "same-day dirty replay")
	assert(bool(same_day_replay.get("done", false)), str(same_day_replay))
	assert(int(_poll(dirty_ext).get("count", 0)) == 1, str(_poll(dirty_ext)))
	assert(int(dirty_ext.explain_effect(601).get("last_evaluated_input_revision", -1)) == 2,
		str(dirty_ext.explain_effect(601)))

	# Declarative candidates use C++ worker planning when available. Platforms
	# built without workers take the same deterministic planning/merge contract
	# on the calling thread, so the result assertion is independent of platform.
	var parallel_catalog := EffectCatalog.new()
	parallel_catalog.metric_keys = catalog.metric_keys
	parallel_catalog.definitions = catalog.definitions
	parallel_catalog.max_work_per_slice = 512
	var parallel_ext = ClassDB.instantiate("DCWorldExt")
	_assert_ok(parallel_ext.configure_effects(parallel_catalog.compile_native_catalog()),
		"parallel catalog")
	var parallel_ids := PackedInt64Array()
	var parallel_programs := PackedStringArray()
	var parallel_targets := PackedInt64Array()
	var parallel_generations := PackedInt32Array()
	var parallel_due := PackedInt64Array()
	var parallel_revisions := PackedInt64Array()
	var parallel_offsets := PackedInt32Array([0])
	var parallel_metric_ids := PackedInt32Array()
	var parallel_metric_values := PackedInt64Array()
	for i in range(96):
		parallel_ids.append(10_000 + i)
		parallel_programs.append("test.workshop_conversion")
		parallel_targets.append(20_000 + i)
		parallel_generations.append(1)
		parallel_due.append(0)
		parallel_revisions.append(1)
		parallel_metric_ids.append(0)
		parallel_metric_values.append(5 * Q16_ONE)
		parallel_offsets.append(parallel_metric_ids.size())
	_assert_ok(parallel_ext.submit_effect_instances({
		"instance_ids": parallel_ids,
		"program_keys": parallel_programs,
		"target_handles": parallel_targets,
		"target_generations": parallel_generations,
		"next_due_days": parallel_due,
	}), "parallel instances")
	_assert_ok(parallel_ext.submit_effect_snapshots({
		"instance_ids": parallel_ids,
		"revisions": parallel_revisions,
		"metric_offsets": parallel_offsets,
		"metric_ids": parallel_metric_ids,
		"metric_values_q16": parallel_metric_values,
	}), "parallel snapshots")
	_assert_ok(parallel_ext.run_effect_daily(0), "parallel first slice")
	_assert_ok(parallel_ext.run_effect_daily(0), "parallel second slice")
	var parallel_report: Dictionary = parallel_ext.get_effect_report()
	assert(int(parallel_report.get("programs_evaluated", 0)) == 96, str(parallel_report))
	assert(int(parallel_ext.poll_effect_transactions(0, 128).get("count", 0)) == 96,
		str(parallel_ext.poll_effect_transactions(0, 128)))
	assert(String(parallel_report.get("last_parallel_path", "")).length() > 0,
		str(parallel_report))

	# Generation changes reset fire sequence and produce a new idempotency epoch.
	_assert_ok(ext.submit_effect_instances({
		"instance_ids": PackedInt64Array([42]),
		"program_keys": PackedStringArray(["test.workshop_conversion"]),
		"generations": PackedInt32Array([2]),
		"target_handles": PackedInt64Array([9001]),
		"target_generations": PackedInt32Array([9]),
		"next_due_days": PackedInt64Array([1]),
	}), "generation update")
	_assert_ok(ext.submit_effect_snapshots({
		"instance_ids": PackedInt64Array([42]),
		"revisions": PackedInt64Array([2]),
		"metric_offsets": PackedInt32Array([0, 1]),
		"metric_ids": PackedInt32Array([0]),
		"metric_values_q16": PackedInt64Array([5 * Q16_ONE]),
	}), "new generation snapshot")
	_assert_ok(ext.run_effect_daily(1), "generation daily")
	var generation_tx := _poll(ext, tx_id)
	assert(int(generation_tx.get("count", 0)) == 1, str(generation_tx))
	var generation_tx_id := int(generation_tx.transaction_ids[0])
	var explanation: Dictionary = ext.explain_effect(42)
	_assert_ok(explanation, "explain")
	assert(int(explanation.get("generation", 0)) == 2, str(explanation))
	assert(int(explanation.get("fire_sequence", -1)) == 1, str(explanation))

	# Reusing an instance ID with a new generation rejects old pending work.
	_assert_ok(ext.submit_effect_instances({
		"instance_ids": PackedInt64Array([42]),
		"program_keys": PackedStringArray(["test.workshop_conversion"]),
		"generations": PackedInt32Array([3]),
		"target_handles": PackedInt64Array([9001]),
		"target_generations": PackedInt32Array([10]),
		"next_due_days": PackedInt64Array([2]),
	}), "stale transaction generation")
	assert(int(_poll(ext, tx_id).get("count", 0)) == 0, str(_poll(ext, tx_id)))
	assert(int(ext.get_effect_report().get("rejected_transactions", 0)) == 1,
		str(ext.get_effect_report()))

	# Duplicate IDs in one submission are rejected deterministically.
	var duplicate_submit: Dictionary = ext.submit_effect_instances({
		"instance_ids": PackedInt64Array([77, 77]),
		"program_keys": PackedStringArray(["test.workshop_conversion", "test.workshop_conversion"]),
	})
	_assert_ok(duplicate_submit, "duplicate submission")
	assert(int(duplicate_submit.get("rejected", 0)) == 1, str(duplicate_submit))

	# A full bounded queue applies backpressure without advancing past the
	# blocked instance. Once the earlier transaction is ACKED, terminal compaction
	# makes room and the same-day cursor continues deterministically.
	var capacity_catalog := EffectCatalog.new()
	capacity_catalog.metric_keys = catalog.metric_keys
	capacity_catalog.definitions = catalog.definitions
	capacity_catalog.max_transactions = 1
	capacity_catalog.max_work_per_slice = 4
	var ext_capacity = ClassDB.instantiate("DCWorldExt")
	_assert_ok(ext_capacity.configure_effects(capacity_catalog.compile_native_catalog()),
		"capacity catalog")
	_assert_ok(ext_capacity.submit_effect_instances({
		"instance_ids": PackedInt64Array([701, 702]),
		"program_keys": PackedStringArray(["test.workshop_conversion", "test.workshop_conversion"]),
		"target_handles": PackedInt64Array([7010, 7020]),
	}), "capacity instances")
	_assert_ok(ext_capacity.submit_effect_snapshots({
		"instance_ids": PackedInt64Array([701, 702]),
		"revisions": PackedInt64Array([1, 1]),
		"metric_offsets": PackedInt32Array([0, 1, 2]),
		"metric_ids": PackedInt32Array([0, 0]),
		"metric_values_q16": PackedInt64Array([5 * Q16_ONE, 5 * Q16_ONE]),
	}), "capacity snapshots")
	var capacity_first: Dictionary = ext_capacity.run_effect_daily(0)
	_assert_ok(capacity_first, "capacity first daily")
	assert(not bool(capacity_first.get("done", true)), str(capacity_first))
	var capacity_blocked: Dictionary = ext_capacity.run_effect_daily(0)
	assert(not bool(capacity_blocked.get("ok", true)), str(capacity_blocked))
	assert(not bool(capacity_blocked.get("done", true)), str(capacity_blocked))
	assert(int(capacity_blocked.get("run_cursor", -1)) == 1,
		str(capacity_blocked))
	var capacity_tx := _poll(ext_capacity)
	assert(int(capacity_tx.get("count", 0)) == 1, str(capacity_tx))
	var capacity_tx_id := int(capacity_tx.transaction_ids[0])
	var capacity_mask := int(capacity_tx.required_ack_masks[0])
	_assert_ok(ext_capacity.preflight_effect_transactions({
		"transaction_ids": PackedInt64Array([capacity_tx_id]),
		"ack_masks": PackedInt32Array([capacity_mask]),
	}), "capacity preflight")
	_assert_ok(ext_capacity.commit_effect_transactions({
		"transaction_ids": PackedInt64Array([capacity_tx_id]),
		"ack_masks": PackedInt32Array([capacity_mask]),
	}), "capacity commit")
	_assert_ok(ext_capacity.ack_effect_transactions({
		"transaction_ids": PackedInt64Array([capacity_tx_id]),
		"ack_masks": PackedInt32Array([capacity_mask]),
	}), "capacity ACK")
	var capacity_resumed: Dictionary = ext_capacity.run_effect_daily(0)
	_assert_ok(capacity_resumed, "capacity resume")
	assert(bool(capacity_resumed.get("done", false)), str(capacity_resumed))
	assert(int(ext_capacity.get_effect_report().get("overflow_count", 0)) >= 1,
		str(ext_capacity.get_effect_report()))

	# A missing native behavior is a retryable evaluation failure, not a silent
	# fire-sequence advance.
	var behavior_catalog := EffectCatalog.new()
	var missing_behavior := EffectDefinition.new()
	missing_behavior.key = &"test.missing_behavior"
	missing_behavior.behavior_id = &"test.behavior.not_registered"
	missing_behavior.max_work = 1
	behavior_catalog.definitions = [missing_behavior]
	var ext_behavior = ClassDB.instantiate("DCWorldExt")
	_assert_ok(ext_behavior.configure_effects(behavior_catalog.compile_native_catalog()),
		"behavior catalog")
	_assert_ok(ext_behavior.submit_effect_instances({
		"instance_ids": PackedInt64Array([801]),
		"program_keys": PackedStringArray(["test.missing_behavior"]),
	}), "behavior instance")
	var behavior_result: Dictionary = ext_behavior.run_effect_daily(0)
	assert(not bool(behavior_result.get("ok", true)), str(behavior_result))
	assert(not bool(behavior_result.get("done", true)), str(behavior_result))
	assert(int(ext_behavior.explain_effect(801).get("fire_sequence", -1)) == 0,
		str(ext_behavior.explain_effect(801)))

	var saved: PackedByteArray = ext.capture_effect_state()
	assert(not saved.is_empty())
	var truncated := saved.duplicate()
	truncated.resize(max(0, truncated.size() - 1))
	var bad_restore: Dictionary = ext.restore_effect_state(truncated)
	assert(not bool(bad_restore.get("ok", true)), str(bad_restore))
	assert(int(ext.get_effect_report().get("instances", 0)) == 3,
		str(ext.get_effect_report()))
	_assert_ok(ext.clear_effect_state(), "clear")
	var restored: Dictionary = ext.restore_effect_state(saved)
	_assert_ok(restored, "restore")
	assert(int(ext.get_effect_report().get("instances", 0)) == 3,
		str(ext.get_effect_report()))
	assert(generation_tx_id > tx_id)

	# Facade transport keeps missing adapters pollable, then performs the
	# adapter preflight -> safe commit -> ACK sequence once both domains exist.
	var ext2 = ClassDB.instantiate("DCWorldExt")
	var facade := EffectFacade.new()
	_assert_ok(facade.configure(ext2, null, catalog), "facade configure")
	_assert_ok(ext2.submit_effect_instances({
		"instance_ids": PackedInt64Array([500]),
		"program_keys": PackedStringArray(["test.workshop_conversion"]),
		"generations": PackedInt32Array([1]),
		"target_handles": PackedInt64Array([7000]),
		"target_generations": PackedInt32Array([11]),
		"next_due_days": PackedInt64Array([0]),
	}), "facade instance")
	_assert_ok(ext2.submit_effect_snapshots({
		"instance_ids": PackedInt64Array([500]),
		"revisions": PackedInt64Array([1]),
		"metric_offsets": PackedInt32Array([0, 1]),
		"metric_ids": PackedInt32Array([0]),
		"metric_values_q16": PackedInt64Array([5 * Q16_ONE]),
	}), "facade snapshot")
	_assert_ok(ext2.run_effect_daily(0), "facade daily")
	var missing_dispatch: Dictionary = facade.dispatch_transactions()
	_assert_ok(missing_dispatch, "missing adapter dispatch")
	assert(int(missing_dispatch.get("dispatched", 0)) == 0, str(missing_dispatch))
	facade.register_adapter(1, 3, &"test.modifier", Callable(self, "_test_effect_adapter"))
	facade.register_adapter(2, 1, &"test.country", Callable(self, "_test_effect_adapter"))
	var dispatched: Dictionary = facade.dispatch_transactions()
	_assert_ok(dispatched, "adapter dispatch")
	assert(int(dispatched.get("dispatched", 0)) == 1, str(dispatched))
	assert(adapter_phases == ["preflight", "preflight", "commit", "commit"],
		str(adapter_phases))

	print("effect_runtime_test: PASS")
	quit()
