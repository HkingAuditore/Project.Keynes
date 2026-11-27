    const std::vector<int32_t> employee_prof = packed_i32(catalog, "building_employee_profession_ids");
    const std::vector<int64_t> employee_slots = packed_i64(catalog, "building_employee_slots");
    const std::vector<int32_t> employee_wage_policies =
        packed_i32(catalog, "building_employee_wage_policies");
    const std::vector<int32_t> construction_goods = packed_i32(catalog, "building_construction_good_ids");
    const std::vector<int64_t> construction_qty = packed_i64(catalog, "building_construction_quantities");
    std::vector<int32_t> construction_candidate_offsets = packed_i32(
        catalog, "building_construction_candidate_offsets");
    std::vector<int32_t> construction_candidate_goods = packed_i32(
        catalog, "building_construction_candidate_good_ids");
    std::vector<int32_t> construction_candidate_efficiencies = packed_i32(
        catalog, "building_construction_candidate_efficiency_q16");
    // v1/v2 catalogs did not carry construction candidate CSR. Expand every
    // legacy fixed material into a one-candidate group before validation.
    if (construction_candidate_offsets.empty() &&
            construction_candidate_goods.empty() &&
            construction_candidate_efficiencies.empty()) {
        construction_candidate_offsets.push_back(0);
        for (const int32_t good : construction_goods) {
            construction_candidate_goods.push_back(good);
            construction_candidate_efficiencies.push_back(Q16_ONE);
            construction_candidate_offsets.push_back(
                static_cast<int32_t>(construction_candidate_goods.size()));
        }
    }
    const std::vector<int32_t> maintenance_goods = packed_i32(
        catalog, "building_maintenance_good_ids");
    const std::vector<int64_t> maintenance_qty = packed_i64(
        catalog, "building_maintenance_quantities");
    const std::vector<int32_t> input_goods = packed_i32(catalog, "building_input_good_ids");
    const std::vector<int64_t> input_qty = packed_i64(catalog, "building_input_quantities");
    std::vector<int32_t> input_required_q16 = packed_i32(catalog, "building_input_required_q16");
    if (input_required_q16.empty() && !input_goods.empty()) {
        input_required_q16.assign(input_goods.size(), static_cast<int32_t>(Q16_ONE));
    }
    const std::vector<int32_t> input_candidate_offsets =
        packed_i32(catalog, "building_input_candidate_offsets");
    const std::vector<int32_t> input_candidate_goods =
        packed_i32(catalog, "building_input_candidate_good_ids");
    const std::vector<int32_t> input_candidate_efficiencies =
        packed_i32(catalog, "building_input_candidate_efficiency_q16");
    const std::vector<int32_t> output_goods = packed_i32(catalog, "building_output_good_ids");
    const std::vector<int64_t> output_qty = packed_i64(catalog, "building_output_quantities");
    _building_output_cost_shares_q16 =
        packed_i32(catalog, "building_output_cost_shares_q16");
    const std::vector<int32_t> resource_ids = packed_i32(catalog, "building_production_resource_ids");
    const std::vector<int64_t> resource_qty = packed_i64(catalog, "building_production_resource_quantities");
    const std::vector<int32_t> resource_modes = packed_i32(catalog, "building_production_resource_modes");
    const std::vector<int32_t> resource_access_modes =
        packed_i32(catalog, "building_production_resource_access_modes");
    const std::vector<int32_t> generation_ids = packed_i32(catalog, "building_resource_generation_ids");
    const std::vector<int64_t> generation_qty = packed_i64(catalog, "building_resource_generation_quantities");
    const std::vector<int32_t> condition_opcodes = packed_i32(catalog, "building_condition_opcodes");
    const std::vector<int32_t> condition_signals = packed_i32(catalog, "building_condition_signals");
    const std::vector<int32_t> condition_compares = packed_i32(catalog, "building_condition_compares");
    const std::vector<int32_t> condition_refs = packed_i32(catalog, "building_condition_references");
    const std::vector<int64_t> condition_values = packed_i64(catalog, "building_condition_values");
    if (employee_offsets.back() != static_cast<int32_t>(employee_prof.size()) ||
        employee_slots.size() != employee_prof.size() ||
        employee_wage_policies.size() != employee_prof.size() ||
        construction_offsets.back() != static_cast<int32_t>(construction_goods.size()) ||
        construction_qty.size() != construction_goods.size() ||
        construction_candidate_offsets.size() != construction_goods.size() + 1 ||
        construction_candidate_offsets.empty() || construction_candidate_offsets.front() != 0 ||
        !std::is_sorted(construction_candidate_offsets.begin(),
                        construction_candidate_offsets.end()) ||
        construction_candidate_offsets.back() !=
            static_cast<int32_t>(construction_candidate_goods.size()) ||
        construction_candidate_efficiencies.size() != construction_candidate_goods.size() ||
        input_offsets.back() != static_cast<int32_t>(input_goods.size()) ||
        input_qty.size() != input_goods.size() ||
        input_required_q16.size() != input_goods.size() ||
        input_candidate_offsets.size() != input_goods.size() + 1 ||
        input_candidate_offsets.empty() || input_candidate_offsets.front() != 0 ||
        !std::is_sorted(input_candidate_offsets.begin(), input_candidate_offsets.end()) ||
        input_candidate_offsets.back() != static_cast<int32_t>(input_candidate_goods.size()) ||
        input_candidate_efficiencies.size() != input_candidate_goods.size() ||
        output_offsets.back() != static_cast<int32_t>(output_goods.size()) ||
        output_qty.size() != output_goods.size() ||
        output_cost_share_offsets.back() !=
            static_cast<int32_t>(_building_output_cost_shares_q16.size()) ||
        resource_offsets.back() != static_cast<int32_t>(resource_ids.size()) ||
        resource_qty.size() != resource_ids.size() || resource_modes.size() != resource_ids.size() ||
        resource_access_modes.size() != resource_ids.size() ||
        generation_offsets.back() != static_cast<int32_t>(generation_ids.size()) ||
        generation_qty.size() != generation_ids.size() ||
        condition_offsets.back() != static_cast<int32_t>(condition_opcodes.size()) ||
        condition_signals.size() != condition_opcodes.size() ||
        condition_compares.size() != condition_opcodes.size() ||
        condition_refs.size() != condition_opcodes.size() ||
        condition_values.size() != condition_opcodes.size()) {
        error = "building_child_column_size_mismatch";
        return false;
    }
    const size_t dependency_branch_count =
        _building_dependency_branch_technologies.size() > 0
            ? static_cast<size_t>(_building_dependency_branch_technology_offsets.size() - 1)
            : 0;
    if (_building_dependency_branch_offsets.back() !=
            static_cast<int32_t>(dependency_branch_count) ||
        _building_dependency_branch_group_offsets.size() != dependency_branch_count + 1) {
        error = "building_dependency_branch_shape_invalid";
        return false;
    }
    for (size_t branch = 0; branch < dependency_branch_count; ++branch) {
        if (_building_dependency_branch_technology_offsets[branch] >=
                _building_dependency_branch_technology_offsets[branch + 1] ||
            _building_dependency_branch_group_offsets[branch] >
                _building_dependency_branch_group_offsets[branch + 1]) {
            error = "building_dependency_branch_empty";
            return false;
        }
    }
    for (size_t group = 0; group < _building_dependency_kinds.size(); ++group) {
        const int32_t kind = _building_dependency_kinds[group];
        const int32_t id = _building_dependency_ids[group];
        if (kind < 1 || kind > 5 ||
            _building_dependency_tag_offsets[group] >=
                _building_dependency_tag_offsets[group + 1] ||
            (kind <= 3 && (id < 0 || id >= static_cast<int32_t>(_good_ids.size()))) ||
            (kind >= 4 && (id < 0 || id >= static_cast<int32_t>(_resource_ids.size())))) {
            error = "building_dependency_group_invalid";
            return false;
        }
        for (int32_t tag = _building_dependency_tag_offsets[group];
             tag < _building_dependency_tag_offsets[group + 1]; ++tag) {
            if (_building_dependency_tags[static_cast<size_t>(tag)] < 0 ||
                _building_dependency_tags[static_cast<size_t>(tag)] >=
                    static_cast<int32_t>(_technology_ids.size())) {
                error = "building_dependency_technology_invalid";
                return false;
            }
        }
    }
    _building_employee_roles.resize(employee_prof.size());
    for (size_t i = 0; i < employee_prof.size(); ++i) {
        if (employee_prof[i] < 0 || employee_prof[i] >= static_cast<int32_t>(_profession_ids.size()) ||
            employee_slots[i] <= 0 || employee_wage_policies[i] < 0 ||
            employee_wage_policies[i] > 2) {
            error = "building_employee_role_invalid";
            return false;
        }
        _building_employee_roles[i] = {employee_prof[i], employee_slots[i],
                                       employee_wage_policies[i]};
    }
    auto compile_goods = [&](const std::vector<int32_t> &ids, const std::vector<int64_t> &qty,
                             std::vector<GoodAmount> &dst, const char *reason) {
        dst.resize(ids.size());
        for (size_t i = 0; i < ids.size(); ++i) {
            if (ids[i] < 0 || ids[i] >= static_cast<int32_t>(_good_ids.size()) || qty[i] <= 0) {
                error = reason;
                return false;
            }
            dst[i] = {ids[i], qty[i]};
        }
        return true;
    };
    if (!compile_goods(construction_goods, construction_qty, _building_construction_goods,
                       "building_construction_good_invalid") ||
        !compile_goods(output_goods, output_qty, _building_outputs,
                       "building_output_good_invalid")) return false;
    if (maintenance_offsets.empty()) {
        _building_maintenance_author_offsets.assign(types + 1, 0);
        _building_maintenance_author_goods.clear();
    } else {
        if (maintenance_offsets.back() != static_cast<int32_t>(maintenance_goods.size()) ||
            maintenance_goods.size() != maintenance_qty.size()) {
            error = "building_maintenance_column_size_mismatch";
            return false;
        }
        if (!compile_goods(maintenance_goods, maintenance_qty,
                           _building_maintenance_author_goods,
                           "building_maintenance_good_invalid")) return false;
        _building_maintenance_author_offsets = maintenance_offsets;
    }
    for (GoodAmount &output : _building_outputs) {
        output.quantity = mul_div_sat(output.quantity,
            _building_output_efficiency_q16, Q16_ONE, _saturation_count);
    }
    _building_inputs.resize(input_goods.size());
    _building_input_candidates.resize(input_candidate_goods.size());
    for (size_t i = 0; i < input_goods.size(); ++i) {
        if (input_goods[i] < 0 || input_goods[i] >= static_cast<int32_t>(_good_ids.size()) ||
            input_qty[i] <= 0 || input_candidate_offsets[i] >= input_candidate_offsets[i + 1] ||
            input_required_q16[i] < 0 || input_required_q16[i] > Q16_ONE) {
            error = "building_input_good_invalid";
            return false;
        }
        _building_inputs[i] = {input_goods[i], input_qty[i], input_candidate_offsets[i],
                               input_candidate_offsets[i + 1] - input_candidate_offsets[i],
                               input_required_q16[i]};
    }
    for (size_t i = 0; i < input_candidate_goods.size(); ++i) {
        if (input_candidate_goods[i] < 0 ||
            input_candidate_goods[i] >= static_cast<int32_t>(_good_ids.size()) ||
            input_candidate_efficiencies[i] <= 0 ||
            input_candidate_efficiencies[i] > Q16_ONE * 4) {
            error = "building_input_candidate_invalid";
            return false;
        }
        _building_input_candidates[i] = {
            input_candidate_goods[i], input_candidate_efficiencies[i]};
    }
    // Physical daily quantity per candidate row is catalogue-static; precompute
    // it once so the startup selection hot path does not redo the two
    // saturating divisions for every (cell, input row) evaluation.
    _building_input_candidate_physical_daily.assign(
        _building_input_candidates.size(), 0);
    for (size_t i = 0; i < _building_inputs.size(); ++i) {
        const ProductionInput &input = _building_inputs[i];
        for (int32_t cursor = input.candidate_begin;
             cursor < input.candidate_begin + input.candidate_count &&
             cursor >= 0 &&
             cursor < static_cast<int32_t>(
                 _building_input_candidate_physical_daily.size());
             ++cursor) {
            int64_t sat = 0;
            const int32_t efficiency = std::max<int32_t>(
                1, _building_input_candidates[static_cast<size_t>(cursor)]
                       .efficiency_q16);
            int64_t physical = mul_div_sat(input.quantity, Q16_ONE, efficiency, sat);
            if (mul_div_sat(physical, efficiency, Q16_ONE, sat) <
                input.quantity) {
                ++physical;
            }
            _building_input_candidate_physical_daily[static_cast<size_t>(cursor)] =
                physical;
        }
    }
    _building_resources.resize(resource_ids.size());
    for (size_t i = 0; i < resource_ids.size(); ++i) {
        if (resource_ids[i] < 0 || resource_ids[i] >= static_cast<int32_t>(_resource_ids.size()) ||
            resource_qty[i] <= 0 || resource_modes[i] < 0 || resource_modes[i] > 1 ||
            resource_access_modes[i] != 0) {
            error = "building_production_resource_invalid";
            return false;
        }
        _building_resources[i] = {resource_ids[i], resource_qty[i], resource_modes[i],
                                  resource_access_modes[i]};
    }
    _building_resource_generation.resize(generation_ids.size());
    for (size_t i = 0; i < generation_ids.size(); ++i) {
        if (generation_ids[i] < 0 ||
            generation_ids[i] >= static_cast<int32_t>(_resource_ids.size()) ||
            generation_qty[i] <= 0) {
            error = "building_resource_generation_invalid";
            return false;
        }
        _building_resource_generation[i] = {generation_ids[i], generation_qty[i], 0, 0};
    }
    _building_conditions.resize(condition_opcodes.size());
    for (size_t i = 0; i < condition_opcodes.size(); ++i) {
        if (condition_opcodes[i] < 1 || condition_opcodes[i] > 4 ||
            condition_compares[i] < 0 || condition_compares[i] > 5) {
            error = "building_condition_token_invalid";
            return false;
        }
        _building_conditions[i] = {condition_opcodes[i], condition_signals[i],
                                   condition_compares[i], condition_refs[i],
                                   condition_values[i]};
    }
