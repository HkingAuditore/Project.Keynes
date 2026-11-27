#include "effect_runtime_dispatch_includes.inc"

namespace pk {
using namespace godot;

Dictionary EffectRuntime::dispatch_native_modifier(ModifierRuntime *modifier_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (modifier_runtime == nullptr || !modifier_api::configured(*modifier_runtime))
        return failure("modifier_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();

    auto binding_exists = [&](int64_t transaction_id) {
        return _native_bound_transaction_ids.find(transaction_id) !=
            _native_bound_transaction_ids.end();
    };
    auto definition_key_ptr = [&](const Command &command) -> const std::string * {
        if (command.command_definition_id >= 0 &&
            command.command_definition_id < static_cast<int32_t>(_command_definitions.size()))
            return &_command_definitions[command.command_definition_id].definition_key;
        return nullptr;
    };

    struct PendingTransaction {
        int32_t transaction_index = -1;
        uint32_t request_offset = 0;
        uint32_t request_count = 0;
        uint32_t domain_mask = 0;
    };
    std::vector<ModifierApi::NativeCommand> native_commands;
    std::vector<PendingTransaction> pending_transactions;
    native_commands.reserve(static_cast<size_t>(_max_native_modifier_commands));
    pending_transactions.reserve(std::min<int32_t>(_max_transactions, 4096));

    // A transaction may contain commands for several native domains. Each
    // adapter claims only its own command subset; the shared ACK mask keeps the
    // transaction hidden from fallback polling until every domain is done.
    for (int32_t tx_index = 0;
         tx_index < static_cast<int32_t>(_transactions.size());
         ++tx_index) {
        Transaction &transaction = _transactions[static_cast<size_t>(tx_index)];
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED)
            continue;
        if (binding_exists(transaction.id) || transaction.command_count == 0 ||
            transaction.required_ack_mask == 0)
            continue;

        const int32_t instance_index = instance_index_for_id(transaction.source_instance_id);
        const Instance *source_instance = instance_index >= 0 &&
            instance_index < static_cast<int32_t>(_instances.size())
            ? &_instances[static_cast<size_t>(instance_index)] : nullptr;
        if (source_instance == nullptr ||
            source_instance->generation != transaction.source_generation)
            continue;

        const uint32_t request_offset = static_cast<uint32_t>(native_commands.size());
        bool supported = true;
        uint32_t domain_mask = 0;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) { supported = false; break; }
            if (command->action != MODIFIER_COMMAND) continue;
            if ((transaction.received_ack_mask & adapter_ack_bit_for(*command)) != 0)
                continue;
            // THE mapping (magnitude, source identity, scope, handles) lives in
            // map_modifier_row; the translation below is storage only.
            ModifierRow row;
            if (!map_modifier_row(transaction, *source_instance, *command, row)) {
                supported = false;
                break;
            }
            ModifierApi::NativeCommand native;
            native.opcode = row.opcode;
            native.producer = row.producer;
            native.sequence = row.sequence;
            native.effective_day = row.effective_day;
            // `map_modifier_row` already rejected a missing key; keep the
            // catalog-owned pointer instead of the loop copy so the `const char*`
            // stays valid after `row` goes out of scope.
            const std::string *definition_key = definition_key_ptr(*command);
            native.definition_key = definition_key != nullptr
                ? definition_key->c_str() : "";
            native.domain = row.domain;
            native.scope = row.scope;
            native.entity_handle = row.entity_handle;
            native.group_handle = row.group_handle;
            native.source_type = row.source_type;
            native.source_id = row.source_id;
            native.duration_days = row.duration_days;
            native.stacks = row.stacks;
            native.magnitude_q16 = row.magnitude_q16;
            native.modifier_handle = 0;
            if (command->domain >= 0 && command->domain < 32)
                domain_mask |= row.domain_bit;
            native_commands.push_back(native);
        }
        if (!supported) {
            native_commands.resize(request_offset);
            break;
        }
        const uint32_t request_count = static_cast<uint32_t>(native_commands.size()) -
            request_offset;
        if (request_count == 0 || domain_mask == 0) continue;
        if (native_commands.size() > static_cast<size_t>(_max_native_modifier_commands)) {
            native_commands.resize(request_offset);
            continue;
        }
        pending_transactions.push_back({tx_index, request_offset, request_count, domain_mask});
    }

    Dictionary out;
    out["ok"] = true;
    out["submitted_transactions"] = 0;
    out["submitted_commands"] = 0;
    if (native_commands.empty()) {
        _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return out;
    }

    std::vector<int64_t> request_ids;
    std::string error;
    if (!modifier_api::submit_commands_pod(*modifier_runtime, native_commands.data(), native_commands.size(),
                                               request_ids, error) ||
        request_ids.size() != native_commands.size()) {
        _last_error = error.empty() ? "effect_native_modifier_enqueue_failed" : error;
        out["ok"] = false;
        out["reason"] = String(_last_error.c_str());
        _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        return out;
    }
    for (const PendingTransaction &pending : pending_transactions) {
        Transaction &transaction = _transactions[static_cast<size_t>(pending.transaction_index)];
        const uint32_t request_begin = static_cast<uint32_t>(_native_request_ids.size());
        _native_request_ids.insert(_native_request_ids.end(),
            request_ids.begin() + pending.request_offset,
            request_ids.begin() + pending.request_offset + pending.request_count);
        _native_ack_bindings.push_back({transaction.id, request_begin,
            pending.request_count, pending.domain_mask});
        _native_bound_transaction_ids.insert(transaction.id);
        transaction.status = PREFLIGHTED;
    }
    out["submitted_transactions"] = static_cast<int32_t>(pending_transactions.size());
    out["submitted_commands"] = static_cast<int32_t>(native_commands.size());
    _native_modifier_transactions += pending_transactions.size();
    _native_modifier_commands += native_commands.size();
    _last_native_dispatch_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

Dictionary EffectRuntime::ack_native_modifier(ModifierRuntime *modifier_runtime) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (modifier_runtime == nullptr || !modifier_api::configured(*modifier_runtime))
        return failure("modifier_runtime_unavailable");
    const auto started = std::chrono::steady_clock::now();

    int32_t acknowledged = 0;
    int32_t rejected = 0;
    std::vector<NativeAckBinding> retained;
    std::vector<int64_t> retained_request_ids;
    retained.reserve(_native_ack_bindings.size());
    retained_request_ids.reserve(_native_request_ids.size());
    for (const NativeAckBinding &binding : _native_ack_bindings) {
        const int32_t tx_index = transaction_index_for_id(binding.transaction_id);
        Transaction *transaction = tx_index >= 0 &&
            tx_index < static_cast<int32_t>(_transactions.size())
            ? &_transactions[static_cast<size_t>(tx_index)] : nullptr;
        if (transaction == nullptr || transaction->status == ACKED ||
            transaction->status == REJECTED || transaction->status == RESYNC_REQUIRED)
            continue;
        bool pending = false;
        bool failed = false;
        std::string failure_reason;
        for (uint32_t i = 0; i < binding.request_count; ++i) {
            const size_t request_index = static_cast<size_t>(binding.request_begin) + i;
            if (request_index >= _native_request_ids.size()) {
                failed = true;
                failure_reason = "effect_native_modifier_binding_invalid";
                break;
            }
            bool complete = false, ok = false;
            std::string reason;
            modifier_api::command_result_pod(*modifier_runtime, _native_request_ids[request_index],
                                                 complete, ok, reason);
            if (!complete) {
                pending = true;
                break;
            }
            if (!ok) {
                failed = true;
                failure_reason = reason.empty() ? "effect_native_modifier_rejected" : reason;
                // Roll back the rows THIS batch already committed.
                //
                // `run_modifier_daily` applies each row in submission order and only then
                // does the ACK reach the failing row, so rows that committed before it are
                // otherwise orphaned: `apply_rejected_instance_transition` only reschedules
                // and never touches the Modifier store (it has no pointer to it). Measured
                // before this fix: a rejected equip left the card's own cost row live while
                // the card was INACTIVE with zero cell contributions.
                //
                // The row identity depends on which adapter branch produced it -- the
                // ideology branch keys on the instance id, the generic MODIFIER_COMMAND
                // branch on the batch's source id -- so BOTH are swept. A row matching
                // neither is not from this batch.
                const int32_t source_index = instance_index_for_id(
                    transaction->source_instance_id);
                if (source_index >= 0 &&
                    source_index < static_cast<int32_t>(_instances.size())) {
                    const Instance &source =
                        _instances[static_cast<size_t>(source_index)];
                    modifier_api::remove_rows_for_source(*modifier_runtime,
                        static_cast<uint64_t>(source.source_type),
                        static_cast<uint64_t>(source.id), _current_day);
                    modifier_api::remove_rows_for_source(*modifier_runtime,
                        static_cast<uint64_t>(source.source_type),
                        static_cast<uint64_t>(source.source_id), _current_day);
                }
                break;
            }
        }
        if (pending) {
            NativeAckBinding kept = binding;
            kept.request_begin = static_cast<uint32_t>(retained_request_ids.size());
            for (uint32_t i = 0; i < binding.request_count; ++i)
                retained_request_ids.push_back(_native_request_ids[
                    static_cast<size_t>(binding.request_begin) + i]);
            retained.push_back(kept);
            continue;
        }
        if (failed) {
            untrack_pending_transaction(*transaction);
            unindex_transaction_commands(*transaction);
            transaction->status = REJECTED;
            apply_rejected_instance_transition(*transaction);
            ++_preflight_rejects;
            ++rejected;
            _last_error = failure_reason;
            continue;
        }
        acknowledge_native_domain(*transaction, binding.domain_bit);
        ++acknowledged;
    }
    for (const NativeAckBinding &binding : _native_ack_bindings) {
        if (std::find_if(retained.begin(), retained.end(),
                [&](const NativeAckBinding &candidate) {
                    return candidate.transaction_id == binding.transaction_id;
                }) == retained.end())
            _native_bound_transaction_ids.erase(binding.transaction_id);
    }
    _native_ack_bindings.swap(retained);
    _native_request_ids.swap(retained_request_ids);
    if (acknowledged != 0 || rejected != 0) compact_terminal_transactions();
    Dictionary out;
    out["ok"] = rejected == 0;
    out["acknowledged"] = acknowledged;
    out["rejected"] = rejected;
    out["pending"] = static_cast<int32_t>(_native_ack_bindings.size());
    if (rejected != 0) out["reason"] = String(_last_error.c_str());
    _native_modifier_acks += static_cast<uint64_t>(acknowledged);
    _last_native_ack_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    return out;
}

} // namespace pk
