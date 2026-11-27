#include "effect_runtime_instances_includes.inc"

namespace pk {
using namespace godot;

bool EffectRuntime::enqueue_family_colonization_pod(
        int64_t effect_id, int64_t effective_day, int64_t source_id,
        uint64_t country_handle, uint32_t country_generation,
        uint64_t expedition_handle, uint32_t expedition_generation,
        int32_t target_cell, uint64_t fire_sequence, std::string &error,
        int64_t *out_transaction_id, bool claim_unowned,
        int32_t population_reward) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    if (effect_id <= 0 || effective_day < 0 || country_handle == 0 ||
        country_generation == 0 || expedition_handle == 0 ||
        expedition_generation == 0 || target_cell < 0) {
        error = "family_colonization_effect_shape_invalid";
        return false;
    }
    const uint64_t base_key = make_hash(static_cast<uint64_t>(effect_id),
        expedition_generation, fire_sequence, 0x434f4c4fU);
    const uint64_t settle_key = make_hash(static_cast<uint64_t>(effect_id),
        expedition_generation, fire_sequence, 1);
    for (const Transaction &existing : _transactions) {
        if (existing.program_id != -1 ||
            existing.source_generation != expedition_generation) continue;
        for (uint32_t ordinal = 0; ordinal < existing.command_count; ++ordinal) {
            const Command *command = command_at(existing, ordinal);
            if (command == nullptr) continue;
            if (command->idempotency_key == base_key ||
                command->idempotency_key == settle_key) {
                if (out_transaction_id != nullptr)
                    *out_transaction_id = existing.id;
                return true;
            }
        }
    }
    if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
        compact_terminal_transactions();
        if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
            error = "effect_transaction_capacity_exceeded";
            return false;
        }
    }
    Transaction transaction;
    transaction.id = allocate_builtin_transaction_id();
    transaction.source_instance_id = source_id;
    transaction.source_generation = expedition_generation;
    transaction.program_id = -1;
    transaction.effective_day = effective_day;

    if (claim_unowned) {
        Command claim;
        claim.action = COUNTRY_COMMAND;
        claim.domain = 7;
        claim.opcode = CountryApi::COMMAND_CLAIM_UNOWNED_TERRITORY;
        claim.target_handle = country_handle;
        claim.target_generation = country_generation;
        claim.command_key_id = -1;
        claim.command_definition_id = -1;
        claim.payload[0] = static_cast<int64_t>(static_cast<uint32_t>(target_cell));
        claim.idempotency_key = base_key;
        append_command(transaction, claim);
    }

    Command settle;
    settle.action = ECONOMY_COMMAND;
    settle.domain = 8;
    settle.opcode = EconomyApi::COMMAND_SETTLE_FAMILY_EXPEDITION;
    settle.target_handle = expedition_handle;
    settle.target_generation = expedition_generation;
    settle.command_key_id = -1;
    settle.command_definition_id = -1;
    settle.payload[0] = static_cast<int64_t>(static_cast<uint32_t>(target_cell));
    settle.payload[1] = static_cast<int64_t>(country_handle);
    settle.payload[2] = claim_unowned ? 1 : 0;
    // payload[3] is SETTLE.i32_1: optional conserved population_reward. Keep
    // it off payload[0] so CLAIM/SETTLE PKEF equality on the cell word holds.
    settle.payload[3] = std::max<int64_t>(0, population_reward);
    settle.idempotency_key = settle_key;
    append_command(transaction, settle);
    const uint32_t expected_commands = claim_unowned ? 2U : 1U;
    if (transaction.command_count != expected_commands) {
        error = "family_colonization_transaction_capacity_exceeded";
        return false;
    }
    transaction.plan_hash = 1469598103934665603ULL;
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.id);
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.effective_day);
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *stored = command_at(transaction, ordinal);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->action);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->domain);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->opcode);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->target_handle);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->target_generation);
        for (const int64_t value : stored->payload)
            transaction.plan_hash = fnv_value(transaction.plan_hash, value);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
                                           stored->idempotency_key);
    }
    _transactions.push_back(std::move(transaction));
    _transaction_ids[_transactions.back().id] =
        static_cast<int32_t>(_transactions.size() - 1);
    track_pending_transaction(_transactions.back());
    index_transaction_commands(_transactions.back());
    if (out_transaction_id != nullptr) *out_transaction_id = _transactions.back().id;
    return true;
}

int32_t EffectRuntime::family_colonization_transaction_status_pod(
        int64_t transaction_id, int64_t effect_id,
        uint32_t expedition_generation, uint64_t fire_sequence,
        int64_t *out_resolved_transaction_id) const {
    if (out_resolved_transaction_id != nullptr) *out_resolved_transaction_id = 0;
    if (effect_id <= 0 || expedition_generation == 0) return 0;
    const uint64_t base_key = make_hash(static_cast<uint64_t>(effect_id),
        expedition_generation, fire_sequence, 0x434f4c4fU);
    const uint64_t settle_key = make_hash(static_cast<uint64_t>(effect_id),
        expedition_generation, fire_sequence, 1);
    auto matches = [&](const Transaction &tx) {
        if (tx.program_id != -1 || tx.source_generation != expedition_generation)
            return false;
        for (uint32_t ordinal = 0; ordinal < tx.command_count; ++ordinal) {
            const Command *command = command_at(tx, ordinal);
            if (command == nullptr) continue;
            if (command->idempotency_key == base_key ||
                command->idempotency_key == settle_key) {
                return true;
            }
        }
        return false;
    };
    const int32_t direct = transaction_index_for_id(transaction_id);
    if (direct >= 0 && direct < static_cast<int32_t>(_transactions.size())) {
        const Transaction &tx = _transactions[static_cast<size_t>(direct)];
        if (matches(tx)) {
            if (out_resolved_transaction_id != nullptr)
                *out_resolved_transaction_id = tx.id;
            return tx.status;
        }
    }
    for (const Transaction &tx : _transactions) {
        if (!matches(tx)) continue;
        if (out_resolved_transaction_id != nullptr)
            *out_resolved_transaction_id = tx.id;
        return tx.status;
    }
    return 0;
}

bool EffectRuntime::family_colonization_includes_claim(
        int64_t transaction_id) const {
    const int32_t index = transaction_index_for_id(transaction_id);
    if (index < 0) return false;
    const Transaction &transaction = _transactions[static_cast<size_t>(index)];
    if (transaction.program_id != -1) return false;
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *command = command_at(transaction, ordinal);
        if (command == nullptr) continue;
        if (command->action == COUNTRY_COMMAND &&
            command->opcode == CountryApi::COMMAND_CLAIM_UNOWNED_TERRITORY)
            return true;
        if (command->action == ECONOMY_COMMAND &&
            command->opcode == EconomyApi::COMMAND_SETTLE_FAMILY_EXPEDITION &&
            command->payload[2] != 0)
            return true;
    }
    return false;
}

int32_t EffectRuntime::family_colonization_population_reward(
        int64_t transaction_id) const {
    const int32_t index = transaction_index_for_id(transaction_id);
    if (index < 0) return 0;
    const Transaction &transaction = _transactions[static_cast<size_t>(index)];
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const Command *command = command_at(transaction, ordinal);
        if (command == nullptr || command->action != ECONOMY_COMMAND ||
            command->opcode != EconomyApi::COMMAND_SETTLE_FAMILY_EXPEDITION)
            continue;
        return static_cast<int32_t>(std::max<int64_t>(0, command->payload[3]));
    }
    return 0;
}

} // namespace pk
