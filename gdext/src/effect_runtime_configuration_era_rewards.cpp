#include "effect_runtime_configuration_includes.inc"

namespace pk {
using namespace godot;

bool EffectRuntime::compile_era_reward_catalog(const Dictionary &catalog,
                                               std::string &error) {
    _era_reward_pools.clear();
    _era_reward_options.clear();
    _era_reward_rules.clear();
    _era_reward_route_technology_indices.clear();
    _era_reward_pool_by_technology.clear();
    const PackedStringArray pool_ids = get_strings(catalog, "era_reward_pool_ids");
    // Focused Effect catalogs may intentionally omit the optional gameplay
    // extension. The production EffectDomainCatalog always supplies it and
    // the strict 11x9 validation below then applies.
    if (!catalog.has("era_reward_pool_ids")) return true;
    const auto reward_command_whitelisted = [](const CommandDefinition &command) {
        if (command.action == MODIFIER_COMMAND)
            return command.domain >= 0 && command.domain <= 3 &&
                (command.opcode == ModifierApi::COMMAND_APPLY ||
                 command.opcode == ModifierApi::COMMAND_REMOVE);
        if (command.action == COUNTRY_COMMAND)
            return command.domain == 1 &&
                command.opcode == CountryApi::COMMAND_GRANT_TECHNOLOGY;
        if (command.action == ECONOMY_COMMAND)
            return command.domain == 2 && command.opcode >= 1 && command.opcode <= 8;
        if (command.action == GAMEPLAY_COMMAND || command.action == PUBLISH_EVENT)
            return command.opcode > 0;
        return false;
    };
    const PackedStringArray pool_titles = get_strings(catalog, "era_reward_pool_titles");
    const PackedInt32Array trigger_tech = get_i32(
        catalog, "era_reward_trigger_technology_indices");
    const PackedByteArray pool_final = get_u8(catalog, "era_reward_pool_final");
    const PackedInt32Array option_offsets = get_i32(
        catalog, "era_reward_option_offsets");
    const PackedStringArray option_ids = get_strings(catalog, "era_reward_option_ids");
    const PackedStringArray option_titles = get_strings(
        catalog, "era_reward_option_titles");
    const PackedStringArray option_descriptions = get_strings(
        catalog, "era_reward_option_descriptions");
    const PackedStringArray option_icons = get_strings(
        catalog, "era_reward_option_icons");
    const PackedInt32Array option_weights = get_i32(
        catalog, "era_reward_option_weights");
    const PackedByteArray option_fallback = get_u8(
        catalog, "era_reward_option_fallback");
    const PackedInt32Array eligibility_codes = get_i32(
        catalog, "era_reward_option_eligibility_codes");
    const PackedInt64Array eligibility_thresholds = get_i64(
        catalog, "era_reward_option_eligibility_thresholds");
    const PackedInt32Array rule_offsets = get_i32(catalog, "era_reward_rule_offsets");
    const PackedInt32Array rule_codes = get_i32(catalog, "era_reward_rule_codes");
    const PackedInt64Array rule_thresholds = get_i64(
        catalog, "era_reward_rule_thresholds");
    const PackedInt32Array rule_multipliers = get_i32(
        catalog, "era_reward_rule_multipliers_q16");
    const PackedStringArray rule_reasons = get_strings(
        catalog, "era_reward_rule_reasons");
    const PackedInt32Array rule_signal_indices = get_i32(
        catalog, "era_reward_rule_signal_indices");
    const PackedInt32Array rule_route_offsets = get_i32(
        catalog, "era_reward_rule_route_technology_offsets");
    const PackedInt32Array rule_route_technologies = get_i32(
        catalog, "era_reward_rule_route_technology_indices");
    const PackedInt32Array command_offsets = get_i32(
        catalog, "era_reward_command_offsets");
    const PackedStringArray command_definition_keys = get_strings(
        catalog, "era_reward_command_definition_keys");
    const PackedStringArray command_effect_keys = get_strings(
        catalog, "era_reward_command_effect_keys");
    const PackedInt32Array selector_entity_types = get_i32(
        catalog, "era_reward_selector_entity_types");
    const PackedInt32Array selector_filter_codes = get_i32(
        catalog, "era_reward_selector_filter_codes");
    const PackedInt32Array selector_rankings = get_i32(
        catalog, "era_reward_selector_rankings");
    const PackedInt32Array selector_top_n = get_i32(
        catalog, "era_reward_selector_top_n");
    const PackedInt32Array selector_minimum = get_i32(
        catalog, "era_reward_selector_minimum");
    if (pool_ids.size() != 11 || pool_titles.size() != 11 ||
        trigger_tech.size() != 11 || pool_final.size() != 11 ||
        option_offsets.size() != 12 || option_offsets[0] != 0 ||
        option_offsets[11] != 99 || option_ids.size() != 99 ||
        option_titles.size() != 99 || option_descriptions.size() != 99 ||
        option_icons.size() != 99 || option_weights.size() != 99 ||
        option_fallback.size() != 99 || eligibility_codes.size() != 99 ||
        eligibility_thresholds.size() != 99 || rule_offsets.size() != 100 ||
        command_offsets.size() != 100 || rule_offsets[0] != 0 ||
        command_offsets[0] != 0 ||
        rule_codes.size() != rule_thresholds.size() ||
        rule_codes.size() != rule_multipliers.size() ||
        rule_codes.size() != rule_reasons.size() ||
        rule_codes.size() != rule_signal_indices.size() ||
        rule_route_offsets.size() != rule_codes.size() + 1 ||
        rule_route_offsets[0] != 0 ||
        rule_route_offsets[rule_route_offsets.size() - 1] !=
            rule_route_technologies.size() ||
        command_definition_keys.size() != command_effect_keys.size() ||
        command_effect_keys.size() != selector_entity_types.size() ||
        command_effect_keys.size() != selector_filter_codes.size() ||
        command_effect_keys.size() != selector_rankings.size() ||
        command_effect_keys.size() != selector_top_n.size() ||
        command_effect_keys.size() != selector_minimum.size()) {
        error = "era_reward_catalog_shape_invalid";
        return false;
    }
    std::unordered_set<std::string> seen;
    for (int32_t pool_index = 0; pool_index < 11; ++pool_index) {
        const int32_t begin = option_offsets[pool_index];
        const int32_t end = option_offsets[pool_index + 1];
        if (end - begin != 9 || trigger_tech[pool_index] < 0 ||
            !_era_reward_pool_by_technology.emplace(
                trigger_tech[pool_index], pool_index).second) {
            error = "era_reward_pool_shape_invalid";
            return false;
        }
        EraRewardPool pool;
        pool.id = string_at(pool_ids, pool_index);
        pool.title = string_at(pool_titles, pool_index);
        pool.trigger_technology = trigger_tech[pool_index];
        pool.final_pool = pool_final[pool_index];
        pool.option_begin = begin;
        pool.option_count = end - begin;
        if (pool.id.empty() || pool.title.empty() || !seen.emplace(pool.id).second) {
            error = "era_reward_pool_identity_invalid";
            return false;
        }
        _era_reward_pools.push_back(std::move(pool));
    }
    seen.clear();
    for (int32_t option_index = 0; option_index < 99; ++option_index) {
        if (rule_offsets[option_index] > rule_offsets[option_index + 1] ||
            command_offsets[option_index] > command_offsets[option_index + 1] ||
            command_offsets[option_index + 1] - command_offsets[option_index] < 1 ||
            command_offsets[option_index + 1] - command_offsets[option_index] > 128) {
            error = "era_reward_option_offsets_invalid";
            return false;
        }
        const int32_t command_begin = command_offsets[option_index];
        int32_t expanded_bound = 0;
        int32_t program_id = -1;
        for (int32_t row = command_begin; row < command_offsets[option_index + 1]; ++row) {
            if (row < 0 || row >= command_effect_keys.size() ||
                string_at(command_definition_keys, row).empty() ||
                selector_entity_types[row] < 0 || selector_entity_types[row] > 6 ||
                selector_filter_codes[row] < 0 ||
                selector_rankings[row] < 0 || selector_rankings[row] > 4 ||
                selector_top_n[row] < 1 || selector_top_n[row] > 32 ||
                selector_minimum[row] < 1 ||
                selector_minimum[row] > selector_top_n[row]) {
                error = "era_reward_selector_invalid";
                return false;
            }
            if (option_fallback[option_index] != 0 &&
                (selector_entity_types[row] != 0 || selector_top_n[row] != 1)) {
                error = "era_reward_fallback_target_invalid";
                return false;
            }
            expanded_bound += selector_top_n[row];
            const auto found = _definition_ids.find(string_at(command_effect_keys, row));
            if (found == _definition_ids.end() ||
                (program_id >= 0 && program_id != found->second)) {
                error = "era_reward_effect_program_missing";
                return false;
            }
            program_id = found->second;
            const Definition &reward_definition = _definitions[
                static_cast<size_t>(program_id)];
            for (int32_t command_index = reward_definition.command_begin;
                 command_index < reward_definition.command_begin +
                     reward_definition.command_count; ++command_index) {
                if (command_index < 0 ||
                    command_index >= static_cast<int32_t>(_command_definitions.size()) ||
                    !reward_command_whitelisted(_command_definitions[
                        static_cast<size_t>(command_index)])) {
                    error = "era_reward_command_not_whitelisted";
                    return false;
                }
            }
        }
        if (expanded_bound > 128 || program_id < 0) {
            error = "era_reward_expanded_command_limit_invalid";
            return false;
        }
        EraRewardOption option;
        option.id = string_at(option_ids, option_index);
        option.title = string_at(option_titles, option_index);
        option.description = string_at(option_descriptions, option_index);
        option.icon = string_at(option_icons, option_index);
        option.base_weight = option_weights[option_index];
        option.fallback = option_fallback[option_index];
        option.eligibility_code = eligibility_codes[option_index];
        option.eligibility_threshold = eligibility_thresholds[option_index];
        option.rule_begin = rule_offsets[option_index];
        option.rule_count = rule_offsets[option_index + 1] - option.rule_begin;
        option.program_id = program_id;
        if (option.id.empty() || option.title.empty() || option.base_weight <= 0 ||
            !seen.emplace(option.id).second ||
            (option.fallback != 0 && option.eligibility_code != 0)) {
            error = "era_reward_option_identity_invalid";
            return false;
        }
        _era_reward_options.push_back(std::move(option));
    }
    if (rule_offsets[99] != rule_codes.size() ||
        command_offsets[99] != command_effect_keys.size()) {
        error = "era_reward_catalog_terminal_offset_invalid";
        return false;
    }
    for (int32_t row = 0; row < rule_codes.size(); ++row) {
        if (rule_codes[row] < 0 || rule_codes[row] > 6 ||
            rule_route_offsets[row] > rule_route_offsets[row + 1] ||
            rule_multipliers[row] <= 0 || rule_multipliers[row] > 262144) {
            error = "era_reward_weight_rule_invalid";
            return false;
        }
        if ((rule_codes[row] == 5 && rule_signal_indices[row] < 0) ||
            (rule_codes[row] == 6 &&
             rule_route_offsets[row] == rule_route_offsets[row + 1])) {
            error = "era_reward_context_rule_invalid";
            return false;
        }
        _era_reward_rules.push_back({rule_codes[row], rule_thresholds[row],
            rule_multipliers[row], rule_signal_indices[row],
            rule_route_offsets[row],
            rule_route_offsets[row + 1] - rule_route_offsets[row],
            string_at(rule_reasons, row)});
    }
    _era_reward_route_technology_indices.reserve(
        static_cast<size_t>(rule_route_technologies.size()));
    for (int32_t technology : rule_route_technologies) {
        if (technology < 0) {
            error = "era_reward_route_technology_invalid";
            return false;
        }
        _era_reward_route_technology_indices.push_back(technology);
    }
    for (const EraRewardPool &pool : _era_reward_pools) {
        int32_t fallbacks = 0;
        for (int32_t i = pool.option_begin;
             i < pool.option_begin + pool.option_count; ++i)
            fallbacks += _era_reward_options[i].fallback != 0 ? 1 : 0;
        if (fallbacks != 3) {
            error = "era_reward_fallback_count_invalid";
            return false;
        }
    }
    return true;
}

bool EffectRuntime::bind_era_reward_player_country_pod(uint64_t country_handle,
                                                       std::string &error) {
    if (!_configured || _country_runtime == nullptr) {
        error = "era_reward_runtime_unavailable";
        return false;
    }
    if (country_handle == 0 ||
        !country_api::valid_handle(*_country_runtime, static_cast<int64_t>(country_handle))) {
        error = "era_reward_player_country_invalid";
        return false;
    }
    if (_era_reward_player_country != 0 &&
        _era_reward_player_country != country_handle &&
        _era_reward_offer.status != 0 && _era_reward_offer.status != 3) {
        error = "era_reward_player_rebind_while_offer_open";
        return false;
    }
    _era_reward_player_country = country_handle;
    return true;
}

bool EffectRuntime::notify_era_reward_technology_activated_pod(
        uint64_t country_handle, int32_t technology_id, int64_t day_index,
        std::string &error) {
    if (!_configured || _country_runtime == nullptr) {
        error = "era_reward_runtime_unavailable";
        return false;
    }
    if (_era_reward_player_country == 0 ||
        country_handle != _era_reward_player_country)
        return true;
    const auto found = _era_reward_pool_by_technology.find(technology_id);
    if (found == _era_reward_pool_by_technology.end()) return true;
    refresh_era_reward_offer_status();
    if (_era_reward_offer.status == 1 || _era_reward_offer.status == 2 ||
        _era_reward_offer.status == 4) {
        error = "era_reward_previous_offer_unresolved";
        return false;
    }
    return plan_era_reward_offer(found->second, country_handle, day_index, error);
}

bool EffectRuntime::plan_era_reward_offer(int32_t pool_index,
                                          uint64_t country_handle,
                                          int64_t day_index,
                                          std::string &error) {
    const auto plan_start = std::chrono::steady_clock::now();
    const NativeCountryRuntime *source = _era_reward_country_view != nullptr
        ? _era_reward_country_view : _country_runtime;
    if (pool_index < 0 || pool_index >= static_cast<int32_t>(_era_reward_pools.size()) ||
        _country_runtime == nullptr ||
        !country_api::valid_handle(*source, static_cast<int64_t>(country_handle))) {
        error = "era_reward_plan_input_invalid";
        return false;
    }
    const Dictionary country = country_api::country_snapshot(*source,
        static_cast<int64_t>(country_handle));
    const Dictionary treasury = country_api::treasury_snapshot(*source,
        static_cast<int64_t>(country_handle));
    const Dictionary research = country_api::research_snapshot(*source,
        static_cast<int64_t>(country_handle));
    const Dictionary signals_snapshot = country_api::research_signal_snapshot(*source,
        static_cast<int64_t>(country_handle));
    if (!static_cast<bool>(country.get("ok", false)) ||
        !static_cast<bool>(treasury.get("ok", false)) ||
        !static_cast<bool>(research.get("ok", false)) ||
        !static_cast<bool>(signals_snapshot.get("ok", false))) {
        error = "era_reward_frozen_snapshot_unavailable";
        return false;
    }
    const PackedInt32Array territory_cells = country.get(
        "territory_cells", PackedInt32Array());
    const int32_t territory = territory_cells.size();
    const int64_t cash = treasury.get("cash", 0);
    const int64_t completed = research.get("completed_total", 0);
    const PackedInt32Array evidence_signal_ids = signals_snapshot.get(
        "signal_ids", PackedInt32Array());
    const PackedInt32Array evidence_signal_counts = signals_snapshot.get(
        "counts", PackedInt32Array());
    PackedInt32Array signal_counts;
    int32_t maximum_signal = -1;
    for (int32_t i = 0; i < evidence_signal_ids.size(); ++i)
        maximum_signal = std::max(maximum_signal, evidence_signal_ids[i]);
    if (maximum_signal >= 0) signal_counts.resize(maximum_signal + 1);
    const PackedInt32Array technology_states = research.get(
        "technology_states", PackedInt32Array());
    int64_t signals = 0;
    for (int32_t i = 0; i < evidence_signal_ids.size(); ++i) {
        const int32_t signal = evidence_signal_ids[i];
        const int32_t count = i < evidence_signal_counts.size()
            ? evidence_signal_counts[i] : 0;
        if (signal >= 0 && signal < signal_counts.size())
            signal_counts.set(signal, count);
        signals += count;
    }
    const EraRewardPool &pool = _era_reward_pools[static_cast<size_t>(pool_index)];
    struct WeightedCandidate {
        int32_t option = -1;
        int64_t weight = 0;
        std::array<std::string, 2> reasons{};
        int32_t reason_count = 0;
    };
    std::vector<WeightedCandidate> normal;
    std::vector<WeightedCandidate> fallbacks;
    for (int32_t option_index = pool.option_begin;
         option_index < pool.option_begin + pool.option_count; ++option_index) {
        const EraRewardOption &option = _era_reward_options[
            static_cast<size_t>(option_index)];
        if (!era_reward_option_eligible(option, cash, territory, completed, signals))
            continue;
        WeightedCandidate candidate;
        candidate.option = option_index;
        candidate.weight = era_reward_option_weight(option, cash, territory,
            completed, signals, signal_counts, technology_states,
            candidate.reasons, candidate.reason_count);
        (option.fallback != 0 ? fallbacks : normal).push_back(std::move(candidate));
    }
    uint64_t seed = static_cast<uint64_t>(country_api::world_seed(*source));
    seed = fnv_string(seed, String(country.get("country_id", "")).utf8().get_data());
    seed = fnv_string(seed, pool.id);
    seed = fnv_value(seed, _era_reward_next_generation);
    std::array<WeightedCandidate, 3> selected{};
    int32_t selected_count = 0;
    while (selected_count < 3 && !normal.empty()) {
        uint64_t total = 0;
        for (const WeightedCandidate &candidate : normal)
            total += static_cast<uint64_t>(std::max<int64_t>(1, candidate.weight));
        const uint64_t pick = total > 0 ? splitmix64_next(seed) % total : 0;
        uint64_t cursor = 0;
        size_t chosen = 0;
        for (; chosen < normal.size(); ++chosen) {
            cursor += static_cast<uint64_t>(std::max<int64_t>(1, normal[chosen].weight));
            if (pick < cursor) break;
        }
        if (chosen >= normal.size()) chosen = normal.size() - 1;
        selected[selected_count++] = normal[chosen];
        normal.erase(normal.begin() + static_cast<ptrdiff_t>(chosen));
    }
    while (selected_count < 3 && !fallbacks.empty()) {
        const size_t chosen = static_cast<size_t>(
            splitmix64_next(seed) % fallbacks.size());
        selected[selected_count++] = fallbacks[chosen];
        fallbacks.erase(fallbacks.begin() + static_cast<ptrdiff_t>(chosen));
    }
    if (selected_count != 3) {
        error = "era_reward_offer_cannot_fill_three";
        return false;
    }
    EraRewardOffer offer;
    offer.plan_id = _era_reward_next_plan_id++;
    offer.generation = _era_reward_next_generation++;
    offer.pool_index = pool_index;
    offer.milestone_technology = pool.trigger_technology;
    offer.country_handle = country_handle;
    offer.country_generation = static_cast<uint32_t>(country_handle >> 32U);
    offer.status = 1;
    offer.plan_hash = 1469598103934665603ULL;
    offer.plan_hash = fnv_value(offer.plan_hash, offer.plan_id);
    offer.plan_hash = fnv_value(offer.plan_hash, offer.generation);
    offer.plan_hash = fnv_value(offer.plan_hash, day_index);
    offer.plan_hash = fnv_string(offer.plan_hash, pool.id);
    for (int32_t i = 0; i < 3; ++i) {
        EraRewardAlternative &alternative = offer.alternatives[i];
        alternative.option_index = selected[i].option;
        alternative.weight = selected[i].weight;
        alternative.target_handle = country_handle;
        alternative.target_generation = offer.country_generation;
        alternative.reasons = selected[i].reasons;
        alternative.reason_count = selected[i].reason_count;
        alternative.target_summary = String(country.get("country_name", "")).utf8().get_data();
        const EraRewardOption &option = _era_reward_options[
            static_cast<size_t>(alternative.option_index)];
        offer.plan_hash = fnv_string(offer.plan_hash, option.id);
        offer.plan_hash = fnv_value(offer.plan_hash, alternative.weight);
        offer.plan_hash = fnv_value(offer.plan_hash, alternative.target_handle);
        offer.plan_hash = fnv_value(offer.plan_hash, alternative.target_generation);
        for (int32_t reason = 0; reason < alternative.reason_count; ++reason)
            offer.plan_hash = fnv_string(offer.plan_hash, alternative.reasons[reason]);
    }
    _era_reward_offer = std::move(offer);
    _last_era_reward_expanded_commands = 0;
    for (const EraRewardAlternative &alternative : _era_reward_offer.alternatives) {
        const int32_t option_index = alternative.option_index;
        if (option_index < 0 ||
            option_index >= static_cast<int32_t>(_era_reward_options.size()))
            continue;
        const int32_t program_id = _era_reward_options[
            static_cast<size_t>(option_index)].program_id;
        if (program_id >= 0 && program_id < static_cast<int32_t>(_definitions.size()))
            _last_era_reward_expanded_commands += _definitions[
                static_cast<size_t>(program_id)].command_count;
    }
    _last_era_reward_plan_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - plan_start).count();
    ++_era_reward_offers_planned;
    country_api::set_era_reward_reference_pod(*_country_runtime,
        _era_reward_offer.plan_id, _era_reward_offer.generation,
        _era_reward_offer.milestone_technology, _era_reward_offer.status);
    return true;
}

Dictionary EffectRuntime::choose_era_reward(int64_t offer_generation,
                                             int32_t choice_index,
                                             int64_t effective_day,
                                             bool host_commit) {
    refresh_era_reward_offer_status();
    if (!_configured) return failure("effect_runtime_unconfigured");
    if (_era_reward_offer.status != 1 ||
        _era_reward_offer.generation != offer_generation)
        return failure("era_reward_offer_generation_stale");
    if (choice_index < 0 || choice_index >= 3 || effective_day < 0)
        return failure("era_reward_choice_invalid");
    const EraRewardAlternative &alternative =
        _era_reward_offer.alternatives[static_cast<size_t>(choice_index)];
    if (alternative.option_index < 0 ||
        alternative.option_index >= static_cast<int32_t>(_era_reward_options.size()))
        return failure("era_reward_frozen_alternative_invalid");
    const EraRewardOption &option = _era_reward_options[
        static_cast<size_t>(alternative.option_index)];
    if (option.program_id < 0 ||
        option.program_id >= static_cast<int32_t>(_definitions.size()))
        return failure("era_reward_program_invalid");
    const Definition &definition = _definitions[static_cast<size_t>(option.program_id)];
    if (host_commit) {
        _era_reward_offer.selected_choice = choice_index;
        std::vector<EraRewardModifierCommand> commands;
        std::string error;
        if (!era_reward_selected_modifier_commands(commands, error)) {
            _era_reward_offer.selected_choice = -1;
            return failure(error.c_str());
        }
        _era_reward_offer.status = 2;
        _era_reward_offer.transaction_id = 0;
        if (_country_runtime != nullptr)
            country_api::set_era_reward_reference_pod(*_country_runtime,
                _era_reward_offer.plan_id, _era_reward_offer.generation,
                _era_reward_offer.milestone_technology, _era_reward_offer.status);
        Dictionary out;
        out["ok"] = true;
        out["offer_generation"] = offer_generation;
        out["choice_index"] = choice_index;
        out["transaction_id"] = 0;
        return out;
    }
    const int64_t instance_id = static_cast<int64_t>(
        0x4552410000000000ULL | (static_cast<uint64_t>(_era_reward_offer.plan_id) &
                                0x000000ffffffffffULL));
    std::string error;
    if (!upsert_instance_pod(instance_id, definition.key, 1, ERA_REWARD_SOURCE_TYPE,
            _era_reward_offer.generation, _era_reward_offer.country_handle,
            alternative.target_handle, alternative.target_generation, 0,
            effective_day, false, error))
        return failure(error.c_str());
    if (static_cast<int32_t>(_transactions.size()) >= _max_transactions) {
        compact_terminal_transactions();
        if (static_cast<int32_t>(_transactions.size()) >= _max_transactions)
            return failure("effect_transaction_capacity_exceeded");
    }
    Transaction transaction;
    transaction.id = _next_transaction_id++;
    transaction.source_instance_id = instance_id;
    transaction.source_generation = 1;
    transaction.program_id = option.program_id;
    transaction.effective_day = effective_day;
    for (int32_t ordinal = 0; ordinal < definition.command_count; ++ordinal) {
        const int32_t command_definition_id = definition.command_begin + ordinal;
        const CommandDefinition &source = _command_definitions[
            static_cast<size_t>(command_definition_id)];
        Command command;
        command.action = source.action;
        command.domain = source.domain;
        command.opcode = source.opcode;
        command.target_handle = alternative.target_handle;
        command.target_generation = alternative.target_generation;
        command.value_q16 = source.value;
        command.duration_days = source.duration_days;
        command.stacks = source.stacks;
        command.command_key_id = command_definition_id;
        command.command_definition_id = command_definition_id;
        command.payload = source.payload;
        command.idempotency_key = make_hash(
            static_cast<uint64_t>(instance_id), 1,
            static_cast<uint64_t>(_era_reward_offer.generation), ordinal);
        append_command(transaction, command);
    }
    if (transaction.command_count == 0 || transaction.command_count > 128)
        return failure("era_reward_transaction_command_count_invalid");
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
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->action);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->domain);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->opcode);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->target_handle);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->target_generation);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->value_q16);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->duration_days);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->stacks);
        transaction.plan_hash = fnv_value(transaction.plan_hash, stored->command_key_id);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->command_definition_id);
        for (int64_t value : stored->payload)
            transaction.plan_hash = fnv_value(transaction.plan_hash, value);
        transaction.plan_hash = fnv_value(transaction.plan_hash,
            stored->idempotency_key);
    }
    _transactions.push_back(std::move(transaction));
    _transaction_ids[_transactions.back().id] =
        static_cast<int32_t>(_transactions.size() - 1);
    track_pending_transaction(_transactions.back());
    index_transaction_commands(_transactions.back());
    _era_reward_offer.status = 2;
    _era_reward_offer.selected_choice = choice_index;
    _era_reward_offer.transaction_id = _transactions.back().id;
    if (_country_runtime != nullptr)
        country_api::set_era_reward_reference_pod(*_country_runtime,
            _era_reward_offer.plan_id, _era_reward_offer.generation,
            _era_reward_offer.milestone_technology, _era_reward_offer.status);
    Dictionary out;
    out["ok"] = true;
    out["offer_generation"] = offer_generation;
    out["choice_index"] = choice_index;
    out["transaction_id"] = _era_reward_offer.transaction_id;
    return out;
}

void EffectRuntime::settle_era_reward_selection_pod(bool ok, const char *error) {
    if (!era_reward_host_selection_pending()) return;
    _era_reward_offer.status = ok ? 3 : 4;
    if (!ok) _era_reward_offer.error = error != nullptr && error[0] != '\0'
        ? error : "era_reward_transaction_rejected";
    if (_country_runtime != nullptr)
        country_api::set_era_reward_reference_pod(*_country_runtime,
            _era_reward_offer.plan_id, _era_reward_offer.generation,
            _era_reward_offer.milestone_technology, _era_reward_offer.status);
}

void EffectRuntime::refresh_era_reward_offer_status() {
    if (_era_reward_offer.status != 2 || _era_reward_offer.transaction_id <= 0)
        return;
    const int32_t status = transaction_status_pod(
        _era_reward_offer.transaction_id);
    if (status == ACKED) {
        _era_reward_offer.status = 3;
    } else if (status == REJECTED || status == RESYNC_REQUIRED || status == 0) {
        _era_reward_offer.status = 4;
        _era_reward_offer.error = status == RESYNC_REQUIRED
            ? "era_reward_resync_required" : "era_reward_transaction_rejected";
    }
    if (_country_runtime != nullptr &&
        (_era_reward_offer.status == 3 || _era_reward_offer.status == 4))
        country_api::set_era_reward_reference_pod(*_country_runtime,
            _era_reward_offer.plan_id, _era_reward_offer.generation,
            _era_reward_offer.milestone_technology, _era_reward_offer.status);
}

} // namespace pk
