#include "effect_runtime.h"
#include "country_api.h"
#include "economy_api.h"
#include "modifier_api.h"
#include "effect_runtime_internal.h"

namespace pk {

using namespace godot;

bool EffectRuntime::map_modifier_row(const Transaction &transaction,
                                     const Instance &source_instance,
                                     const Command &command,
                                     ModifierRow &out) const {
    if (command.action != MODIFIER_COMMAND) return false;
    const std::string *definition_key = nullptr;
    if (command.command_definition_id >= 0 &&
        command.command_definition_id < static_cast<int32_t>(_command_definitions.size())) {
        definition_key = &_command_definitions[
            static_cast<size_t>(command.command_definition_id)].definition_key;
    }
    if (definition_key == nullptr || definition_key->empty()) return false;
    int32_t adapter_kind = NATIVE_MODIFIER_GENERIC;
    if (command.command_definition_id >= 0 &&
        command.command_definition_id < static_cast<int32_t>(
            _command_definitions.size())) {
        adapter_kind = _command_definitions[
            static_cast<size_t>(command.command_definition_id)]
            .native_modifier_adapter;
    } else {
        // Behavior commands are a compile-time extension point. Keep
        // their legacy key compatibility outside declarative content;
        // ordinary catalog/template commands never execute this
        // string branch in the native daily adapter path.
        const std::string behavior_key = command_key_for(command);
        if (behavior_key == "technology.modifier")
            adapter_kind = NATIVE_MODIFIER_TECHNOLOGY;
        else if (behavior_key == "family.modifier")
            adapter_kind = NATIVE_MODIFIER_FAMILY;
        else if (behavior_key == "person.modifier")
            adapter_kind = NATIVE_MODIFIER_PERSON;
        else if (behavior_key == "trigger.modifier")
            adapter_kind = NATIVE_MODIFIER_TRIGGER;
    }
    // L3-9: the program's compiled magnitude is the base; this instance may
    // carry a multiplier written by another card's synergy. Applied here, on
    // the single path that turns a program command into a modifier row, so
    // there is exactly one place where "how strong is this row" is decided.
    // A scale of exactly 1.0 takes the old path bit-for-bit.
    const int32_t magnitude_scale_q16 = source_instance.magnitude_scale_q16;
    const auto scaled_magnitude = [magnitude_scale_q16](int64_t value) -> int32_t {
        return effect_scaled_magnitude_q16(value, magnitude_scale_q16);
    };

    out = ModifierRow();
    out.opcode = command.opcode;
    out.sequence = static_cast<int64_t>(command.idempotency_key &
        0x7fffffffffffffffULL);
    out.effective_day = transaction.effective_day;
    out.definition_key = *definition_key;
    out.duration_days = command.duration_days;
    out.stacks = std::max(1, command.stacks);
    out.domain_bit = adapter_ack_bit_for(command);
    // A REMOVE row is proved by absence, everything else by presence.
    out.expect_present = command.opcode != ModifierApi::COMMAND_REMOVE;

    if (adapter_kind == NATIVE_MODIFIER_TECHNOLOGY) {
        out.producer = 180;
        out.domain = ModifierApi::COUNTRY;
        out.scope = ModifierApi::ENTITY;
        out.entity_handle = command.target_handle;
        out.source_type = 0x54454348ULL; // TECH
        out.source_id = static_cast<uint64_t>(transaction.source_instance_id) & 0xffffULL;
        out.magnitude_q16 = ModifierApi::Q16_ONE;
    } else if (adapter_kind == NATIVE_MODIFIER_FAMILY) {
        out.producer = 160;
        out.domain = ModifierApi::ECONOMY;
        out.scope = ModifierApi::GROUP;
        out.group_handle = command.target_generation;
        out.source_type = 0x46414d494c59ULL; // FAMILY
        out.source_id = command.target_handle;
        out.magnitude_q16 = static_cast<int32_t>(std::clamp<int64_t>(
            scaled_magnitude(command.value_q16), 0, EFFECT_MAX_MAGNITUDE_Q16));
    } else if (adapter_kind == NATIVE_MODIFIER_PERSON) {
        out.producer = 170;
        out.domain = command.domain;
        out.scope = ModifierApi::ENTITY;
        out.entity_handle = command.target_handle;
        out.source_type = 0x504552534f4eULL; // PERSON
        out.source_id = static_cast<uint64_t>(transaction.source_instance_id);
        out.magnitude_q16 = static_cast<int32_t>(std::clamp<int64_t>(
            scaled_magnitude(command.value_q16), 0, EFFECT_MAX_MAGNITUDE_Q16));
    } else if (adapter_kind == NATIVE_MODIFIER_TRIGGER) {
        out.producer = 175;
        out.domain = command.domain;
        out.scope = ModifierApi::ENTITY;
        out.entity_handle = command.target_handle;
        out.source_type = 0x54524947474552ULL; // TRIGGER
        out.source_id = static_cast<uint64_t>(transaction.source_instance_id);
        out.magnitude_q16 = static_cast<int32_t>(std::clamp<int64_t>(
            scaled_magnitude(command.value_q16), 0, EFFECT_MAX_MAGNITUDE_Q16));
    } else if (adapter_kind == NATIVE_MODIFIER_FAMILY_EFFECT) {
        out.producer = 161;
        out.domain = command.domain;
        out.source_type = 0x46414d4546464543ULL; // FAMEFFEC
        out.source_id = static_cast<uint64_t>(source_instance.id);
        out.magnitude_q16 = static_cast<int32_t>(std::clamp<int64_t>(
            scaled_magnitude(command.value_q16), 0, EFFECT_MAX_MAGNITUDE_Q16));
        switch (source_instance.target_domain) {
            case 0: // Family.
            case 1: // Branch.
                out.scope = ModifierApi::ENTITY;
                out.entity_handle = command.target_handle;
                break;
            case 2: // Settlement cell.
            case 5: // Building/resource selector within the cell.
                out.scope = ModifierApi::GROUP;
                out.group_handle = command.target_handle;
                break;
            case 3: // Country.
            case 4: // Climate cell.
                out.scope = ModifierApi::ENTITY;
                out.entity_handle = command.target_handle;
                break;
            default:
                return false;
        }
    } else if (adapter_kind == NATIVE_MODIFIER_IDEOLOGY) {
        out.producer = 162;
        out.domain = command.domain;
        out.source_type = 0x4944454fULL; // IDEO
        out.source_id = static_cast<uint64_t>(source_instance.id);
        out.magnitude_q16 = static_cast<int32_t>(std::clamp<int64_t>(
            scaled_magnitude(command.value_q16), 0, EFFECT_MAX_MAGNITUDE_Q16));
        // X9-b family programs carry the stable family handle in ENTITY;
        // cell/resource programs (2/5) carry a cell in GROUP. Both
        // handles must not be set: Modifier's scope_id_for() would read
        // the family handle as a settlement group while scope is GROUP.
        switch (source_instance.target_domain) {
            case 0: // Family.
                out.scope = ModifierApi::ENTITY;
                out.entity_handle = command.target_handle;
                out.group_handle = 0;
                break;
            case 2: // Settlement cell.
            case 5: // Building/resource selector within the cell.
                out.scope = ModifierApi::GROUP;
                out.entity_handle = command.target_handle;
                out.group_handle = command.target_handle;
                break;
            default:
                out.scope = ModifierApi::ENTITY;
                out.entity_handle = command.target_handle;
                out.group_handle = 0;
                break;
        }
        // Command-level scope override. payload[2] == 0 means "unset",
        // never GLOBAL -- GLOBAL is also 0, so defaulting would silently
        // widen a cell effect to the whole country.
        if (command.payload[2] >= 1 && command.payload[2] <= 2) {
            out.scope = static_cast<int32_t>(command.payload[2]);
            out.group_handle = out.scope == ModifierApi::GROUP
                ? command.target_handle : 0;
        }
    } else if (command.action == MODIFIER_COMMAND) {
        // Generic declarative Modifier command. Complex target/source
        // resolvers stay on the adapter path until declared natively.
        // This is the branch SYNERGY rows take: their command's owner_program_id
        // is -1, so `native_modifier_adapter` stays NATIVE_MODIFIER_GENERIC
        // (see the assignment at :1124-1132) and the IDEOLOGY branch below is
        // never reached for them.
        out.producer = 200;
        out.domain = command.domain;
        out.scope = ModifierApi::ENTITY;
        out.entity_handle = command.target_handle;
        out.source_type = static_cast<uint64_t>(source_instance.source_type);
        // A command may carry its own stable identity; synergy rows do
        // (`ExternalEffectCommandPod::stable_source_identity`). This matters
        // because a synergy's apply and its later deactivation are enqueued as
        // SEPARATE batches naming DIFFERENT generations (`:3629-3636`), so
        // `source_instance->source_id` -- the batch's transition source -- can
        // never be equal for the two. With it equal, ModifierRuntime could not
        // find the row and answered `already_removed`, leaking the effect
        // permanently (measured: factors stayed at 0.95/1.03 after the bond died).
        out.source_id = command.external_source_is_stable &&
                command.external_source_id != 0
            ? static_cast<uint64_t>(command.external_source_id)
            : static_cast<uint64_t>(source_instance.source_id);
        out.magnitude_q16 = static_cast<int32_t>(std::clamp<int64_t>(
            scaled_magnitude(command.value_q16), 0, EFFECT_MAX_MAGNITUDE_Q16));
    } else {
        return false;
    }
    return true;
}

const EffectRuntime::ModifierBinding *EffectRuntime::worker_modifier_binding(
        int32_t index) const {
    if (index < 0 || index >= static_cast<int32_t>(_split_settle_bindings.size()))
        return nullptr;
    return &_split_settle_bindings[static_cast<size_t>(index)];
}

const EffectRuntime::ModifierRow *EffectRuntime::worker_modifier_row(
        int32_t index) const {
    if (index < 0 || index >= static_cast<int32_t>(_split_settle_rows.size()))
        return nullptr;
    return &_split_settle_rows[static_cast<size_t>(index)];
}

std::vector<EffectRuntime::ModifierRow> EffectRuntime::collect_worker_modifier_rows(
        int64_t day_index, std::vector<ModifierBinding> &out_bindings) {
    out_bindings.clear();
    if (!_configured) return {};
    const size_t ledger_begin = _split_settle_rows.size();
    for (Transaction &transaction : _transactions) {
        if (transaction.status == ACKED || transaction.status == REJECTED ||
            transaction.status == RESYNC_REQUIRED)
            continue;
        const int32_t source_index = instance_index_for_id(transaction.source_instance_id);
        if (source_index < 0 ||
            source_index >= static_cast<int32_t>(_instances.size()))
            continue;
        const Instance &source = _instances[static_cast<size_t>(source_index)];
        if (source.source_type != IDEOLOGY_SOURCE_TYPE) continue;
        if (source.generation != transaction.source_generation) continue;
        if (transaction.command_count == 0 || transaction.required_ack_mask == 0)
            continue;
        // Already handed to the worker: re-collecting it would enqueue the same
        // row a second time, and an INDEPENDENT stack policy applies that as a
        // second stack (the measured 1.03 -> 1.0609 double-add defect).
        bool bound = false;
        for (const ModifierBinding &binding : _split_settle_bindings) {
            if (binding.transaction_id == transaction.id) { bound = true; break; }
        }
        if (bound) continue;
        const size_t row_begin = _split_settle_rows.size();
        uint32_t domain_mask = 0;
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) continue;
            if (command->action != MODIFIER_COMMAND) continue;
            if ((transaction.received_ack_mask & adapter_ack_bit_for(*command)) != 0)
                continue;
            ModifierRow row;
            if (!map_modifier_row(transaction, source, *command, row)) continue;
            domain_mask |= row.domain_bit;
            _split_settle_rows.push_back(std::move(row));
        }
        const int32_t row_count =
            static_cast<int32_t>(_split_settle_rows.size() - row_begin);
        if (row_count == 0 || domain_mask == 0) {
            _split_settle_rows.resize(row_begin);
            continue;
        }
        // COMMITTED, not PLANNED: the transaction is on its way to the worker and
        // must not be re-planned. The ACK bit lands when the worker proves the
        // rows are in its committed Modifier store.
        transaction.status = COMMITTED;
        ModifierBinding binding;
        binding.transaction_id = transaction.id;
        binding.domain_bit = domain_mask;
        binding.row_begin = static_cast<int32_t>(row_begin);
        binding.row_count = row_count;
        binding.submitted_day = day_index;
        _split_settle_bindings.push_back(binding);
        out_bindings.push_back(binding);
    }
    return std::vector<ModifierRow>(
        _split_settle_rows.begin() + static_cast<std::ptrdiff_t>(ledger_begin),
        _split_settle_rows.end());
}

int32_t EffectRuntime::acknowledge_worker_modifier_rows(
        const std::vector<int64_t> &transaction_ids) {
    return finish_worker_modifier_bindings(transaction_ids, true);
}

void EffectRuntime::discard_worker_modifier_rows(
        const std::vector<int64_t> &transaction_ids) {
    finish_worker_modifier_bindings(transaction_ids, false);
}

int32_t EffectRuntime::finish_worker_modifier_bindings(
        const std::vector<int64_t> &transaction_ids, bool confirm) {
    if (!_configured || _split_settle_bindings.empty()) return 0;
    int32_t completed = 0;
    std::vector<ModifierBinding> retained;
    retained.reserve(_split_settle_bindings.size());
    for (const ModifierBinding &binding : _split_settle_bindings) {
        const int32_t tx_index = transaction_index_for_id(binding.transaction_id);
        const bool named = std::find(transaction_ids.begin(),
            transaction_ids.end(), binding.transaction_id) != transaction_ids.end();
        if (!named) {
            // A transaction that is gone can never complete; dropping its ledger
            // row is what stops the settle from pinning rows forever.
            if (tx_index >= 0) retained.push_back(binding);
            continue;
        }
        if (tx_index >= 0 &&
            tx_index < static_cast<int32_t>(_transactions.size())) {
            Transaction &transaction = _transactions[static_cast<size_t>(tx_index)];
            if (transaction.status != ACKED && transaction.status != REJECTED &&
                transaction.status != RESYNC_REQUIRED) {
                if (confirm) {
                    acknowledge_native_domain(transaction, binding.domain_bit);
                    if (transaction.status == ACKED) ++completed;
                } else {
                    transaction.status = PLANNED;
                }
            }
        }
    }
    std::vector<ModifierRow> retained_rows;
    retained_rows.reserve(_split_settle_rows.size());
    std::vector<ModifierBinding> rebased;
    rebased.reserve(retained.size());
    for (const ModifierBinding &binding : retained) {
        ModifierBinding kept = binding;
        kept.row_begin = static_cast<int32_t>(retained_rows.size());
        for (int32_t offset = 0; offset < binding.row_count; ++offset) {
            const int32_t src = binding.row_begin + offset;
            if (src < 0 ||
                src >= static_cast<int32_t>(_split_settle_rows.size()))
                continue;
            retained_rows.push_back(_split_settle_rows[static_cast<size_t>(src)]);
        }
        kept.row_count =
            static_cast<int32_t>(retained_rows.size()) - kept.row_begin;
        rebased.push_back(kept);
    }
    _split_settle_rows.swap(retained_rows);
    _split_settle_bindings.swap(rebased);
    if (completed != 0) compact_terminal_transactions();
    return completed;
}

} // namespace pk
