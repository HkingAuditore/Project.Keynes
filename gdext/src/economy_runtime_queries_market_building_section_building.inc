Dictionary NativeEconomyRuntime::building_cell_snapshot(int32_t cell_idx) const {
    Dictionary out;
    out["cell_idx"] = cell_idx;
    out["committed"] = !_epoch_active && !_fatal;
    out["busy"] = _epoch_active;
    out["snapshot_source"] = "rolling_committed";
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count.get()) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    out["ok"] = true;
    out["state_day"] = _cell_last_settlement_day[cell_idx];
    out["age_days"] = std::max<int64_t>(0,
        _current_day.get() - _cell_last_settlement_day[cell_idx]);
    out["settlement_generation"] = static_cast<int64_t>(
        _cell_settlement_generation[cell_idx]);
    out["epoch_id"] = _epoch_id.get();
    out["period_days"] = std::max(1, _epoch_days.get());
    PackedStringArray type_ids;
    PackedInt64Array type_counts;
    PackedInt32Array target_operating_margin_q16;
    PackedInt32Array supply_price_elasticity_q16;
	PackedInt32Array building_kinds;
	PackedInt32Array upgrade_family_indices;
	PackedInt32Array upgrade_tiers;
	PackedInt32Array highest_available_tiers;
	PackedInt32Array technology_tag_offsets;
	PackedStringArray technology_tags;
	PackedInt32Array required_technology_tag_offsets;
	PackedStringArray required_technology_tags;
	PackedByteArray technology_available;
	PackedByteArray construction_available;
	technology_tag_offsets.push_back(0);
	required_technology_tag_offsets.push_back(0);
    type_counts.resize(static_cast<int64_t>(_building_types.size()));
    type_counts.fill(0);
    for (const std::string &id : _building_type_ids) type_ids.push_back(String(id.c_str()));
    for (const BuildingType &type : _building_types) {
        target_operating_margin_q16.push_back(type.target_operating_margin_q16);
        supply_price_elasticity_q16.push_back(type.supply_price_elasticity_q16);
    }
	for (size_t i = 0; i < _building_types.size(); ++i) {
		building_kinds.push_back(_building_types[i].kind);
		upgrade_family_indices.push_back(_building_upgrade_family_indices[i]);
		upgrade_tiers.push_back(_building_upgrade_tiers[i]);
		technology_available.push_back(building_available(
			cell_idx, static_cast<int32_t>(i), false) ? 1 : 0);
		construction_available.push_back(building_constructible(
			cell_idx, static_cast<int32_t>(i), false) ? 1 : 0);
		int32_t highest_tier = 0;
		const int32_t family = _building_upgrade_family_indices[i];
		if (family >= 0) {
			for (size_t candidate = 0; candidate < _building_types.size(); ++candidate) {
				if (_building_upgrade_family_indices[candidate] == family &&
					building_available(cell_idx, static_cast<int32_t>(candidate), false)) {
					highest_tier = std::max(highest_tier, _building_upgrade_tiers[candidate]);
				}
			}
		}
		highest_available_tiers.push_back(highest_tier);
		for (int32_t k = _building_technology_tag_offsets[i];
			 k < _building_technology_tag_offsets[i + 1]; ++k) {
			technology_tags.push_back(String(_building_technology_tags[k].c_str()));
		}
		technology_tag_offsets.push_back(technology_tags.size());
		for (int32_t k = _building_required_technology_tag_offsets[i];
			 k < _building_required_technology_tag_offsets[i + 1]; ++k) {
			required_technology_tags.push_back(String(
				_building_required_technology_tags[k].c_str()));
		}
		required_technology_tag_offsets.push_back(required_technology_tags.size());
	}
    PackedInt32Array group_type_ids;
    PackedInt32Array owner_signature_ids;
    PackedInt64Array group_counts;
    PackedInt64Array owner_capacity;
    PackedInt64Array owner_required;
    PackedInt64Array projected_owner_income;
    PackedInt64Array employee_tax_retention_q16;
    PackedInt64Array filled_owner;
    PackedInt64Array owner_openings;
    PackedInt32Array employee_fill_offsets;
    PackedInt32Array employee_profession_ids;
    PackedInt64Array employee_required;
    PackedInt64Array employee_filled;
    PackedInt32Array employee_wage_policies;
    PackedInt64Array employee_contract_wages;
    PackedInt64Array employee_expected_wages;
    PackedInt32Array employee_payment_credibility_q16;
    PackedInt32Array employee_forecast_pay_ratio_q16;
    PackedInt64Array employee_base_living_cost;
    PackedInt64Array employee_role_living_cost;
    PackedInt64Array employee_local_average_wage;
    PackedInt64Array employee_base_wage_due;
    PackedInt64Array employee_base_wage_paid;
    PackedInt64Array employee_bonus_due;
    PackedInt64Array employee_bonus_paid;
    PackedInt64Array capacity_q16;
    PackedInt64Array last_temperature_fit_q16;
    PackedInt64Array last_water_fit_q16;
    PackedInt64Array last_climate_capacity_q16;
    PackedInt64Array last_climate_lost_output;
    PackedInt64Array purchase_intent_capacity_q16;
    PackedInt64Array funded_capacity_q16;
    PackedInt64Array owner_working_capital_allocated;
    PackedInt64Array owner_livelihood_in_kind_credit;
    PackedInt64Array investment_score_q16;
    PackedInt64Array investment_payback_days;
    PackedInt32Array investment_rejection_reason;
    PackedInt32Array investment_driver_good_id;
    PackedInt64Array investment_driver_pressure_q16;
    PackedInt64Array investment_driver_utilization_q16;
    PackedInt64Array investment_driver_sellable;
    PackedInt64Array investment_driver_merchant_sold;
    PackedInt64Array investment_driver_sell_through_q16;
    PackedByteArray pending_operating_state;
    PackedInt32Array recovery_cooldown_cycles;
    PackedInt64Array investment_driver_discard_q16;
    PackedInt64Array investment_stealable;
    PackedInt64Array investment_challenger_unit_cost;
    PackedInt64Array investment_incumbent_unit_cost;
    PackedInt64Array investment_return_on_capital_q16;
    PackedInt64Array investment_cost_advantage_q16;
    PackedInt32Array realized_profit_margin_q16;
    PackedInt32Array severe_loss_cycles;
    PackedInt32Array recovery_cycles;
    PackedInt32Array recovery_failed_reviews;
    PackedByteArray operating_state;
    PackedInt64Array merchant_debt_principal;
    PackedInt64Array merchant_debt_premium;
    PackedInt32Array merchant_debt_term_cycles_left;
    PackedInt32Array merchant_debt_delinquent_cycles;
    PackedInt64Array last_in_kind_livelihood_value;
    PackedInt64Array last_input;
    PackedInt64Array last_output;
    PackedInt64Array last_sold;
    PackedInt64Array last_discarded;
    PackedInt64Array last_retained;
    PackedInt64Array last_resource;
    PackedInt64Array last_resource_generated;
    PackedInt64Array last_revenue;
    PackedInt64Array last_input_cost;
    PackedInt64Array last_wages_paid;
    PackedInt64Array last_wages_due;
    PackedInt64Array last_expected_revenue;
    PackedInt64Array last_operating_cost;
    PackedInt64Array last_maintenance_cost;
    PackedInt64Array last_market_receipt;
    PackedInt64Array last_bullion_mint_receipt;
    PackedInt64Array last_producer_support_receipt;
    PackedInt64Array last_business_tax_paid;
    PackedInt64Array last_business_subsidy_received;
    PackedInt64Array last_maintenance_due;
    PackedInt64Array last_observed_capacity_days_q16;
    PackedInt64Array last_quoted_market_receipt;
    PackedInt64Array last_quoted_operating_cost;
    PackedInt32Array last_margin_gap_q16;
    PackedInt32Array planned_utilization_q16;
    PackedInt64Array last_base_wages_due;
    PackedInt64Array last_base_wages_paid;
    PackedInt64Array last_bonus_due;
    PackedInt64Array last_bonus_paid;
    PackedByteArray wage_suspended;
    PackedInt64Array opportunity_owner_income_per_day;
    PackedInt64Array opportunity_disposable_survival_power_per_day;
    PackedInt64Array opportunity_executable_capacity_q16;
    PackedInt64Array opportunity_in_kind_retail_value;
    PackedByteArray survival_priority;
    PackedInt64Array survival_shortage_q16;
    PackedInt64Array monetary_quota_absorption_q16;
    PackedByteArray monetary_quote_capped;
    PackedInt32Array group_input_selected_offsets;
    PackedInt32Array group_input_selected_good_ids;
    PackedInt32Array family_ownership_offsets;
    PackedInt64Array family_ownership_handles;
    PackedInt64Array family_owned_counts;
    PackedInt64Array family_filled_owner;
    employee_fill_offsets.push_back(0);
    group_input_selected_offsets.push_back(0);
    family_ownership_offsets.push_back(0);
    const int32_t group_begin = _building_cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)
        ? _building_cell_offsets[cell_idx] : 0;
    const int32_t group_end = _building_cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)
        ? _building_cell_offsets[cell_idx + 1] : 0;
    auto diagnostic_for_type = [&](int32_t type_id) -> const InvestmentDiagnostic * {
        if (_investment_diagnostic_cell != cell_idx) return nullptr;
        for (const InvestmentDiagnostic &item : _investment_diagnostics) {
            if (item.type_id == type_id) return &item;
        }
        return nullptr;
    };
    for (int32_t group_idx = group_begin; group_idx < group_end; ++group_idx) {
        const auto group = building_at(static_cast<size_t>(group_idx));
        if (group.cell != cell_idx || group.count <= 0) continue;
        type_counts.set(group.type_id, type_counts[group.type_id] + group.count);
        const BuildingType &type = _building_types[group.type_id];
        int64_t snapshot_sat = 0;
        const int64_t full_owner_capacity = saturating_mul(
            group.count, type.owner_slots_per_building, snapshot_sat);
        int64_t employment_utilization_q16 = group.operating_state == 1
            ? 0 : group.planned_utilization_q16;
        const int64_t planned_owner_required = planned_owner_demand(
            group, snapshot_sat);
        group_type_ids.push_back(group.type_id);
        owner_signature_ids.push_back(group.owner_signature_id);
        group_counts.push_back(group.count);
        owner_capacity.push_back(full_owner_capacity);
        owner_required.push_back(planned_owner_required);
        projected_owner_income.push_back(projected_owner_income_per_day(
            group, snapshot_sat));
        int64_t prospective_employee_required = 0;
        int64_t prospective_employee_filled = 0;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            prospective_employee_required = saturating_add(
                prospective_employee_required,
                saturating_mul(group.count, role.slots_per_building, snapshot_sat),
                snapshot_sat);
            const int32_t role_index = group.employee_fill_begin + r;
            if (role_index >= 0 && role_index < static_cast<int32_t>(
                    _building_employee_filled.size())) {
                prospective_employee_filled = saturating_add(
                    prospective_employee_filled,
                    std::max<int64_t>(0, _building_employee_filled[role_index]),
                    snapshot_sat);
            }
        }
        const int64_t employee_fillability_q16 = prospective_employee_required > 0
            ? std::clamp<int64_t>(mul_div_sat(prospective_employee_filled,
                Q16_ONE, prospective_employee_required, snapshot_sat), 0, Q16_ONE)
            : Q16_ONE;
        const OwnerOpportunityQuote opportunity = owner_opportunity_quote(
            group, Q16_ONE, employee_fillability_q16, snapshot_sat);
        opportunity_owner_income_per_day.push_back(
            opportunity.owner_income_per_day);
        opportunity_disposable_survival_power_per_day.push_back(
            opportunity.disposable_survival_power_per_day);
        opportunity_executable_capacity_q16.push_back(
            opportunity.executable_capacity_q16);
        opportunity_in_kind_retail_value.push_back(
            opportunity.in_kind_retail_value);
        survival_priority.push_back(opportunity.survival_priority ? 1 : 0);
        int64_t group_survival_shortage_q16 = 0;
        const int32_t group_market = market_store().cell_to_market[group.cell];
        for (int32_t output = 0; output < type.output_count; ++output) {
            const int32_t good = _building_outputs[type.output_begin + output].good_id;
            if (good >= 0 && good < static_cast<int32_t>(
                    _survival_food_good_mask.size()) &&
                _survival_food_good_mask[good] != 0) {
                group_survival_shortage_q16 = std::max<int64_t>(
                    group_survival_shortage_q16,
                    market_store().last_shortage_q16[market_store().index(group_market, good)]);
            }
        }
        survival_shortage_q16.push_back(group_survival_shortage_q16);
        monetary_quota_absorption_q16.push_back(
            opportunity.monetary_quota_absorption_q16);
        monetary_quote_capped.push_back(opportunity.monetary_quote_capped ? 1 : 0);
        employee_tax_retention_q16.push_back(
            projected_employee_tax_retention_q16(group, snapshot_sat));
        filled_owner.push_back(group.filled_owner);
        owner_openings.push_back(std::max<int64_t>(
            0, planned_owner_required - group.filled_owner));
        if (_family_building_offsets.size() == building_count() + 1) {
            for (int32_t p = _family_building_offsets[group_idx];
                 p < _family_building_offsets[group_idx + 1]; ++p) {
                const FamilyBuildingOwnership &ownership =
                    family_ownerships().read_at(_family_building_edge_indices[p], __FILE__, __LINE__);
                family_ownership_handles.push_back(static_cast<int64_t>(
                    ownership.family_handle));
                family_owned_counts.push_back(ownership.owned_count);
                family_filled_owner.push_back(ownership.filled_owner);
            }
        }
        family_ownership_offsets.push_back(family_ownership_handles.size());
        capacity_q16.push_back(group.last_capacity_q16);
        last_temperature_fit_q16.push_back(group.last_temperature_fit_q16);
        last_water_fit_q16.push_back(group.last_water_fit_q16);
        last_climate_capacity_q16.push_back(group.last_climate_capacity_q16);
        last_climate_lost_output.push_back(group.last_climate_lost_output);
        purchase_intent_capacity_q16.push_back(group.purchase_intent_capacity_q16);
        funded_capacity_q16.push_back(group_idx < static_cast<int32_t>(
            _building_funded_capacity_q16.size())
            ? _building_funded_capacity_q16[group_idx] : group.last_capacity_q16);
        owner_working_capital_allocated.push_back(group_idx < static_cast<int32_t>(
            _building_working_capital_allocated.size())
            ? _building_working_capital_allocated[group_idx] : 0);
        owner_livelihood_in_kind_credit.push_back(group_idx < static_cast<int32_t>(
            _building_owner_livelihood_credit.size())
            ? _building_owner_livelihood_credit[group_idx] : 0);
        investment_score_q16.push_back(group_idx < static_cast<int32_t>(
            _building_investment_score_q16.size())
            ? _building_investment_score_q16[group_idx] : 0);
        investment_payback_days.push_back(group_idx < static_cast<int32_t>(
            _building_investment_payback_days.size())
            ? _building_investment_payback_days[group_idx] : 0);
        investment_rejection_reason.push_back(group_idx < static_cast<int32_t>(
            _building_investment_rejection.size())
            ? _building_investment_rejection[group_idx] : 0);
        const InvestmentDiagnostic *investment_diagnostic =
            diagnostic_for_type(group.type_id);
        investment_driver_good_id.push_back(investment_diagnostic != nullptr
            ? investment_diagnostic->driver_good_id : -1);
        investment_driver_pressure_q16.push_back(investment_diagnostic != nullptr
            ? investment_diagnostic->driver_pressure_q16 : 0);
        investment_driver_utilization_q16.push_back(investment_diagnostic != nullptr
            ? investment_diagnostic->driver_utilization_q16 : 0);
        investment_driver_sellable.push_back(investment_diagnostic != nullptr
            ? investment_diagnostic->driver_sellable : 0);
        investment_driver_merchant_sold.push_back(investment_diagnostic != nullptr
            ? investment_diagnostic->driver_merchant_sold : 0);
        investment_driver_sell_through_q16.push_back(investment_diagnostic != nullptr
            ? investment_diagnostic->driver_sell_through_q16 : 0);
        investment_driver_discard_q16.push_back(investment_diagnostic != nullptr
            ? investment_diagnostic->driver_discard_q16 : 0);
        investment_stealable.push_back(investment_diagnostic != nullptr
            ? investment_diagnostic->stealable : 0);
        investment_challenger_unit_cost.push_back(investment_diagnostic != nullptr
            ? investment_diagnostic->challenger_unit_cost : 0);
        investment_incumbent_unit_cost.push_back(investment_diagnostic != nullptr
            ? investment_diagnostic->incumbent_unit_cost : 0);
        investment_return_on_capital_q16.push_back(
            investment_diagnostic != nullptr
                ? investment_diagnostic->return_on_capital_q16 : 0);
        investment_cost_advantage_q16.push_back(
            investment_diagnostic != nullptr
                ? investment_diagnostic->cost_advantage_q16 : 0);
        realized_profit_margin_q16.push_back(group.realized_profit_margin_q16);
        severe_loss_cycles.push_back(group.severe_loss_cycles);
        recovery_cycles.push_back(group.recovery_cycles);
        recovery_failed_reviews.push_back(group.recovery_failed_reviews);
        pending_operating_state.push_back(group.pending_operating_state <= 1
            ? group.pending_operating_state : uint8_t{255});
        recovery_cooldown_cycles.push_back(0);
        operating_state.push_back(std::min<uint8_t>(group.operating_state, 1));
        merchant_debt_principal.push_back(group.merchant_debt_principal);
        merchant_debt_premium.push_back(group.merchant_debt_premium);
        merchant_debt_term_cycles_left.push_back(group.merchant_debt_term_cycles_left);
        merchant_debt_delinquent_cycles.push_back(group.merchant_debt_delinquent_cycles);
        last_in_kind_livelihood_value.push_back(group.last_in_kind_livelihood_value);
        last_input.push_back(group.last_input);
        last_output.push_back(group.last_output);
        last_sold.push_back(group.last_sold);
        last_discarded.push_back(group.last_discarded);
        last_retained.push_back(std::max<int64_t>(
            0, group.last_output - group.last_sold - group.last_discarded));
        last_resource.push_back(group.last_resource);
        last_resource_generated.push_back(group.last_resource_generated);
        last_revenue.push_back(group.last_revenue);
        last_input_cost.push_back(group.last_input_cost);
        last_wages_paid.push_back(group.last_wages_paid);
        last_wages_due.push_back(group.last_wages_due);
        last_expected_revenue.push_back(group.last_expected_revenue);
        last_operating_cost.push_back(group.last_operating_cost);
        last_maintenance_cost.push_back(group.last_maintenance_cost);
        last_market_receipt.push_back(group.last_market_receipt);
        last_bullion_mint_receipt.push_back(group.last_bullion_mint_receipt);
        last_producer_support_receipt.push_back(group.last_producer_support_receipt);
        last_business_tax_paid.push_back(group.last_business_tax_paid);
        last_business_subsidy_received.push_back(group.last_business_subsidy_received);
        last_maintenance_due.push_back(group.last_maintenance_due);
        last_observed_capacity_days_q16.push_back(
            group.last_observed_capacity_days_q16);
        last_quoted_market_receipt.push_back(group.last_quoted_market_receipt);
        last_quoted_operating_cost.push_back(group.last_quoted_operating_cost);
        last_margin_gap_q16.push_back(group.last_margin_gap_q16);
        planned_utilization_q16.push_back(group.planned_utilization_q16);
        last_base_wages_due.push_back(group.last_base_wages_due);
        last_base_wages_paid.push_back(group.last_base_wages_paid);
        last_bonus_due.push_back(group.last_bonus_due);
        last_bonus_paid.push_back(group.last_bonus_paid);
        wage_suspended.push_back(group.wage_suspended);
        for (int32_t input = 0; input < type.input_count; ++input) {
            const int32_t index = group.last_input_selection_begin + input;
            group_input_selected_good_ids.push_back(
                index >= 0 && index < static_cast<int32_t>(
                    _building_last_input_selected_goods.size())
                    ? _building_last_input_selected_goods[index] : -1);
        }
        group_input_selected_offsets.push_back(group_input_selected_good_ids.size());
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            employee_profession_ids.push_back(role.profession_id);
            const int32_t role_index = group.employee_fill_begin + r;
            employee_wage_policies.push_back(role.wage_policy);
            const int64_t contract = std::max<int64_t>(
                0, _building_role_contract_wage[role_index]);
            employee_contract_wages.push_back(contract);
            const int64_t due = std::max<int64_t>(
                0, _building_role_base_wage_due[role_index]);
            const int64_t paid = std::max<int64_t>(
                0, _building_role_base_wage_paid[role_index]);
            const int32_t signal = labor_signal_index(cell_idx, role.profession_id);
            const int64_t profession_paid = signal >= 0 && signal <
                    static_cast<int32_t>(_labor_signals.paid_wage_ema.size())
                ? std::max<int64_t>(0, _labor_signals.paid_wage_ema[signal]) : 0;
            const int64_t role_credibility = due > 0
                ? std::clamp<int64_t>(mul_div_sat(
                    paid, Q16_ONE, due, snapshot_sat), 0, Q16_ONE)
                : Q16_ONE;
            const int64_t role_expected = mul_div_sat(
                contract, role_credibility, Q16_ONE, snapshot_sat);
            const int32_t forecast_ratio_q16 = role_index >= 0 &&
                    role_index < static_cast<int32_t>(
                        _building_role_forecast_pay_ratio_q16.size())
                ? std::clamp<int32_t>(
                    _building_role_forecast_pay_ratio_q16[role_index],
                    0, Q16_ONE)
                : Q16_ONE;
            const int64_t forecast_expected = mul_div_sat(
                contract, forecast_ratio_q16, Q16_ONE, snapshot_sat);
            const int64_t history_expected = profession_paid > 0
                    ? saturating_add(role_expected,
                        std::min(contract, profession_paid), snapshot_sat) / 2
                    : role_expected;
            const int64_t expected = due <= 0
                ? forecast_expected
                : std::min(history_expected, forecast_expected);
            employee_expected_wages.push_back(expected);
            employee_payment_credibility_q16.push_back(static_cast<int32_t>(
                contract > 0 ? std::clamp<int64_t>(mul_div_sat(
                    expected, Q16_ONE, contract, snapshot_sat), 0, Q16_ONE)
                    : Q16_ONE));
            employee_forecast_pay_ratio_q16.push_back(forecast_ratio_q16);
            employee_base_living_cost.push_back(
                _building_role_base_living_cost[role_index]);
            employee_role_living_cost.push_back(
                _building_role_living_cost[role_index]);
            employee_local_average_wage.push_back(
                _building_role_local_average_wage[role_index]);
            employee_base_wage_due.push_back(
                _building_role_base_wage_due[role_index]);
            employee_base_wage_paid.push_back(
                _building_role_base_wage_paid[role_index]);
            employee_bonus_due.push_back(_building_role_bonus_due[role_index]);
            employee_bonus_paid.push_back(_building_role_bonus_paid[role_index]);
            const int64_t full_required = saturating_mul(
                group.count, role.slots_per_building, snapshot_sat);
            int64_t planned_required = mul_div_sat(
                full_required, employment_utilization_q16, Q16_ONE, snapshot_sat);
            if (planned_required == 0 && full_required > 0 &&
                employment_utilization_q16 > 0) planned_required = 1;
            employee_required.push_back(planned_required);
            employee_filled.push_back(_building_employee_filled[group.employee_fill_begin + r]);
        }
        employee_fill_offsets.push_back(employee_profession_ids.size());
    }
    PackedInt32Array construction_types;
    PackedInt32Array construction_owners;
    PackedInt64Array construction_counts;
    PackedInt64Array construction_ready_days;
    PackedInt64Array construction_merchant_debt_principal;
    PackedInt64Array construction_merchant_debt_premium;
    PackedInt32Array construction_merchant_debt_term_cycles_left;
    for (const auto pending : pending_construction()) {
        if (pending.cell != cell_idx) continue;
        construction_types.push_back(pending.type_id);
        construction_owners.push_back(pending.owner_signature_id);
        construction_counts.push_back(pending.count);
        construction_ready_days.push_back(pending.ready_day);
        construction_merchant_debt_principal.push_back(pending.merchant_debt_principal);
        construction_merchant_debt_premium.push_back(pending.merchant_debt_premium);
        construction_merchant_debt_term_cycles_left.push_back(
            pending.merchant_debt_term_cycles_left);
    }
    PackedInt32Array investment_candidate_type_ids;
    PackedInt32Array investment_candidate_rejection_reasons;
    PackedInt64Array investment_candidate_shortage_q16;
    PackedInt64Array investment_candidate_utilization_q16;
    PackedInt64Array investment_candidate_score_q16;
    PackedInt64Array investment_candidate_payback_days;
    PackedInt64Array investment_candidate_required_capital;
    PackedInt64Array investment_candidate_projected_profit_per_day;
    PackedInt32Array investment_candidate_driver_good_id;
    PackedInt64Array investment_candidate_driver_pressure_q16;
    PackedInt64Array investment_candidate_driver_utilization_q16;
    PackedInt64Array investment_candidate_driver_sellable;
    PackedInt64Array investment_candidate_driver_merchant_sold;
    PackedInt64Array investment_candidate_driver_sell_through_q16;
    PackedInt64Array investment_candidate_driver_discard_q16;
    PackedInt64Array investment_candidate_stealable;
    PackedInt64Array investment_candidate_challenger_unit_cost;
    PackedInt64Array investment_candidate_incumbent_unit_cost;
    PackedInt64Array investment_candidate_return_on_capital_q16;
    PackedInt64Array investment_candidate_cost_advantage_q16;
    PackedInt64Array investment_candidate_monetary_quota_initial;
    PackedInt64Array investment_candidate_monetary_quota_daily;
    PackedInt64Array investment_candidate_monetary_units;
    PackedInt64Array investment_candidate_monetary_candidate_slots;
    PackedInt64Array investment_candidate_monetary_request_money_per_day;
    PackedInt64Array investment_candidate_monetary_expected_revenue_per_day;
    PackedInt32Array investment_candidate_failed_material_group;
    PackedInt32Array investment_candidate_selected_material_offsets;
    PackedInt32Array investment_candidate_selected_material_good_ids;
    PackedInt64Array investment_candidate_selected_material_quantities;
    investment_candidate_selected_material_offsets.push_back(0);
    if (_investment_diagnostic_cell == cell_idx) {
        for (const InvestmentDiagnostic &item : _investment_diagnostics) {
            investment_candidate_type_ids.push_back(item.type_id);
            investment_candidate_rejection_reasons.push_back(item.rejection_reason);
            investment_candidate_shortage_q16.push_back(item.shortage_q16);
            investment_candidate_utilization_q16.push_back(item.utilization_q16);
            investment_candidate_score_q16.push_back(item.score_q16);
            investment_candidate_payback_days.push_back(item.payback_days);
            investment_candidate_required_capital.push_back(item.required_capital);
            investment_candidate_projected_profit_per_day.push_back(
                item.projected_profit_per_day);
            investment_candidate_driver_good_id.push_back(item.driver_good_id);
            investment_candidate_driver_pressure_q16.push_back(
                item.driver_pressure_q16);
            investment_candidate_driver_utilization_q16.push_back(
                item.driver_utilization_q16);
            investment_candidate_driver_sellable.push_back(item.driver_sellable);
            investment_candidate_driver_merchant_sold.push_back(
                item.driver_merchant_sold);
            investment_candidate_driver_sell_through_q16.push_back(
                item.driver_sell_through_q16);
            investment_candidate_driver_discard_q16.push_back(
                item.driver_discard_q16);
            investment_candidate_stealable.push_back(item.stealable);
            investment_candidate_challenger_unit_cost.push_back(
                item.challenger_unit_cost);
            investment_candidate_incumbent_unit_cost.push_back(
                item.incumbent_unit_cost);
            investment_candidate_return_on_capital_q16.push_back(
                item.return_on_capital_q16);
            investment_candidate_cost_advantage_q16.push_back(
                item.cost_advantage_q16);
            investment_candidate_monetary_quota_initial.push_back(
                item.monetary_quota_initial);
            investment_candidate_monetary_quota_daily.push_back(
                item.monetary_quota_daily);
            investment_candidate_monetary_units.push_back(
                item.monetary_units);
            investment_candidate_monetary_candidate_slots.push_back(
                item.monetary_candidate_slots);
            investment_candidate_monetary_request_money_per_day.push_back(
                item.monetary_request_money_per_day);
            investment_candidate_monetary_expected_revenue_per_day.push_back(
                item.monetary_expected_revenue_per_day);
            investment_candidate_failed_material_group.push_back(
                item.failed_material_group);
            for (size_t material = 0;
                 material < item.selected_material_good_ids.size(); ++material) {
                investment_candidate_selected_material_good_ids.push_back(
                    item.selected_material_good_ids[material]);
                investment_candidate_selected_material_quantities.push_back(
                    material < item.selected_material_quantities.size()
                        ? item.selected_material_quantities[material] : 0);
            }
            investment_candidate_selected_material_offsets.push_back(
                investment_candidate_selected_material_good_ids.size());
        }

    }
    out["building_type_ids"] = type_ids;
    out["building_counts_by_type"] = type_counts;
    out["target_operating_margin_q16_by_type"] = target_operating_margin_q16;
    out["supply_price_elasticity_q16_by_type"] = supply_price_elasticity_q16;
	out["building_kinds"] = building_kinds;
	PackedStringArray upgrade_family_ids;
	for (const std::string &id : _building_upgrade_family_ids)
		upgrade_family_ids.push_back(String(id.c_str()));
	out["building_upgrade_family_ids"] = upgrade_family_ids;
	out["building_upgrade_family_indices"] = upgrade_family_indices;
	out["building_upgrade_tiers"] = upgrade_tiers;
	out["building_highest_available_tiers"] = highest_available_tiers;
	out["building_technology_tag_offsets"] = technology_tag_offsets;
	out["building_technology_tags"] = technology_tags;
	out["building_required_technology_tag_offsets"] = required_technology_tag_offsets;
	out["building_required_technology_tags"] = required_technology_tags;
	out["building_technology_available"] = technology_available;
	out["building_construction_available"] = construction_available;
    out["group_type_ids"] = group_type_ids;
    out["owner_signature_ids"] = owner_signature_ids;
    out["group_counts"] = group_counts;
    out["owner_capacity"] = owner_capacity;
    out["owner_required"] = owner_required;
    out["projected_owner_income_per_day"] = projected_owner_income;
    out["opportunity_owner_income_per_day"] = opportunity_owner_income_per_day;
    out["opportunity_disposable_survival_power_per_day"] =
        opportunity_disposable_survival_power_per_day;
    out["opportunity_executable_capacity_q16"] =
        opportunity_executable_capacity_q16;
    out["opportunity_in_kind_retail_value"] =
        opportunity_in_kind_retail_value;
    out["survival_priority"] = survival_priority;
    out["survival_shortage_q16"] = survival_shortage_q16;
    out["monetary_quota_absorption_q16"] = monetary_quota_absorption_q16;
    out["monetary_quote_capped"] = monetary_quote_capped;
    out["employee_tax_retention_q16"] = employee_tax_retention_q16;
    out["filled_owner"] = filled_owner;
    out["owner_openings"] = owner_openings;
    out["family_ownership_offsets"] = family_ownership_offsets;
    out["family_ownership_handles"] = family_ownership_handles;
    out["family_owned_counts"] = family_owned_counts;
    out["family_filled_owner"] = family_filled_owner;
    out["employee_fill_offsets"] = employee_fill_offsets;
    out["employee_profession_ids"] = employee_profession_ids;
    out["employee_required"] = employee_required;
    out["employee_filled"] = employee_filled;
    out["employee_wage_policies"] = employee_wage_policies;
    out["employee_contract_wages_per_day"] = employee_contract_wages;
    out["employee_expected_wages_per_day"] = employee_expected_wages;
    out["employee_payment_credibility_q16"] =
        employee_payment_credibility_q16;
    out["employee_forecast_pay_ratio_q16"] =
        employee_forecast_pay_ratio_q16;
    out["employee_base_living_cost_per_day"] = employee_base_living_cost;
    out["employee_role_living_cost_per_day"] = employee_role_living_cost;
    out["employee_local_average_wage_per_day"] = employee_local_average_wage;
    out["employee_base_wage_due"] = employee_base_wage_due;
    out["employee_base_wage_paid"] = employee_base_wage_paid;
    out["employee_bonus_due"] = employee_bonus_due;
    out["employee_bonus_paid"] = employee_bonus_paid;
    out["capacity_q16"] = capacity_q16;
    out["last_temperature_fit_q16"] = last_temperature_fit_q16;
    out["last_water_fit_q16"] = last_water_fit_q16;
    out["last_climate_capacity_q16"] = last_climate_capacity_q16;
    out["last_climate_lost_output"] = last_climate_lost_output;
    out["purchase_intent_capacity_q16"] = purchase_intent_capacity_q16;
    out["funded_capacity_q16"] = funded_capacity_q16;
    out["owner_working_capital_allocated"] = owner_working_capital_allocated;
    out["owner_livelihood_in_kind_credit"] = owner_livelihood_in_kind_credit;
    out["investment_score_q16"] = investment_score_q16;
    out["investment_payback_days"] = investment_payback_days;
    out["investment_rejection_reason"] = investment_rejection_reason;
    out["investment_driver_good_id"] = investment_driver_good_id;
    out["investment_driver_pressure_q16"] = investment_driver_pressure_q16;
    out["investment_driver_utilization_q16"] = investment_driver_utilization_q16;
    out["investment_driver_sellable"] = investment_driver_sellable;
    out["investment_driver_merchant_sold"] = investment_driver_merchant_sold;
    out["investment_driver_sell_through_q16"] = investment_driver_sell_through_q16;
    out["investment_driver_discard_q16"] = investment_driver_discard_q16;
    out["investment_stealable"] = investment_stealable;
    out["investment_challenger_unit_cost"] = investment_challenger_unit_cost;
    out["investment_incumbent_unit_cost"] = investment_incumbent_unit_cost;
    out["investment_return_on_capital_q16"] =
        investment_return_on_capital_q16;
    out["investment_cost_advantage_q16"] = investment_cost_advantage_q16;
    out["investment_candidate_diagnostic_day"] = _investment_diagnostic_cell == cell_idx
        ? _investment_diagnostic_day : -1;
    out["investment_candidate_type_ids"] = investment_candidate_type_ids;
    out["investment_candidate_rejection_reasons"] =
        investment_candidate_rejection_reasons;
    out["investment_candidate_shortage_q16"] = investment_candidate_shortage_q16;
    out["investment_candidate_utilization_q16"] = investment_candidate_utilization_q16;
    out["investment_candidate_score_q16"] = investment_candidate_score_q16;
    out["investment_candidate_payback_days"] = investment_candidate_payback_days;
    out["investment_candidate_required_capital"] =
        investment_candidate_required_capital;
    out["investment_candidate_projected_profit_per_day"] =
        investment_candidate_projected_profit_per_day;
    out["investment_candidate_driver_good_id"] =
        investment_candidate_driver_good_id;
    out["investment_candidate_driver_pressure_q16"] =
        investment_candidate_driver_pressure_q16;
    out["investment_candidate_driver_utilization_q16"] =
        investment_candidate_driver_utilization_q16;
    out["investment_candidate_driver_sellable"] =
        investment_candidate_driver_sellable;
    out["investment_candidate_failed_material_group"] =
        investment_candidate_failed_material_group;
    out["investment_candidate_selected_material_offsets"] =
        investment_candidate_selected_material_offsets;
    out["investment_candidate_selected_material_good_ids"] =
        investment_candidate_selected_material_good_ids;
    out["investment_candidate_selected_material_quantities"] =
        investment_candidate_selected_material_quantities;
    out["investment_candidate_driver_merchant_sold"] =
        investment_candidate_driver_merchant_sold;
    out["investment_candidate_driver_sell_through_q16"] =
        investment_candidate_driver_sell_through_q16;
    out["investment_candidate_driver_discard_q16"] =
        investment_candidate_driver_discard_q16;
    out["investment_candidate_stealable"] = investment_candidate_stealable;
    out["investment_candidate_challenger_unit_cost"] =
        investment_candidate_challenger_unit_cost;
    out["investment_candidate_incumbent_unit_cost"] =
        investment_candidate_incumbent_unit_cost;
    out["investment_candidate_return_on_capital_q16"] =
        investment_candidate_return_on_capital_q16;
    out["investment_candidate_cost_advantage_q16"] =
        investment_candidate_cost_advantage_q16;
    out["investment_candidate_monetary_quota_initial"] =
        investment_candidate_monetary_quota_initial;
    out["investment_candidate_monetary_quota_daily"] =
        investment_candidate_monetary_quota_daily;
    out["investment_candidate_monetary_units"] =
        investment_candidate_monetary_units;
    out["investment_candidate_monetary_candidate_slots"] =
        investment_candidate_monetary_candidate_slots;
    out["investment_candidate_monetary_request_money_per_day"] =
        investment_candidate_monetary_request_money_per_day;
    out["investment_candidate_monetary_expected_revenue_per_day"] =
        investment_candidate_monetary_expected_revenue_per_day;
    out["realized_profit_margin_q16"] = realized_profit_margin_q16;
    out["severe_loss_cycles"] = severe_loss_cycles;
    out["recovery_cycles"] = recovery_cycles;
    out["pending_operating_state"] = pending_operating_state;
    out["recovery_cooldown_cycles"] = recovery_cooldown_cycles;
    out["recovery_failed_reviews"] = recovery_failed_reviews;
    out["operating_state"] = operating_state;
    out["merchant_debt_principal"] = merchant_debt_principal;
    out["merchant_debt_premium"] = merchant_debt_premium;
    out["merchant_debt_term_cycles_left"] = merchant_debt_term_cycles_left;
    out["merchant_debt_delinquent_cycles"] = merchant_debt_delinquent_cycles;
    out["last_in_kind_livelihood_value"] = last_in_kind_livelihood_value;
    out["last_input"] = last_input;
    out["last_output"] = last_output;
    out["last_sold"] = last_sold;
    out["last_discarded"] = last_discarded;
    out["last_retained"] = last_retained;
    out["last_resource"] = last_resource;
    out["last_resource_generated"] = last_resource_generated;
    out["last_revenue"] = last_revenue;
    out["last_input_cost"] = last_input_cost;
    out["last_wages_paid"] = last_wages_paid;
    out["last_wages_due"] = last_wages_due;
    out["last_expected_revenue"] = last_expected_revenue;
    out["last_operating_cost"] = last_operating_cost;
    out["last_maintenance_cost"] = last_maintenance_cost;
    out["last_market_receipt"] = last_market_receipt;
    out["last_bullion_mint_receipt"] = last_bullion_mint_receipt;
    out["last_producer_support_receipt"] = last_producer_support_receipt;
    out["last_business_tax_paid"] = last_business_tax_paid;
    out["last_business_subsidy_received"] = last_business_subsidy_received;
    out["last_maintenance_due"] = last_maintenance_due;
    out["last_observed_capacity_days_q16"] = last_observed_capacity_days_q16;
    out["last_quoted_market_receipt"] = last_quoted_market_receipt;
    out["last_quoted_operating_cost"] = last_quoted_operating_cost;
    out["last_margin_gap_q16"] = last_margin_gap_q16;
    out["planned_utilization_q16"] = planned_utilization_q16;
    out["last_base_wages_due"] = last_base_wages_due;
    out["last_base_wages_paid"] = last_base_wages_paid;
    out["last_bonus_due"] = last_bonus_due;
    out["last_bonus_paid"] = last_bonus_paid;
    out["wage_suspended"] = wage_suspended;
    out["group_input_selected_offsets"] = group_input_selected_offsets;
    out["group_input_selected_good_ids"] = group_input_selected_good_ids;
    PackedInt32Array labor_professions;
    PackedInt64Array labor_contract_ema;
    PackedInt64Array labor_paid_ema;
    PackedInt64Array labor_base_cost;
    PackedInt64Array labor_role_cost;
    PackedInt64Array labor_job_days;
    PackedInt32Array labor_pay_ratio;
    for (int32_t i = _labor_signals.cell_offsets[cell_idx];
         i < _labor_signals.cell_offsets[cell_idx + 1]; ++i) {
        labor_professions.push_back(_labor_signals.profession_ids[i]);
        labor_contract_ema.push_back(_labor_signals.contract_wage_ema[i]);
        labor_paid_ema.push_back(_labor_signals.paid_wage_ema[i]);
        labor_base_cost.push_back(_labor_signals.base_living_cost[i]);
        labor_role_cost.push_back(_labor_signals.role_living_cost[i]);
        labor_job_days.push_back(_labor_signals.job_days[i]);
        labor_pay_ratio.push_back(_labor_signals.pay_ratio_q16[i]);
    }
    out["labor_market_profession_ids"] = labor_professions;
    out["labor_market_contract_wage_ema"] = labor_contract_ema;
    out["labor_market_paid_wage_ema"] = labor_paid_ema;
    out["labor_market_base_living_cost"] = labor_base_cost;
    out["labor_market_role_living_cost"] = labor_role_cost;
    out["labor_market_job_days"] = labor_job_days;
    out["labor_market_pay_ratio_q16"] = labor_pay_ratio;
    out["construction_type_ids"] = construction_types;
    out["construction_owner_signature_ids"] = construction_owners;
    out["construction_counts"] = construction_counts;
    out["construction_ready_days"] = construction_ready_days;
    out["construction_merchant_debt_principal"] = construction_merchant_debt_principal;
    out["construction_merchant_debt_premium"] = construction_merchant_debt_premium;
    out["construction_merchant_debt_term_cycles_left"] =
        construction_merchant_debt_term_cycles_left;
    return out;
}
