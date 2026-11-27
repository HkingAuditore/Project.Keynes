#include "effect_runtime_dispatch_includes.inc"

namespace pk {
using namespace godot;

Dictionary EffectRuntime::dispatch_native_economy(NativeEconomyRuntime *economy_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (economy_runtime == nullptr) return failure("economy_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();
    struct PendingTransaction { int32_t index = -1; uint32_t begin = 0; uint32_t count = 0; uint32_t domain_mask = 0; };
    std::vector<EconomyApi::EffectCommand> commands;
    std::vector<PendingTransaction> pending;
    commands.reserve(static_cast<size_t>(_max_native_modifier_commands));
    int32_t rejected_transactions = 0;
    int32_t retryable_transactions = 0;
    for (int32_t tx_index = 0; tx_index < static_cast<int32_t>(_transactions.size()); ++tx_index) {
        Transaction &transaction = _transactions[static_cast<size_t>(tx_index)];
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED ||
            _native_economy_bound_transaction_ids.find(transaction.id) !=
                _native_economy_bound_transaction_ids.end() ||
            transaction.command_count == 0)
            continue;
        if (transaction.program_id == -1) {
            // Colonization is intentionally ordered: Economy may consume the
            // transit payload only after the Country claim has committed and
            // ACKed. A rejected claim therefore never reaches Economy.
            uint32_t prerequisite_mask = 0;
            for (uint32_t ordinal = 0; ordinal < transaction.command_count;
                    ++ordinal) {
                const Command *command = command_at(transaction, ordinal);
                if (command != nullptr && command->action == COUNTRY_COMMAND)
                    prerequisite_mask |= adapter_ack_bit_for(*command);
            }
            if (prerequisite_mask != 0 &&
                (transaction.received_ack_mask & prerequisite_mask) !=
                    prerequisite_mask) continue;
        }
        const uint32_t begin = static_cast<uint32_t>(commands.size());
        bool supported = true;
        uint32_t domain_mask = 0;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) {
                supported = false;
                break;
            }
            if (command->action != ECONOMY_COMMAND) continue;
            if ((transaction.received_ack_mask & adapter_ack_bit_for(*command)) != 0)
                continue;
            if (command->domain < 0 || command->domain >= 32 ||
                command->opcode < EconomyApi::COMMAND_TRANSFER_TO_COHORT ||
                (command->opcode > EconomyApi::COMMAND_SETTLE_FAMILY_EXPEDITION &&
                 command->opcode != EconomyApi::COMMAND_FAMILY_ABSORB_ANONYMOUS &&
                 command->opcode != EconomyApi::COMMAND_FAMILY_PURCHASE_DISCOUNT &&
                 command->opcode != EconomyApi::COMMAND_FAMILY_SET_SPLIT_POLICY)) {
                supported = false;
                break;
            }
            EconomyApi::EffectCommand native;
            native.opcode = command->opcode;
            native.effective_day = transaction.effective_day;
            native.sequence = static_cast<int64_t>(command->idempotency_key &
                0x7fffffffffffffffULL);
            native.target_handle = command->target_handle;
            native.target_generation = command->target_generation;
            const uint64_t packed_i32 = static_cast<uint64_t>(command->payload[0]);
            native.i32_0 = static_cast<int32_t>(packed_i32 & 0xffffffffULL);
            native.i32_1 = command->opcode ==
                EconomyApi::COMMAND_SETTLE_FAMILY_EXPEDITION
                ? static_cast<int32_t>(command->payload[3])
                : static_cast<int32_t>((packed_i32 >> 32U) & 0xffffffffULL);
            native.i64_0 = command->opcode ==
                EconomyApi::COMMAND_SETTLE_FAMILY_EXPEDITION
                ? command->payload[2] : command->value_q16;
            native.i64_1 = command->payload[1];
            native.idempotency_key = command->idempotency_key;
            commands.push_back(native);
            domain_mask |= adapter_ack_bit_for(*command);
        }
        if (!supported) {
            commands.resize(begin);
            continue;
        }
        const uint32_t count = static_cast<uint32_t>(commands.size()) - begin;
        if (count == 0 || domain_mask == 0 || commands.size() > static_cast<size_t>(_max_native_modifier_commands)) {
            commands.resize(begin);
            continue;
        }
        std::string preflight_error;
        const int32_t preflight = economy_api::preflight_effect_commands_pod(
            *economy_runtime, commands.data() + begin, count, preflight_error);
        if (preflight == EconomyApi::EFFECT_PREFLIGHT_RETRY) {
            commands.resize(begin);
            ++retryable_transactions;
            if (!preflight_error.empty()) _last_error = preflight_error;
            continue;
        }
        if (preflight != EconomyApi::EFFECT_PREFLIGHT_ACCEPT) {
            commands.resize(begin);
            untrack_pending_transaction(transaction);
            unindex_transaction_commands(transaction);
            transaction.status = REJECTED;
            apply_rejected_instance_transition(transaction);
            ++_preflight_rejects;
            ++rejected_transactions;
            _last_error = preflight_error.empty()
                ? "effect_native_economy_preflight_rejected"
                : preflight_error;
            continue;
        }
        pending.push_back({tx_index, begin, count, domain_mask});
    }
    Dictionary out;
    out["ok"] = true;
    out["submitted_transactions"] = 0;
    out["submitted_commands"] = 0;
    out["rejected_transactions"] = rejected_transactions;
    out["retryable_transactions"] = retryable_transactions;
    if (rejected_transactions != 0 || retryable_transactions != 0)
        out["reason"] = String(_last_error.c_str());
    if (commands.empty()) {
        _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return out;
    }
    std::vector<int64_t> request_ids;
    std::string error;
    if (!economy_api::submit_effect_commands_pod(*economy_runtime, commands.data(),
            commands.size(), request_ids, error) || request_ids.size() != commands.size()) {
        _last_error = error.empty() ? "effect_native_economy_enqueue_failed" : error;
        out["ok"] = false;
        out["reason"] = String(_last_error.c_str());
        return out;
    }
    for (const PendingTransaction &item : pending) {
        Transaction &transaction = _transactions[static_cast<size_t>(item.index)];
        const uint32_t request_begin = static_cast<uint32_t>(
            _native_economy_request_ids.size());
        _native_economy_request_ids.insert(_native_economy_request_ids.end(),
            request_ids.begin() + item.begin, request_ids.begin() + item.begin + item.count);
        _native_economy_ack_bindings.push_back({transaction.id, request_begin,
            item.count, item.domain_mask});
        _native_economy_bound_transaction_ids.insert(transaction.id);
        transaction.status = PREFLIGHTED;
    }
    out["submitted_transactions"] = static_cast<int32_t>(pending.size());
    out["submitted_commands"] = static_cast<int32_t>(commands.size());
    _native_economy_transactions += pending.size();
    _native_economy_commands += commands.size();
    _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::ack_native_economy(NativeEconomyRuntime *economy_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (economy_runtime == nullptr) return failure("economy_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();
    std::vector<NativeAckBinding> retained;
    std::vector<int64_t> retained_ids;
    retained.reserve(_native_economy_ack_bindings.size());
    retained_ids.reserve(_native_economy_request_ids.size());
    int32_t acknowledged = 0;
    int32_t rejected = 0;
    for (const NativeAckBinding &binding : _native_economy_ack_bindings) {
        const int32_t index = transaction_index_for_id(binding.transaction_id);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size())) continue;
        Transaction &transaction = _transactions[static_cast<size_t>(index)];
        bool pending = false;
        bool failed = false;
        std::string reason;
        for (uint32_t i = 0; i < binding.request_count; ++i) {
            const size_t request_index = static_cast<size_t>(binding.request_begin) + i;
            if (request_index >= _native_economy_request_ids.size()) {
                failed = true;
                reason = "effect_native_economy_binding_invalid";
                break;
            }
            bool complete = false;
            bool ok = false;
            if (!economy_api::effect_command_result_pod(*economy_runtime,
                    _native_economy_request_ids[request_index], complete, ok, reason)) {
                failed = true;
                break;
            }
            if (!complete) {
                pending = true;
                break;
            }
            if (!ok) {
                failed = true;
                break;
            }
        }
        if (pending && !failed) {
            NativeAckBinding kept{binding.transaction_id,
                static_cast<uint32_t>(retained_ids.size()), binding.request_count,
                binding.domain_bit};
            for (uint32_t i = 0; i < binding.request_count; ++i)
                retained_ids.push_back(_native_economy_request_ids[
                    static_cast<size_t>(binding.request_begin) + i]);
            retained.push_back(kept);
            continue;
        }
        if (failed) {
            untrack_pending_transaction(transaction);
            unindex_transaction_commands(transaction);
            transaction.status = REJECTED;
            apply_rejected_instance_transition(transaction);
            ++_preflight_rejects;
            ++rejected;
            _last_error = reason.empty() ? "effect_native_economy_rejected" : reason;
        } else {
            acknowledge_native_domain(transaction, binding.domain_bit);
            ++acknowledged;
        }
        _native_economy_bound_transaction_ids.erase(binding.transaction_id);
    }
    _native_economy_ack_bindings.swap(retained);
    _native_economy_request_ids.swap(retained_ids);
    if (acknowledged != 0 || rejected != 0) compact_terminal_transactions();
    Dictionary out;
    out["ok"] = rejected == 0;
    out["acknowledged"] = acknowledged;
    out["rejected"] = rejected;
    out["pending"] = static_cast<int32_t>(_native_economy_ack_bindings.size());
    if (rejected != 0) out["reason"] = String(_last_error.c_str());
    _native_economy_acks += static_cast<uint64_t>(acknowledged);
    _last_native_ack_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::dispatch_native_gameplay(DCWorldExt *world_ext) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (world_ext == nullptr) return failure("gameplay_effect_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();
    struct PendingTransaction { int32_t index = -1; uint32_t begin = 0; uint32_t count = 0; uint32_t domain_mask = 0; };
    std::vector<DCWorldExt::EffectGameplayCommand> commands;
    std::vector<PendingTransaction> pending;
    commands.reserve(static_cast<size_t>(_max_native_modifier_commands));
    for (int32_t tx_index = 0; tx_index < static_cast<int32_t>(_transactions.size()); ++tx_index) {
        Transaction &transaction = _transactions[static_cast<size_t>(tx_index)];
        if ((transaction.status != PLANNED && transaction.status != PREFLIGHTED &&
             transaction.status != COMMITTED) || transaction.command_count == 0 ||
            _native_gameplay_bound_transaction_ids.find(transaction.id) !=
                _native_gameplay_bound_transaction_ids.end())
            continue;
        const uint32_t begin = static_cast<uint32_t>(commands.size());
        bool supported = true;
        uint32_t domain_mask = 0;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) {
                supported = false;
                break;
            }
            const bool native_gameplay = command != nullptr &&
                command->action == GAMEPLAY_COMMAND && command->domain == 3 &&
                command->opcode > 0;
            const bool native_publish = command != nullptr &&
                command->action == PUBLISH_EVENT && command->domain == 4 &&
                command->opcode > 0;
            const bool native_custom = command != nullptr &&
                command->action == CUSTOM_DOMAIN_COMMAND && command->domain == 6 &&
                (command->opcode == CUSTOM_AUDIT_OPCODE ||
                 command->opcode == CUSTOM_CANAL_COMMIT_OPCODE ||
                 command->opcode == CUSTOM_IDEOLOGY_FREE_DRAW_OPCODE);
            if (!native_gameplay && !native_publish && !native_custom) {
                continue;
            }
            if ((transaction.received_ack_mask & adapter_ack_bit_for(*command)) != 0)
                continue;
            DCWorldExt::EffectGameplayCommand native;
            native.action = command->action;
            native.domain = command->domain;
            native.opcode = command->opcode;
            native.effective_day = transaction.effective_day;
            native.target_handle = command->target_handle;
            native.target_generation = command->target_generation;
            native.value_i64 = command->value_q16;
            native.payload = command->payload;
            native.idempotency_key = command->idempotency_key;
            commands.push_back(native);
            domain_mask |= adapter_ack_bit_for(*command);
        }
        if (!supported) {
            commands.resize(begin);
            continue;
        }
        const uint32_t count = static_cast<uint32_t>(commands.size()) - begin;
        if (count == 0 || domain_mask == 0 || commands.size() > static_cast<size_t>(_max_native_modifier_commands)) {
            commands.resize(begin);
            continue;
        }
        pending.push_back({tx_index, begin, count, domain_mask});
    }
    Dictionary out;
    out["ok"] = true;
    out["submitted_transactions"] = 0;
    out["submitted_commands"] = 0;
    if (commands.empty()) {
        _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return out;
    }
    std::vector<int64_t> request_ids;
    std::string error;
    if (!world_ext->submit_effect_gameplay_commands_pod(commands.data(),
            commands.size(), request_ids, error) || request_ids.size() != commands.size()) {
        _last_error = error.empty() ? "effect_native_gameplay_enqueue_failed" : error;
        out["ok"] = false;
        out["reason"] = String(_last_error.c_str());
        return out;
    }
    for (const PendingTransaction &item : pending) {
        Transaction &transaction = _transactions[static_cast<size_t>(item.index)];
        const uint32_t request_begin = static_cast<uint32_t>(
            _native_gameplay_request_ids.size());
        _native_gameplay_request_ids.insert(_native_gameplay_request_ids.end(),
            request_ids.begin() + item.begin, request_ids.begin() + item.begin + item.count);
        _native_gameplay_ack_bindings.push_back({transaction.id, request_begin,
            item.count, item.domain_mask});
        _native_gameplay_bound_transaction_ids.insert(transaction.id);
        transaction.status = PREFLIGHTED;
    }
    out["submitted_transactions"] = static_cast<int32_t>(pending.size());
    out["submitted_commands"] = static_cast<int32_t>(commands.size());
    _native_gameplay_transactions += pending.size();
    _native_gameplay_commands += commands.size();
    _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::ack_native_gameplay(DCWorldExt *world_ext) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (world_ext == nullptr) return failure("gameplay_effect_runtime_unavailable");
    std::vector<NativeAckBinding> retained;
    std::vector<int64_t> retained_ids;
    retained.reserve(_native_gameplay_ack_bindings.size());
    retained_ids.reserve(_native_gameplay_request_ids.size());
    int32_t acknowledged = 0;
    int32_t rejected = 0;
    for (const NativeAckBinding &binding : _native_gameplay_ack_bindings) {
        const int32_t index = transaction_index_for_id(binding.transaction_id);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size())) continue;
        Transaction &transaction = _transactions[static_cast<size_t>(index)];
        bool pending = false;
        bool failed = false;
        std::string reason;
        for (uint32_t i = 0; i < binding.request_count; ++i) {
            const size_t request_index = static_cast<size_t>(binding.request_begin) + i;
            bool complete = false;
            bool ok = false;
            if (request_index >= _native_gameplay_request_ids.size() ||
                !world_ext->effect_gameplay_command_result_pod(
                    _native_gameplay_request_ids[request_index], complete, ok, reason)) {
                failed = true;
                if (reason.empty()) reason = "effect_native_gameplay_binding_invalid";
                break;
            }
            if (!complete) { pending = true; failed = false; break; }
            if (!ok) { failed = true; break; }
        }
        if (pending && !failed) {
            NativeAckBinding kept{binding.transaction_id,
                static_cast<uint32_t>(retained_ids.size()), binding.request_count};
            for (uint32_t i = 0; i < binding.request_count; ++i)
                retained_ids.push_back(_native_gameplay_request_ids[
                    static_cast<size_t>(binding.request_begin) + i]);
            retained.push_back(kept);
            continue;
        }
        if (failed) {
            untrack_pending_transaction(transaction);
            unindex_transaction_commands(transaction);
            transaction.status = REJECTED;
            apply_rejected_instance_transition(transaction);
            ++_preflight_rejects;
            ++rejected;
            _last_error = reason.empty() ? "effect_native_gameplay_rejected" : reason;
        } else {
            acknowledge_native_domain(transaction, binding.domain_bit);
            ++acknowledged;
        }
        _native_gameplay_bound_transaction_ids.erase(binding.transaction_id);
    }
    _native_gameplay_ack_bindings.swap(retained);
    _native_gameplay_request_ids.swap(retained_ids);
    if (acknowledged != 0 || rejected != 0) compact_terminal_transactions();
    Dictionary out;
    out["ok"] = rejected == 0;
    out["acknowledged"] = acknowledged;
    out["rejected"] = rejected;
    out["pending"] = static_cast<int32_t>(_native_gameplay_ack_bindings.size());
    if (rejected != 0) out["reason"] = String(_last_error.c_str());
    _native_gameplay_acks += static_cast<uint64_t>(acknowledged);
    return out;
}

} // namespace pk
