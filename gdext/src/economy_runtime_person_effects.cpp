#include "economy_runtime_includes.inc"

namespace pk {

using namespace godot;
using namespace variant_helpers;

namespace {
bool reconcile_trigger_branch_binding(TriggerRuntime *runtime,
                                      const std::string &key,
                                      uint64_t branch_handle,
                                      int32_t cell,
                                      int32_t reward_target,
                                      bool enabled) {
    if (runtime == nullptr || key.empty()) return false;
    Dictionary batch;
    PackedStringArray keys;
    PackedInt64Array branches;
    PackedInt32Array cells;
    PackedInt32Array rewards;
    PackedByteArray states;
    keys.push_back(key.c_str());
    branches.push_back(static_cast<int64_t>(branch_handle));
    cells.push_back(cell);
    rewards.push_back(reward_target);
    states.push_back(enabled ? 1 : 0);
    batch["trigger_keys"] = keys;
    batch["branch_handles"] = branches;
    batch["cells"] = cells;
    batch["reward_targets"] = rewards;
    batch["enabled"] = states;
    const Dictionary result = runtime->reconcile_branch_bindings(batch);
    return static_cast<bool>(result.get("ok", false));
}

} // namespace

namespace {

using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}


} // namespace

void NativeEconomyRuntime::clear_family_branch_effects(uint64_t branch_handle) {
    int32_t branch = -1;
    if (!family_influences().valid_handle(branch_handle, branch)) return;
    for (const FamilyTriggerBinding &binding : _family_trigger_bindings) {
        if (binding.branch_handle != branch_handle) continue;
        reconcile_trigger_branch_binding(_trigger_runtime,
            binding.definition_key, branch_handle,
            family_influences().cell[branch], binding.reward_target, false);
    }
    _family_trigger_bindings.erase_if(
        [&](const FamilyTriggerBinding &binding) {
            return binding.branch_handle == branch_handle;
        });
    if (_effect_runtime != nullptr) {
        const uint64_t stable_id = static_cast<uint64_t>(family_influences().stable_id[branch]);
        const uint32_t generation = static_cast<uint32_t>(branch_handle >> 32U);
        const auto branch_bindings = _family_effect_instances_by_branch.find(
            branch_handle);
        const std::vector<int64_t> instance_ids = branch_bindings ==
                _family_effect_instances_by_branch.end()
            ? std::vector<int64_t>() : branch_bindings->second;
        for (const int64_t instance_id : instance_ids) {
            const auto indexed = _family_effect_binding_by_instance.find(instance_id);
            if (indexed == _family_effect_binding_by_instance.end()) continue;
            const size_t binding_index = indexed->second;
            const FamilyEffectBinding &binding = _family_effect_bindings[binding_index];
            std::string error;
            const bool retired = effect_pod_retire(_effect_runtime,
                _effect_forwarder, binding.instance_id, binding.generation,
                _current_day.get(), error);
            if (retired) {
                remove_family_effect_binding(binding_index);
            }
        }
        for (size_t binding_row = 0; binding_row < _family_modifier_bindings.size(); ++binding_row) {
        auto binding_write = _family_modifier_bindings.edit_row(binding_row);
        FamilyModifierBinding &binding = binding_write[0];
            if (binding.branch_handle != branch_handle ||
                binding.magnitude_q16 == 0) continue;
            std::string error;
            uint64_t identity = trace_hash_mix(1469598103934665603ULL, stable_id);
            identity = trace_hash_mix(identity, static_cast<uint32_t>(
                family_influences().cell[branch]));
            uint64_t definition_hash = 1469598103934665603ULL;
            for (unsigned char ch : binding.definition_key)
                definition_hash = trace_hash_mix(definition_hash, ch);
            identity = trace_hash_mix(identity, definition_hash);
            const int64_t instance_id = static_cast<int64_t>(identity &
                0x7fffffffffffffffULL);
            const bool retired = effect_pod_retire(_effect_runtime,
                _effect_forwarder, instance_id, generation, _current_day.get(),
                error);
            // Keep a non-zero binding when the bounded Effect queue is full or
            // the definition is temporarily unavailable. The next branch
            // reconciliation can retry retirement instead of silently losing
            // the only cleanup handle.
            if (retired) binding.magnitude_q16 = 0;
        }
    } else if (_modifier_runtime != nullptr) {
        for (size_t binding_row = 0; binding_row < _family_modifier_bindings.size(); ++binding_row) {
        auto binding_write = _family_modifier_bindings.edit_row(binding_row);
        FamilyModifierBinding &binding = binding_write[0];
            if (binding.branch_handle != branch_handle ||
                binding.magnitude_q16 == 0) continue;
            std::string error;
            modifier_api::queue_family_group_effect_remove(*_modifier_runtime,
                binding.definition_key, family_influences().cell[branch],
                static_cast<uint64_t>(family_influences().stable_id[branch]),
                _current_day.get(), error);
            binding.magnitude_q16 = 0;
        }
    }
    _family_modifier_bindings.erase_if(
        [&](const FamilyModifierBinding &binding) {
            return binding.branch_handle == branch_handle &&
                binding.magnitude_q16 == 0;
        });
}





// Canonical row order is (person slot, need id). Rows arrive grouped by market
// cell batch, so a comparison sort would run in full every epoch; bucketing by
// slot is linear and produces the offsets the CSR needs as a by-product.
void NativeEconomyRuntime::retire_person(int32_t person_index) {
    if (person_index < 0 || person_index >= static_cast<int32_t>(
            persons_store().active.size()) || persons_store().active[person_index] == 0) return;
    const auto retire_call_started = Clock::now();
    ++_person_retire_calls;
    const uint64_t person_handle = persons_store().handle_for_index(person_index);
    if (_effect_runtime != nullptr) {
        uint64_t hash = trace_hash_mix(1469598103934665603ULL,
            static_cast<uint64_t>(persons_store().stable_id[person_index]));
        hash = trace_hash_mix(hash, 0x504552534f4eULL);
        std::string error;
        const int64_t instance_id = static_cast<int64_t>(
            hash & 0x7fffffffffffffffULL);
        const uint32_t generation = static_cast<uint32_t>(person_handle >> 32U);
        effect_pod_retire(_effect_runtime, _effect_forwarder, instance_id,
                          generation, _current_day.get(), error);
    }
    if (_modifier_runtime != nullptr)
        modifier_api::unregister_person_target(*_modifier_runtime, person_handle);
    // An expedition payload owns the population unit of a travelling notable
    // person. If some other authority retires that person (family dissolution),
    // the payload must drop the reference before the slot generation bumps:
    // a persisted handle that no restore accepts rejects the whole PKEC save.
    drop_expedition_transit_person(person_handle);
    // Releasing the slot bumps the generation, so the retired handle can never
    // match again. Orphaned need rows are dropped by one compaction pass
    // instead of one full-array erase per retirement.
    _person_stable_ids.erase(persons_store().stable_id[person_index]);
    persons_store().release(person_index);
    _person_needs_orphaned = true;
    _person_indices_dirty = true;
    _person_retire_call_ms += elapsed_ms(retire_call_started);
}

void NativeEconomyRuntime::register_person_effect(int32_t person_index) {
    if (_effect_runtime == nullptr || _modifier_runtime == nullptr ||
        person_index < 0 || person_index >= static_cast<int32_t>(persons_store().active.size()) ||
        persons_store().active[person_index] == 0) return;
    const uint64_t person_handle = persons_store().handle_for_index(person_index);
    modifier_api::register_person_target(*_modifier_runtime, person_handle);
    uint64_t hash = trace_hash_mix(1469598103934665603ULL,
        static_cast<uint64_t>(persons_store().stable_id[person_index]));
    hash = trace_hash_mix(hash, 0x504552534f4eULL);
    const int64_t instance_id = static_cast<int64_t>(
        hash & 0x7fffffffffffffffULL);
    // Authority-aware dedup. EffectRuntime is writeback-only under worker
    // authority, so the old query was always false there and every call
    // re-upserted the row -- and each re-upsert carries a fresh next_due_day,
    // which kept postponing the fire instead of being a no-op.
    bool already_registered = false;
    effect_pod_instance_exists(_effect_runtime, _effect_forwarder, instance_id,
        static_cast<uint32_t>(person_handle >> 32U), already_registered);
    if (already_registered) return;
    std::string error;
    effect_pod_upsert(_effect_runtime, _effect_forwarder, instance_id,
        "person.modifier.gameplay.generic.bonus",
        static_cast<uint32_t>(person_handle >> 32U), 0x50455253,
        persons_store().stable_id[person_index], person_handle, person_handle,
        static_cast<uint32_t>(person_handle >> 32U), 0, _current_day.get(), -1,
        true, error);
}

} // namespace pk
