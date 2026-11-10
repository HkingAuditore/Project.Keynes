#include "effect_runtime.h"

namespace pk {

void EffectRuntime::advance_committed_generation() {
    if (++_committed_generation == 0) _committed_generation = 1;
}

void EffectRuntime::reset_runtime_state() {
    _pod_snapshot_generation = 0;
    advance_committed_generation();
    _current_day = -1;
    _last_completed_day = -1;
    _run_day = -1;
    _run_cursor = 0;
    _next_transaction_id = 1;
    _acked_transaction_id = 0;
    _next_activation_sequence = 1;
    _instances.clear();
    _free_instance_indices.clear();
    _instance_ids.clear();
    _metric_values.clear();
    _metric_present.clear();
    _dirty_queue.clear();
    _dirty_epoch_counter = 1;
    _stack_decision_epoch = 1;
    _family_effect_groups.clear();
    _family_effect_candidate_scratch.clear();
    while (!_due_heap.empty()) _due_heap.pop();
    _run_candidates.clear();
    _candidate_cursor = 0;
    _schedule_token = 1;
    _command_arena.clear();
    _transactions.clear();
    _transaction_ids.clear();
    _pending_transactions_by_instance.clear();
    _pending_command_idempotency.clear();
    _native_request_ids.clear();
    _native_ack_bindings.clear();
    _native_bound_transaction_ids.clear();
    _native_country_request_ids.clear();
    _native_country_ack_bindings.clear();
    _native_country_bound_transaction_ids.clear();
    _native_economy_request_ids.clear();
    _native_economy_ack_bindings.clear();
    _native_economy_bound_transaction_ids.clear();
    _native_gameplay_request_ids.clear();
    _native_gameplay_ack_bindings.clear();
    _native_gameplay_bound_transaction_ids.clear();
    _external_bindings.clear();
    _external_binding_ids.clear();
    _era_reward_player_country = 0;
    _era_reward_next_plan_id = 1;
    _era_reward_next_generation = 1;
    _era_reward_offer = EraRewardOffer{};
    _last_era_reward_plan_ms = 0.0;
    _era_reward_offers_planned = 0;
    _last_era_reward_expanded_commands = 0;
    _instances_submitted = 0;
    _programs_evaluated = 0;
    _commands_emitted = 0;
    _transactions_acked = 0;
    _preflight_rejects = 0;
    _behavior_failures = 0;
    _overflow_count = 0;
    _native_modifier_transactions = 0;
    _native_modifier_commands = 0;
    _native_modifier_acks = 0;
    _native_country_transactions = 0;
    _native_country_commands = 0;
    _native_country_acks = 0;
    _native_economy_transactions = 0;
    _native_economy_commands = 0;
    _native_economy_acks = 0;
    _native_gameplay_transactions = 0;
    _native_gameplay_commands = 0;
    _native_gameplay_acks = 0;
    _last_native_dispatch_ms = 0.0;
    _last_native_ack_ms = 0.0;
    _last_parallel_planning_ms = 0.0;
    _last_parallel_merge_ms = 0.0;
    _last_parallel_worker_count = 1;
    _parallel_dispatches = 0;
    _serial_fallback_dispatches = 0;
    _last_parallel_path = "serial";
    _last_parallel_fallback_reason.clear();
    _last_error.clear();
}

} // namespace pk
