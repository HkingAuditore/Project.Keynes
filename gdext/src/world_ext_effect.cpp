#include "world_ext.h"

#include "effect_runtime.h"
#include "effect_instance_forwarder.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "ideology_runtime.h"
#include "modifier_runtime.h"
#include "runtime_effect_pod.h"
#include "runtime_era_reward.h"
#include "runtime_era_advancement.h"
#include "native_simulation_host.h"

#include <algorithm>
#include <limits>
#include <string>
#include <type_traits>
#include <unordered_map>

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
Dictionary economy_adapter_deferred() {
    Dictionary out;
    out["ok"] = true;
    out["deferred"] = true;
    out["reason"] = "economy_worker_day_inflight";
    out["submitted_transactions"] = 0;
    out["submitted_commands"] = 0;
    out["acknowledged"] = 0;
    out["rejected"] = 0;
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
                               const EffectRuntime *effect,
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
    // Optional per-definition capability flag from EffectCatalog. Definitions
    // the POD subset cannot express (selectors 8..11, StateId > 3) are dropped
    // here instead of being handed to a validator that rejects the catalog as a
    // whole. Absent column => treat every definition as expressible, preserving
    // the pre-filter contract. Offsets stay valid because conditions /
    // instructions / commands are copied globally above, not per definition.
    const auto pod_expressible = packed_u8(catalog, "pod_expressible");
    const auto source_kinds = packed_i32(catalog, "source_kinds");
    const auto target_domains = packed_i32(catalog, "target_domains");
    const auto operations = packed_i32(catalog, "operations");
    const auto lifecycles = packed_i32(catalog, "lifecycles");
    const auto managed_flags = packed_u8(catalog, "managed_flags");
    const auto duration_days = packed_i32(catalog, "duration_days");
    const auto stack_policies = packed_i32(catalog, "stack_policies");
    const auto stack_keys = packed_strings(catalog, "stack_keys");
    const auto max_stacks = packed_i32(catalog, "max_stacks");
    const auto priorities = packed_i32(catalog, "priorities");
    const auto selector_kinds = packed_i32(catalog, "target_selector_kinds");
    const auto selector_ids = packed_strings(catalog, "target_selector_ids");
    const auto target_selector_params =
        packed_i32(catalog, "target_selector_params");
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
         (!target_selector_params.is_empty() &&
          target_selector_params.size() != count * 2) ||
        (!managed_flags.is_empty() && managed_flags.size() != count) ||
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
    // The POD validates its payload as a whole, so a definition it cannot
    // express must not contribute *any* condition, instruction or command.
    // Skipping only the definition entry left its payload behind in the shared
    // side tables, and one out-of-range condition there still rejected the
    // whole catalog. Compact the three side tables and rebuild every
    // definition's offsets against the compacted index space.
    std::vector<uint8_t> include(static_cast<size_t>(count), 1);
    for (int i = 0; i < count; ++i) {
        if (i < pod_expressible.size())
            include[static_cast<size_t>(i)] = pod_expressible[i] != 0 ? 1 : 0;
    }

    std::vector<int32_t> pod_condition_offsets(static_cast<size_t>(count) + 1, 0);
    for (int i = 0; i < count; ++i) {
        pod_condition_offsets[static_cast<size_t>(i)] =
            static_cast<int32_t>(out.conditions.size());
        if (include[static_cast<size_t>(i)] == 0) continue;
        for (int c = condition_offsets[i]; c < condition_offsets[i + 1]; ++c) {
            RuntimeEffectPodCondition value;
            value.op = static_cast<RuntimeEffectPodConditionOp>(condition_ops[c]);
            value.arg0 = condition_arg0[c]; value.value = condition_values[c];
            out.conditions.push_back(value);
        }
    }
    pod_condition_offsets[static_cast<size_t>(count)] =
        static_cast<int32_t>(out.conditions.size());

    std::vector<int32_t> pod_instruction_offsets(static_cast<size_t>(count) + 1, 0);
    for (int i = 0; i < count; ++i) {
        pod_instruction_offsets[static_cast<size_t>(i)] =
            static_cast<int32_t>(out.instructions.size());
        if (include[static_cast<size_t>(i)] == 0) continue;
        for (int c = instruction_offsets[i]; c < instruction_offsets[i + 1]; ++c) {
            RuntimeEffectPodInstruction value;
            value.op = static_cast<RuntimeEffectPodInstructionOp>(instruction_ops[c]);
            value.arg0 = instruction_arg0[c]; value.arg1 = instruction_arg1[c];
            value.value = instruction_values[c];
            out.instructions.push_back(value);
        }
    }
    pod_instruction_offsets[static_cast<size_t>(count)] =
        static_cast<int32_t>(out.instructions.size());
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
    std::vector<int32_t> pod_command_offsets(static_cast<size_t>(count) + 1, 0);
    for (int i = 0; i < count; ++i) {
        pod_command_offsets[static_cast<size_t>(i)] =
            static_cast<int32_t>(out.commands.size());
        if (include[static_cast<size_t>(i)] == 0) continue;
        for (int c = command_offsets[i]; c < command_offsets[i + 1]; ++c) {
            if (command_keys[c].is_empty()) { error = "effect_pod_command_key_empty"; return false; }
            RuntimeEffectPodCommandDefinition value;
            value.action = static_cast<RuntimeEffectPodAction>(command_actions[c]);
            value.domain = command_domains[c]; value.opcode = command_opcodes[c];
            value.target_resolver = static_cast<RuntimeEffectPodTargetResolver>(command_resolvers[c]);
            value.static_target = static_cast<uint64_t>(command_targets[c]);
            value.value_mode = static_cast<RuntimeEffectPodValueMode>(command_value_modes[c]);
            value.value = command_values[c]; value.duration_days = command_durations[c];
            value.stacks = command_stacks[c];
            value.command_key_hash = RuntimeEffectPodAuthority::hash_text(
                command_keys[c].utf8().get_data());
            value.definition_key_hash = command_definition_keys[c].is_empty() ? 0 :
                RuntimeEffectPodAuthority::hash_text(command_definition_keys[c].utf8().get_data());
            value.payload = {c < payload_i0.size() ? payload_i0[c] : 0,
                             c < payload_i1.size() ? payload_i1[c] : 0,
                             c < payload_i2.size() ? payload_i2[c] : 0,
                             c < payload_i3.size() ? payload_i3[c] : 0};
            // The adapter is a per-command property EffectRuntime already
            // compiled (effect_runtime.cpp:1003). Copy it across instead of
            // re-deriving it here, so the two can never disagree.
            out.command_native_adapters.push_back(
                effect != nullptr
                    ? effect->native_modifier_adapter_for_command(c)
                    : 0);
            out.commands.push_back(value);
        }
    }
    pod_command_offsets[static_cast<size_t>(count)] =
        static_cast<int32_t>(out.commands.size());
    // F8: resolve open-ended behaviors from EffectRuntime registry into POD
    // metadata. Missing implementations hard-fail (no silent legacy fallback).
    std::unordered_map<uint64_t, size_t> behavior_index_by_hash;
    for (int i = 0; i < behavior_keys.size(); ++i) {
        const String key = behavior_keys[i];
        if (key.is_empty()) continue;
        const std::string key_utf8 = key.utf8().get_data();
        const uint64_t hash = RuntimeEffectPodAuthority::hash_text(key_utf8.c_str());
        if (behavior_index_by_hash.count(hash) != 0) continue;
        if (!EffectRuntime::has_behavior(key_utf8)) {
            error = "effect_pod_behavior_implementation_missing:" + key_utf8;
            return false;
        }
        RuntimeEffectPodBehaviorMetadata meta;
        meta.behavior_id_hash = hash;
        meta.version = 1;
        meta.max_output = RUNTIME_EFFECT_POD_MAX_BEHAVIOR_OUTPUT;
        meta.thread_safe = 1;
        meta.implemented = 1;
        meta.function = nullptr; // via runtime_effect_pod_behavior_resolver
        behavior_index_by_hash[hash] = out.behaviors.size();
        out.behaviors.push_back(meta);
    }
    for (int i = 0; i < count; ++i) {
        if (include[static_cast<size_t>(i)] == 0) continue;
        if (effect_keys[i].is_empty()) {
            error = "effect_pod_definition_key_empty";
            return false;
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
        if (i < behavior_keys.size() && !behavior_keys[i].is_empty()) {
            value.behavior_id_hash = RuntimeEffectPodAuthority::hash_text(
                behavior_keys[i].utf8().get_data());
        }
        value.condition_begin = pod_condition_offsets[static_cast<size_t>(i)];
        value.condition_count = pod_condition_offsets[static_cast<size_t>(i) + 1] -
            pod_condition_offsets[static_cast<size_t>(i)];
        value.instruction_begin = pod_instruction_offsets[static_cast<size_t>(i)];
        value.instruction_count = pod_instruction_offsets[static_cast<size_t>(i) + 1] -
            pod_instruction_offsets[static_cast<size_t>(i)];
        value.command_begin = pod_command_offsets[static_cast<size_t>(i)];
        value.command_count = pod_command_offsets[static_cast<size_t>(i) + 1] -
            pod_command_offsets[static_cast<size_t>(i)];
        value.source_kind = source_kinds[i]; value.target_domain = target_domains[i];
        value.operation = operations[i];
        value.lifecycle = static_cast<RuntimeEffectPodLifecycle>(lifecycles[i]);
        // Same rule as EffectRuntime::uses_managed_lifecycle(): a lifecycle
        // declaration or an explicit managed flag owns reconciliation. When the
        // optional column is absent, the legacy family prefix is the fallback.
        const bool legacy_family_owned =
            effect_keys[i].begins_with("family.effect.");
        value.managed = static_cast<uint8_t>(
            lifecycles[i] != 0 ||
            (managed_flags.is_empty()
                ? legacy_family_owned : managed_flags[i] != 0));
        value.duration_days = duration_days[i];
        value.stack_policy = static_cast<RuntimeEffectPodStackPolicy>(stack_policies[i]);
        value.stack_key_hash = stack_keys[i].is_empty() ? 0 :
            RuntimeEffectPodAuthority::hash_text(stack_keys[i].utf8().get_data());
        value.max_stacks = max_stacks[i]; value.priority = priorities[i];
        value.target_selector_kind = selector_kinds[i];
        value.target_selector_hash = selector_ids[i].is_empty() ? 0 :
            RuntimeEffectPodAuthority::hash_text(selector_ids[i].utf8().get_data());
        value.min_magnitude_scale_q16 =
            EffectRuntime::minimum_magnitude_scale_for_selector(
                value.target_selector_kind,
                target_selector_params.size() == count * 2
                    ? &target_selector_params[i * 2] : nullptr);
        for (int tier = 0; tier < 6; ++tier)
            value.magnitude_by_prestige_q16[tier] = prestige.is_empty()
                ? 65536 : prestige[i * 6 + tier];
        out.definitions.push_back(value);
    }
    // F8: behaviors resolved above via EffectRuntime registry + POD resolver.
    out.catalog_hash = 0;
    return true;
}
} // namespace

Dictionary DCWorldExt::configure_effects(const Dictionary &catalog) {
    if (_effect_runtime == nullptr) _effect_runtime = new EffectRuntime();
    // The forwarder is the single write path for declarative instances. Create
    // it here, next to the runtime it fronts, so `_effect_forwarder != nullptr`
    // means exactly what `_effect_runtime != nullptr` used to mean.
    if (_effect_forwarder == nullptr)
        _effect_forwarder = std::make_unique<EffectInstanceForwarder>();
    _effect_forwarder->attach(runtime_from(_effect_runtime), _runtime_host.get());
    // attach() re-baselines the epoch from live host authority, so a seam set
    // before the catalog existed has to be re-applied after every attach.
    _effect_forwarder->set_authority_override_for_test(
        _effect_forwarder_authority_override);
    runtime_effect_pod_set_behavior_resolver(
        [](uint64_t behavior_id_hash,
           const RuntimeEffectPodBehaviorInput &input,
           RuntimeEffectPodBehaviorOutput &output,
           std::string &error) -> bool {
            return EffectRuntime::invoke_pod_behavior(
                behavior_id_hash, input, output, error);
        });
    // Metric capacity contract. NativeEconomyRuntime samples ids below
    // FAMILY_METRIC_COUNT; ids above that boundary are ideology-local scalars
    // published by NativeIdeologyRuntime from its own derived state. Both share
    // the one Effect metric table, and the Effect/MetricMask capacity is the
    // ceiling for the merged namespace.
    const int32_t declared_metrics =
        static_cast<int32_t>(packed_strings(catalog, "metric_keys").size());
    if (declared_metrics > MetricMask::CAPACITY) {
        Dictionary rejected;
        rejected["ok"] = false;
        rejected["reason"] = String("effect_metric_count_exceeds_mask");
        rejected["declared_metrics"] = declared_metrics;
        rejected["mask_capacity"] = MetricMask::CAPACITY;
        return rejected;
    }
    Dictionary result = runtime_from(_effect_runtime)->configure(catalog);
    if (bool(result.get("ok", false))) {
        if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
        RuntimeEffectPodCatalog pod_catalog;
        std::string pod_error;
        const bool pod_ok = compile_effect_pod_catalog(catalog, runtime_from(_effect_runtime), pod_catalog, pod_error) &&
            _runtime_host->configure_effect_pod(pod_catalog, pod_error);
        result["effect_pod_ready"] = pod_ok;
        result["effect_pod_fallback_reason"] = String(pod_error.c_str());
        result["effect_pod_catalog_hash"] = pod_ok
            ? static_cast<int64_t>(_runtime_host->effect_pod_report().catalog_hash) : 0;
        // A reloaded catalog changes program ids, so drop the cached
        // program_key -> program_id facts and re-read the new authority state.
        if (_effect_forwarder != nullptr) {
            _effect_forwarder->attach(runtime_from(_effect_runtime),
                                      _runtime_host.get());
            _effect_forwarder->set_authority_override_for_test(
                _effect_forwarder_authority_override);
        }
        if (_country_runtime != nullptr) {
            runtime_from(_effect_runtime)->attach_country_runtime(
                static_cast<NativeCountryRuntime *>(_country_runtime));
            static_cast<NativeCountryRuntime *>(_country_runtime)->attach_effect_runtime(
                runtime_from(_effect_runtime));
            // Country installs one technology instance per (country, tech) both
            // at bootstrap and from the peer adapter. Those are ordinary Effect
            // instances, so they take the same authority-aware door as the
            // family writes; attach here, where the forwarder was just rebuilt.
            static_cast<NativeCountryRuntime *>(_country_runtime)
                ->attach_effect_forwarder(_effect_forwarder.get());
        }
        if (_economy_runtime != nullptr)
            static_cast<NativeEconomyRuntime *>(_economy_runtime)->attach_effect_runtime(
                runtime_from(_effect_runtime));
        // Tag predicates live in the effect catalog but are evaluated by the
        // economy's target selector, so hand over the compiled table here --
        // after configure(), so it is already populated.
        if (_economy_runtime != nullptr)
            static_cast<NativeEconomyRuntime *>(_economy_runtime)->set_target_tags(
                runtime_from(_effect_runtime)->target_tags());
        // M2b: the family path writes Effect instances one row at a time and must
        // make the same worker/legacy decision the declarative batch path makes.
        // Re-attached here because this call also rebuilt the forwarder.
        if (_economy_runtime != nullptr)
            static_cast<NativeEconomyRuntime *>(_economy_runtime)
                ->attach_effect_forwarder(_effect_forwarder.get());
        // Country runtime is configured before EffectRuntime during normal
        // startup, and ideology is intentionally configured with the country
        // catalog at that same early boundary.  Keep the peer link symmetric:
        // otherwise NativeIdeologyRuntime retains a null EffectRuntime when
        // EffectRuntime is configured later, so its first equip/upgrade is
        // rejected despite both runtimes being healthy.
        if (_ideology_runtime != nullptr)
            static_cast<NativeIdeologyRuntime *>(_ideology_runtime)->attach_effect_runtime(
                runtime_from(_effect_runtime));
        if (_ideology_runtime != nullptr) {
            std::string ideology_error;
            if (!static_cast<NativeIdeologyRuntime *>(_ideology_runtime)
                    ->resolve_synergy_override_tags(ideology_error)) {
                Dictionary rejected;
                rejected["ok"] = false;
                rejected["reason"] = String(ideology_error.c_str());
                return rejected;
            }
        }
        // Re-attach on every configure: the forwarder's program facts are keyed
        // by the catalog this call just replaced.
        if (_ideology_runtime != nullptr)
            static_cast<NativeIdeologyRuntime *>(_ideology_runtime)
                ->attach_effect_forwarder(_effect_forwarder.get());
    }
    return result;
}

Dictionary DCWorldExt::bind_era_reward_player_country(int64_t country_handle) {
    if (_effect_runtime == nullptr) return unavailable();
    if (_runtime_host && !_runtime_host->execution_has_stopped()) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = "era_session_setup_requires_stopped_executor";
        return out;
    }
    std::string error;
    const bool ok = runtime_from(_effect_runtime)
        ->bind_era_reward_player_country_pod(
            static_cast<uint64_t>(country_handle), error);
    Dictionary out;
    out["ok"] = ok;
    if (!ok) out["reason"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::submit_era_advancement(const String &action,
        int64_t country, int64_t day, int64_t sequence, const Dictionary &data) {
    if (!_runtime_host) return unavailable();
    using Kind = RuntimeEraRewardRequest::Kind;
    auto request = std::make_shared<RuntimeEraRewardRequest>();
    if (action == "bind") request->kind = Kind::BIND_ADVANCEMENT;
    else if (action == "restore") request->kind = Kind::RESTORE_ADVANCEMENT;
    else if (action == "start") request->kind = Kind::START_ADVANCEMENT;
    else if (action == "pause") request->kind = Kind::PAUSE_ADVANCEMENT;
    else if (action == "resume") request->kind = Kind::RESUME_ADVANCEMENT;
    else if (action == "policy") request->kind = Kind::SET_ADVANCEMENT_POLICY;
    else return unavailable();
    request->country_handle = static_cast<uint64_t>(country);
    request->effective_day = day;
    request->advancement_sequence = sequence;
    request->advancement = data.duplicate(true);
    return _runtime_host->submit_era_reward_request(std::move(request));
}

Dictionary DCWorldExt::get_era_advancement_view() const {
    if (!_runtime_host || !_runtime_host->effect_adapter_owned()) return Dictionary();
    const auto view = _runtime_host->latest_era_advancement();
    Dictionary out;
    if (view) {
        out["model"] = view->model.duplicate(true);
        out["state"] = view->state.duplicate(true);
        out["save"] = view->save.duplicate(true);
    }
    return out;
}

Dictionary DCWorldExt::get_era_reward_offer() {
    if (_effect_runtime == nullptr) return unavailable();
    if (_runtime_host != nullptr && _runtime_host->effect_adapter_owned()) {
        const auto view = _runtime_host->latest_era_reward();
        return view ? view->offer.duplicate(true) : unavailable();
    }
    return runtime_from(_effect_runtime)->era_reward_offer_snapshot();
}

Dictionary DCWorldExt::choose_era_reward(int64_t offer_generation,
                                        int choice_index,
                                        int64_t effective_day, int64_t sequence) {
    if (_effect_runtime == nullptr) return unavailable();
    if (_runtime_host != nullptr && _runtime_host->effect_adapter_owned()) {
        auto request = std::make_shared<RuntimeEraRewardRequest>();
        request->advancement_sequence = sequence;
        request->offer_generation = offer_generation;
        request->choice = choice_index;
        request->effective_day = effective_day;
        return _runtime_host->submit_era_reward_request(std::move(request));
    }
    return runtime_from(_effect_runtime)->choose_era_reward(
        offer_generation, choice_index, effective_day);
}

Dictionary DCWorldExt::submit_effect_instances(const Dictionary &batch) {
    if (_effect_forwarder == nullptr) return unavailable();
    return _effect_forwarder->submit_batch(batch);
}

Dictionary DCWorldExt::retire_effect_instance(int64_t instance_id,
                                              int64_t generation,
                                              int64_t effective_day) {
    if (_effect_forwarder == nullptr) return unavailable();
    return _effect_forwarder->retire(instance_id, generation, effective_day);
}

Dictionary DCWorldExt::set_effect_forwarder_authority_for_test(int32_t mode) {
    const int32_t normalized = mode < 0 ? -1 : (mode != 0 ? 1 : 0);
    _effect_forwarder_authority_override = normalized;
    // Applied to the live forwarder as well, so a test can flip authority
    // between two submissions of one fixture instead of rebuilding the world.
    // configure_effects re-applies the stored value on every rebuild.
    if (_effect_forwarder != nullptr)
        _effect_forwarder->set_authority_override_for_test(normalized);
    Dictionary out;
    out["ok"] = _effect_forwarder != nullptr;
    out["reason"] = _effect_forwarder != nullptr
        ? "ok" : "effect_forwarder_not_attached";
    out["override"] = normalized;
    out["worker_authoritative"] = _effect_forwarder != nullptr &&
        _effect_forwarder->worker_authoritative();
    out["authority_epoch"] = _effect_forwarder != nullptr
        ? static_cast<int64_t>(_effect_forwarder->authority_epoch()) : 0;
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

Dictionary DCWorldExt::query_effect_instance_metric(int64_t instance_id,
                                                    int32_t metric_id) const {
    if (_effect_runtime == nullptr) return unavailable();
    int64_t value = 0;
    bool present = false;
    const bool ok = runtime_from(_effect_runtime)->instance_metric_pod(
        instance_id, metric_id, value, present);
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = ok ? "ok" : "effect_instance_metric_unavailable";
    out["value"] = value;
    out["present"] = present;
    return out;
}

Dictionary DCWorldExt::run_effect_daily(int64_t day_index) {
    if (_effect_runtime == nullptr) return unavailable();
    if (_runtime_host != nullptr &&
        _runtime_host->domain_main_thread_suppressed(RuntimeDomainId::EFFECT)) {
        Dictionary out;
        out["ok"] = true;
        out["suppressed"] = true;
        out["path"] = "EFFECT_WORKER";
        out["day"] = day_index;
        out["split_settle"] = settle_split_authority_effects(day_index);
        return out;
    }
    return runtime_from(_effect_runtime)->run_daily(day_index);
}

#include "world_ext_effect_section_settlement_and_state.inc"

} // namespace pk
