#include "effect_runtime_includes.inc"

namespace pk {
using namespace godot;

Dictionary EffectRuntime::explain(int64_t instance_id) const {
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0) return failure("effect_instance_not_found");
    const Instance &instance = _instances[index];
    const Definition &definition = _definitions[instance.program_id];
    Dictionary out;
    out["ok"] = true;
    out["instance_id"] = instance.id;
    out["generation"] = static_cast<int64_t>(instance.generation);
    out["program_key"] = String(definition.key.c_str());
    out["program_version"] = definition.version;
    out["level"] = instance.level;
    out["source_kind"] = instance.source_kind;
    out["target_domain"] = instance.target_domain;
    out["operation"] = instance.operation;
    out["lifecycle"] = instance.lifecycle;
    out["duration_days"] = instance.duration_days;
    out["stack_policy"] = instance.stack_policy;
    out["stack_count"] = instance.stack_count;
    out["applied_stack_count"] = instance.applied_stack_count;
    out["max_stacks"] = instance.max_stacks;
    out["priority"] = instance.priority;
    out["activation_sequence"] = static_cast<int64_t>(
        instance.activation_sequence);
    out["expires_day"] = instance.expires_day;
    out["effect_applied"] = instance.effect_applied != 0;
    out["retire_requested"] = instance.retire_requested != 0;
    out["applied_input_revision"] = instance.applied_input_revision;
    out["last_acked_fire_sequence"] = static_cast<int64_t>(
        instance.last_acked_fire_sequence);
    // Persisted since PKEF 13. Exposed so a test can tell a genuinely latched
    // instance from one that merely round-tripped a zero.
    out["latched"] = instance.latched != 0;
    out["next_due_day"] = instance.next_due_day;
    out["input_revision"] = instance.input_revision;
    out["last_evaluated_input_revision"] = instance.last_evaluated_input_revision;
    out["fire_sequence"] = static_cast<int64_t>(instance.fire_sequence);
    out["condition_passes"] = evaluate_condition(definition, instance);
    return out;
}

Dictionary EffectRuntime::report() const {
    Dictionary out;
    std::array<int32_t, RESYNC_REQUIRED + 1> status_counts{};
    for (const Transaction &transaction : _transactions) {
        if (transaction.status >= PLANNED && transaction.status <= RESYNC_REQUIRED)
            ++status_counts[transaction.status];
    }
    out["configured"] = _configured;
    out["protocol_version"] = PROTOCOL_VERSION;
    out["save_schema_version"] = SAVE_SCHEMA_VERSION;
    out["catalog_hash"] = static_cast<int64_t>(_catalog_hash);
    out["committed_generation"] = static_cast<int64_t>(_committed_generation);
    out["current_day"] = _current_day;
    out["last_completed_day"] = _last_completed_day;
    out["definitions"] = static_cast<int32_t>(_definitions.size());
    out["metrics"] = _metric_count;
    out["instances"] = static_cast<int32_t>(_instance_ids.size());
    out["instance_storage_slots"] = static_cast<int32_t>(_instances.size());
    out["free_instance_slots"] = static_cast<int32_t>(_free_instance_indices.size());
    out["family_effect_stack_groups"] = static_cast<int64_t>(
        _family_effect_groups.size());
    int64_t family_effect_group_members = 0;
    int64_t family_effect_group_bytes = 0;
    for (const auto &entry : _family_effect_groups) {
        family_effect_group_members += static_cast<int64_t>(entry.second.size());
        family_effect_group_bytes += static_cast<int64_t>(
            sizeof(entry.first) + entry.second.capacity() * sizeof(int32_t));
    }
    out["family_effect_group_members"] = family_effect_group_members;
    out["family_effect_group_bytes"] = family_effect_group_bytes;
    out["transactions"] = static_cast<int32_t>(_transactions.size());
    out["external_bindings"] = static_cast<int32_t>(_external_binding_ids.size());
    out["pending_command_idempotency_count"] = static_cast<int64_t>(
        _pending_command_idempotency.size());
    out["pending_transactions"] = static_cast<int32_t>(std::count_if(
        _transactions.begin(), _transactions.end(), [](const Transaction &transaction) {
            return transaction.status == PLANNED || transaction.status == PREFLIGHTED ||
                transaction.status == COMMITTED;
        }));
    out["planned_transactions"] = status_counts[PLANNED];
    out["preflighted_transactions"] = status_counts[PREFLIGHTED];
    out["committed_transactions"] = status_counts[COMMITTED];
    out["acked_transactions"] = status_counts[ACKED];
    out["rejected_transactions"] = status_counts[REJECTED];
    out["resync_required_transactions"] = status_counts[RESYNC_REQUIRED];
    out["max_work_per_slice"] = _max_work_per_slice;
    out["instances_submitted"] = static_cast<int64_t>(_instances_submitted);
    out["programs_evaluated"] = static_cast<int64_t>(_programs_evaluated);
    out["commands_emitted"] = static_cast<int64_t>(_commands_emitted);
    out["transactions_acked"] = static_cast<int64_t>(_transactions_acked);
    out["preflight_rejects"] = static_cast<int64_t>(_preflight_rejects);
    out["behavior_failures"] = static_cast<int64_t>(_behavior_failures);
    out["overflow_count"] = static_cast<int64_t>(_overflow_count);
    out["last_evaluate_ms"] = _last_evaluate_ms;
    out["last_native_modifier_dispatch_ms"] = _last_native_dispatch_ms;
    out["last_native_modifier_ack_ms"] = _last_native_ack_ms;
    out["last_parallel_planning_ms"] = _last_parallel_planning_ms;
    out["last_parallel_merge_ms"] = _last_parallel_merge_ms;
    out["last_parallel_worker_count"] = _last_parallel_worker_count;
    out["parallel_dispatches"] = static_cast<int64_t>(_parallel_dispatches);
    out["serial_fallback_dispatches"] = static_cast<int64_t>(_serial_fallback_dispatches);
    out["last_parallel_path"] = String(_last_parallel_path.c_str());
    out["last_parallel_fallback_reason"] = String(_last_parallel_fallback_reason.c_str());
    out["native_modifier_transactions"] = static_cast<int64_t>(_native_modifier_transactions);
    out["native_modifier_commands"] = static_cast<int64_t>(_native_modifier_commands);
    out["native_modifier_acks"] = static_cast<int64_t>(_native_modifier_acks);
    out["native_country_transactions"] = static_cast<int64_t>(_native_country_transactions);
    out["native_country_commands"] = static_cast<int64_t>(_native_country_commands);
    out["native_country_acks"] = static_cast<int64_t>(_native_country_acks);
    out["native_economy_transactions"] = static_cast<int64_t>(_native_economy_transactions);
    out["native_economy_commands"] = static_cast<int64_t>(_native_economy_commands);
    out["native_economy_acks"] = static_cast<int64_t>(_native_economy_acks);
    out["native_gameplay_transactions"] = static_cast<int64_t>(_native_gameplay_transactions);
    out["native_gameplay_commands"] = static_cast<int64_t>(_native_gameplay_commands);
    out["native_gameplay_acks"] = static_cast<int64_t>(_native_gameplay_acks);
    out["due_queue_count"] = static_cast<int64_t>(_due_heap.size());
    out["dirty_queue_count"] = static_cast<int64_t>(_dirty_queue.size());
    out["candidate_count"] = static_cast<int64_t>(_run_candidates.size());
    out["candidate_cursor"] = _candidate_cursor;
    out["native_modifier_ack_pending"] = static_cast<int64_t>(
        _native_ack_bindings.size());
    out["native_country_ack_pending"] = static_cast<int64_t>(
        _native_country_ack_bindings.size());
    out["native_economy_ack_pending"] = static_cast<int64_t>(
        _native_economy_ack_bindings.size());
    out["native_gameplay_ack_pending"] = static_cast<int64_t>(
        _native_gameplay_ack_bindings.size());
    out["dormant_instances_scanned"] = 0;
    out["metric_slab_bytes"] = static_cast<int64_t>(
        _metric_values.capacity() * sizeof(int64_t) +
        _metric_present.capacity() * sizeof(uint8_t));
    out["instance_storage_bytes"] = static_cast<int64_t>(
        _instances.capacity() * sizeof(Instance));
    out["era_reward_last_plan_ms"] = _last_era_reward_plan_ms;
    out["era_reward_offers_planned"] = static_cast<int64_t>(
        _era_reward_offers_planned);
    out["era_reward_last_expanded_commands"] =
        _last_era_reward_expanded_commands;
    int64_t era_reward_storage_bytes = static_cast<int64_t>(
        _era_reward_pools.capacity() * sizeof(EraRewardPool) +
        _era_reward_options.capacity() * sizeof(EraRewardOption) +
        _era_reward_rules.capacity() * sizeof(EraRewardRule) +
        sizeof(EraRewardOffer));
    for (const EraRewardAlternative &alternative : _era_reward_offer.alternatives) {
        era_reward_storage_bytes += static_cast<int64_t>(
            alternative.target_summary.capacity());
        for (const std::string &reason : alternative.reasons)
            era_reward_storage_bytes += static_cast<int64_t>(reason.capacity());
    }
    out["era_reward_storage_bytes"] = era_reward_storage_bytes;
    out["last_error"] = String(_last_error.c_str());
    out["run_cursor"] = _run_cursor;
    return out;
}

} // namespace pk
