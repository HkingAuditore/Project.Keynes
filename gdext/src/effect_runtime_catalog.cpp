#include "effect_runtime.h"
#include "effect_runtime_internal.h"

namespace pk {

using namespace godot;

bool EffectRuntime::register_behavior(const std::string &behavior_id,
                                      BehaviorFn fn) {
    if (behavior_id.empty() || fn == nullptr) return false;
    std::lock_guard<std::mutex> lock(behavior_registry_mutex());
    if (!behavior_registry().emplace(behavior_id, fn).second) return false;
    behavior_hash_registry()[behavior_id_hash(behavior_id)] = fn;
    return true;
}

bool EffectRuntime::unregister_behavior(const std::string &behavior_id) {
    std::lock_guard<std::mutex> lock(behavior_registry_mutex());
    const auto it = behavior_registry().find(behavior_id);
    if (it == behavior_registry().end()) return false;
    behavior_hash_registry().erase(behavior_id_hash(behavior_id));
    behavior_registry().erase(it);
    return true;
}

EffectRuntime::BehaviorFn EffectRuntime::find_behavior(
        const std::string &behavior_id) {
    std::lock_guard<std::mutex> lock(behavior_registry_mutex());
    const auto it = behavior_registry().find(behavior_id);
    return it == behavior_registry().end() ? nullptr : it->second;
}

EffectRuntime::BehaviorFn EffectRuntime::find_behavior_hash(
        uint64_t behavior_id_hash) {
    std::lock_guard<std::mutex> lock(behavior_registry_mutex());
    const auto it = behavior_hash_registry().find(behavior_id_hash);
    return it == behavior_hash_registry().end() ? nullptr : it->second;
}

bool EffectRuntime::has_behavior(const std::string &behavior_id) {
    return find_behavior(behavior_id) != nullptr;
}

bool EffectRuntime::era_reward_option_eligible(
        const EraRewardOption &option, int64_t cash, int32_t territory,
        int64_t completed, int64_t signals) const {
    switch (option.eligibility_code) {
        case 0: return true;
        case 1: return territory >= option.eligibility_threshold;
        case 2: return cash >= option.eligibility_threshold;
        case 3: return completed < option.eligibility_threshold;
        case 4: return signals >= option.eligibility_threshold;
        case 5: return false; // Requires a registered frozen goods selector.
        default: return false;
    }
}

int64_t EffectRuntime::era_reward_option_weight(
        const EraRewardOption &option, int64_t cash, int32_t territory,
        int64_t completed, int64_t signals,
        const PackedInt32Array &signal_counts,
        const PackedInt32Array &technology_states,
        std::array<std::string, 2> &reasons, int32_t &reason_count) const {
    int64_t weight = option.base_weight;
    reason_count = 0;
    struct Hit { int64_t impact = 0; std::string reason; };
    std::vector<Hit> hits;
    for (int32_t i = option.rule_begin;
         i < option.rule_begin + option.rule_count; ++i) {
        const EraRewardRule &rule = _era_reward_rules[static_cast<size_t>(i)];
        bool hit = false;
        switch (rule.code) {
            case 0: hit = true; break;
            case 1: hit = cash < std::max<int64_t>(1, territory) * 500000; break;
            case 2: hit = territory >= rule.threshold; break;
            case 3: hit = completed < 64; break;
            case 4: hit = signals >= rule.threshold; break;
            case 5:
                hit = rule.signal_index >= 0 &&
                    rule.signal_index < signal_counts.size() &&
                    signal_counts[rule.signal_index] > 0;
                break;
            case 6:
                for (int32_t route = rule.route_technology_begin;
                     route < rule.route_technology_begin +
                         rule.route_technology_count; ++route) {
                    if (route < 0 || route >= static_cast<int32_t>(
                            _era_reward_route_technology_indices.size()))
                        continue;
                    const int32_t technology =
                        _era_reward_route_technology_indices[
                            static_cast<size_t>(route)];
                    if (technology >= 0 && technology < technology_states.size() &&
                        technology_states[technology] >= 4) {
                        hit = true;
                        break;
                    }
                }
                break;
            default: break;
        }
        if (!hit) continue;
        const int64_t before = weight;
        weight = std::max<int64_t>(1, mul_q16(weight, rule.multiplier_q16));
        if (!rule.reason.empty())
            hits.push_back({std::llabs(weight - before), rule.reason});
    }
    std::stable_sort(hits.begin(), hits.end(), [](const Hit &lhs, const Hit &rhs) {
        if (lhs.impact != rhs.impact) return lhs.impact > rhs.impact;
        return lhs.reason < rhs.reason;
    });
    reason_count = std::min<int32_t>(2, static_cast<int32_t>(hits.size()));
    for (int32_t i = 0; i < reason_count; ++i) reasons[i] = hits[i].reason;
    return weight;
}

bool EffectRuntime::era_reward_selected_modifier_commands(
        std::vector<EraRewardModifierCommand> &out, std::string &error) const {
    out.clear();
    error.clear();
    const int32_t choice = _era_reward_offer.selected_choice;
    if (choice < 0 || choice >= 3) {
        error = "era_reward_choice_invalid";
        return false;
    }
    const EraRewardAlternative &alternative =
        _era_reward_offer.alternatives[static_cast<size_t>(choice)];
    if (alternative.option_index < 0 ||
        alternative.option_index >= static_cast<int32_t>(_era_reward_options.size())) {
        error = "era_reward_frozen_alternative_invalid";
        return false;
    }
    const EraRewardOption &option = _era_reward_options[
        static_cast<size_t>(alternative.option_index)];
    if (option.program_id < 0 ||
        option.program_id >= static_cast<int32_t>(_definitions.size())) {
        error = "era_reward_program_invalid";
        return false;
    }
    const Definition &definition = _definitions[static_cast<size_t>(option.program_id)];
    for (int32_t ordinal = 0; ordinal < definition.command_count; ++ordinal) {
        const CommandDefinition &source = _command_definitions[
            static_cast<size_t>(definition.command_begin + ordinal)];
        if (source.action != MODIFIER_COMMAND || source.opcode != 1 ||
            source.definition_key.empty()) {
            error = "era_reward_host_command_unsupported";
            return false;
        }
        // Same mapping as the generic declarative Modifier adapter, so both
        // commit paths produce one identical UNIQUE_SOURCE entry.
        EraRewardModifierCommand command;
        command.definition_key = source.definition_key;
        command.domain = source.domain;
        command.target_handle = alternative.target_handle;
        command.magnitude_q16 = static_cast<int32_t>(std::clamp<int64_t>(
            source.value, 0, EFFECT_MAX_MAGNITUDE_Q16));
        command.duration_days = source.duration_days;
        command.stacks = std::max(1, source.stacks);
        command.source_id = _era_reward_offer.generation;
        out.push_back(std::move(command));
    }
    if (out.empty() || out.size() > 128) {
        error = "era_reward_transaction_command_count_invalid";
        return false;
    }
    return true;
}

Dictionary EffectRuntime::era_reward_offer_snapshot() {
    refresh_era_reward_offer_status();
    Dictionary out;
    out["ok"] = true;
    const char *status = "NONE";
    if (_era_reward_offer.status == 1) status = "OPEN";
    else if (_era_reward_offer.status == 2) status = "SELECTED_PENDING";
    else if (_era_reward_offer.status == 3) status = "RESOLVED";
    else if (_era_reward_offer.status == 4) status = "ERROR";
    out["status"] = status;
    out["plan_id"] = _era_reward_offer.plan_id;
    out["offer_generation"] = _era_reward_offer.generation;
    out["country_handle"] = static_cast<int64_t>(_era_reward_offer.country_handle);
    out["milestone_technology"] = _era_reward_offer.milestone_technology;
    out["selected_choice"] = _era_reward_offer.selected_choice;
    out["transaction_id"] = _era_reward_offer.transaction_id;
    out["plan_hash"] = static_cast<int64_t>(_era_reward_offer.plan_hash);
    out["error"] = String(_era_reward_offer.error.c_str());
    if (_era_reward_offer.pool_index >= 0 &&
        _era_reward_offer.pool_index < static_cast<int32_t>(_era_reward_pools.size())) {
        const EraRewardPool &pool = _era_reward_pools[
            static_cast<size_t>(_era_reward_offer.pool_index)];
        out["pool_id"] = String(pool.id.c_str());
        out["era_title"] = String::utf8(pool.title.c_str());
        out["final_pool"] = pool.final_pool != 0;
    }
    Array alternatives;
    if (_era_reward_offer.status != 0) {
        for (const EraRewardAlternative &alternative : _era_reward_offer.alternatives) {
            if (alternative.option_index < 0 || alternative.option_index >=
                static_cast<int32_t>(_era_reward_options.size())) continue;
            const EraRewardOption &option = _era_reward_options[
                static_cast<size_t>(alternative.option_index)];
            Dictionary row;
            row["option_id"] = String(option.id.c_str());
            row["title"] = String::utf8(option.title.c_str());
            row["description"] = String::utf8(option.description.c_str());
            row["icon_id"] = String(option.icon.c_str());
            row["weight"] = alternative.weight;
            row["target_handle"] = static_cast<int64_t>(alternative.target_handle);
            row["target_generation"] = static_cast<int64_t>(
                alternative.target_generation);
            row["target_summary"] = String::utf8(alternative.target_summary.c_str());
            PackedStringArray reasons;
            for (int32_t i = 0; i < alternative.reason_count; ++i)
                reasons.push_back(String::utf8(alternative.reasons[i].c_str()));
            row["reasons"] = reasons;
            alternatives.push_back(row);
        }
    }
    out["alternatives"] = alternatives;
    return out;
}

int32_t EffectRuntime::definition_id_for_key(const std::string &key) const {
    auto it = _definition_ids.find(key);
    return it == _definition_ids.end() ? -1 : it->second;
}

int32_t EffectRuntime::metric_id_for_key(const std::string &key) const {
    const auto found = _metric_ids.find(key);
    return found == _metric_ids.end() ? -1 : found->second;
}

int32_t EffectRuntime::native_command_definition_count() const {
    return static_cast<int32_t>(_command_definitions.size());
}

int32_t EffectRuntime::native_modifier_adapter_for_command(
        int32_t command_index) const {
    // The worker Modifier stage reads adapters out of runtime_effect_pod.h
    // because it cannot include this header without a cycle. Pin the two
    // enumerations together here (member scope, where the private enum is
    // visible) so a new adapter on one side fails the build instead of
    // silently mislabelling commands on the other.
    static_assert(NATIVE_MODIFIER_GENERIC == EFFECT_MODIFIER_GENERIC,
                  "adapter kinds drifted between EffectRuntime and the POD");
    static_assert(NATIVE_MODIFIER_TECHNOLOGY == EFFECT_MODIFIER_TECHNOLOGY,
                  "adapter kinds drifted between EffectRuntime and the POD");
    static_assert(NATIVE_MODIFIER_FAMILY == EFFECT_MODIFIER_FAMILY,
                  "adapter kinds drifted between EffectRuntime and the POD");
    static_assert(NATIVE_MODIFIER_PERSON == EFFECT_MODIFIER_PERSON,
                  "adapter kinds drifted between EffectRuntime and the POD");
    static_assert(NATIVE_MODIFIER_TRIGGER == EFFECT_MODIFIER_TRIGGER,
                  "adapter kinds drifted between EffectRuntime and the POD");
    static_assert(NATIVE_MODIFIER_FAMILY_EFFECT ==
                      EFFECT_MODIFIER_FAMILY_EFFECT,
                  "adapter kinds drifted between EffectRuntime and the POD");
    static_assert(NATIVE_MODIFIER_IDEOLOGY == EFFECT_MODIFIER_IDEOLOGY,
                  "adapter kinds drifted between EffectRuntime and the POD");
    if (command_index < 0 ||
        command_index >= static_cast<int32_t>(_command_definitions.size()))
        return EFFECT_MODIFIER_GENERIC;
    return _command_definitions[static_cast<size_t>(command_index)]
        .native_modifier_adapter;
}

bool EffectRuntime::declarative_facts_for_key(
        const std::string &key, int32_t &program_id, int32_t &source_kind,
        bool &managed_declared, int32_t &target_selector_kind,
        int32_t *target_selector_param) const {
    program_id = -1;
    source_kind = 0;
    managed_declared = false;
    target_selector_kind = 0;
    if (target_selector_param != nullptr) {
        target_selector_param[0] = 0;
        target_selector_param[1] = 0;
    }
    if (!_configured) return false;
    const int32_t index = definition_id_for_key(key);
    if (index < 0 || index >= static_cast<int32_t>(_definitions.size()))
        return false;
    const Definition &definition = _definitions[static_cast<size_t>(index)];
    program_id = index;
    source_kind = definition.source_kind;
    managed_declared = definition.managed_declared;
    target_selector_kind = definition.target_selector_kind;
    if (target_selector_param != nullptr) {
        target_selector_param[0] = definition.target_selector_param[0];
        target_selector_param[1] = definition.target_selector_param[1];
    }
    return true;
}

std::string EffectRuntime::command_key_for(const Command &command) const {
    if (command.command_definition_id >= 0 &&
        command.command_definition_id < static_cast<int32_t>(_command_definitions.size()))
        return _command_definitions[command.command_definition_id].command_key;
    if (command.command_key_id >= 0 &&
        command.command_key_id < static_cast<int32_t>(_behavior_command_keys.size()))
        return _behavior_command_keys[command.command_key_id];
    return {};
}

std::string EffectRuntime::command_definition_key_for(
        const Transaction &transaction, const Command &command) const {
    if (command.command_definition_id >= 0 &&
        command.command_definition_id < static_cast<int32_t>(_command_definitions.size()))
        return _command_definitions[command.command_definition_id].definition_key;
    if (transaction.program_id >= 0 &&
        transaction.program_id < static_cast<int32_t>(_definitions.size()))
        return _definitions[transaction.program_id].key;
    return {};
}

} // namespace pk
