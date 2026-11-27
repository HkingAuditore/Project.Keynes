#include "effect_runtime_instances_includes.inc"

namespace pk {
using namespace godot;

int64_t EffectRuntime::metric_value(const Instance &instance, int32_t metric_id) const {
    const int64_t *metric = metric_ptr(instance, metric_id);
    return metric != nullptr ? *metric : 0;
}

uint64_t EffectRuntime::command_idempotency_key(const Instance &instance,
                                                 uint32_t command_index) const {
    return make_hash(static_cast<uint64_t>(instance.id), instance.generation,
                     instance.fire_sequence, command_index);
}

const EffectRuntime::Command *EffectRuntime::command_at(
        const Transaction &transaction, uint32_t ordinal) const {
    if (ordinal >= transaction.command_count) return nullptr;
    const size_t index = static_cast<size_t>(transaction.command_begin) + ordinal;
    return index < _command_arena.size() ? &_command_arena[index] : nullptr;
}

int32_t EffectRuntime::transaction_index_for_id(int64_t transaction_id) const {
    const auto found = _transaction_ids.find(transaction_id);
    return found == _transaction_ids.end() ? -1 : found->second;
}

void EffectRuntime::append_command(Transaction &transaction, const Command &command) {
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *existing = command_at(transaction, ordinal);
        if (existing != nullptr && existing->idempotency_key == command.idempotency_key)
            return;
    }
    if (_pending_command_idempotency.find(command.idempotency_key) !=
        _pending_command_idempotency.end()) return;
    if (transaction.command_count == 0)
        transaction.command_begin = static_cast<uint32_t>(_command_arena.size());
    _command_arena.push_back(command);
    ++transaction.command_count;
    ++_commands_emitted;
    transaction.required_ack_mask |= adapter_ack_bit_for(command);
}

void EffectRuntime::index_transaction_commands(const Transaction &transaction) {
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *command = command_at(transaction, ordinal);
        if (command != nullptr) ++_pending_command_idempotency[command->idempotency_key];
    }
}

void EffectRuntime::unindex_transaction_commands(const Transaction &transaction) {
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *command = command_at(transaction, ordinal);
        if (command == nullptr) continue;
        auto found = _pending_command_idempotency.find(command->idempotency_key);
        if (found == _pending_command_idempotency.end()) continue;
        if (found->second <= 1) _pending_command_idempotency.erase(found);
        else --found->second;
    }
}

void EffectRuntime::track_pending_transaction(const Transaction &transaction) {
    if (transaction.status == ACKED || transaction.status == REJECTED) return;
    ++_pending_transactions_by_instance[transaction.source_instance_id];
}

void EffectRuntime::untrack_pending_transaction(const Transaction &transaction) {
    if (transaction.status == ACKED || transaction.status == REJECTED) return;
    const auto found = _pending_transactions_by_instance.find(
        transaction.source_instance_id);
    if (found == _pending_transactions_by_instance.end()) return;
    if (found->second <= 1) _pending_transactions_by_instance.erase(found);
    else --found->second;
}

void EffectRuntime::apply_acked_instance_transition(
        const Transaction &transaction) {
    if (transaction.instance_transition == TRANSITION_NONE ||
        transaction.program_id < 0)
        return;
    const int32_t index = instance_index_for_id(transaction.source_instance_id);
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return;
    Instance &instance = _instances[static_cast<size_t>(index)];
    if (instance.generation != transaction.source_generation) return;
    instance.last_acked_fire_sequence = std::max(
        instance.last_acked_fire_sequence,
        transaction.transition_fire_sequence);
    switch (transaction.instance_transition) {
        case TRANSITION_APPLY:
        case TRANSITION_UPDATE:
            instance.effect_applied = 1;
            instance.retire_requested = 0;
            instance.applied_stack_count = std::max(
                1, transaction.transition_stack_count);
            instance.applied_input_revision = std::max(
                instance.applied_input_revision,
                transaction.transition_input_revision);
            break;
        case TRANSITION_DEACTIVATE:
            instance.effect_applied = 0;
            instance.applied_stack_count = 0;
            instance.applied_input_revision = std::max(
                instance.applied_input_revision,
                transaction.transition_input_revision);
            break;
        case TRANSITION_RETIRE:
            instance.effect_applied = 0;
            instance.retire_requested = 0;
            instance.applied_stack_count = 0;
            instance.applied_input_revision = std::max(
                instance.applied_input_revision,
                transaction.transition_input_revision);
            instance.active = 0;
            instance.schedule_token = 0;
            break;
        default:
            break;
    }
}

void EffectRuntime::apply_rejected_instance_transition(
        const Transaction &transaction) {
    if (transaction.instance_transition == TRANSITION_NONE ||
        transaction.program_id < 0) return;
    const int32_t index = instance_index_for_id(transaction.source_instance_id);
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return;
    Instance &instance = _instances[static_cast<size_t>(index)];
    if (instance.generation != transaction.source_generation ||
        instance.active == 0) return;
    // Domain rejection is not a lifecycle decision. Preserve the last ACKed
    // state and make the transition retryable with a new fire sequence.
    // Explicit retirement sets retire_requested when its REMOVE transaction is
    // created. EVENT_ONCE also uses TRANSITION_RETIRE, but must remain a normal
    // retry when its first domain commit is rejected.
    instance.next_due_day = std::max<int64_t>(
        _current_day >= 0 ? _current_day + 1 : 0,
        transaction.effective_day + 1);
    mark_family_effect_group_dirty(index);
    schedule_instance(index, instance.next_due_day);
}

bool EffectRuntime::acknowledge_native_domain(Transaction &transaction,
                                              uint32_t domain_bit) {
    if (domain_bit == 0 || (domain_bit & transaction.required_ack_mask) == 0) {
        transaction.status = RESYNC_REQUIRED;
        _last_error = "effect_native_ack_domain_mask_invalid";
        return false;
    }
    const uint32_t previous_ack_mask = transaction.received_ack_mask;
    transaction.received_ack_mask |= domain_bit;
    if (transaction.received_ack_mask != previous_ack_mask)
        advance_committed_generation();
    if ((transaction.received_ack_mask & transaction.required_ack_mask) !=
            transaction.required_ack_mask) {
        transaction.status = COMMITTED;
        return false;
    }
    untrack_pending_transaction(transaction);
    transaction.status = ACKED;
    unindex_transaction_commands(transaction);
    apply_acked_instance_transition(transaction);
    _acked_transaction_id = std::max(_acked_transaction_id, transaction.id);
    ++_transactions_acked;
    if (_era_reward_offer.transaction_id == transaction.id)
        refresh_era_reward_offer_status();
    return true;
}

void EffectRuntime::rebuild_command_idempotency_index() {
    _pending_command_idempotency.clear();
    _pending_transactions_by_instance.clear();
    for (const Transaction &transaction : _transactions) {
        // ACKED commands have reached their durable destination and do not
        // block the next fire sequence. REJECTED rows retain their key until
        // terminal compaction, matching the previous vector scan behavior.
        if (transaction.status == ACKED || transaction.status == REJECTED) continue;
        index_transaction_commands(transaction);
        track_pending_transaction(transaction);
    }
}

Dictionary EffectRuntime::poll_transactions(int64_t after_transaction_id,
                                            int32_t limit) const {
    Dictionary out;
    out["ok"] = true;
    PackedInt64Array ids;
    PackedInt64Array source_instances;
    PackedInt32Array source_generations;
    PackedInt32Array program_ids;
    PackedInt64Array effective_days;
    PackedInt64Array plan_hashes;
    PackedInt32Array required_masks;
    PackedInt32Array received_masks;
    PackedInt32Array statuses;
    PackedInt32Array instance_transitions;
    PackedInt64Array transition_input_revisions;
    PackedInt64Array transition_fire_sequences;
    PackedInt32Array command_offsets;
    PackedInt32Array command_actions;
    PackedInt32Array command_domains;
    PackedInt32Array command_opcodes;
    PackedInt64Array command_targets;
    PackedInt32Array command_target_generations;
    PackedInt64Array command_values;
    PackedInt32Array command_durations;
    PackedInt32Array command_stacks;
    PackedInt64Array command_idempotency_keys;
    PackedStringArray command_keys;
    PackedStringArray command_definition_keys;
    PackedInt64Array payload_i0;
    PackedInt64Array payload_i1;
    PackedInt64Array payload_i2;
    PackedInt64Array payload_i3;
    command_offsets.append(0);
    int32_t emitted = 0;
    int32_t native_claimed = 0;
    limit = std::max(1, std::min(limit, 1024));
    for (const Transaction &transaction : _transactions) {
        if (transaction.id <= after_transaction_id || transaction.status == ACKED ||
            transaction.status == REJECTED || transaction.status == RESYNC_REQUIRED)
            continue;
        // Native-owned transactions must never be handed back to the legacy
        // GDScript transport.  This matters for ideology: a transaction is
        // already PREFLIGHTED by a POD adapter while the domain waits for its
        // own safe boundary, and a second transport must not try to resolve
        // its command keys or create a duplicate request.
        const bool native_owned_pending =
            _native_bound_transaction_ids.find(transaction.id) !=
                _native_bound_transaction_ids.end() ||
            _native_country_bound_transaction_ids.find(transaction.id) !=
                _native_country_bound_transaction_ids.end() ||
            _native_economy_bound_transaction_ids.find(transaction.id) !=
                _native_economy_bound_transaction_ids.end() ||
            _native_gameplay_bound_transaction_ids.find(transaction.id) !=
                _native_gameplay_bound_transaction_ids.end();
        if (native_owned_pending) {
            ++native_claimed;
            continue;
        }
        if (emitted >= limit) break;
        ids.append(transaction.id);
        source_instances.append(transaction.source_instance_id);
        source_generations.append(static_cast<int32_t>(transaction.source_generation));
        program_ids.append(transaction.program_id);
        effective_days.append(transaction.effective_day);
        plan_hashes.append(static_cast<int64_t>(transaction.plan_hash));
        required_masks.append(static_cast<int32_t>(transaction.required_ack_mask));
        received_masks.append(static_cast<int32_t>(transaction.received_ack_mask));
        statuses.append(transaction.status);
        instance_transitions.append(transaction.instance_transition);
        transition_input_revisions.append(transaction.transition_input_revision);
        transition_fire_sequences.append(static_cast<int64_t>(
            transaction.transition_fire_sequence));
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) continue;
            command_actions.append(command->action);
            command_domains.append(command->domain);
            command_opcodes.append(command->opcode);
            command_targets.append(static_cast<int64_t>(command->target_handle));
            command_target_generations.append(static_cast<int32_t>(command->target_generation));
            command_values.append(command->value_q16);
            command_durations.append(command->duration_days);
            command_stacks.append(command->stacks);
            command_idempotency_keys.append(static_cast<int64_t>(command->idempotency_key));
            const std::string command_key = command_key_for(*command);
            const std::string definition_key = command_definition_key_for(transaction, *command);
            command_keys.append(String(command_key.c_str()));
            command_definition_keys.append(String(definition_key.c_str()));
            payload_i0.append(command->payload[0]); payload_i1.append(command->payload[1]);
            payload_i2.append(command->payload[2]); payload_i3.append(command->payload[3]);
        }
        command_offsets.append(command_actions.size());
        ++emitted;
    }
    out["transaction_ids"] = ids;
    out["source_instance_ids"] = source_instances;
    out["source_generations"] = source_generations;
    out["program_ids"] = program_ids;
    out["effective_days"] = effective_days;
    out["plan_hashes"] = plan_hashes;
    out["required_ack_masks"] = required_masks;
    out["received_ack_masks"] = received_masks;
    out["statuses"] = statuses;
    out["instance_transitions"] = instance_transitions;
    out["transition_input_revisions"] = transition_input_revisions;
    out["transition_fire_sequences"] = transition_fire_sequences;
    out["command_offsets"] = command_offsets;
    out["command_actions"] = command_actions;
    out["command_domains"] = command_domains;
    out["command_opcodes"] = command_opcodes;
    out["command_targets"] = command_targets;
    out["command_target_generations"] = command_target_generations;
    out["command_values_q16"] = command_values;
    out["command_duration_days"] = command_durations;
    out["command_stacks"] = command_stacks;
    out["command_idempotency_keys"] = command_idempotency_keys;
    out["command_keys"] = command_keys;
    out["command_definition_keys"] = command_definition_keys;
    out["command_payload_i0"] = payload_i0;
    out["command_payload_i1"] = payload_i1;
    out["command_payload_i2"] = payload_i2;
    out["command_payload_i3"] = payload_i3;
    out["count"] = emitted;
    out["native_claimed_transactions"] = native_claimed;
    return out;
}

Dictionary EffectRuntime::preflight_transactions(const Dictionary &batch) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    const PackedInt64Array ids = get_i64(batch, "transaction_ids");
    const PackedInt32Array masks = get_i32(batch, "ack_masks");
    if (ids.is_empty() || masks.size() != ids.size())
        return failure("effect_preflight_columns_invalid");
    std::vector<int32_t> indices;
    indices.reserve(ids.size());
    std::unordered_set<int64_t> seen;
    for (int32_t i = 0; i < ids.size(); ++i) {
        if (!seen.emplace(ids[i]).second) return failure("effect_preflight_duplicate_transaction");
        const int32_t index = transaction_index_for_id(ids[i]);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size()))
            return failure("effect_preflight_unknown_transaction");
        const Transaction &transaction = _transactions[static_cast<size_t>(index)];
        const uint32_t mask = static_cast<uint32_t>(masks[i]);
        if (mask != transaction.required_ack_mask ||
            transaction.status == REJECTED || transaction.status == RESYNC_REQUIRED)
            return failure("effect_preflight_mask_or_status_invalid");
        indices.push_back(index);
    }
    int32_t preflighted = 0;
    for (int32_t index : indices) {
        Transaction &transaction = _transactions[index];
        if (transaction.status == PLANNED) {
            transaction.status = PREFLIGHTED;
            ++preflighted;
        }
    }
    Dictionary out;
    out["ok"] = true;
    out["preflighted"] = preflighted;
    return out;
}

Dictionary EffectRuntime::commit_transactions(const Dictionary &batch) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    const PackedInt64Array ids = get_i64(batch, "transaction_ids");
    const PackedInt32Array masks = get_i32(batch, "ack_masks");
    if (ids.is_empty() || masks.size() != ids.size())
        return failure("effect_commit_columns_invalid");
    std::vector<int32_t> indices;
    indices.reserve(ids.size());
    std::unordered_set<int64_t> seen;
    for (int32_t i = 0; i < ids.size(); ++i) {
        if (!seen.emplace(ids[i]).second) return failure("effect_commit_duplicate_transaction");
        const int32_t index = transaction_index_for_id(ids[i]);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size()))
            return failure("effect_commit_unknown_transaction");
        const Transaction &transaction = _transactions[static_cast<size_t>(index)];
        const uint32_t mask = static_cast<uint32_t>(masks[i]);
        if (mask != transaction.required_ack_mask ||
            (transaction.status != PREFLIGHTED && transaction.status != COMMITTED &&
             transaction.status != ACKED))
            return failure("effect_commit_mask_or_status_invalid");
        indices.push_back(index);
    }
    int32_t committed = 0;
    for (int32_t index : indices) {
        Transaction &transaction = _transactions[index];
        if (transaction.status == PREFLIGHTED) {
            transaction.status = COMMITTED;
            ++committed;
        }
    }
    Dictionary out;
    out["ok"] = true;
    out["committed"] = committed;
    return out;
}

Dictionary EffectRuntime::ack_transactions(const Dictionary &batch) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    const PackedInt64Array ids = get_i64(batch, "transaction_ids");
    const PackedInt32Array masks = get_i32(batch, "ack_masks");
    if (ids.is_empty() || masks.size() != ids.size())
        return failure("effect_ack_columns_invalid");
    int32_t acknowledged = 0;
    int32_t rejected = 0;
    for (int32_t i = 0; i < ids.size(); ++i) {
        const int32_t index = transaction_index_for_id(ids[i]);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size())) {
            if (ids[i] <= _acked_transaction_id) continue;
            ++rejected;
            continue;
        }
        Transaction &transaction = _transactions[static_cast<size_t>(index)];
        const uint32_t mask = static_cast<uint32_t>(masks[i]);
        if ((mask & ~transaction.required_ack_mask) != 0 ||
            (transaction.status != COMMITTED && transaction.status != ACKED)) {
            ++rejected;
            continue;
        }
        if (transaction.status == ACKED) continue;
        transaction.received_ack_mask |= mask;
        const bool fully_acknowledged =
            (transaction.received_ack_mask & transaction.required_ack_mask) ==
            transaction.required_ack_mask;
        if (fully_acknowledged) {
            untrack_pending_transaction(transaction);
            transaction.status = ACKED;
            unindex_transaction_commands(transaction);
            apply_acked_instance_transition(transaction);
            _acked_transaction_id = std::max(_acked_transaction_id, transaction.id);
            ++_transactions_acked;
            ++acknowledged;
        } else {
            transaction.status = COMMITTED;
        }
    }
    if (acknowledged != 0) {
        refresh_era_reward_offer_status();
        compact_terminal_transactions();
    }
    Dictionary out;
    out["ok"] = rejected == 0;
    out["acknowledged"] = acknowledged;
    out["rejected"] = rejected;
    out["acked_transaction_id"] = _acked_transaction_id;
    if (rejected != 0) out["reason"] = "effect_ack_unknown_transaction";
    return out;
}

} // namespace pk
