#include "effect_runtime.h"
#include "modifier_api.h"
#include "effect_runtime_internal.h"

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



void EffectRuntime::release_retired_instance_if_terminal(int32_t instance_index) {
    if (instance_index < 0 || instance_index >= static_cast<int32_t>(_instances.size()))
        return;
    Instance &instance = _instances[static_cast<size_t>(instance_index)];
    if (instance.active != 0 || instance.id <= 0) return;
    if (_pending_transactions_by_instance.find(instance.id) !=
        _pending_transactions_by_instance.end()) return;
    if (is_family_effect_instance(instance)) {
        const FamilyEffectGroupKey group = family_effect_group_key(instance);
        const auto found = _family_effect_groups.find(group);
        if (found != _family_effect_groups.end())
            for (const int32_t member : found->second)
                if (member != instance_index) mark_dirty(member);
        remove_family_effect_group_member(instance_index, group);
    }
    // Keep the backing slab allocation stable; it is reused when a later
    // upsert reuses the slot. Removing the ID releases lifecycle and
    // scheduling capacity immediately after the domain safe boundary.
    const uint32_t metric_base = instance.metric_base;
    _instance_ids.erase(instance.id);
    instance = Instance{};
    instance.metric_base = metric_base;
    instance.generation = 0;
    instance.active = 0;
    // A terminal ACK may arrive after planning but before the next save or
    // slice. Remove this slot from queued candidate/dirty work so a reused
    // index cannot inherit an old same-day evaluation and PKEF never records a
    // candidate pointing at a tombstone.
    const int32_t consumed = std::min<int32_t>(
        _candidate_cursor, static_cast<int32_t>(_run_candidates.size()));
    int32_t removed_before_cursor = 0;
    for (int32_t i = 0; i < consumed; ++i)
        if (_run_candidates[static_cast<size_t>(i)] == instance_index)
            ++removed_before_cursor;
    _run_candidates.erase(std::remove(_run_candidates.begin(), _run_candidates.end(),
                                      instance_index), _run_candidates.end());
    _candidate_cursor = std::min<int32_t>(
        std::max(0, _candidate_cursor - removed_before_cursor),
        static_cast<int32_t>(_run_candidates.size()));
    _run_cursor = _candidate_cursor;
    _dirty_queue.erase(std::remove(_dirty_queue.begin(), _dirty_queue.end(),
                                   instance_index), _dirty_queue.end());
    _free_instance_indices.push_back(instance_index);
}

void EffectRuntime::compact_terminal_transactions() {
    if (_transactions.empty()) return;
    std::vector<int32_t> retired_candidates;
    retired_candidates.reserve(_transactions.size());
    std::vector<Transaction> retained;
    retained.reserve(_transactions.size());
    std::vector<Command> compacted_commands;
    compacted_commands.reserve(_command_arena.size());
    for (Transaction &transaction : _transactions) {
        if (transaction.status == ACKED) {
            // Built-in transactions (negative program IDs) are owned by a
            // peer runtime and do not have an Effect instance. Their numeric
            // source IDs may legitimately overlap an unrelated instance ID.
            if (transaction.program_id >= 0) {
                const int32_t instance_index =
                    instance_index_for_id(transaction.source_instance_id);
                if (instance_index >= 0)
                    retired_candidates.push_back(instance_index);
            }
            continue;
        }
        const uint32_t new_begin = static_cast<uint32_t>(compacted_commands.size());
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command != nullptr) compacted_commands.push_back(*command);
        }
        transaction.command_begin = new_begin;
        retained.push_back(std::move(transaction));
    }
    if (retained.size() == _transactions.size()) return;
    _transactions.swap(retained);
    _command_arena.swap(compacted_commands);
    _transaction_ids.clear();
    _transaction_ids.reserve(_transactions.size());
    for (size_t i = 0; i < _transactions.size(); ++i)
        _transaction_ids[_transactions[i].id] = static_cast<int32_t>(i);
    rebuild_command_idempotency_index();
    std::sort(retired_candidates.begin(), retired_candidates.end());
    retired_candidates.erase(std::unique(retired_candidates.begin(),
                                         retired_candidates.end()),
                             retired_candidates.end());
    for (const int32_t index : retired_candidates)
        release_retired_instance_if_terminal(index);
}

bool EffectRuntime::create_retirement_transaction(int32_t instance_index,
                                                  int64_t effective_day,
                                                  std::string &error,
                                                  bool retire_instance) {
    if (instance_index < 0 || instance_index >= static_cast<int32_t>(_instances.size())) {
        error = "effect_instance_unknown";
        return false;
    }
    if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
        compact_terminal_transactions();
        if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
            ++_overflow_count;
            error = "effect_transaction_capacity_exceeded";
            return false;
        }
    }
    Instance &instance = _instances[static_cast<size_t>(instance_index)];
    if (instance.program_id < 0 ||
        instance.program_id >= static_cast<int32_t>(_definitions.size())) {
        error = "effect_instance_program_invalid";
        return false;
    }
    const Definition &definition = _definitions[instance.program_id];
    if (uses_managed_lifecycle(definition) && !instance.effect_applied) {
        if (retire_instance) {
            instance.active = 0;
            instance.schedule_token = 0;
            release_retired_instance_if_terminal(instance_index);
        }
        return true;
    }
    ++instance.fire_sequence;
    Transaction transaction;
    transaction.id = _next_transaction_id++;
    transaction.source_instance_id = instance.id;
    transaction.source_generation = instance.generation;
    transaction.program_id = instance.program_id;
    transaction.effective_day = effective_day;
    transaction.instance_transition = retire_instance
        ? TRANSITION_RETIRE : TRANSITION_DEACTIVATE;
    transaction.transition_input_revision = instance.input_revision;
    transaction.transition_fire_sequence = instance.fire_sequence;
    transaction.transition_stack_count = 0;
    for (int32_t ordinal = 0; ordinal < definition.command_count; ++ordinal) {
        const int32_t command_definition_id = definition.command_begin + ordinal;
        const CommandDefinition &definition_command =
            _command_definitions[static_cast<size_t>(command_definition_id)];
        if (definition_command.action != MODIFIER_COMMAND ||
            definition_command.opcode != ModifierApi::COMMAND_APPLY)
            continue;
        Command command;
        command.action = MODIFIER_COMMAND;
        command.domain = definition_command.domain;
        command.opcode = ModifierApi::COMMAND_REMOVE;
        command.duration_days = -1;
        command.stacks = 1;
        command.command_key_id = command_definition_id;
        command.command_definition_id = command_definition_id;
        command.payload = definition_command.payload;
        if (definition_command.target_resolver == TARGET_STATIC) {
            command.target_handle = definition_command.static_target;
        } else if (definition_command.target_resolver == TARGET_SOURCE) {
            command.target_handle = instance.source_handle;
            command.target_generation = instance.generation;
        } else {
            command.target_handle = instance.target_handle;
            command.target_generation = instance.target_generation;
        }
        command.idempotency_key = command_idempotency_key(instance,
            static_cast<uint32_t>(definition.command_count + ordinal));
        append_command(transaction, command);
    }
    if (transaction.command_count == 0 || transaction.required_ack_mask == 0) {
        error = "effect_retire_reversible_command_missing";
        return false;
    }
    transaction.plan_hash = 1469598103934665603ULL;
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_instance_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_generation);
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.program_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.effective_day);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.instance_transition);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.transition_input_revision);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.transition_fire_sequence);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.transition_stack_count);
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *command = command_at(transaction, ordinal);
        if (command == nullptr) continue;
        transaction.plan_hash = fnv_value(transaction.plan_hash, command->action);
        transaction.plan_hash = fnv_value(transaction.plan_hash, command->domain);
        transaction.plan_hash = fnv_value(transaction.plan_hash, command->opcode);
        transaction.plan_hash = fnv_value(transaction.plan_hash, command->target_handle);
        transaction.plan_hash = fnv_value(transaction.plan_hash, command->target_generation);
        transaction.plan_hash = fnv_value(transaction.plan_hash, command->value_q16);
        transaction.plan_hash = fnv_value(transaction.plan_hash, command->duration_days);
        transaction.plan_hash = fnv_value(transaction.plan_hash, command->stacks);
        transaction.plan_hash = fnv_value(transaction.plan_hash, command->command_key_id);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            command->command_definition_id);
        for (const int64_t payload_value : command->payload)
            transaction.plan_hash = fnv_value(transaction.plan_hash, payload_value);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            command->idempotency_key);
    }
    _transactions.push_back(std::move(transaction));
    _transaction_ids[_transactions.back().id] =
        static_cast<int32_t>(_transactions.size() - 1);
    track_pending_transaction(_transactions.back());
    index_transaction_commands(_transactions.back());
    if (retire_instance) {
        instance.retire_requested = 1;
        mark_family_effect_group_dirty(instance_index);
    }
    instance.next_due_day = effective_day + 1;
    schedule_instance(instance_index, instance.next_due_day);
    return true;
}

} // namespace pk
