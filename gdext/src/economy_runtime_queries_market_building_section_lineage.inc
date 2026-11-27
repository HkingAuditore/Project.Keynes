Dictionary NativeEconomyRuntime::family_cell_snapshot(
        int32_t cell_idx, int32_t offset, int32_t limit) const {
    Dictionary out;
    out["cell_idx"] = cell_idx;
    out["committed"] = !_epoch_active && !_fatal;
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count.get()) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" :
            "cell_out_of_range";
        return out;
    }
    offset = std::max(0, offset);
    limit = std::clamp(limit, 1, 256);
    std::vector<int32_t> indices;
    if (_family_cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)) {
        for (int32_t p = _family_cell_offsets[cell_idx];
             p < _family_cell_offsets[cell_idx + 1]; ++p)
            indices.push_back(_family_cell_indices[p]);
    }
    std::sort(indices.begin(), indices.end(), [&](int32_t a, int32_t b) {
        const uint64_t ah = families_store().handle_for_index(a);
        const uint64_t bh = families_store().handle_for_index(b);
        const int64_t ap = family_population(ah);
        const int64_t bp = family_population(bh);
        return ap != bp ? ap > bp : families_store().stable_id[a] <
            families_store().stable_id[b];
    });
    PackedInt64Array handles, stable_ids, populations, cash_claims,
        owned_buildings;
    PackedInt32Array notable_person_counts, prestige_levels, prestige_scores;
    PackedStringArray surnames;
    PackedInt32Array disambiguators, home_cells, origin_cells,
        origin_ethnicities, culture_groups;
    const int32_t end = std::min<int32_t>(indices.size(), offset + limit);
    for (int32_t pos = offset; pos < end; ++pos) {
        const int32_t index = indices[pos];
        const uint64_t handle = families_store().handle_for_index(index);
        handles.push_back(static_cast<int64_t>(handle));
        stable_ids.push_back(families_store().stable_id[index]);
        const int32_t surname = families_store().surname_id[index];
        surnames.push_back(surname >= 0 && surname < static_cast<int32_t>(
            _family_surname_text.size()) ? from_utf8(
                _family_surname_text[surname]) : String());
        disambiguators.push_back(static_cast<int32_t>(
            families_store().surname_disambiguator[index]));
        populations.push_back(family_population(handle));
        cash_claims.push_back(family_cash_claim(handle));
        owned_buildings.push_back(family_owned_buildings(handle));
        home_cells.push_back(families_store().home_cell[index]);
        origin_cells.push_back(families_store().origin_cell[index]);
        origin_ethnicities.push_back(families_store().origin_ethnicity[index]);
        culture_groups.push_back(families_store().culture_group_id[index]);
        notable_person_counts.push_back(_person_family_offsets.size() ==
                families_store().active.size() + 1
            ? _person_family_offsets[index + 1] - _person_family_offsets[index]
            : 0);
        int32_t prestige = 0, score = 0;
        for (int32_t branch = 0; branch < static_cast<int32_t>(
                family_influences().active.size()); ++branch) {
            if (family_influences().active[branch] != 0 &&
                family_influences().family_handle[branch] == handle &&
                family_influences().cell[branch] == cell_idx) {
                prestige = family_influences().prestige_level[branch];
                score = family_influences().score_q16[branch];
                break;
            }
        }
        prestige_levels.push_back(prestige);
        prestige_scores.push_back(score);
    }
    out["ok"] = true;
    out["offset"] = offset;
    out["limit"] = limit;
    out["total"] = static_cast<int32_t>(indices.size());
    out["has_more"] = end < static_cast<int32_t>(indices.size());
    out["family_handles"] = handles;
    out["stable_ids"] = stable_ids;
    out["surnames"] = surnames;
    out["surname_disambiguators"] = disambiguators;
    out["populations"] = populations;
    out["cash_claims"] = cash_claims;
    out["owned_buildings"] = owned_buildings;
    out["home_cells"] = home_cells;
    out["origin_cells"] = origin_cells;
    out["origin_ethnicity_ids"] = origin_ethnicities;
    out["culture_group_ids"] = culture_groups;
    out["notable_person_counts"] = notable_person_counts;
    out["prestige_levels"] = prestige_levels;
    out["prestige_scores_q16"] = prestige_scores;
    return out;
}

Dictionary NativeEconomyRuntime::submit_family_trait_commands(
        const Dictionary &batch) {
    Dictionary out;
    if (!_configured) {
        out["ok"] = false;
        out["reason"] = "economy_not_configured";
        return out;
    }
    if (dict_num<int32_t>(batch, "protocol_version", 0) != 1) {
        out["ok"] = false;
        out["reason"] = "family_trait_protocol_unsupported";
        return out;
    }
    const std::vector<int32_t> operations = packed_i32(batch, "operations");
    const std::vector<int64_t> handles = packed_i64(batch, "family_handles");
    const std::vector<std::string> keys = packed_strings(batch, "trait_keys");
    const std::vector<int32_t> strengths = packed_i32(batch, "strength_q16");
    const std::vector<int64_t> days = packed_i64(batch, "effective_days");
    const std::vector<int32_t> priorities = packed_i32(batch, "priorities");
    const std::vector<int64_t> sequences = packed_i64(batch, "sequences");
    const size_t count = operations.size();
    if (count == 0 || handles.size() != count || keys.size() != count ||
        strengths.size() != count || days.size() != count ||
        priorities.size() != count || sequences.size() != count) {
        out["ok"] = false;
        out["reason"] = "family_trait_command_shape_invalid";
        return out;
    }
    std::vector<FamilyTraitCommand> commands;
    commands.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        std::string error;
        const int32_t id = resolve_family_trait_command(operations[i], handles[i], keys[i],
            strengths[i], days[i], error);
        if (id < 0) {
            out["ok"] = false;
            out["reason"] = error.c_str();
            return out;
        }
        commands.push_back({operations[i], static_cast<uint64_t>(handles[i]), id,
            strengths[i], days[i], priorities[i], sequences[i], ++_next_submit_order});
    }
    _family_trait_commands.insert(_family_trait_commands.end(),
        commands.begin(), commands.end());
    PackedInt64Array request_orders;
    for (const FamilyTraitCommand &command : commands)
        request_orders.push_back(static_cast<int64_t>(command.submit_order));
    out["ok"] = true;
    out["request_orders"] = request_orders;
    out["pending_count"] = static_cast<int64_t>(_family_trait_commands.size());
    return out;
}

Dictionary NativeEconomyRuntime::family_snapshot(int64_t family_handle_value) const {
    Dictionary out;
    const uint64_t handle = static_cast<uint64_t>(family_handle_value);
    int32_t index = -1;
    if (!_bootstrapped || !families_store().valid_handle(handle, index)) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" :
            "family_handle_invalid";
        return out;
    }
    std::vector<int64_t> profession_people(_profession_ids.size(), 0);
    std::vector<int64_t> profession_owner(_profession_ids.size(), 0);
    std::vector<int64_t> profession_employee(_profession_ids.size(), 0);
    const bool member_csr_ready = _family_member_offsets.size() ==
        families_store().active.size() + 1;
    const int32_t member_begin = member_csr_ready
        ? _family_member_offsets[index] : 0;
    const int32_t member_end = member_csr_ready
        ? _family_member_offsets[index + 1]
        : static_cast<int32_t>(family_memberships().size());
    for (int32_t p = member_begin; p < member_end; ++p) {
        const FamilyMembershipEdge &edge = family_memberships()[
            member_csr_ready ? _family_member_edge_indices[p] : p];
        if (edge.family_handle != handle) continue;
        int32_t slot = -1;
        if (!population_store().valid_handle(edge.cohort_handle, slot)) continue;
        const int32_t signature = static_cast<int32_t>(
            population_store().signature_id[slot]);
        const int32_t profession = _signatures[signature].profession_id;
        profession_people[profession] += edge.people;
        profession_owner[profession] += edge.owner_employed;
        profession_employee[profession] += edge.employee_employed;
    }
    int64_t transit_population = 0;
    for (size_t expedition = 0; expedition < family_expeditions_store().active.size(); ++expedition) {
        if (family_expeditions_store().active[expedition] == 0 ||
            family_expeditions_store().family_handle[expedition] != handle) continue;
        transit_population += family_expedition_payload_people(
            static_cast<int32_t>(expedition));
        const uint32_t begin = family_expeditions_store().payload_begin[expedition];
        const uint32_t count = family_expeditions_store().payload_count[expedition];
        for (uint32_t p = 0; p < count; ++p) {
            const FamilyExpeditionPayload &payload =
                family_expedition_payloads()[begin + p];
            if (payload.signature < 0 ||
                payload.signature >= static_cast<int32_t>(_signatures.size())) continue;
            const int32_t profession = _signatures[payload.signature].profession_id;
            profession_people[profession] += payload.people;
        }
    }
    PackedInt32Array professions;
    PackedInt64Array people, owners, employees;

    for (int32_t p = 0; p < static_cast<int32_t>(_profession_ids.size()); ++p) {
        if (profession_people[p] <= 0) continue;
        professions.push_back(p);
        people.push_back(profession_people[p]);
        owners.push_back(profession_owner[p]);
        employees.push_back(profession_employee[p]);
    }
    int64_t asset_value = 0;
    int64_t capital_value = 0;
    int64_t asset_sat = 0;
    const bool owned_csr_ready = _family_owned_offsets.size() ==
        families_store().active.size() + 1;
    const int32_t owned_begin = owned_csr_ready
        ? _family_owned_offsets[index] : 0;
    const int32_t owned_end = owned_csr_ready
        ? _family_owned_offsets[index + 1]
        : static_cast<int32_t>(family_ownerships().size());
    for (int32_t p = owned_begin; p < owned_end; ++p) {
        const FamilyBuildingOwnership &ownership = family_ownerships().read_at(
            owned_csr_ready ? _family_owned_edge_indices[p] : p, __FILE__, __LINE__);
        if (ownership.family_handle != handle) continue;
        const int32_t group = building_index_for_handle(ownership.building_handle);
        if (group < 0 || buildings_store().group_units[group] <= 0) continue;
        asset_value += mul_div_sat(std::max<int64_t>(
            buildings_store().last_expected_revenue[group],
            buildings_store().last_operating_cost[group]), ownership.owned_count,
            buildings_store().group_units[group], asset_sat);
        capital_value = saturating_add(capital_value, saturating_mul(
            building_reset_capital_value(building_at(static_cast<size_t>(group))),
            std::max<int64_t>(0, ownership.owned_count), asset_sat), asset_sat);
    }
    const int64_t cash = family_cash_claim(handle);
    const int32_t surname = families_store().surname_id[index];
    out["ok"] = true;
    out["family_handle"] = family_handle_value;
    out["stable_id"] = families_store().stable_id[index];
    out["surname_pack_id"] = from_utf8(_family_surname_pack_id);
    out["surname_id"] = surname >= 0 ? from_utf8(
        _family_surname_ids[surname]) : String();
    out["surname"] = surname >= 0 ? from_utf8(
        _family_surname_text[surname]) : String();
    out["surname_disambiguator"] = static_cast<int32_t>(
        families_store().surname_disambiguator[index]);
    out["founded_day"] = families_store().founded_day[index];
    out["home_cell"] = families_store().home_cell[index];
    out["origin_cell"] = families_store().origin_cell[index];
    out["origin_ethnicity_id"] = families_store().origin_ethnicity[index];
    out["culture_group_id"] = families_store().culture_group_id[index];
    out["culture_group_stable_id"] = families_store().culture_group_id[index] >= 0 &&
        families_store().culture_group_id[index] < static_cast<int32_t>(
            _family_culture_group_ids.size())
        ? from_utf8(_family_culture_group_ids[families_store().culture_group_id[index]]) : String();
    out["culture_group_display_name"] = families_store().culture_group_id[index] >= 0 &&
        families_store().culture_group_id[index] < static_cast<int32_t>(
            _family_culture_group_display_names.size())
        ? from_utf8(_family_culture_group_display_names[families_store().culture_group_id[index]]) : String();
    out["culture_group_naming_format"] = families_store().culture_group_id[index] >= 0 &&
        families_store().culture_group_id[index] < static_cast<int32_t>(
            _family_culture_group_naming_formats.size())
        ? from_utf8(_family_culture_group_naming_formats[families_store().culture_group_id[index]]) : String();
    out["culture_group_separator"] = families_store().culture_group_id[index] >= 0 &&
        families_store().culture_group_id[index] < static_cast<int32_t>(
            _family_culture_group_separators.size())
        ? from_utf8(_family_culture_group_separators[families_store().culture_group_id[index]]) : String();
    out["culture_group_suffix"] = families_store().culture_group_id[index] >= 0 &&
        families_store().culture_group_id[index] < static_cast<int32_t>(
            _family_culture_group_suffixes.size())
        ? from_utf8(_family_culture_group_suffixes[families_store().culture_group_id[index]]) : String();
    out["decline_reviews"] = families_store().decline_reviews[index];
    out["flags"] = static_cast<int32_t>(families_store().flags[index]);
    out["population"] = family_population(handle);
    out["transit_population"] = transit_population;
    out["cash_claim"] = cash;
    // Net worth uses the same reset-capital valuation as the branch rows, so
    // the dossier total equals the sum of its branches.
    out["productive_asset_value"] = asset_value;
    out["building_asset_value"] = capital_value;
    out["net_worth"] = saturating_add(cash, capital_value, asset_sat);
    out["owned_buildings"] = family_owned_buildings(handle);
    out["profession_ids"] = professions;
    out["profession_people"] = people;
    out["profession_owner_employed"] = owners;
    out["profession_employee_employed"] = employees;
    out["notable_person_count"] = _person_family_offsets.size() ==
            families_store().active.size() + 1
        ? _person_family_offsets[index + 1] - _person_family_offsets[index] : 0;
    out["trait_count"] = static_cast<int32_t>(std::count_if(
        family_trait_rolls().begin(), family_trait_rolls().end(),
        [&](const FamilyTraitRoll &roll) {
            return roll.family_handle == handle;
        }));
    return out;
}

Dictionary NativeEconomyRuntime::family_traits(
        int64_t family_handle_value) const {
    Dictionary out;
    const uint64_t handle = static_cast<uint64_t>(family_handle_value);
    int32_t family = -1;
    if (!families_store().valid_handle(handle, family)) {
        out["ok"] = false;
        out["reason"] = "family_handle_invalid";
        return out;
    }
    PackedStringArray keys, names;
    PackedInt32Array strengths, behavior_offsets, behavior_axes,
        behavior_selector_kinds, behavior_selector_ids, behavior_factors;
    PackedByteArray core;
    behavior_offsets.push_back(0);
    for (const FamilyTraitRoll &roll : family_trait_rolls()) {
        if (roll.family_handle != handle || roll.trait_id < 0 ||
            roll.trait_id >= static_cast<int32_t>(_family_trait_ids.size()))
            continue;
        keys.push_back(_family_trait_ids[roll.trait_id].c_str());
        names.push_back(from_utf8(_family_trait_display_names[roll.trait_id]));
        strengths.push_back(roll.strength_q16);
        core.push_back(roll.core);
        for (int32_t edge = _family_trait_behavior_offsets[roll.trait_id];
             edge < _family_trait_behavior_offsets[roll.trait_id + 1]; ++edge) {
            behavior_axes.push_back(_family_trait_behavior_axes[edge]);
            behavior_selector_kinds.push_back(
                _family_trait_behavior_selector_kinds[edge]);
            behavior_selector_ids.push_back(
                _family_trait_behavior_selector_ids[edge]);
            const int64_t preferred = _family_trait_behavior_factors_q16[edge];
            behavior_factors.push_back(static_cast<int32_t>(Q16_ONE +
                (preferred - Q16_ONE) * roll.strength_q16 / Q16_ONE));
        }
        behavior_offsets.push_back(behavior_axes.size());
    }
    out["ok"] = true;
    out["family_handle"] = family_handle_value;
    out["trait_catalog_version"] = _family_trait_catalog_version.get();
    out["trait_catalog_hash"] = _family_trait_catalog_hash.get();
    out["trait_keys"] = keys;
    out["display_names"] = names;
    out["strength_q16"] = strengths;
    out["core"] = core;
    out["behavior_offsets"] = behavior_offsets;
    out["behavior_axes"] = behavior_axes;
    out["behavior_selector_kinds"] = behavior_selector_kinds;
    out["behavior_selector_ids"] = behavior_selector_ids;
    out["behavior_factors_q16"] = behavior_factors;
    PackedStringArray bound_effect_keys;
    std::set<std::string> unique_effect_keys;
    for (const FamilyEffectBinding &binding : _family_effect_bindings) {
        int32_t branch = -1;
        if (!family_influences().valid_handle(binding.branch_handle, branch) ||
            family_influences().family_handle[static_cast<size_t>(branch)] !=
                handle ||
            binding.definition_key.empty())
            continue;
        unique_effect_keys.insert(binding.definition_key);
    }
    for (const std::string &key : unique_effect_keys)
        bound_effect_keys.push_back(from_utf8(key));
    out["effect_definition_keys"] = bound_effect_keys;
    return out;
}

Dictionary NativeEconomyRuntime::family_branch_effects(
        int64_t family_handle_value, int32_t cell) const {
    Dictionary out;
    const uint64_t family_handle = static_cast<uint64_t>(family_handle_value);
    int32_t family = -1, branch = -1;
    if (!families_store().valid_handle(family_handle, family)) {
        out["ok"] = false;
        out["reason"] = "family_handle_invalid";
        return out;
    }
    for (int32_t i = 0; i < static_cast<int32_t>(
            family_influences().active.size()); ++i) {
        if (family_influences().active[i] != 0 &&
            family_influences().family_handle[i] == family_handle &&
            family_influences().cell[i] == cell) {
            branch = i;
            break;
        }
    }
    if (branch < 0) {
        out["ok"] = false;
        out["reason"] = "family_branch_missing";
        return out;
    }
    const uint64_t branch_handle =
        family_influences().handle_for_index(branch);
    PackedStringArray definition_keys;
    PackedInt32Array magnitudes;
    for (const FamilyModifierBinding &binding : _family_modifier_bindings) {
        if (binding.branch_handle != branch_handle ||
            binding.magnitude_q16 <= 0) continue;
        definition_keys.push_back(binding.definition_key.c_str());
        magnitudes.push_back(binding.magnitude_q16);
    }
    out["ok"] = true;
    out["family_handle"] = family_handle_value;
    out["branch_handle"] = static_cast<int64_t>(branch_handle);
    out["branch_stable_id"] = family_influences().stable_id[branch];
    out["cell_idx"] = cell;
    out["population"] = family_influences().population[branch];
    out["cash_claim"] = family_influences().cash[branch];
    out["building_asset_value"] = family_influences().building_asset[branch];
    out["population_share_q16"] =
        family_influences().population_share_q16[branch];
    out["cash_share_q16"] = family_influences().cash_share_q16[branch];
    out["building_share_q16"] =
        family_influences().building_share_q16[branch];
    out["prestige_score_q16"] = family_influences().score_q16[branch];
    out["satisfaction_q16"] = family_influences().satisfaction_q16[branch];
    out["prestige_level"] = family_influences().prestige_level[branch];
    out["pending_target_level"] =
        family_influences().pending_target_level[branch];
    out["review_streak"] = family_influences().review_streak[branch];
    out["last_review_day"] = family_influences().last_review_day[branch];
    const FamilyDemographyRow *demography = family_demography_row(family_handle, cell);
    out["demography_share_q16"] = demography != nullptr ? demography->share_q16 : 0;
    out["target_share_q16"] = demography != nullptr ? demography->target_share_q16 : 0;
    out["distress_q16"] = demography != nullptr ? demography->distress_q16 : 0;
    out["birth_weight_q16"] = demography != nullptr ? demography->birth_weight_q16 : 0;
    out["death_weight_q16"] = demography != nullptr ? demography->death_weight_q16 : 0;
    out["modifier_definition_keys"] = definition_keys;
    out["modifier_magnitude_q16"] = magnitudes;
    PackedStringArray effect_keys;
    PackedInt32Array effect_magnitudes;
    // M2b ownership columns. `effect_present` is EffectRuntime::has_instance_pod
    // for each held ref, the same bit the ideology report exposes: 1 means the
    // main thread owns the instance, 0 means it was handed to the Effect worker
    // (or vanished). Without it a reroute cannot be told apart from a drop.
    PackedInt64Array effect_instance_ids;
    PackedInt64Array effect_generations;
    PackedInt64Array effect_target_handles;
    PackedInt32Array effect_target_generations;
    PackedByteArray effect_present;
    for (const FamilyEffectBinding &binding : _family_effect_bindings) {
        if (binding.branch_handle != branch_handle) continue;
        effect_keys.push_back(from_utf8(binding.definition_key));
        effect_magnitudes.push_back(binding.strength_q16);
        effect_instance_ids.push_back(binding.instance_id);
        effect_generations.push_back(static_cast<int64_t>(binding.generation));
        effect_target_handles.push_back(static_cast<int64_t>(binding.target_handle));
        effect_target_generations.push_back(
            static_cast<int32_t>(binding.target_generation));
        effect_present.push_back(_effect_runtime != nullptr &&
            _effect_runtime->has_instance_pod(
                binding.instance_id, binding.generation) ? 1 : 0);
    }
    out["effect_definition_keys"] = effect_keys;
    out["effect_magnitude_q16"] = effect_magnitudes;
    out["effect_instance_ids"] = effect_instance_ids;
    out["effect_generations"] = effect_generations;
    out["effect_target_handles"] = effect_target_handles;
    out["effect_target_generations"] = effect_target_generations;
    out["effect_present"] = effect_present;
    if (_trigger_runtime != nullptr) {
        const Dictionary progress = _trigger_runtime->branch_progress(
            branch_handle);
        const Array keys = progress.keys();
        for (int32_t index = 0; index < keys.size(); ++index) {
            const Variant key = keys[index];
            const String text = key;
            if (text == "ok" || text == "branch_handle") continue;
            out[key] = progress[key];
        }
    } else {
        out["trigger_definition_keys"] = PackedStringArray();
        out["trigger_progress"] = PackedInt64Array();
        out["trigger_remainders"] = PackedInt64Array();
        out["trigger_thresholds"] = PackedInt64Array();
        out["trigger_completed"] = PackedInt32Array();
        out["trigger_reward_targets"] = PackedInt32Array();
    }
    return out;
}

Dictionary NativeEconomyRuntime::family_branches(
        int64_t family_handle_value, int32_t offset, int32_t limit) const {
    Dictionary out;
    const uint64_t handle = static_cast<uint64_t>(family_handle_value);
    int32_t index = -1;
    if (!families_store().valid_handle(handle, index)) {
        out["ok"] = false;
        out["reason"] = "family_handle_invalid";
        return out;
    }
    struct Branch { int32_t cell; int64_t people; int64_t cash; int64_t asset; };
    std::unordered_map<int32_t, Branch> by_cell;
    const bool member_csr_ready = _family_member_offsets.size() ==
        families_store().active.size() + 1;
    const int32_t member_begin = member_csr_ready
        ? _family_member_offsets[index] : 0;
    const int32_t member_end = member_csr_ready
        ? _family_member_offsets[index + 1]
        : static_cast<int32_t>(family_memberships().size());
    for (int32_t p = member_begin; p < member_end; ++p) {
        const FamilyMembershipEdge &edge = family_memberships()[
            member_csr_ready ? _family_member_edge_indices[p] : p];
        if (edge.family_handle != handle) continue;
        int32_t slot = -1;
        if (!population_store().valid_handle(edge.cohort_handle, slot)) continue;
        const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
        Branch &branch = by_cell[cell];
        branch.cell = cell; branch.people += edge.people;
        branch.cash += edge.cash_claim;
    }
    const bool owned_csr_ready = _family_owned_offsets.size() ==
        families_store().active.size() + 1;
    const int32_t owned_begin = owned_csr_ready
        ? _family_owned_offsets[index] : 0;
    const int32_t owned_end = owned_csr_ready
        ? _family_owned_offsets[index + 1]
        : static_cast<int32_t>(family_ownerships().size());
    for (int32_t p = owned_begin; p < owned_end; ++p) {
        const FamilyBuildingOwnership &edge = family_ownerships().read_at(
            owned_csr_ready ? _family_owned_edge_indices[p] : p, __FILE__, __LINE__);
        if (edge.family_handle != handle) continue;
        const int32_t group = building_index_for_handle(edge.building_handle);
        if (group < 0) continue;
        const int32_t cell = buildings_store().cell[group];
        Branch &branch = by_cell[cell];
        branch.cell = cell;
        int64_t sat = 0;
        branch.asset = saturating_add(branch.asset, saturating_mul(
            building_reset_capital_value(building_at(static_cast<size_t>(group))),
            std::max<int64_t>(0, edge.owned_count), sat), sat);
    }
    std::vector<Branch> rows;
    for (const auto &item : by_cell) rows.push_back(item.second);
    std::sort(rows.begin(), rows.end(), [](const Branch &a, const Branch &b) {
        return a.people != b.people ? a.people > b.people : a.cell < b.cell;
    });
    offset = std::max(0, offset); limit = std::clamp(limit, 1, 256);
    const int32_t end = std::min<int32_t>(rows.size(), offset + limit);
    PackedInt32Array cells, prestige_levels, population_shares, cash_shares,
        building_shares, scores, satisfactions, pending_targets, review_streaks,
        demography_shares, target_shares, distresses;
    PackedInt64Array branch_handles, branch_stable_ids, populations, cash_claims,
        building_assets, last_review_days;
    for (int32_t i = offset; i < end; ++i) {
        cells.push_back(rows[i].cell);
        populations.push_back(rows[i].people);
        cash_claims.push_back(rows[i].cash);
        building_assets.push_back(rows[i].asset);
        int32_t influence = -1;
        for (int32_t branch = 0; branch < static_cast<int32_t>(
                family_influences().active.size()); ++branch) {
            if (family_influences().active[branch] != 0 &&
                family_influences().family_handle[branch] == handle &&
                family_influences().cell[branch] == rows[i].cell) {
                influence = branch;
                break;
            }
        }
        branch_handles.push_back(influence >= 0 ? static_cast<int64_t>(
            family_influences().handle_for_index(influence)) : 0);
        branch_stable_ids.push_back(influence >= 0
            ? family_influences().stable_id[influence] : 0);
        prestige_levels.push_back(influence >= 0
            ? family_influences().prestige_level[influence] : 0);
        population_shares.push_back(influence >= 0
            ? family_influences().population_share_q16[influence] : 0);
        cash_shares.push_back(influence >= 0
            ? family_influences().cash_share_q16[influence] : 0);
        building_shares.push_back(influence >= 0
            ? family_influences().building_share_q16[influence] : 0);
        scores.push_back(influence >= 0
            ? family_influences().score_q16[influence] : 0);
        satisfactions.push_back(influence >= 0
            ? family_influences().satisfaction_q16[influence] : 0);
        pending_targets.push_back(influence >= 0
            ? family_influences().pending_target_level[influence] : 0);
        review_streaks.push_back(influence >= 0
            ? family_influences().review_streak[influence] : 0);
        last_review_days.push_back(influence >= 0
            ? family_influences().last_review_day[influence] : -1);
        const FamilyDemographyRow *demography = family_demography_row(handle, rows[i].cell);
        demography_shares.push_back(demography != nullptr ? demography->share_q16 : 0);
        target_shares.push_back(demography != nullptr ? demography->target_share_q16 : 0);
        distresses.push_back(demography != nullptr ? demography->distress_q16 : 0);
    }
    out["ok"] = true; out["total"] = static_cast<int32_t>(rows.size());
    out["offset"] = offset; out["limit"] = limit;
    out["has_more"] = end < static_cast<int32_t>(rows.size());
    out["cell_indices"] = cells; out["populations"] = populations;
    out["cash_claims"] = cash_claims;
    out["building_asset_values"] = building_assets;
    out["branch_handles"] = branch_handles;
    out["branch_stable_ids"] = branch_stable_ids;

    out["prestige_levels"] = prestige_levels;
    out["population_shares_q16"] = population_shares;
    out["cash_shares_q16"] = cash_shares;
    out["building_shares_q16"] = building_shares;
    out["prestige_scores_q16"] = scores;
    out["satisfactions_q16"] = satisfactions;
    out["pending_target_levels"] = pending_targets;
    out["review_streaks"] = review_streaks;
    out["last_review_days"] = last_review_days;
    out["demography_shares_q16"] = demography_shares;
    out["target_shares_q16"] = target_shares;
    out["distress_q16"] = distresses;
    return out;
}

Dictionary NativeEconomyRuntime::family_industries(
        int64_t family_handle_value, int32_t offset, int32_t limit) const {
    Dictionary out;
    const uint64_t handle = static_cast<uint64_t>(family_handle_value);
    int32_t index = -1;
    if (!families_store().valid_handle(handle, index)) {
        out["ok"] = false; out["reason"] = "family_handle_invalid";
        return out;
    }
    std::vector<const FamilyBuildingOwnership *> rows;
    const bool owned_csr_ready = _family_owned_offsets.size() ==
        families_store().active.size() + 1;
    const int32_t owned_begin = owned_csr_ready
        ? _family_owned_offsets[index] : 0;
    const int32_t owned_end = owned_csr_ready
        ? _family_owned_offsets[index + 1]
        : static_cast<int32_t>(family_ownerships().size());
    for (int32_t p = owned_begin; p < owned_end; ++p) {
        const FamilyBuildingOwnership &edge = family_ownerships().read_at(
            owned_csr_ready ? _family_owned_edge_indices[p] : p, __FILE__, __LINE__);
        if (edge.family_handle == handle) rows.push_back(&edge);
    }
    std::sort(rows.begin(), rows.end(), [&](const auto *a, const auto *b) {
        const int32_t ai = building_index_for_handle(a->building_handle);
        const int32_t bi = building_index_for_handle(b->building_handle);
        const auto ak = ai >= 0 ? std::tuple(buildings_store().cell[ai],
            buildings_store().type_id[ai], buildings_store().owner_signature_id[ai]) :
            std::tuple(INT32_MAX, INT32_MAX, INT32_MAX);
        const auto bk = bi >= 0 ? std::tuple(buildings_store().cell[bi],
            buildings_store().type_id[bi], buildings_store().owner_signature_id[bi]) :
            std::tuple(INT32_MAX, INT32_MAX, INT32_MAX);
        return ak < bk;
    });
    offset = std::max(0, offset); limit = std::clamp(limit, 1, 256);
    const int32_t end = std::min<int32_t>(rows.size(), offset + limit);
    PackedInt64Array building_handles, counts, filled;
    PackedInt32Array cells, types, owner_signatures;
    for (int32_t i = offset; i < end; ++i) {
        const auto &edge = *rows[i];
        const int32_t group = building_index_for_handle(edge.building_handle);
        if (group < 0) continue;
        building_handles.push_back(static_cast<int64_t>(edge.building_handle));
        cells.push_back(buildings_store().cell[group]);
        types.push_back(buildings_store().type_id[group]);
        owner_signatures.push_back(buildings_store().owner_signature_id[group]);
        counts.push_back(edge.owned_count);
        filled.push_back(edge.filled_owner);
    }
    out["ok"] = true; out["total"] = static_cast<int32_t>(rows.size());
    out["offset"] = offset; out["limit"] = limit;
    out["has_more"] = end < static_cast<int32_t>(rows.size());
    out["building_handles"] = building_handles; out["cell_indices"] = cells;
    out["building_type_ids"] = types;
    out["owner_signature_ids"] = owner_signatures;
    out["owned_counts"] = counts; out["filled_owner"] = filled;
    return out;
}
