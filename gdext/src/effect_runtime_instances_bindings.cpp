#include "effect_runtime_instances_includes.inc"

namespace pk {
using namespace godot;

bool EffectRuntime::upsert_instance_pod(int64_t instance_id,
                                        const std::string &program_key,
                                        uint32_t generation,
                                        int32_t source_type,
                                        int64_t source_id,
                                        uint64_t source_handle,
                                        uint64_t target_handle,
                                        uint32_t target_generation,
                                        int32_t level,
                                        int64_t next_due_day,
                                        bool active,
                                        std::string &error) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    if (instance_id <= 0 || generation == 0) {
        error = "effect_instance_identity_invalid"; return false;
    }
    const int32_t program_id = definition_id_for_key(program_key);
    if (program_id < 0) { error = "effect_program_unknown"; return false; }
    int32_t index = instance_index_for_id(instance_id);
    const bool created = index < 0;
    bool had_family_group = false;
    FamilyEffectGroupKey previous_group;
    if (index >= 0 && index < static_cast<int32_t>(_instances.size()) &&
        is_family_effect_instance(_instances[static_cast<size_t>(index)])) {
        had_family_group = true;
        previous_group = family_effect_group_key(
            _instances[static_cast<size_t>(index)]);
    }
    if (index < 0) {
        if (static_cast<int32_t>(_instance_ids.size()) >= _max_instances) {
            ++_overflow_count; error = "effect_instance_capacity_exceeded"; return false;
        }
        if (!_free_instance_indices.empty()) {
            index = _free_instance_indices.back();
            _free_instance_indices.pop_back();
            Instance &slot = _instances[static_cast<size_t>(index)];
            const uint32_t metric_base = slot.metric_base;
            slot = Instance{};
            slot.metric_base = metric_base;
            std::fill(_metric_values.begin() + metric_base,
                      _metric_values.begin() + metric_base + _metric_count, 0);
            std::fill(_metric_present.begin() + metric_base,
                      _metric_present.begin() + metric_base + _metric_count, 0);
        } else {
            Instance instance;
            instance.metric_base = static_cast<uint32_t>(_metric_values.size());
            _metric_values.resize(_metric_values.size() + static_cast<size_t>(_metric_count), 0);
            _metric_present.resize(_metric_present.size() + static_cast<size_t>(_metric_count), 0);
            _instances.push_back(std::move(instance));
            index = static_cast<int32_t>(_instances.size() - 1);
        }
        Instance &slot = _instances[static_cast<size_t>(index)];
        slot.id = instance_id;
        slot.generation = generation;
        slot.program_id = program_id;
        _instance_ids[instance_id] = index;
    }
    Instance &instance = _instances[static_cast<size_t>(index)];
    const int32_t previous_program_id = instance.program_id;
    const int32_t previous_level = instance.level;
    const bool generation_changed = instance.generation != generation;
    const bool level_changed = !created && previous_level != level;
    instance.generation = generation;
    instance.program_id = program_id;
    instance.source_type = source_type;
    instance.source_id = source_id;
    instance.source_handle = source_handle;
    instance.target_handle = target_handle;
    instance.target_generation = target_generation;
    instance.level = level;
    instance.next_due_day = next_due_day;
    instance.active = active ? 1 : 0;
    const Definition &definition = _definitions[static_cast<size_t>(program_id)];
    const bool new_binding = created || generation_changed ||
        previous_program_id != program_id;
    instance.source_kind = definition.source_kind;
    instance.target_domain = definition.target_domain;
    instance.operation = definition.operation;
    instance.lifecycle = definition.lifecycle;
    instance.duration_days = definition.duration_days;
    instance.stack_policy = definition.stack_policy;
    instance.max_stacks = definition.max_stacks;
    instance.priority = definition.priority;
    instance.stack_key_hash = fnv_string(1469598103934665603ULL,
        definition.stack_key.empty() ? definition.key : definition.stack_key);
    if (new_binding) {
        instance.effect_applied = 0;
        instance.retire_requested = 0;
        instance.applied_stack_count = 0;
        instance.applied_input_revision = 0;
        instance.last_acked_fire_sequence = 0;
        instance.activation_sequence = _next_activation_sequence++;
    } else if (level_changed) {
        instance.last_evaluated_input_revision = 0;
    }
    // Upsert is structural reconciliation, not an activation event. Repeating
    // the same authoritative row must therefore be idempotent for every stack
    // policy. Event/random/player ingress supplies an explicit stack count via
    // submit_instances instead of turning daily reconciliation into ADD_STACK.
    if (new_binding) instance.stack_count = 1;
    else instance.stack_count = std::clamp(instance.stack_count, 1,
                                           definition.max_stacks);
    // A reconciliation/upsert must not refresh a running duration. Expiry is
    // anchored to the first binding generation; only a new generation or
    // program binding receives a fresh lifetime.
    if (definition.lifecycle == 1 &&
        (new_binding || instance.expires_day < 0)) {
        instance.expires_day = next_due_day +
            static_cast<int64_t>(definition.duration_days);
    } else if (definition.lifecycle != 1) {
        instance.expires_day = -1;
    }
    if (generation_changed) {
        for (Transaction &transaction : _transactions) {
            if (transaction.source_instance_id == instance.id &&
                transaction.source_generation != generation &&
                transaction.status != ACKED && transaction.status != REJECTED) {
                untrack_pending_transaction(transaction);
                unindex_transaction_commands(transaction);
                transaction.status = REJECTED;
                apply_rejected_instance_transition(transaction);
                ++_preflight_rejects;
            }
        }
        instance.fire_sequence = 0;
        instance.input_revision = 0;
        instance.last_evaluated_input_revision = 0;
        instance.effect_applied = 0;
        instance.retire_requested = 0;
        instance.applied_stack_count = 0;
        instance.applied_input_revision = 0;
        instance.last_acked_fire_sequence = 0;
        std::fill(_metric_present.begin() + instance.metric_base,
                  _metric_present.begin() + instance.metric_base + _metric_count, 0);
    }
    const bool has_family_group = is_family_effect_instance(instance);
    const FamilyEffectGroupKey current_group = has_family_group
        ? family_effect_group_key(instance) : FamilyEffectGroupKey{};
    if (had_family_group && (!has_family_group ||
        !(previous_group == current_group))) {
        const auto previous = _family_effect_groups.find(previous_group);
        if (previous != _family_effect_groups.end())
            for (const int32_t member : previous->second) mark_dirty(member);
        remove_family_effect_group_member(index, previous_group);
    }
    if (has_family_group) add_family_effect_group_member(index);
    mark_family_effect_group_dirty(index);
    schedule_instance(index, instance.next_due_day);
    _run_cursor = 0;
    advance_committed_generation();
    ++_instances_submitted;
    return true;
}

bool EffectRuntime::has_instance_pod(int64_t instance_id, uint32_t generation) const {
    const int32_t index = instance_index_for_id(instance_id);
    return index >= 0 && index < static_cast<int32_t>(_instances.size()) &&
        _instances[static_cast<size_t>(index)].generation == generation;
}

bool EffectRuntime::upsert_external_binding_pod(
        int64_t binding_id, uint32_t generation, int32_t source_type,
        int64_t source_id, uint64_t target_handle, uint32_t target_generation,
        int32_t level, uint8_t location, uint64_t template_signature,
        uint64_t program_hash, std::string &error) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    if (binding_id <= 0 || generation == 0 || target_handle == 0 ||
        target_generation == 0 || level < -1 || location > 2) {
        error = "effect_external_binding_invalid";
        return false;
    }
    const auto found = _external_binding_ids.find(binding_id);
    if (found != _external_binding_ids.end()) {
        ExternalSourceBinding &binding = _external_bindings[
            static_cast<size_t>(found->second)];
        // A rejected transition may roll a stable external identity back to
        // its previously durable generation.  This is safe only after that
        // binding was explicitly retired: an active binding must remain
        // monotonic so no live source can be overwritten by a stale command.
        if (binding.generation != generation && generation < binding.generation &&
            binding.active != 0) {
            error = "effect_external_binding_generation_regressed";
            return false;
        }
        binding.generation = generation;
        binding.source_type = source_type;
        binding.source_id = source_id;
        binding.target_handle = target_handle;
        binding.target_generation = target_generation;
        binding.level = level;
        binding.location = location;
        binding.active = 1;
        binding.template_signature = template_signature;
        binding.program_hash = program_hash;
        advance_committed_generation();
        return true;
    }
    if (static_cast<int32_t>(_external_bindings.size()) >= _max_instances) {
        ++_overflow_count;
        error = "effect_external_binding_capacity_exceeded";
        return false;
    }
    ExternalSourceBinding binding;
    binding.binding_id = binding_id;
    binding.generation = generation;
    binding.source_type = source_type;
    binding.source_id = source_id;
    binding.target_handle = target_handle;
    binding.target_generation = target_generation;
    binding.level = level;
    binding.location = location;
    binding.active = 1;
    binding.template_signature = template_signature;
    binding.program_hash = program_hash;
    _external_binding_ids[binding_id] = static_cast<int32_t>(_external_bindings.size());
    _external_bindings.push_back(binding);
    advance_committed_generation();
    return true;
}

bool EffectRuntime::retire_external_binding_pod(int64_t binding_id,
                                                uint32_t generation,
                                                std::string &error) {
    const auto found = _external_binding_ids.find(binding_id);
    if (found == _external_binding_ids.end()) {
        error = "effect_external_binding_unknown";
        return false;
    }
    ExternalSourceBinding &binding = _external_bindings[
        static_cast<size_t>(found->second)];
    if (binding.generation != generation) {
        error = "effect_external_binding_generation_mismatch";
        return false;
    }
    if (binding.active != 0) {
        binding.active = 0;
        advance_committed_generation();
    }
    return true;
}

bool EffectRuntime::has_external_binding_pod(int64_t binding_id,
                                             uint32_t generation,
                                             int32_t source_type,
                                             int64_t source_id,
                                             uint64_t target_handle,
                                             uint32_t target_generation,
                                             int32_t level,
                                             uint8_t location,
                                             uint64_t template_signature,
                                             uint64_t program_hash) const {
    const auto found = _external_binding_ids.find(binding_id);
    if (found == _external_binding_ids.end()) return false;
    const ExternalSourceBinding &binding = _external_bindings[
        static_cast<size_t>(found->second)];
    return binding.active != 0 && binding.generation == generation &&
        binding.source_type == source_type && binding.source_id == source_id &&
        binding.target_handle == target_handle &&
        binding.target_generation == target_generation && binding.level == level &&
        binding.location == location &&
        binding.template_signature == template_signature &&
        binding.program_hash == program_hash;
}

bool EffectRuntime::verify_external_pending_transactions_pod(
        int32_t source_type, uint64_t target_handle, uint64_t source_id_mask,
        const std::vector<int64_t> &expected_transaction_ids,
        const std::vector<uint64_t> &expected_source_ids,
        std::string &error) const {
    if (target_handle == 0 || source_id_mask == 0 ||
        expected_transaction_ids.size() != expected_source_ids.size()) {
        error = "effect_external_pending_audit_invalid";
        return false;
    }
    std::unordered_map<int64_t, uint64_t> expected;
    expected.reserve(expected_transaction_ids.size());
    for (size_t i = 0; i < expected_transaction_ids.size(); ++i) {
        const int64_t transaction_id = expected_transaction_ids[i];
        const uint64_t source_id = expected_source_ids[i] & source_id_mask;
        if (transaction_id <= 0 || source_id == 0 ||
            !expected.emplace(transaction_id, source_id).second) {
            error = "effect_external_pending_expected_invalid";
            return false;
        }
    }
    auto source_for = [&](const Transaction &transaction) -> const Instance * {
        const int32_t index = instance_index_for_id(transaction.source_instance_id);
        if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return nullptr;
        const Instance &instance = _instances[static_cast<size_t>(index)];
        return instance.source_type == source_type &&
            instance.target_handle == target_handle ? &instance : nullptr;
    };
    for (const auto &entry : expected) {
        const int32_t transaction_index = transaction_index_for_id(entry.first);
        if (transaction_index < 0 ||
            transaction_index >= static_cast<int32_t>(_transactions.size())) {
            error = "effect_external_pending_transaction_missing";
            return false;
        }
        const Transaction &transaction = _transactions[
            static_cast<size_t>(transaction_index)];
        if (transaction.status != PLANNED && transaction.status != PREFLIGHTED &&
            transaction.status != COMMITTED) {
            error = "effect_external_pending_transaction_terminal";
            return false;
        }
        const Instance *instance = source_for(transaction);
        if (instance == nullptr ||
            (static_cast<uint64_t>(instance->source_id) & source_id_mask) !=
                entry.second) {
            error = "effect_external_pending_source_mismatch";
            return false;
        }
    }
    for (const Transaction &transaction : _transactions) {
        if (transaction.status != PLANNED && transaction.status != PREFLIGHTED &&
            transaction.status != COMMITTED)
            continue;
        const Instance *instance = source_for(transaction);
        if (instance == nullptr) continue;
        const auto found = expected.find(transaction.id);
        if (found == expected.end() ||
            (static_cast<uint64_t>(instance->source_id) & source_id_mask) !=
                found->second) {
            error = "effect_external_pending_transaction_unknown";
            return false;
        }
    }
    return true;
}

bool EffectRuntime::instance_fire_acked_pod(int64_t instance_id,
                                            uint32_t generation) const {
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return false;
    const Instance &instance = _instances[static_cast<size_t>(index)];
    if (instance.generation != generation || instance.fire_sequence == 0) return false;
    if (instance.last_acked_fire_sequence >= instance.fire_sequence) return true;
    // A fire is domain-complete when nothing is still in flight. ACKED rows may
    // already have been compacted, so fire_sequence is the durable evidence of
    // a successful path. REJECTED rows must not poison a later ACKED fire.
    bool saw_acked = false;
    bool saw_rejected = false;
    for (const Transaction &transaction : _transactions) {
        if (transaction.source_instance_id != instance_id ||
            transaction.source_generation != generation) continue;
        if (transaction.status != ACKED && transaction.status != REJECTED) return false;
        if (transaction.status == ACKED) saw_acked = true;
        else saw_rejected = true;
    }
    if (saw_acked) return true;
    if (saw_rejected) return false;
    return true;
}

bool EffectRuntime::nudge_unacked_instance_pod(int64_t instance_id,
                                               uint32_t generation,
                                               int64_t day_index) {
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return false;
    Instance &instance = _instances[static_cast<size_t>(index)];
    if (instance.generation != generation || instance.active == 0) return false;
    if (instance_fire_acked_pod(instance_id, generation)) return true;
    instance.next_due_day = day_index;
    mark_family_effect_group_dirty(index);
    schedule_instance(index, day_index);
    advance_committed_generation();
    return true;
}

} // namespace pk
