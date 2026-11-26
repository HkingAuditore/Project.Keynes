#include "effect_runtime_dispatch_includes.inc"

namespace pk {
using namespace godot;

bool EffectRuntime::has_pending_research_discovery(uint64_t country, int32_t signal) const {
    for (const Transaction &transaction : _transactions) {
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED) continue;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command != nullptr && command->action == COUNTRY_COMMAND &&
                command->target_handle == country &&
                country_api::discovers_signal(command->opcode, command->payload[0], signal))
                return true;
        }
    }
    return false;
}

Dictionary EffectRuntime::dispatch_native_country(NativeCountryRuntime *country_runtime,
                                                  bool trigger_delivery) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (country_runtime == nullptr) return failure("country_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();
    struct PendingTransaction { int32_t index = -1; uint32_t begin = 0; uint32_t count = 0; uint32_t domain_mask = 0; };
    std::vector<CountryEffectCommand> commands;
    std::vector<PendingTransaction> pending;
    commands.reserve(static_cast<size_t>(_max_native_modifier_commands));
    for (int32_t tx_index = 0; tx_index < static_cast<int32_t>(_transactions.size()); ++tx_index) {
        Transaction &transaction = _transactions[static_cast<size_t>(tx_index)];
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED)
            continue;
        if (_native_country_bound_transaction_ids.find(transaction.id) !=
                _native_country_bound_transaction_ids.end())
            continue;
        if (transaction.command_count == 0) continue;
        const uint32_t begin = static_cast<uint32_t>(commands.size());
        bool supported = true;
        uint32_t domain_mask = 0;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) {
                supported = false;
                break;
            }
            if (command->action != COUNTRY_COMMAND) continue;
            if ((transaction.received_ack_mask & adapter_ack_bit_for(*command)) != 0)
                continue;
            if (command->domain < 0 || command->domain >= 32 ||
                command->opcode < CountryApi::COMMAND_CREATE_COUNTRY ||
                command->opcode > CountryApi::COMMAND_CLAIM_UNOWNED_TERRITORY ||
                (command->command_definition_id < 0 &&
                 command->opcode != CountryApi::COMMAND_CLAIM_UNOWNED_TERRITORY) ||
                command->command_definition_id >= static_cast<int32_t>(_command_definitions.size())) {
                supported = false;
                break;
            }
            CountryEffectCommand native;
            native.opcode = command->opcode;
            native.effective_day = transaction.effective_day;
            native.sequence = static_cast<int64_t>(command->idempotency_key &
                0x7fffffffffffffffULL);
            native.target_handle = command->target_handle;
            native.target_generation = command->target_generation;
            native.value = command->value_q16;
            native.payload = command->payload;
            native.idempotency_key = command->idempotency_key;
            native.trigger_delivery = trigger_delivery;
            // For structural country commands the catalog carries immutable
            // names in the existing cold string columns.  No Godot Variant is
            // built in this bridge.
            if (command->command_definition_id >= 0) {
                const CommandDefinition &definition = _command_definitions[
                    static_cast<size_t>(command->command_definition_id)];
                native.stable_id = definition.definition_key.c_str();
                native.display_name = definition.command_key.c_str();
            }
            commands.push_back(native);
            domain_mask |= adapter_ack_bit_for(*command);
        }
        if (!supported) { commands.resize(begin); continue; }
        const uint32_t count = static_cast<uint32_t>(commands.size()) - begin;
        if (count == 0 || domain_mask == 0 || commands.size() > static_cast<size_t>(_max_native_modifier_commands)) {
            commands.resize(begin);
            continue;
        }
        pending.push_back({tx_index, begin, count, domain_mask});
    }
    Dictionary out;
    out["ok"] = true; out["submitted_transactions"] = 0; out["submitted_commands"] = 0;
    if (commands.empty()) {
        _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return out;
    }
    std::vector<int64_t> request_ids;
    std::string error;
    if (!country_api::submit_effect_commands_pod(*country_runtime, commands.data(), commands.size(), request_ids, error) ||
        request_ids.size() != commands.size()) {
        _last_error = error.empty() ? "effect_native_country_enqueue_failed" : error;
        out["ok"] = false; out["reason"] = String(_last_error.c_str());
        return out;
    }
    for (const PendingTransaction &item : pending) {
        Transaction &transaction = _transactions[static_cast<size_t>(item.index)];
        const uint32_t request_begin = static_cast<uint32_t>(_native_country_request_ids.size());
        _native_country_request_ids.insert(_native_country_request_ids.end(),
            request_ids.begin() + item.begin, request_ids.begin() + item.begin + item.count);
        _native_country_ack_bindings.push_back({transaction.id, request_begin,
            item.count, item.domain_mask});
        _native_country_bound_transaction_ids.insert(transaction.id);
        transaction.status = PREFLIGHTED;
    }
    out["submitted_transactions"] = static_cast<int32_t>(pending.size());
    out["submitted_commands"] = static_cast<int32_t>(commands.size());
    _native_country_transactions += pending.size();
    _native_country_commands += commands.size();
    _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::ack_native_country(NativeCountryRuntime *country_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (country_runtime == nullptr) return failure("country_runtime_unavailable");
    country_api::drain_effect_host_command_receipts(*country_runtime);
    int32_t acknowledged = 0, rejected = 0;
    std::vector<NativeAckBinding> retained;
    std::vector<int64_t> retained_ids;
    retained.reserve(_native_country_ack_bindings.size());
    retained_ids.reserve(_native_country_request_ids.size());
    for (const NativeAckBinding &binding : _native_country_ack_bindings) {
        const int32_t index = transaction_index_for_id(binding.transaction_id);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size())) continue;
        Transaction &transaction = _transactions[static_cast<size_t>(index)];
        bool pending = false, failed = false;
        std::string reason;
        for (uint32_t i = 0; i < binding.request_count; ++i) {
            const size_t request_index = static_cast<size_t>(binding.request_begin) + i;
            if (request_index >= _native_country_request_ids.size()) { failed = true; reason = "effect_native_country_binding_invalid"; break; }
            bool complete = false, ok = false;
            if (!country_api::effect_command_result_pod(*country_runtime, _native_country_request_ids[request_index],
                    complete, ok, reason)) { failed = true; break; }
            if (!complete) { pending = true; break; }
            if (!ok) { failed = true; break; }
        }
        if (pending && !failed) {
            NativeAckBinding kept{binding.transaction_id,
                static_cast<uint32_t>(retained_ids.size()), binding.request_count,
                binding.domain_bit};
            for (uint32_t i = 0; i < binding.request_count; ++i)
                retained_ids.push_back(_native_country_request_ids[
                    static_cast<size_t>(binding.request_begin) + i]);
            retained.push_back(kept);
            continue;
        }
        if (failed) {
            untrack_pending_transaction(transaction);
            unindex_transaction_commands(transaction);
            transaction.status = REJECTED;
            apply_rejected_instance_transition(transaction);
            ++_preflight_rejects; ++rejected; _last_error = reason.empty() ? "effect_native_country_rejected" : reason;
        } else {
            acknowledge_native_domain(transaction, binding.domain_bit);
            ++acknowledged;
        }
        _native_country_bound_transaction_ids.erase(binding.transaction_id);
    }
    _native_country_ack_bindings.swap(retained);
    _native_country_request_ids.swap(retained_ids);
    if (acknowledged != 0 || rejected != 0) compact_terminal_transactions();
    Dictionary out;
    out["ok"] = rejected == 0; out["acknowledged"] = acknowledged;
    out["rejected"] = rejected; out["pending"] = static_cast<int32_t>(_native_country_ack_bindings.size());
    if (rejected != 0) out["reason"] = String(_last_error.c_str());
    _native_country_acks += static_cast<uint64_t>(acknowledged);
    return out;
}

Dictionary EffectRuntime::settle_orphaned_native_country_acks() {
    if (!_configured) return failure("effect_runtime_unconfigured");
    int32_t settled = 0;
    std::vector<NativeAckBinding> bindings = _native_country_ack_bindings;
    std::vector<int64_t> request_ids = _native_country_request_ids;
    std::vector<NativeAckBinding> retained;
    std::vector<int64_t> retained_ids;
    retained.reserve(bindings.size());
    retained_ids.reserve(request_ids.size());
    _native_country_ack_bindings.clear();
    _native_country_request_ids.clear();
    auto keep = [&](const NativeAckBinding &binding) {
        NativeAckBinding kept{binding.transaction_id,
            static_cast<uint32_t>(retained_ids.size()), binding.request_count,
            binding.domain_bit};
        for (uint32_t i = 0; i < binding.request_count; ++i) {
            const size_t index =
                static_cast<size_t>(binding.request_begin) + i;
            if (index < request_ids.size())
                retained_ids.push_back(request_ids[index]);
        }
        retained.push_back(kept);
    };
    for (const NativeAckBinding &binding : bindings) {
        const int32_t index = transaction_index_for_id(binding.transaction_id);
        if (index < 0 || index >= static_cast<int32_t>(_transactions.size())) {
            _native_country_bound_transaction_ids.erase(binding.transaction_id);
            continue;
        }
        Transaction &transaction = _transactions[static_cast<size_t>(index)];
        if (transaction.status != PREFLIGHTED && transaction.status != COMMITTED &&
            transaction.status != PLANNED) {
            _native_country_bound_transaction_ids.erase(binding.transaction_id);
            continue;
        }
        // Soft-settling exists to stop a stalled Country domain from pinning the
        // clock, but it must not forge an ACK that another domain is ordered
        // behind. dispatch_native_economy holds an Economy command until the
        // Country commands in the same transaction are ACKed, so releasing this
        // binding early let colonization SETTLE run against a claim that had not
        // committed: Economy read the target as unowned and sent the settlers
        // home while the claim still landed. Only transactions that actually
        // pair Country and Economy work are held back; everything else still
        // soft-settles, which is what keeps a stalled Country off the clock.
        bool has_country_command = false;
        bool has_economy_command = false;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count;
                ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) continue;
            if (command->action == COUNTRY_COMMAND) has_country_command = true;
            else if (command->action == ECONOMY_COMMAND) has_economy_command = true;
        }
        if (has_country_command && has_economy_command) {
            keep(binding);
            continue;
        }
        acknowledge_native_domain(transaction, binding.domain_bit);
        _native_country_bound_transaction_ids.erase(binding.transaction_id);
        ++settled;
    }
    _native_country_ack_bindings.swap(retained);
    _native_country_request_ids.swap(retained_ids);
    if (settled != 0) compact_terminal_transactions();
    _native_country_acks += static_cast<uint64_t>(settled);
    Dictionary out;
    out["ok"] = true;
    out["acknowledged"] = settled;
    out["pending"] = static_cast<int32_t>(_native_country_ack_bindings.size());
    return out;
}

} // namespace pk
