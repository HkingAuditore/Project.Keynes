#include "world_ext.h"

#include "effect_runtime.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "ideology_runtime.h"
#include "modifier_runtime.h"
#include "runtime_effect_pod.h"
#include "native_simulation_host.h"

#include <algorithm>
#include <string>
#include <type_traits>

namespace pk {

using namespace godot;

namespace {
EffectRuntime *runtime_from(void *opaque) {
    return static_cast<EffectRuntime *>(opaque);
}
const EffectRuntime *runtime_from(const void *opaque) {
    return static_cast<const EffectRuntime *>(opaque);
}
Dictionary unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "effect_runtime_unavailable";
    return out;
}

template <typename T>
T packed_value(const godot::Dictionary &catalog, const char *key,
               int index, T fallback = T{}) {
    const godot::Variant raw = catalog.get(key, godot::Variant());
    if (raw.get_type() != godot::Variant::PACKED_INT32_ARRAY &&
        raw.get_type() != godot::Variant::PACKED_INT64_ARRAY &&
        raw.get_type() != godot::Variant::PACKED_BYTE_ARRAY) return fallback;
    if constexpr (std::is_same_v<T, int32_t>) {
        const auto values = static_cast<godot::PackedInt32Array>(raw);
        return index >= 0 && index < values.size() ? values[index] : fallback;
    } else if constexpr (std::is_same_v<T, int64_t>) {
        const auto values = static_cast<godot::PackedInt64Array>(raw);
        return index >= 0 && index < values.size() ? values[index] : fallback;
    } else {
        const auto values = static_cast<godot::PackedByteArray>(raw);
        return index >= 0 && index < values.size() ? values[index] : fallback;
    }
}

godot::PackedInt32Array packed_i32(const godot::Dictionary &catalog,
                                   const char *key) {
    return catalog.get(key, godot::PackedInt32Array());
}
godot::PackedInt64Array packed_i64(const godot::Dictionary &catalog,
                                   const char *key) {
    return catalog.get(key, godot::PackedInt64Array());
}
godot::PackedByteArray packed_u8(const godot::Dictionary &catalog,
                                 const char *key) {
    return catalog.get(key, godot::PackedByteArray());
}
godot::PackedStringArray packed_strings(const godot::Dictionary &catalog,
                                        const char *key) {
    return catalog.get(key, godot::PackedStringArray());
}

bool compile_effect_pod_catalog(const Dictionary &catalog,
                               RuntimeEffectPodCatalog &out,
                               std::string &error) {
    error.clear();
    out = RuntimeEffectPodCatalog{};
    const int protocol = static_cast<int>(catalog.get("protocol_version", 0));
    if (protocol != 1) { error = "effect_pod_protocol_version_invalid"; return false; }
    out.max_instances = static_cast<uint32_t>(std::max<int64_t>(1,
        static_cast<int64_t>(catalog.get("max_instances", 4096))));
    out.max_transactions = static_cast<uint32_t>(std::max<int64_t>(1,
        static_cast<int64_t>(catalog.get("max_transactions", 8192))));
    out.max_work_per_slice = static_cast<uint32_t>(std::max<int64_t>(1,
        static_cast<int64_t>(catalog.get("max_work_per_slice", 1024))));
    out.max_commands_per_transaction = static_cast<uint32_t>(std::max<int64_t>(1,
        static_cast<int64_t>(catalog.get("max_native_modifier_commands", 4096))));

    const auto metric_keys = packed_strings(catalog, "metric_keys");
    for (int i = 0; i < metric_keys.size(); ++i) {
        const String key = metric_keys[i];
        if (key.is_empty()) { error = "effect_pod_metric_key_empty"; return false; }
        out.metric_key_hashes.push_back(RuntimeEffectPodAuthority::hash_text(
            key.utf8().get_data()));
    }
    const auto behavior_keys = packed_strings(catalog, "behavior_keys");
    const auto effect_keys = packed_strings(catalog, "effect_keys");
    const auto versions = packed_i32(catalog, "versions");
    const auto cadence_days = packed_i32(catalog, "cadence_days");
    const auto max_work = packed_i32(catalog, "max_work");
    const auto enabled = packed_u8(catalog, "enabled");
    const auto source_kinds = packed_i32(catalog, "source_kinds");
    const auto target_domains = packed_i32(catalog, "target_domains");
    const auto operations = packed_i32(catalog, "operations");
    const auto lifecycles = packed_i32(catalog, "lifecycles");
    const auto duration_days = packed_i32(catalog, "duration_days");
    const auto stack_policies = packed_i32(catalog, "stack_policies");
    const auto stack_keys = packed_strings(catalog, "stack_keys");
    const auto max_stacks = packed_i32(catalog, "max_stacks");
    const auto priorities = packed_i32(catalog, "priorities");
    const auto selector_kinds = packed_i32(catalog, "target_selector_kinds");
    const auto selector_ids = packed_strings(catalog, "target_selector_ids");
    const auto prestige = packed_i32(catalog, "magnitude_by_prestige_q16");
    const int count = effect_keys.size();
    if (behavior_keys.size() != count || versions.size() != count ||
        cadence_days.size() != count || max_work.size() != count ||
        enabled.size() != count || source_kinds.size() != count ||
        target_domains.size() != count || operations.size() != count ||
        lifecycles.size() != count || duration_days.size() != count ||
        stack_policies.size() != count || stack_keys.size() != count ||
        max_stacks.size() != count || priorities.size() != count ||
        selector_kinds.size() != count || selector_ids.size() != count ||
        (!prestige.is_empty() && prestige.size() != count * 6)) {
        error = "effect_pod_definition_columns_invalid";
        return false;
    }

    const auto condition_offsets = packed_i32(catalog, "condition_offsets");
    const auto condition_ops = packed_i32(catalog, "condition_ops");
    const auto condition_arg0 = packed_i32(catalog, "condition_arg0");
    const auto condition_values = packed_i64(catalog, "condition_values");
    const auto instruction_offsets = packed_i32(catalog, "instruction_offsets");
    const auto instruction_ops = packed_i32(catalog, "instruction_ops");
    const auto instruction_arg0 = packed_i32(catalog, "instruction_arg0");
    const auto instruction_arg1 = packed_i32(catalog, "instruction_arg1");
    const auto instruction_values = packed_i64(catalog, "instruction_values");
    const auto command_offsets = packed_i32(catalog, "command_offsets");
    const auto command_actions = packed_i32(catalog, "command_actions");
    const auto command_domains = packed_i32(catalog, "command_domains");
    const auto command_opcodes = packed_i32(catalog, "command_opcodes");
    const auto command_resolvers = packed_i32(catalog, "command_target_resolvers");
    const auto command_targets = packed_i64(catalog, "command_static_targets");
    const auto command_value_modes = packed_i32(catalog, "command_value_modes");
    const auto command_values = packed_i64(catalog, "command_values");
    const auto command_durations = packed_i32(catalog, "command_duration_days");
    const auto command_stacks = packed_i32(catalog, "command_stacks");
    const auto command_keys = packed_strings(catalog, "command_keys");
    const auto command_definition_keys = packed_strings(catalog, "command_definition_keys");
    const auto payload_i0 = packed_i64(catalog, "command_payload_i0");
    const auto payload_i1 = packed_i64(catalog, "command_payload_i1");
    const auto payload_i2 = packed_i64(catalog, "command_payload_i2");
    const auto payload_i3 = packed_i64(catalog, "command_payload_i3");
    if (condition_offsets.size() != count + 1 || instruction_offsets.size() != count + 1 ||
        command_offsets.size() != count + 1 || condition_ops.size() != condition_arg0.size() ||
        condition_ops.size() != condition_values.size() ||
        instruction_ops.size() != instruction_arg0.size() ||
        instruction_ops.size() != instruction_arg1.size() ||
        instruction_ops.size() != instruction_values.size()) {
        error = "effect_pod_program_columns_invalid";
        return false;
    }
    for (int i = 0; i < condition_ops.size(); ++i) {
        RuntimeEffectPodCondition value;
        value.op = static_cast<RuntimeEffectPodConditionOp>(condition_ops[i]);
        value.arg0 = condition_arg0[i]; value.value = condition_values[i];
        out.conditions.push_back(value);
    }
    for (int i = 0; i < instruction_ops.size(); ++i) {
        RuntimeEffectPodInstruction value;
        value.op = static_cast<RuntimeEffectPodInstructionOp>(instruction_ops[i]);
        value.arg0 = instruction_arg0[i]; value.arg1 = instruction_arg1[i];
        value.value = instruction_values[i];
        out.instructions.push_back(value);
    }
    if (command_actions.size() != command_domains.size() ||
        command_actions.size() != command_opcodes.size() ||
        command_actions.size() != command_resolvers.size() ||
        command_actions.size() != command_targets.size() ||
        command_actions.size() != command_value_modes.size() ||
        command_actions.size() != command_values.size() ||
        command_actions.size() != command_durations.size() ||
        command_actions.size() != command_stacks.size() ||
        command_actions.size() != command_keys.size() ||
        command_actions.size() != command_definition_keys.size()) {
        error = "effect_pod_command_columns_invalid";
        return false;
    }
    for (int i = 0; i < command_actions.size(); ++i) {
        if (command_keys[i].is_empty()) { error = "effect_pod_command_key_empty"; return false; }
        RuntimeEffectPodCommandDefinition value;
        value.action = static_cast<RuntimeEffectPodAction>(command_actions[i]);
        value.domain = command_domains[i]; value.opcode = command_opcodes[i];
        value.target_resolver = static_cast<RuntimeEffectPodTargetResolver>(command_resolvers[i]);
        value.static_target = static_cast<uint64_t>(command_targets[i]);
        value.value_mode = static_cast<RuntimeEffectPodValueMode>(command_value_modes[i]);
        value.value = command_values[i]; value.duration_days = command_durations[i];
        value.stacks = command_stacks[i];
        value.command_key_hash = RuntimeEffectPodAuthority::hash_text(
            command_keys[i].utf8().get_data());
        value.definition_key_hash = command_definition_keys[i].is_empty() ? 0 :
            RuntimeEffectPodAuthority::hash_text(command_definition_keys[i].utf8().get_data());
        value.payload = {i < payload_i0.size() ? payload_i0[i] : 0,
                         i < payload_i1.size() ? payload_i1[i] : 0,
                         i < payload_i2.size() ? payload_i2[i] : 0,
                         i < payload_i3.size() ? payload_i3[i] : 0};
        out.commands.push_back(value);
    }
    for (int i = 0; i < count; ++i) {
        if (effect_keys[i].is_empty() || behavior_keys[i].is_empty() == false) {
            if (!behavior_keys[i].is_empty()) {
                error = "effect_pod_behavior_implementation_missing:" +
                    std::string(behavior_keys[i].utf8().get_data());
                return false;
            }
        }
        const auto valid_offset = [](const PackedInt32Array &offsets, int index,
                                     int total) { return offsets[index] >= 0 &&
            offsets[index] <= offsets[index + 1] && offsets[index + 1] <= total; };
        if (!valid_offset(condition_offsets, i, condition_ops.size()) ||
            !valid_offset(instruction_offsets, i, instruction_ops.size()) ||
            !valid_offset(command_offsets, i, command_actions.size())) {
            error = "effect_pod_definition_offsets_invalid";
            return false;
        }
        RuntimeEffectPodDefinition value;
        value.key_hash = RuntimeEffectPodAuthority::hash_text(effect_keys[i].utf8().get_data());
        value.version = versions[i]; value.cadence_days = cadence_days[i];
        value.max_work = max_work[i]; value.enabled = enabled[i] != 0;
        value.condition_begin = condition_offsets[i];
        value.condition_count = condition_offsets[i + 1] - condition_offsets[i];
        value.instruction_begin = instruction_offsets[i];
        value.instruction_count = instruction_offsets[i + 1] - instruction_offsets[i];
        value.command_begin = command_offsets[i];
        value.command_count = command_offsets[i + 1] - command_offsets[i];
        value.source_kind = source_kinds[i]; value.target_domain = target_domains[i];
        value.operation = operations[i];
        value.lifecycle = static_cast<RuntimeEffectPodLifecycle>(lifecycles[i]);
        value.duration_days = duration_days[i];
        value.stack_policy = static_cast<RuntimeEffectPodStackPolicy>(stack_policies[i]);
        value.stack_key_hash = stack_keys[i].is_empty() ? 0 :
            RuntimeEffectPodAuthority::hash_text(stack_keys[i].utf8().get_data());
        value.max_stacks = max_stacks[i]; value.priority = priorities[i];
        value.target_selector_kind = selector_kinds[i];
        value.target_selector_hash = selector_ids[i].is_empty() ? 0 :
            RuntimeEffectPodAuthority::hash_text(selector_ids[i].utf8().get_data());
        for (int tier = 0; tier < 6; ++tier)
            value.magnitude_by_prestige_q16[tier] = prestige.is_empty()
                ? 65536 : prestige[i * 6 + tier];
        out.definitions.push_back(value);
    }
    // No behavior is registered by this bridge yet. Declarative programs are
    // fully POD; open-ended behavior programs fail explicitly above.
    out.catalog_hash = 0;
    return true;
}
} // namespace

Dictionary DCWorldExt::configure_effects(const Dictionary &catalog) {
    if (_effect_runtime == nullptr) _effect_runtime = new EffectRuntime();
    Dictionary result = runtime_from(_effect_runtime)->configure(catalog);
    if (bool(result.get("ok", false))) {
        if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
        RuntimeEffectPodCatalog pod_catalog;
        std::string pod_error;
        const bool pod_ok = compile_effect_pod_catalog(catalog, pod_catalog, pod_error) &&
            _runtime_host->configure_effect_pod(pod_catalog, pod_error);
        result["effect_pod_ready"] = pod_ok;
        result["effect_pod_fallback_reason"] = String(pod_error.c_str());
        result["effect_pod_catalog_hash"] = pod_ok
            ? static_cast<int64_t>(_runtime_host->effect_pod_report().catalog_hash) : 0;
        if (_country_runtime != nullptr) {
            runtime_from(_effect_runtime)->attach_country_runtime(
                static_cast<NativeCountryRuntime *>(_country_runtime));
            static_cast<NativeCountryRuntime *>(_country_runtime)->attach_effect_runtime(
                runtime_from(_effect_runtime));
        }
        if (_economy_runtime != nullptr)
            static_cast<NativeEconomyRuntime *>(_economy_runtime)->attach_effect_runtime(
                runtime_from(_effect_runtime));
        // Country runtime is configured before EffectRuntime during normal
        // startup, and ideology is intentionally configured with the country
        // catalog at that same early boundary.  Keep the peer link symmetric:
        // otherwise NativeIdeologyRuntime retains a null EffectRuntime when
        // EffectRuntime is configured later, so its first equip/upgrade is
        // rejected despite both runtimes being healthy.
        if (_ideology_runtime != nullptr)
            static_cast<NativeIdeologyRuntime *>(_ideology_runtime)->attach_effect_runtime(
                runtime_from(_effect_runtime));
    }
    return result;
}

Dictionary DCWorldExt::bind_era_reward_player_country(int64_t country_handle) {
    if (_effect_runtime == nullptr) return unavailable();
    std::string error;
    const bool ok = runtime_from(_effect_runtime)
        ->bind_era_reward_player_country_pod(
            static_cast<uint64_t>(country_handle), error);
    Dictionary out;
    out["ok"] = ok;
    if (!ok) out["reason"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::get_era_reward_offer() {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->era_reward_offer_snapshot();
}

Dictionary DCWorldExt::choose_era_reward(int64_t offer_generation,
                                         int choice_index,
                                         int64_t effective_day) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->choose_era_reward(
            offer_generation, choice_index, effective_day);
}

Dictionary DCWorldExt::submit_effect_instances(const Dictionary &batch) {
    if (_effect_runtime == nullptr) return unavailable();
    Dictionary result = runtime_from(_effect_runtime)->submit_instances(batch);
    // F7 SHADOW mirror: best-effort queue of accepted declarative instances.
    // Failures here never roll back the production EffectRuntime write.
    if (bool(result.get("ok", false)) && _runtime_host != nullptr) {
        const PackedInt64Array accepted_ids = result.get("instance_ids",
                                                         PackedInt64Array());
        const PackedInt64Array ids = batch.get("instance_ids", PackedInt64Array());
        const PackedStringArray program_keys = batch.get("program_keys",
                                                          PackedStringArray());
        const PackedInt32Array generations = batch.get("generations",
                                                        PackedInt32Array());
        const PackedInt32Array source_types = batch.get("source_types",
                                                         PackedInt32Array());
        const PackedInt64Array source_ids = batch.get("source_ids",
                                                       PackedInt64Array());
        const PackedInt64Array source_handles = batch.get("source_handles",
                                                           PackedInt64Array());
        const PackedInt64Array target_handles = batch.get("target_handles",
                                                           PackedInt64Array());
        const PackedInt32Array target_generations = batch.get(
            "target_generations", PackedInt32Array());
        const PackedInt32Array levels = batch.get("levels", PackedInt32Array());
        const PackedInt64Array next_due_days = batch.get("next_due_days",
                                                          PackedInt64Array());
        const PackedByteArray active = batch.get("active", PackedByteArray());
        int32_t mirrored = 0;
        int32_t mirror_rejected = 0;
        for (int i = 0; i < ids.size() && i < program_keys.size(); ++i) {
            const int64_t id = ids[i];
            bool accepted = false;
            for (int a = 0; a < accepted_ids.size(); ++a) {
                if (accepted_ids[a] == id) { accepted = true; break; }
            }
            if (!accepted) continue;
            const int32_t program_id = _runtime_host->effect_pod_program_id_for_key(
                program_keys[i].utf8().get_data());
            if (program_id < 0) {
                ++mirror_rejected;
                continue;
            }
            RuntimeEffectPodInstanceInput input;
            input.instance_id = id;
            input.generation = static_cast<uint32_t>(std::max(
                1, i < generations.size() ? generations[i] : 1));
            input.program_id = program_id;
            input.source_type = i < source_types.size() ? source_types[i] : 0;
            input.source_id = i < source_ids.size() ? source_ids[i] : 0;
            input.source_handle = static_cast<uint64_t>(
                i < source_handles.size() ? source_handles[i] : 0);
            input.target_handle = static_cast<uint64_t>(
                i < target_handles.size() ? target_handles[i] : 0);
            input.target_generation = static_cast<uint32_t>(std::max(
                0, i < target_generations.size() ? target_generations[i] : 0));
            input.level = i < levels.size() ? levels[i] : 0;
            input.next_due_day = i < next_due_days.size() ? next_due_days[i] : 0;
            input.active = i >= active.size() || active[i] != 0;
            std::string mirror_error;
            if (_runtime_host->queue_effect_pod_instance(input, mirror_error))
                ++mirrored;
            else
                ++mirror_rejected;
        }
        result["effect_pod_mirrored"] = mirrored;
        result["effect_pod_mirror_rejected"] = mirror_rejected;
    }
    return result;
}

Dictionary DCWorldExt::retire_effect_instance(int64_t instance_id,
                                              int64_t generation,
                                              int64_t effective_day) {
    if (_effect_runtime == nullptr) return unavailable();
    std::string error;
    const bool ok = generation > 0 && runtime_from(_effect_runtime)->retire_instance_pod(
        instance_id, static_cast<uint32_t>(generation), effective_day, error);
    Dictionary out;
    out["ok"] = ok;
    if (!ok) out["reason"] = String(error.c_str());
    if (ok && _runtime_host != nullptr) {
        std::string mirror_error;
        out["effect_pod_mirrored"] = _runtime_host->queue_effect_pod_remove(
            instance_id, static_cast<uint32_t>(generation), mirror_error);
        if (!bool(out["effect_pod_mirrored"]))
            out["effect_pod_mirror_reason"] = String(mirror_error.c_str());
    }
    return out;
}

Dictionary DCWorldExt::queue_effect_pod_instance(const Dictionary &source) {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_host_unavailable";
        return out;
    }
    RuntimeEffectPodInstanceInput input;
    input.instance_id = static_cast<int64_t>(source.get("instance_id", 0));
    input.generation = static_cast<uint32_t>(std::max<int64_t>(
        1, static_cast<int64_t>(source.get("generation", 1))));
    input.program_id = static_cast<int32_t>(source.get("program_id", -1));
    if (source.has("program_key")) {
        const String key = source.get("program_key", String());
        const int32_t resolved = _runtime_host->effect_pod_program_id_for_key(
            key.utf8().get_data());
        if (resolved >= 0) input.program_id = resolved;
    }
    input.source_type = static_cast<int32_t>(source.get("source_type", 0));
    input.source_id = static_cast<int64_t>(source.get("source_id", 0));
    input.source_handle = static_cast<uint64_t>(
        static_cast<int64_t>(source.get("source_handle", 0)));
    input.target_handle = static_cast<uint64_t>(
        static_cast<int64_t>(source.get("target_handle", 0)));
    input.target_generation = static_cast<uint32_t>(std::max<int64_t>(
        0, static_cast<int64_t>(source.get("target_generation", 0))));
    input.level = static_cast<int32_t>(source.get("level", 0));
    input.next_due_day = static_cast<int64_t>(source.get("next_due_day", 0));
    input.active = bool(source.get("active", true));
    std::string error;
    const bool ok = _runtime_host->queue_effect_pod_instance(input, error);
    out["ok"] = ok;
    out["code"] = ok ? "ok" : String(error.c_str());
    return out;
}

Dictionary DCWorldExt::queue_effect_pod_metric(const Dictionary &source) {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_host_unavailable";
        return out;
    }
    std::string error;
    const bool ok = _runtime_host->queue_effect_pod_metric(
        static_cast<int64_t>(source.get("instance_id", 0)),
        static_cast<uint32_t>(std::max<int64_t>(
            1, static_cast<int64_t>(source.get("generation", 1)))),
        static_cast<int32_t>(source.get("metric_id", 0)),
        static_cast<int64_t>(source.get("revision", 1)),
        static_cast<int64_t>(source.get("value", 0)),
        error);
    out["ok"] = ok;
    out["code"] = ok ? "ok" : String(error.c_str());
    return out;
}

Dictionary DCWorldExt::queue_effect_pod_remove(int64_t instance_id,
                                               int64_t generation) {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_host_unavailable";
        return out;
    }
    std::string error;
    const bool ok = generation > 0 && _runtime_host->queue_effect_pod_remove(
        instance_id, static_cast<uint32_t>(generation), error);
    out["ok"] = ok;
    out["code"] = ok ? "ok" : String(error.empty() ? "effect_remove_invalid" :
                                                    error.c_str());
    return out;
}

Dictionary DCWorldExt::poll_effect_worker_intent() {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_host_unavailable";
        return out;
    }
    RuntimeDomainIntent intent;
    if (!_runtime_host->poll_effect_pod_intent(intent)) {
        out["ok"] = true;
        out["available"] = false;
        return out;
    }
    out["ok"] = true;
    out["available"] = true;
    out["request_id"] = static_cast<int64_t>(intent.request_id);
    out["transaction_id"] = static_cast<int64_t>(intent.request_id);
    out["source_id"] = static_cast<int64_t>(intent.source_id);
    out["target_handle"] = static_cast<int64_t>(intent.target_handle);
    out["target_generation"] = static_cast<int64_t>(intent.target_generation);
    out["target_domain"] = static_cast<int64_t>(intent.target_domain);
    out["opcode"] = static_cast<int64_t>(intent.opcode);
    out["effect_action"] = static_cast<int64_t>(intent.effect_action);
    out["effective_day"] = intent.effective_day;
    out["sequence"] = static_cast<int64_t>(intent.sequence);
    out["duration_days"] = intent.duration_days;
    out["stacks"] = intent.stacks;
    out["magnitude_q16"] = intent.magnitude_q16;
    PackedInt64Array payload;
    for (int64_t value : intent.payload) payload.append(value);
    out["payload"] = payload;
    return out;
}

Dictionary DCWorldExt::submit_effect_worker_ack(const Dictionary &source) {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_host_unavailable";
        return out;
    }
    RuntimeDomainAck ack;
    ack.request_id = static_cast<uint64_t>(
        static_cast<int64_t>(source.get("request_id", 0)));
    ack.transaction_id = static_cast<uint64_t>(
        static_cast<int64_t>(source.get("transaction_id",
            source.get("request_id", 0))));
    ack.target_handle = static_cast<uint64_t>(
        static_cast<int64_t>(source.get("target_handle", 0)));
    ack.target_generation = static_cast<uint32_t>(
        static_cast<int64_t>(source.get("target_generation", 0)));
    ack.domain = static_cast<uint16_t>(
        static_cast<int64_t>(source.get(
            "domain", static_cast<int64_t>(RuntimeDomainId::MODIFIER))));
    ack.code = static_cast<RuntimeDomainAckCode>(
        static_cast<int32_t>(source.get("code", 0)));
    ack.effective_day = static_cast<int64_t>(source.get("effective_day", 0));
    ack.producer_id = static_cast<uint32_t>(
        static_cast<int64_t>(source.get("producer_id", 0)));
    ack.sequence = static_cast<uint64_t>(
        static_cast<int64_t>(source.get("sequence", 0)));
    std::string error;
    const bool ok = _runtime_host->submit_effect_pod_ack(ack, error);
    out["ok"] = ok;
    out["code"] = ok ? "ok" : String(error.c_str());
    return out;
}

bool DCWorldExt::effect_instance_fire_acked(int64_t instance_id,
                                            int64_t generation) const {
    return _effect_runtime != nullptr && generation > 0 &&
        runtime_from(_effect_runtime)->instance_fire_acked_pod(
            instance_id, static_cast<uint32_t>(generation));
}

Dictionary DCWorldExt::submit_effect_snapshots(const Dictionary &batch) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->submit_snapshots(batch);
}

Dictionary DCWorldExt::run_effect_daily(int64_t day_index) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->run_daily(day_index);
}

Dictionary DCWorldExt::dispatch_effect_native_modifier() {
    if (_effect_runtime == nullptr || _modifier_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->dispatch_native_modifier(
        static_cast<ModifierRuntime *>(_modifier_runtime));
}

Dictionary DCWorldExt::ack_effect_native_modifier() {
    if (_effect_runtime == nullptr || _modifier_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->ack_native_modifier(
        static_cast<ModifierRuntime *>(_modifier_runtime));
}

Dictionary DCWorldExt::dispatch_effect_native_country() {
    if (_effect_runtime == nullptr || _country_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->dispatch_native_country(
        static_cast<NativeCountryRuntime *>(_country_runtime));
}

Dictionary DCWorldExt::ack_effect_native_country() {
    if (_effect_runtime == nullptr || _country_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->ack_native_country(
        static_cast<NativeCountryRuntime *>(_country_runtime));
}

Dictionary DCWorldExt::dispatch_effect_native_economy() {
    if (_effect_runtime == nullptr || _economy_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->dispatch_native_economy(
        static_cast<NativeEconomyRuntime *>(_economy_runtime));
}

Dictionary DCWorldExt::ack_effect_native_economy() {
    if (_effect_runtime == nullptr || _economy_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->ack_native_economy(
        static_cast<NativeEconomyRuntime *>(_economy_runtime));
}

Dictionary DCWorldExt::dispatch_effect_native_gameplay() {
    if (_effect_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->dispatch_native_gameplay(this);
}

Dictionary DCWorldExt::ack_effect_native_gameplay() {
    if (_effect_runtime == nullptr) return unavailable();
    return runtime_from(_effect_runtime)->ack_native_gameplay(this);
}

Dictionary DCWorldExt::get_effect_native_adapter_report() const {
    Dictionary out;
    const bool country_pending = _country_runtime != nullptr &&
        static_cast<const NativeCountryRuntime *>(_country_runtime)
            ->has_pending_effect_commands();
    const bool economy_pending = _economy_runtime != nullptr &&
        static_cast<const NativeEconomyRuntime *>(_economy_runtime)
            ->has_pending_effect_commands();
    const bool gameplay_pending = !_effect_gameplay_commands.empty();
    out["country_pending"] = country_pending;
    out["economy_pending"] = economy_pending;
    out["gameplay_pending"] = gameplay_pending;
    out["country_pending_count"] = country_pending ? 1 : 0;
    out["economy_pending_count"] = economy_pending ? 1 : 0;
    out["gameplay_pending_count"] = static_cast<int64_t>(
        _effect_gameplay_commands.size());
    out["idle"] = !country_pending && !economy_pending && !gameplay_pending;
    return out;
}

bool DCWorldExt::effect_should_run(int64_t day_index) const {
    return _effect_runtime != nullptr &&
        runtime_from(_effect_runtime)->should_run(day_index);
}

Dictionary DCWorldExt::poll_effect_transactions(int64_t after_transaction_id,
                                                int limit) const {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->poll_transactions(after_transaction_id, limit);
}

Dictionary DCWorldExt::preflight_effect_transactions(const Dictionary &batch) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->preflight_transactions(batch);
}

Dictionary DCWorldExt::commit_effect_transactions(const Dictionary &batch) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->commit_transactions(batch);
}

Dictionary DCWorldExt::ack_effect_transactions(const Dictionary &batch) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->ack_transactions(batch);
}

Dictionary DCWorldExt::explain_effect(int64_t instance_id) const {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->explain(instance_id);
}

Dictionary DCWorldExt::get_effect_report() const {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->report();
}

PackedByteArray DCWorldExt::capture_effect_state() const {
    return _effect_runtime == nullptr ? PackedByteArray()
        : runtime_from(_effect_runtime)->capture();
}

Dictionary DCWorldExt::restore_effect_state(const PackedByteArray &bytes) {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->restore(bytes);
}

Dictionary DCWorldExt::clear_effect_state() {
    return _effect_runtime == nullptr ? unavailable()
        : runtime_from(_effect_runtime)->clear_state();
}

} // namespace pk
