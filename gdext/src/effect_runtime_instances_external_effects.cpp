#include "effect_runtime_instances_includes.inc"

namespace pk {
using namespace godot;

bool EffectRuntime::enqueue_external_effect_pod(
        int64_t effect_id, int64_t effective_day, int32_t source_type,
        int64_t source_id, const std::string &program_key, uint64_t source_handle,
        uint64_t target_handle, uint32_t target_generation, uint64_t fire_sequence,
        int32_t action, int32_t domain, int32_t opcode, int64_t resolved_value,
        int32_t duration_days, int32_t stacks, const std::string &command_key,
        const std::string &definition_key, const std::array<int64_t, 4> &payload,
        std::string &error, int64_t *out_transaction_id) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    if (effect_id <= 0 || target_generation == 0 || target_handle == 0 ||
        domain < 0 || domain >= 32 || stacks <= 0 || command_key.empty() ||
        (definition_key.empty() && action != ECONOMY_COMMAND)) {
        error = "trigger_effect_shape_invalid";
        return false;
    }
    const uint64_t idempotency = make_hash(static_cast<uint64_t>(effect_id),
        target_generation, fire_sequence, 0);
    if (_pending_command_idempotency.find(idempotency) !=
        _pending_command_idempotency.end()) {
        if (out_transaction_id != nullptr) {
            for (const Transaction &transaction : _transactions) {
                for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
                    const Command *existing = command_at(transaction, ordinal);
                    if (existing != nullptr && existing->idempotency_key == idempotency) {
                        *out_transaction_id = transaction.id;
                        return true;
                    }
                }
            }
        }
        return true;
    }
    const bool modifier_remove = action == MODIFIER_COMMAND &&
        opcode == ModifierApi::COMMAND_REMOVE;
    int32_t command_definition_id = -1;
    for (int32_t i = 0; i < static_cast<int32_t>(_command_definitions.size()); ++i) {
        const CommandDefinition &candidate = _command_definitions[i];
        const bool dynamic_country_signal_payload =
            action == COUNTRY_COMMAND &&
            opcode == CountryApi::COMMAND_DISCOVER_COUNTRY_SIGNAL &&
            candidate.action == action && candidate.opcode == opcode &&
            (static_cast<uint64_t>(candidate.payload[0]) >> 32U) ==
                (static_cast<uint64_t>(payload[0]) >> 32U) &&
            candidate.payload[1] == payload[1] &&
            candidate.payload[2] == payload[2] &&
            candidate.payload[3] == payload[3];
        const bool dynamic_family_economy =
            action == ECONOMY_COMMAND &&
            candidate.action == action &&
            candidate.command_key == command_key &&
            candidate.opcode == opcode;
        if ((candidate.command_key == command_key &&
            candidate.definition_key == definition_key &&
            candidate.action == action && candidate.domain == domain &&
            (candidate.opcode == opcode || (modifier_remove &&
                candidate.opcode == ModifierApi::COMMAND_APPLY)) &&
            candidate.target_resolver == TARGET_INSTANCE &&
            (candidate.duration_days == duration_days ||
             action == MODIFIER_COMMAND) &&
            candidate.stacks == stacks &&
            (candidate.payload == payload || dynamic_country_signal_payload)) ||
            dynamic_family_economy) {
            command_definition_id = i;
            break;
        }
    }
    if (command_definition_id < 0) {
        error = "trigger_effect_definition_not_compiled";
        return false;
    }
    const int64_t instance_id = static_cast<int64_t>(make_hash(
        static_cast<uint64_t>(source_type), static_cast<uint32_t>(source_id),
        static_cast<uint64_t>(effect_id), static_cast<uint32_t>(target_generation)) &
        0x7fffffffffffffffULL);
    const uint32_t generation = std::max<uint32_t>(1, target_generation);
    if (instance_index_for_id(instance_id) < 0) {
        if (!upsert_instance_pod(instance_id, program_key, generation,
                source_type, source_id, source_handle, target_handle,
                target_generation, 0, effective_day, false, error)) return false;
    }
    if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
        compact_terminal_transactions();
        if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
            ++_overflow_count;
            error = "effect_transaction_capacity_exceeded";
            return false;
        }
    }
    const Instance &source = _instances[static_cast<size_t>(instance_index_for_id(instance_id))];
    Command command;
    command.action = action;
    command.domain = domain;
    command.opcode = opcode;
    command.target_handle = target_handle;
    command.target_generation = target_generation;
    command.value_q16 = resolved_value;
    command.duration_days = duration_days;
    command.stacks = stacks;
    command.command_key_id = command_definition_id;
    command.command_definition_id = command_definition_id;
    command.payload = payload;
    command.idempotency_key = idempotency;
    command.external_effect_id = effect_id;
    command.external_source_id = source_id;
    Transaction transaction;
    transaction.id = _next_transaction_id++;
    transaction.source_instance_id = source.id;
    transaction.source_generation = source.generation;
    transaction.program_id = source.program_id;
    transaction.effective_day = effective_day;
    append_command(transaction, command);
    if (transaction.command_count == 0) {
        error = "trigger_effect_transaction_empty";
        return false;
    }
    transaction.plan_hash = 1469598103934665603ULL;
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_instance_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_generation);
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.program_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.effective_day);
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *stored = command_at(transaction, ordinal);
        if (stored == nullptr) continue;
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->action);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->domain);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->opcode);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->target_handle);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->target_generation);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->value_q16);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->duration_days);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->stacks);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->command_key_id);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->command_definition_id);
        for (const int64_t value : stored->payload)
            transaction.plan_hash = fnv_value(transaction.plan_hash, value);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->idempotency_key);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->external_effect_id);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->external_source_id);
    }
    _transactions.push_back(std::move(transaction));
    _transaction_ids[_transactions.back().id] =
        static_cast<int32_t>(_transactions.size() - 1);
    track_pending_transaction(_transactions.back());
    index_transaction_commands(_transactions.back());
    if (out_transaction_id != nullptr) *out_transaction_id = _transactions.back().id;
    return true;
}

bool EffectRuntime::enqueue_external_effect_batch_pod(
        int64_t effective_day, int32_t source_type,
        int64_t transition_source_id, uint64_t source_handle,
        uint64_t target_handle, uint32_t target_generation,
        const ExternalEffectCommandPod *commands, size_t command_count,
        std::string &error, int64_t *out_transaction_id) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    if (effective_day < 0 || transition_source_id == 0 || source_handle == 0 ||
            target_handle == 0 || target_generation == 0 || commands == nullptr ||
            command_count == 0 || command_count > 4096) {
        error = "effect_external_batch_shape_invalid";
        return false;
    }
    std::vector<Command> staged;
    staged.reserve(command_count);
    int64_t replay_transaction_id = 0;
    size_t replayed = 0;
    for (size_t row = 0; row < command_count; ++row) {
        const ExternalEffectCommandPod &source = commands[row];
        if (source.effect_id <= 0 || source.source_id == 0 ||
                source.program_key.empty() || source.domain < 0 ||
                source.domain >= 32 || source.stacks <= 0 ||
                source.command_key.empty() || source.definition_key.empty()) {
            error = "effect_external_batch_command_invalid";
            return false;
        }
        const uint64_t idempotency = make_hash(
            static_cast<uint64_t>(source.effect_id), target_generation,
            source.fire_sequence, 0);
        if (_pending_command_idempotency.find(idempotency) !=
                _pending_command_idempotency.end()) {
            int64_t matched_transaction_id = 0;
            for (const Transaction &transaction : _transactions) {
                for (uint32_t ordinal = 0;
                        ordinal < transaction.command_count; ++ordinal) {
                    const Command *existing = command_at(transaction, ordinal);
                    if (existing != nullptr &&
                            existing->idempotency_key == idempotency) {
                        matched_transaction_id = transaction.id;
                        break;
                    }
                }
                if (matched_transaction_id != 0) break;
            }
            if (matched_transaction_id == 0 ||
                    (replay_transaction_id != 0 &&
                     replay_transaction_id != matched_transaction_id)) {
                error = "effect_external_batch_partial_replay";
                return false;
            }
            replay_transaction_id = matched_transaction_id;
            ++replayed;
            continue;
        }
        const bool modifier_remove =
            source.action == MODIFIER_COMMAND &&
            source.opcode == ModifierApi::COMMAND_REMOVE;
        int32_t command_definition_id = -1;
        for (int32_t definition_index = 0;
                definition_index <
                    static_cast<int32_t>(_command_definitions.size());
                ++definition_index) {
            const CommandDefinition &candidate =
                _command_definitions[static_cast<size_t>(definition_index)];
            const bool dynamic_country_signal_payload =
                source.action == COUNTRY_COMMAND &&
                source.opcode ==
                    CountryApi::COMMAND_DISCOVER_COUNTRY_SIGNAL &&
                candidate.action == source.action &&
                candidate.opcode == source.opcode &&
                (static_cast<uint64_t>(candidate.payload[0]) >> 32U) ==
                    (static_cast<uint64_t>(source.payload[0]) >> 32U) &&
                candidate.payload[1] == source.payload[1] &&
                candidate.payload[2] == source.payload[2] &&
                candidate.payload[3] == source.payload[3];
            if (candidate.command_key == source.command_key &&
                    candidate.definition_key == source.definition_key &&
                    candidate.action == source.action &&
                    candidate.domain == source.domain &&
                    (candidate.opcode == source.opcode ||
                     (modifier_remove &&
                      candidate.opcode == ModifierApi::COMMAND_APPLY)) &&
                    candidate.target_resolver == TARGET_INSTANCE &&
                    (candidate.duration_days == source.duration_days ||
                     source.action == MODIFIER_COMMAND) &&
                    candidate.stacks == source.stacks &&
                    (candidate.payload == source.payload ||
                     dynamic_country_signal_payload)) {
                command_definition_id = definition_index;
                break;
            }
        }
        if (command_definition_id < 0) {
            error = "effect_external_batch_definition_not_compiled";
            return false;
        }
        if (definition_id_for_key(source.program_key) < 0) {
            error = "effect_external_batch_program_unknown";
            return false;
        }
        Command command;
        command.action = source.action;
        command.domain = source.domain;
        command.opcode = source.opcode;
        command.target_handle = target_handle;
        command.target_generation = target_generation;
        command.value_q16 = source.resolved_value;
        command.duration_days = source.duration_days;
        command.stacks = source.stacks;
        command.command_key_id = command_definition_id;
        command.command_definition_id = command_definition_id;
        command.payload = source.payload;
        command.idempotency_key = idempotency;
        command.external_effect_id = source.effect_id;
        command.external_source_id = source.source_id;
        command.external_source_is_stable = source.stable_source_identity;
        staged.push_back(command);
    }
    if (replayed != 0) {
        if (replayed != command_count || !staged.empty()) {
            error = "effect_external_batch_partial_replay";
            return false;
        }
        if (out_transaction_id != nullptr)
            *out_transaction_id = replay_transaction_id;
        return true;
    }
    if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
        compact_terminal_transactions();
        if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
            ++_overflow_count;
            error = "effect_transaction_capacity_exceeded";
            return false;
        }
    }
    const ExternalEffectCommandPod &first = commands[0];
    const int64_t instance_id = static_cast<int64_t>(make_hash(
        static_cast<uint64_t>(source_type),
        static_cast<uint32_t>(transition_source_id),
        static_cast<uint64_t>(first.effect_id),
        static_cast<uint32_t>(first.fire_sequence)) &
        0x7fffffffffffffffULL);
    const uint32_t generation = std::max<uint32_t>(1, target_generation);
    if (!upsert_instance_pod(instance_id, first.program_key, generation,
            source_type, transition_source_id, source_handle, target_handle,
            target_generation, 0, effective_day, false, error))
        return false;
    const int32_t source_index = instance_index_for_id(instance_id);
    if (source_index < 0) {
        error = "effect_external_batch_source_missing";
        return false;
    }
    const Instance &source =
        _instances[static_cast<size_t>(source_index)];
    Transaction transaction;
    transaction.id = _next_transaction_id++;
    transaction.source_instance_id = source.id;
    transaction.source_generation = source.generation;
    transaction.program_id = source.program_id;
    transaction.effective_day = effective_day;
    _command_arena.reserve(_command_arena.size() + staged.size());
    for (const Command &command : staged) append_command(transaction, command);
    if (transaction.command_count != staged.size()) {
        error = "effect_external_batch_command_collision";
        return false;
    }
    transaction.plan_hash = 1469598103934665603ULL;
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_instance_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.source_generation);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.program_id);
    transaction.plan_hash = fnv_value(transaction.plan_hash,
        transaction.effective_day);
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *stored = command_at(transaction, ordinal);
        if (stored == nullptr) continue;
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->action);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->domain);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->opcode);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->target_handle);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->target_generation);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->value_q16);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->duration_days);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->stacks);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->command_key_id);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->command_definition_id);
        for (const int64_t value : stored->payload)
            transaction.plan_hash = fnv_value(transaction.plan_hash, value);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->idempotency_key);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->external_effect_id);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->external_source_id);
    }
    _transactions.push_back(std::move(transaction));
    _transaction_ids[_transactions.back().id] =
        static_cast<int32_t>(_transactions.size() - 1);
    track_pending_transaction(_transactions.back());
    index_transaction_commands(_transactions.back());
    if (out_transaction_id != nullptr)
        *out_transaction_id = _transactions.back().id;
    return true;
}

} // namespace pk
