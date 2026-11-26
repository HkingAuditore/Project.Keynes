    // Production first spends only on physical inputs. Base wages are income
    // distribution and settle after the producer has sold this cycle's output.
    for (size_t owner_index = 0; owner_index < payroll_owners.size(); ++owner_index) {
        const int32_t owner_signature = payroll_owners[owner_index];
        const int32_t owner_groups_begin = owner_group_offsets[owner_index];
        const int32_t owner_groups_end = owner_group_offsets[owner_index + 1];
        const int32_t owner_slot = find_cohort_slot(cell, owner_signature);
        int64_t total_due = 0;
        for (int32_t gi = owner_groups_begin; gi < owner_groups_end; ++gi) {
            const int32_t g = owner_groups[static_cast<size_t>(gi)];
            const auto group = building_view(static_cast<size_t>(g));
            if (group.owner_signature_id != owner_signature ||
                !building_available(cell, group.type_id, true)) continue;
            total_due = saturating_add(total_due, std::max<int64_t>(
                0, group.last_base_wages_due - group.last_base_wages_paid),
                _saturation_count);
        }
        const int64_t available = owner_slot >= 0
            ? std::min(total_due, std::max<int64_t>(
                0, population_store().funds[owner_slot])) : 0;
        int64_t prefix = 0;
        int64_t allocated = 0;
        int64_t owner_paid = 0;
        for (int32_t gi = owner_groups_begin; gi < owner_groups_end; ++gi) {
            const int32_t g = owner_groups[static_cast<size_t>(gi)];
            {
                const auto group_view = building_view(static_cast<size_t>(g));
                if (group_view.owner_signature_id != owner_signature ||
                    !building_available(cell, group_view.type_id, true)) continue;
            }
            auto group = building_at(static_cast<size_t>(g));
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const int32_t role_index = group.employee_fill_begin + r;
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int64_t due = std::max<int64_t>(
                    0, _building_role_base_wage_due[role_index] -
                       _building_role_base_wage_paid[role_index]);
                prefix = saturating_add(prefix, due, _saturation_count);
                const int64_t next = total_due > 0 ? mul_div_sat(
                    available, prefix, total_due, _saturation_count) : 0;
                const int64_t cap = std::max<int64_t>(0, next - allocated);
                allocated = next;
                const int64_t paid = pay_building_wage_amount(
                    cell, owner_slot, role.profession_id,
                    _building_employee_filled[role_index], due, cap,
                    &_saturation_count);
                _building_role_base_wage_paid.write_scalar(role_index, saturating_add(
                    _building_role_base_wage_paid[role_index], paid, _saturation_count), market_mutation_sink());
                group.last_base_wages_paid = saturating_add(
                    group.last_base_wages_paid, paid, _saturation_count);
                owner_paid = saturating_add(owner_paid, paid, _saturation_count);
            }
        }
        _building_base_wages_paid = saturating_add(
            _building_base_wages_paid, owner_paid, _saturation_count);
        _building_base_wages_due = saturating_add(
            _building_base_wages_due, total_due, _saturation_count);
        _building_wages_paid = saturating_add(
            _building_wages_paid, owner_paid, _saturation_count);
        _building_wages_unpaid = saturating_add(
            _building_wages_unpaid, total_due - owner_paid, _saturation_count);
        for (int32_t gi = owner_groups_begin; gi < owner_groups_end; ++gi) {
            const int32_t g = owner_groups[static_cast<size_t>(gi)];
            {
                const auto group_view = building_view(static_cast<size_t>(g));
                if (group_view.owner_signature_id != owner_signature ||
                    !building_available(cell, group_view.type_id, true)) continue;
            }
            auto group = building_at(static_cast<size_t>(g));
            group.last_wages_paid = group.last_base_wages_paid;
            group.last_operating_cost = saturating_add(
                group.last_input_cost, group.last_base_wages_due, _saturation_count);
            group.wage_suspended = group.last_base_wages_paid < group.last_base_wages_due ? 1 : 0;
            if (group.wage_suspended != 0) ++_wage_suspended_building_groups;
        }
    }

    // Merchant debt is serviced after base wages and before discretionary
    // bonuses. Principal is retired before the one-time premium.
    for (int32_t g = begin; g < end; ++g) {
        {
            const auto group_view = building_view(static_cast<size_t>(g));
            if (group_view.merchant_debt_principal <= 0 &&
                group_view.merchant_debt_premium <= 0) continue;
        }
        auto group = building_at(static_cast<size_t>(g));
        const int32_t owner_slot = find_cohort_slot(cell, group.owner_signature_id);
        int64_t due_sat = 0;
        const int64_t due = building_debt_due(group, due_sat);
        _saturation_count = saturating_add(
            _saturation_count, due_sat, _saturation_count);
        int64_t premium_paid = 0;
        const int64_t paid = repay_building_debt(
            cell, owner_slot, group, due, premium_paid);
        result.merchant_credit_repaid = saturating_add(
            result.merchant_credit_repaid, paid, _saturation_count);
        result.merchant_credit_premium_repaid = saturating_add(
            result.merchant_credit_premium_repaid, premium_paid,
            _saturation_count);
        if (group.merchant_debt_principal > 0 || group.merchant_debt_premium > 0) {
            if (group.merchant_debt_term_cycles_left > 0)
                --group.merchant_debt_term_cycles_left;
            if (paid < due) {
                group.merchant_debt_delinquent_cycles = static_cast<uint16_t>(
                    std::min<int32_t>(65535,
                        static_cast<int32_t>(group.merchant_debt_delinquent_cycles) + 1));
            } else {
                group.merchant_debt_delinquent_cycles = 0;
            }
            if (group.merchant_debt_term_cycles_left == 0)
                group.merchant_debt_delinquent_cycles = std::max<uint16_t>(
                    1, group.merchant_debt_delinquent_cycles);
        }
    }

    // Profit bonuses are settled after sales. They cannot retroactively stop
    // production and are excluded from the local regular-wage anchor.
    for (int32_t g = begin; g < end; ++g) {
        {
            const auto group_view = building_view(static_cast<size_t>(g));
            if (group_view.wage_suspended != 0 ||
                group_view.last_base_wages_due <= 0) continue;
        }
        auto group = building_at(static_cast<size_t>(g));
        const BuildingType &type = _building_types[group.type_id];
        const int64_t base_cost = saturating_add(
            group.last_input_cost, group.last_base_wages_due, _saturation_count);
        const int64_t target_profit = mul_div_sat(
            base_cost, type.target_operating_margin_q16, Q16_ONE, _saturation_count);
        const int64_t excess = std::max<int64_t>(0, saturating_sub(
            saturating_sub(group.last_revenue, base_cost, _saturation_count),
            target_profit, _saturation_count));
        group.last_bonus_due = mul_div_sat(
            excess, _employee_profit_share_q16, Q16_ONE, _saturation_count);
        int64_t prefix = 0;
        int64_t allocated = 0;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const int32_t role_index = group.employee_fill_begin + r;
            prefix = saturating_add(prefix,
                _building_role_base_wage_due[role_index], _saturation_count);
            const int64_t next = mul_div_sat(
                group.last_bonus_due, prefix, group.last_base_wages_due,
                _saturation_count);
            _building_role_bonus_due.write_scalar(role_index, std::max<int64_t>(0, next - allocated), market_mutation_sink());
            allocated = next;
        }
    }
    for (size_t owner_index = 0; owner_index < payroll_owners.size(); ++owner_index) {
        const int32_t owner_signature = payroll_owners[owner_index];
        const int32_t owner_groups_begin = owner_group_offsets[owner_index];
        const int32_t owner_groups_end = owner_group_offsets[owner_index + 1];
        const int32_t owner_slot = find_cohort_slot(cell, owner_signature);
        int64_t total_due = 0;
        for (int32_t gi = owner_groups_begin; gi < owner_groups_end; ++gi) {
            const int32_t g = owner_groups[static_cast<size_t>(gi)];
            total_due = saturating_add(
                total_due, buildings_store().last_bonus_due[g], _saturation_count);
        }
        const int64_t available = owner_slot >= 0
            ? std::min(total_due, std::max<int64_t>(
                0, population_store().funds[owner_slot])) : 0;
        int64_t prefix = 0;
        int64_t allocated = 0;
        int64_t owner_paid = 0;
        for (int32_t gi = owner_groups_begin; gi < owner_groups_end; ++gi) {
            const int32_t g = owner_groups[static_cast<size_t>(gi)];
            auto group = building_at(static_cast<size_t>(g));
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const int32_t role_index = group.employee_fill_begin + r;
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                const int64_t due = _building_role_bonus_due[role_index];
                prefix = saturating_add(prefix, due, _saturation_count);
                const int64_t next = total_due > 0 ? mul_div_sat(
                    available, prefix, total_due, _saturation_count) : 0;
                const int64_t cap = std::max<int64_t>(0, next - allocated);
                allocated = next;
                const int64_t paid = pay_building_wage_amount(
                    cell, owner_slot, role.profession_id,
                    _building_employee_filled[role_index], due, cap,
                    &_saturation_count);
                _building_role_bonus_paid.write_scalar(role_index, paid, market_mutation_sink());
                owner_paid = saturating_add(owner_paid, paid, _saturation_count);
                group.last_bonus_paid = saturating_add(
                    group.last_bonus_paid, paid, _saturation_count);
            }
            group.last_wages_due = saturating_add(
                group.last_base_wages_due, group.last_bonus_due, _saturation_count);
            group.last_wages_paid = saturating_add(
                group.last_base_wages_paid, group.last_bonus_paid, _saturation_count);
            group.last_operating_cost = saturating_add(
                saturating_add(group.last_input_cost, group.last_base_wages_due,
                               _saturation_count),
                group.last_bonus_due, _saturation_count);
        }
        _building_bonus_due = saturating_add(
            _building_bonus_due, total_due, _saturation_count);
        _building_bonus_paid = saturating_add(
            _building_bonus_paid, owner_paid, _saturation_count);
        _building_wages_paid = saturating_add(
            _building_wages_paid, owner_paid, _saturation_count);
        _building_wages_unpaid = saturating_add(
            _building_wages_unpaid, total_due - owner_paid, _saturation_count);
    }
