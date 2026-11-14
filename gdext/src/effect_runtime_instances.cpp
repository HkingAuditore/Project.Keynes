#include "effect_runtime.h"
#include "country_api.h"
#include "economy_api.h"
#include "modifier_api.h"
#include "effect_runtime_internal.h"

namespace pk {

using namespace godot;

int64_t *EffectRuntime::metric_ptr(Instance &instance, int32_t metric_id) {
    if (metric_id < 0 || metric_id >= _metric_count) return nullptr;
    const size_t offset = static_cast<size_t>(instance.metric_base) +
        static_cast<size_t>(metric_id);
    return offset < _metric_values.size() ? &_metric_values[offset] : nullptr;
}

const int64_t *EffectRuntime::metric_ptr(const Instance &instance,
                                         int32_t metric_id) const {
    if (metric_id < 0 || metric_id >= _metric_count) return nullptr;
    const size_t offset = static_cast<size_t>(instance.metric_base) +
        static_cast<size_t>(metric_id);
    return offset < _metric_values.size() ? &_metric_values[offset] : nullptr;
}

void EffectRuntime::schedule_instance(int32_t index, int64_t day) {
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return;
    Instance &instance = _instances[static_cast<size_t>(index)];
    if (!instance.active || instance.generation == 0) return;
    const uint64_t token = _schedule_token++;
    instance.schedule_token = token;
    _due_heap.push({day, index, instance.generation, token});
    compact_due_heap_if_needed();
}

void EffectRuntime::mark_dirty(int32_t index) {
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return;
    if (_dirty_epoch_counter == 0) {
        for (Instance &instance : _instances) instance.dirty_epoch = 0;
        _dirty_epoch_counter = 1;
    }
    Instance &instance = _instances[static_cast<size_t>(index)];
    if (instance.dirty_epoch == _dirty_epoch_counter) return;
    instance.dirty_epoch = _dirty_epoch_counter;
    _dirty_queue.push_back(index);
}

int32_t EffectRuntime::instance_index_for_id(int64_t id) const {
    auto it = _instance_ids.find(id);
    return it == _instance_ids.end() ? -1 : it->second;
}

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

bool EffectRuntime::set_metric_pod(int64_t instance_id, int32_t metric_id,
                                   int64_t revision, int64_t value_q16,
                                   std::string &error) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0) { error = "effect_instance_unknown"; return false; }
    if (metric_id < 0 || metric_id >= _metric_count) {
        error = "effect_snapshot_metric_invalid"; return false;
    }
    Instance &instance = _instances[static_cast<size_t>(index)];
    // Two different questions, two different fields:
    //   staleness -- is this snapshot older than one already consumed?
    //   change    -- does this publish alter a value any consumer reads?
    // A frozen snapshot is published column by column, so equal revisions are
    // part of the same atomic logical row and must still be written; only
    // genuinely older snapshots are stale.
    if (revision < instance.metric_observed_revision) return true;
    if (revision > instance.metric_observed_revision)
        instance.metric_observed_revision = revision;
    int64_t *metric = metric_ptr(instance, metric_id);
    if (metric == nullptr) { error = "effect_snapshot_metric_invalid"; return false; }
    const size_t present_offset = static_cast<size_t>(instance.metric_base) +
        static_cast<size_t>(metric_id);
    const bool present = present_offset < _metric_present.size() &&
        _metric_present[present_offset] != 0;
    // An unchanged value is not an input change. Returning before the
    // watermark moves is what stops a daily re-publish from creating one
    // transaction per instance per day (P1-C).
    if (present && *metric == value_q16) return true;
    *metric = value_q16;
    if (present_offset < _metric_present.size()) _metric_present[present_offset] = 1;
    if (revision > instance.input_revision) {
        instance.input_revision = revision;
        mark_family_effect_group_dirty(index);
    }
    advance_committed_generation();
    return true;
}

bool EffectRuntime::instance_metric_pod(int64_t instance_id, int32_t metric_id,
                                       int64_t &out_value, bool &out_present) const {
    out_value = 0;
    out_present = false;
    if (!_configured) return false;
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0) return false;
    if (metric_id < 0 || metric_id >= _metric_count) return false;
    const Instance &instance = _instances[static_cast<size_t>(index)];
    const int64_t *value = metric_ptr(instance, metric_id);
    if (value == nullptr) return false;
    out_value = *value;
    const size_t offset = static_cast<size_t>(instance.metric_base) +
        static_cast<size_t>(metric_id);
    out_present = offset < _metric_present.size() && _metric_present[offset] != 0;
    return true;
}

bool EffectRuntime::set_instance_expiry_pod(int64_t instance_id,
                                            uint32_t generation,
                                            int64_t expires_day) {
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) return false;
    Instance &instance = _instances[static_cast<size_t>(index)];
    // A stale generation must not retarget the live instance's expiry: the
    // caller resolved this row against a different incarnation.
    if (instance.generation != generation) return false;
    instance.expires_day = expires_day;
    advance_committed_generation();
    return true;
}

bool EffectRuntime::uses_managed_lifecycle(const Definition &definition) {
    return definition.lifecycle != 0 || definition.managed_declared;
}

bool EffectRuntime::is_family_effect_instance(const Instance &instance) const {
    return instance.program_id >= 0 &&
        instance.program_id < static_cast<int32_t>(_definitions.size()) &&
        instance.operation != 4 &&
        _definitions[static_cast<size_t>(instance.program_id)]
            .managed_declared;
}

EffectRuntime::FamilyEffectGroupKey EffectRuntime::family_effect_group_key(
        const Instance &instance) const {
    return {instance.target_domain, instance.target_handle,
            instance.target_generation, instance.stack_key_hash};
}

void EffectRuntime::add_family_effect_group_member(int32_t instance_index) {
    if (instance_index < 0 ||
        instance_index >= static_cast<int32_t>(_instances.size()) ||
        !is_family_effect_instance(_instances[static_cast<size_t>(instance_index)]))
        return;
    auto &members = _family_effect_groups[family_effect_group_key(
        _instances[static_cast<size_t>(instance_index)])];
    if (std::find(members.begin(), members.end(), instance_index) == members.end())
        members.push_back(instance_index);
}

void EffectRuntime::remove_family_effect_group_member(
        int32_t instance_index, const FamilyEffectGroupKey &key) {
    auto found = _family_effect_groups.find(key);
    if (found == _family_effect_groups.end()) return;
    auto &members = found->second;
    members.erase(std::remove(members.begin(), members.end(), instance_index),
                  members.end());
    if (members.empty()) _family_effect_groups.erase(found);
}

void EffectRuntime::rebuild_family_effect_groups() {
    _family_effect_groups.clear();
    for (int32_t index = 0; index < static_cast<int32_t>(_instances.size()); ++index)
        if (_instances[static_cast<size_t>(index)].id > 0)
            add_family_effect_group_member(index);
}

void EffectRuntime::mark_family_effect_group_dirty(int32_t instance_index) {
    if (instance_index < 0 ||
        instance_index >= static_cast<int32_t>(_instances.size())) return;
    const Instance &instance = _instances[static_cast<size_t>(instance_index)];
    if (!is_family_effect_instance(instance)) {
        mark_dirty(instance_index);
        return;
    }
    const auto found = _family_effect_groups.find(
        family_effect_group_key(instance));
    if (found == _family_effect_groups.end()) {
        mark_dirty(instance_index);
        return;
    }
    for (const int32_t member : found->second) mark_dirty(member);
}

bool EffectRuntime::preview_family_effect_value(
        const Definition &definition, const Instance &instance,
        int64_t &value, std::string &error) const {
    // Bind both accessors to this instance and delegate. `state_value` reads the
    // instance's latched STATE words, which a caller without an instance has no
    // equivalent for -- the derived layer passes a constant 0 accessor, which is
    // correct because a program reading STATE is not eligible for DerivedCell in
    // the first place (`state_dependent` in cell_program_eligibility.h).
    return run_program_machine(
        definition,
        [this, &instance](int32_t metric_id) {
            return metric_value(instance, metric_id);
        },
        [this, &instance](int32_t state_id) {
            return state_value(instance, state_id);
        },
        value, error);
}

bool EffectRuntime::retire_instance_pod(int64_t instance_id,
                                        uint32_t generation,
                                        int64_t effective_day,
                                        std::string &error) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    const int32_t index = instance_index_for_id(instance_id);
    if (index < 0 || index >= static_cast<int32_t>(_instances.size())) {
        // No Effect instance means no Effect-owned Modifier was committed.
        return true;
    }
    Instance &instance = _instances[static_cast<size_t>(index)];
    if (instance.generation != generation) {
        error = "effect_instance_generation_stale";
        return false;
    }
    if (instance.active == 0) return true;
    if (instance.retire_requested != 0) return true;
    const auto pending = _pending_transactions_by_instance.find(instance.id);
    if (pending != _pending_transactions_by_instance.end() &&
        pending->second > 0) {
        instance.retire_requested = 1;
        instance.next_due_day = std::max<int64_t>(
            instance.next_due_day, effective_day + 1);
        mark_family_effect_group_dirty(index);
        schedule_instance(index, instance.next_due_day);
        return true;
    }
    return create_retirement_transaction(index, effective_day, error);
}

bool EffectRuntime::enqueue_trigger_effect_pod(
        int64_t effect_id, int64_t effective_day, int32_t trigger_id,
        uint64_t target_handle, uint32_t target_generation,
        uint64_t fire_sequence, int32_t action, int32_t domain, int32_t opcode,
        int64_t resolved_value, int32_t duration_days, int32_t stacks,
        const std::string &command_key, const std::string &definition_key,
        const std::array<int64_t, 4> &payload, std::string &error) {
    const std::string program_key = action == COUNTRY_COMMAND
        ? std::string("trigger.country.") + definition_key
        : action == ECONOMY_COMMAND
            ? std::string("trigger.economy.") + command_key
            : std::string("trigger.modifier.") + definition_key;
    return enqueue_external_effect_pod(effect_id, effective_day, 0x54524947,
        trigger_id, program_key, target_handle,
        target_handle, target_generation, fire_sequence, action, domain, opcode,
        resolved_value, duration_days, stacks, command_key, definition_key, payload, error);
}

uint64_t EffectRuntime::family_colonization_settle_idempotency_key(
        int64_t effect_id, uint32_t expedition_generation,
        uint64_t fire_sequence) const {
    return make_hash(static_cast<uint64_t>(effect_id), expedition_generation,
                     fire_sequence, 1);
}

bool EffectRuntime::enqueue_canal_commit_pod(
        int64_t effect_id, int64_t effective_day, int64_t source_id,
        uint64_t project_handle, uint32_t project_generation,
        uint64_t fire_sequence, std::string &error,
        int64_t *out_transaction_id) {
    if (!_configured) { error = "effect_runtime_unconfigured"; return false; }
    if (effect_id <= 0 || effective_day < 0 || source_id <= 0 ||
        project_handle == 0 || project_generation == 0) {
        error = "canal_effect_shape_invalid";
        return false;
    }
    const uint64_t idempotency = make_hash(static_cast<uint64_t>(effect_id),
        project_generation, fire_sequence, 0x43414e4cU);
    for (const Transaction &existing : _transactions) {
        const Command *first = command_at(existing, 0);
        if (first != nullptr && first->idempotency_key == idempotency) {
            if (out_transaction_id != nullptr) *out_transaction_id = existing.id;
            return true;
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
    transaction.id = _next_transaction_id++;
    transaction.source_instance_id = source_id;
    transaction.source_generation = project_generation;
    transaction.program_id = -2;
    transaction.effective_day = effective_day;

    Command commit;
    commit.action = CUSTOM_DOMAIN_COMMAND;
    commit.domain = 6;
    commit.opcode = 2; // geography.canal.commit
    commit.target_handle = project_handle;
    commit.target_generation = project_generation;
    commit.command_key_id = -1;
    commit.command_definition_id = -1;
    commit.idempotency_key = idempotency;
    append_command(transaction, commit);
    if (transaction.command_count != 1) {
        error = "canal_effect_transaction_capacity_exceeded";
        return false;
    }
    transaction.plan_hash = 1469598103934665603ULL;
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.id);
    transaction.plan_hash = fnv_value(transaction.plan_hash, transaction.effective_day);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.action);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.domain);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.opcode);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.target_handle);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.target_generation);
    transaction.plan_hash = fnv_value(transaction.plan_hash, commit.idempotency_key);
    _transactions.push_back(std::move(transaction));
    _transaction_ids[_transactions.back().id] =
        static_cast<int32_t>(_transactions.size() - 1);
    track_pending_transaction(_transactions.back());
    index_transaction_commands(_transactions.back());
    if (out_transaction_id != nullptr) *out_transaction_id = _transactions.back().id;
    return true;
}

int32_t EffectRuntime::transaction_status_pod(int64_t transaction_id) const {
    const int32_t index = transaction_index_for_id(transaction_id);
    if (index >= 0 && index < static_cast<int32_t>(_transactions.size()))
        return _transactions[static_cast<size_t>(index)].status;
    return transaction_id > 0 && transaction_id <= _acked_transaction_id ? ACKED : 0;
}

bool EffectRuntime::consume_rejected_transaction_pod(
        int64_t transaction_id, int64_t source_id) {
    const int32_t index = transaction_index_for_id(transaction_id);
    if (index < 0 || index >= static_cast<int32_t>(_transactions.size()))
        return false;
    Transaction &transaction = _transactions[static_cast<size_t>(index)];
    if (transaction.source_instance_id != source_id ||
        (transaction.status != REJECTED &&
         transaction.status != RESYNC_REQUIRED)) return false;
    // The producer has converted the failure into its own durable state. Mark
    // the row terminal so the generic arena compactor can retire it without
    // retaining rejected expedition transactions for the rest of the session.
    transaction.status = ACKED;
    compact_terminal_transactions();
    return true;
}

Dictionary EffectRuntime::submit_instances(const Dictionary &batch) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    const PackedInt64Array ids = get_i64(batch, "instance_ids");
    const PackedStringArray program_keys = get_strings(batch, "program_keys");
    const int32_t count = ids.size();
    const PackedInt32Array generations = get_i32(batch, "generations");
    const PackedInt32Array source_types = get_i32(batch, "source_types");
    const PackedInt32Array declared_source_kinds = get_i32(
        batch, "source_kinds");
    const PackedInt64Array source_ids = get_i64(batch, "source_ids");
    const PackedInt64Array source_handles = get_i64(batch, "source_handles");
    const PackedInt64Array target_handles = get_i64(batch, "target_handles");
    const PackedInt32Array target_generations = get_i32(batch, "target_generations");
    const PackedInt32Array levels = get_i32(batch, "levels");
    // Optional per-instance magnitude multiplier (L3-9). Absent means 1.0 for
    // every row, which is exactly the pre-L3-9 behaviour, so no existing caller
    // has to change.
    const PackedInt32Array magnitude_scales = get_i32(batch, "magnitude_scales");
    const PackedInt32Array submitted_stack_counts = get_i32(batch, "stack_counts");
    const PackedInt64Array activation_sequences = get_i64(
        batch, "activation_sequences");
    const PackedInt64Array next_due_days = get_i64(batch, "next_due_days");
    const PackedByteArray active = get_u8(batch, "active");
    // A5: optional latch column. Absent means 0 ("no latch"), which is the
    // pre-existing behaviour for every caller that does not carry one, so no
    // existing batch has to change. A supplied column must match the row count,
    // like the other optional columns, so a truncated column cannot latch the
    // wrong instances.
    const PackedByteArray latched_column = get_u8(batch, "latched");
    if (count <= 0 || count > _max_instances || program_keys.size() != count ||
        (!submitted_stack_counts.is_empty() && submitted_stack_counts.size() != count) ||
        (!activation_sequences.is_empty() && activation_sequences.size() != count) ||
        (!declared_source_kinds.is_empty() && declared_source_kinds.size() != count) ||
        (!magnitude_scales.is_empty() && magnitude_scales.size() != count) ||
        (!latched_column.is_empty() && latched_column.size() != count))
        return failure("effect_instance_columns_invalid");
    int32_t accepted = 0;
    int32_t rejected = 0;
    std::unordered_set<int64_t> batch_ids;
    PackedInt64Array accepted_ids;
    for (int32_t i = 0; i < count; ++i) {
        const int64_t id = ids[i];
        const int32_t program_id = definition_id_for_key(program_keys[i].utf8().get_data());
        if (id <= 0 || program_id < 0 || !batch_ids.emplace(id).second) {
            ++rejected;
            continue;
        }
        const uint32_t generation = static_cast<uint32_t>(std::max(1, i32_at(generations, i, 1)));
        const Definition &definition = _definitions[static_cast<size_t>(program_id)];
        // Shared with the worker transport path via effect_declarative_validation.h.
        // The batch columns are sparse, so read them only when the row exists.
        EffectDeclarativeFacts facts;
        facts.source_kind = definition.source_kind;
        facts.managed_declared = definition.managed_declared;
        const EffectDeclarativeReject declarative = validate_effect_declarative_row(
            facts, id, generation, !declared_source_kinds.is_empty(),
            i < declared_source_kinds.size() ? declared_source_kinds[i] : 0,
            u8_at(active, i, 1) != 0);
        if (declarative != EffectDeclarativeReject::NONE) {
            ++rejected;
            _last_error = effect_declarative_reject_token(declarative);
            continue;
        }
        const bool requested_active = u8_at(active, i, 1) != 0;
        const int32_t previous_index = instance_index_for_id(id);
        const bool was_active = previous_index >= 0 &&
            _instances[static_cast<size_t>(previous_index)].active != 0;
        const uint64_t previous_activation = previous_index >= 0
            ? _instances[static_cast<size_t>(previous_index)].activation_sequence
            : 0;
        const int64_t due_day = i64_at(next_due_days, i,
            _current_day >= 0 ? _current_day : 0);
        std::string error;
        if (!upsert_instance_pod(id, string_at(program_keys, i), generation,
                i32_at(source_types, i, 0), i64_at(source_ids, i, 0),
                static_cast<uint64_t>(i64_at(source_handles, i, 0)),
                static_cast<uint64_t>(i64_at(target_handles, i, 0)),
                static_cast<uint32_t>(std::max(0,
                    i32_at(target_generations, i, 0))),
                i32_at(levels, i, 0), due_day, requested_active, error)) {
            ++rejected;
            _last_error = error;
            continue;
        }
        const int32_t index = instance_index_for_id(id);
        if (index < 0) {
            ++rejected;
            _last_error = "effect_instance_missing_after_upsert";
            continue;
        }
        Instance &instance = _instances[static_cast<size_t>(index)];
        bool arbitration_changed = false;
        if (!submitted_stack_counts.is_empty()) {
            const int32_t requested_stacks = std::clamp(
                submitted_stack_counts[i], 1,
                definition.max_stacks);
            arbitration_changed = arbitration_changed ||
                requested_stacks != instance.stack_count;
            instance.stack_count = requested_stacks;
        }
        if (!magnitude_scales.is_empty()) {
            // Clamped to the same [0.25x, 4x] band the authoring layer enforces.
            // A scale change has to force a re-emit: the instance is already
            // `effect_applied`, and without clearing that flag the new
            // multiplier would sit unused until something else touched the row.
            const int32_t max_scale = static_cast<int32_t>(4 * Q16_ONE);
            const int32_t raw_scale = magnitude_scales[i];
            int32_t requested_scale = std::clamp(
                raw_scale, static_cast<int32_t>(Q16_ONE / 4), max_scale);
            if (definition.target_selector_kind ==
                    SELECTOR_TAG_SOURCE_COUNT) {
                const SourceCountSelector selector =
                    decode_source_count_selector(
                        definition.target_selector_param);
                const int32_t count_min_scale = static_cast<int32_t>(
                    Q16_ONE / std::clamp(selector.cap, 1, 15));
                requested_scale = std::clamp(
                    raw_scale, count_min_scale, max_scale);
            }
            if (requested_scale != instance.magnitude_scale_q16) {
                instance.magnitude_scale_q16 = requested_scale;
                instance.effect_applied = 0;
            }
        }
        if (!latched_column.is_empty()) {
            // A5: carry the evaluating side's latch across an authority flip.
            //
            // Only an explicit column writes it. Absent means "the caller does not
            // own this state", so the instance keeps whatever it had -- which is
            // what keeps a legacy caller from clearing a live latch on every
            // submit. A change does NOT force a re-emit: the latch is an input to
            // the next evaluation, not a command to replay.
            instance.latched = latched_column[i] != 0 ? 1 : 0;
        }
        const uint64_t submitted_activation = activation_sequences.is_empty()
            ? 0 : static_cast<uint64_t>(std::max<int64_t>(
                0, activation_sequences[i]));
        const bool explicit_activation = submitted_activation >
            instance.activation_sequence;
        const bool reactivated = !was_active && requested_active &&
            previous_activation != 0;
        if (explicit_activation) {
            instance.activation_sequence = submitted_activation;
            _next_activation_sequence = std::max(
                _next_activation_sequence, submitted_activation + 1);
            arbitration_changed = true;
        } else if (reactivated) {
            instance.activation_sequence = _next_activation_sequence++;
            arbitration_changed = true;
        }
        if ((explicit_activation || reactivated) &&
            definition.stack_policy == 1 && definition.lifecycle == 1) {
            instance.expires_day = due_day +
                static_cast<int64_t>(definition.duration_days);
        }
        if (arbitration_changed) mark_family_effect_group_dirty(index);
        schedule_instance(index, instance.next_due_day);
        ++accepted;
        accepted_ids.append(id);
    }
    _run_cursor = 0;
    Dictionary out;
    out["ok"] = true;
    out["accepted"] = accepted;
    out["rejected"] = rejected;
    out["instance_ids"] = accepted_ids;
    return out;
}

Dictionary EffectRuntime::submit_snapshots(const Dictionary &batch) {
    if (!_configured) return failure("effect_runtime_unconfigured");
    const PackedInt64Array instance_ids = get_i64(batch, "instance_ids");
    const PackedInt64Array revisions = get_i64(batch, "revisions");
    const PackedInt32Array offsets = get_i32(batch, "metric_offsets");
    const PackedInt32Array metric_ids = get_i32(batch, "metric_ids");
    const PackedInt64Array metric_values = get_i64(batch, "metric_values_q16");
    const int32_t count = instance_ids.size();
    if (count <= 0 || offsets.size() != count + 1 ||
        metric_ids.size() != metric_values.size() ||
        offsets[0] != 0 || offsets[count] != metric_ids.size())
        return failure("effect_snapshot_columns_invalid");
    for (int32_t i = 1; i < offsets.size(); ++i) {
        if (offsets[i] < offsets[i - 1] || offsets[i] < 0 ||
            offsets[i] > metric_ids.size())
            return failure("effect_snapshot_offsets_invalid");
    }
    int32_t accepted = 0;
    for (int32_t i = 0; i < count; ++i) {
        const int32_t instance_index = instance_index_for_id(instance_ids[i]);
        if (instance_index < 0) continue;
        const int32_t begin = offsets[i];
        const int32_t end = offsets[i + 1];
        if (begin < 0 || end < begin || end > metric_ids.size())
            return failure("effect_snapshot_offsets_invalid");
        Instance &instance = _instances[instance_index];
        const int64_t revision = i64_at(revisions, i, instance.input_revision + 1);
        if (revision <= instance.input_revision) continue;
        std::fill(_metric_present.begin() + instance.metric_base,
                  _metric_present.begin() + instance.metric_base + _metric_count, 0);
        for (int32_t j = begin; j < end; ++j) {
            const int32_t metric_id = metric_ids[j];
            if (metric_id < 0 || metric_id >= _metric_count)
                return failure("effect_snapshot_metric_invalid");
            int64_t *metric = metric_ptr(instance, metric_id);
            if (metric == nullptr) return failure("effect_snapshot_metric_invalid");
            *metric = metric_values[j];
            _metric_present[static_cast<size_t>(instance.metric_base) +
                            static_cast<size_t>(metric_id)] = 1;
        }
        instance.input_revision = revision;
        mark_family_effect_group_dirty(instance_index);
        ++accepted;
    }
    Dictionary out;
    out["ok"] = true;
    out["accepted"] = accepted;
    out["metrics_written"] = metric_values.size();
    return out;
}

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
    if (acknowledged != 0) compact_terminal_transactions();
    Dictionary out;
    out["ok"] = rejected == 0;
    out["acknowledged"] = acknowledged;
    out["rejected"] = rejected;
    out["acked_transaction_id"] = _acked_transaction_id;
    if (rejected != 0) out["reason"] = "effect_ack_unknown_transaction";
    return out;
}



void EffectRuntime::compact_due_heap_if_needed() {
    const size_t threshold = std::max<size_t>(1024, _instances.size() * 4 + 1024);
    if (_due_heap.size() <= threshold) return;
    std::priority_queue<DueNode, std::vector<DueNode>, std::greater<DueNode>> compacted;
    for (int32_t index = 0; index < static_cast<int32_t>(_instances.size()); ++index) {
        Instance &instance = _instances[static_cast<size_t>(index)];
        if (!instance.active || instance.generation == 0) continue;
        if (instance.schedule_token == 0) instance.schedule_token = _schedule_token++;
        compacted.push({instance.next_due_day, index, instance.generation,
                        instance.schedule_token});
    }
    _due_heap.swap(compacted);
}

void EffectRuntime::rebuild_run_candidates(int64_t day_index) {
    _run_candidates.clear();
    ++_dirty_epoch_counter;
    if (_dirty_epoch_counter == 0) {
        for (Instance &instance : _instances) instance.dirty_epoch = 0;
        _dirty_epoch_counter = 1;
    }
    ++_stack_decision_epoch;
    if (_stack_decision_epoch == 0) {
        for (Instance &instance : _instances)
            instance.stack_decision_epoch = 0;
        _stack_decision_epoch = 1;
    }
    while (!_due_heap.empty() && _due_heap.top().day <= day_index) {
        const DueNode node = _due_heap.top();
        _due_heap.pop();
        if (node.instance_index < 0 ||
            node.instance_index >= static_cast<int32_t>(_instances.size())) continue;
        Instance &instance = _instances[static_cast<size_t>(node.instance_index)];
        if (!instance.active || instance.generation != node.generation ||
            instance.next_due_day > day_index ||
            instance.schedule_token != node.schedule_token) continue;
        if (instance.dirty_epoch != _dirty_epoch_counter) {
            instance.dirty_epoch = _dirty_epoch_counter;
            _run_candidates.push_back(node.instance_index);
        }
    }
    for (const int32_t index : _dirty_queue) {
        if (index < 0 || index >= static_cast<int32_t>(_instances.size())) continue;
        Instance &instance = _instances[static_cast<size_t>(index)];
        if (!instance.active) continue;
        if (instance.dirty_epoch != _dirty_epoch_counter) {
            instance.dirty_epoch = _dirty_epoch_counter;
            _run_candidates.push_back(index);
        }
    }
    _dirty_queue.clear();
    std::sort(_run_candidates.begin(), _run_candidates.end(),
        [&](int32_t a, int32_t b) {
            const Instance &lhs = _instances[static_cast<size_t>(a)];
            const Instance &rhs = _instances[static_cast<size_t>(b)];
            if (lhs.program_id != rhs.program_id) return lhs.program_id < rhs.program_id;
            if (lhs.id != rhs.id) return lhs.id < rhs.id;
            return a < b;
        });
    _run_candidates.erase(std::unique(_run_candidates.begin(), _run_candidates.end()),
                          _run_candidates.end());
    _candidate_cursor = 0;
}

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
    transaction.id = _next_transaction_id++;
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
