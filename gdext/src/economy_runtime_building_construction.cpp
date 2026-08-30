#include "economy_runtime.h"
#include "country_runtime.h"

#include <algorithm>
#include <limits>

namespace pk {

bool NativeEconomyRuntime::plan_construction_materials(
        int32_t cell, int32_t type_id, int64_t count, int32_t cost_factor_q16,
        ConstructionMaterialPlan &plan,
        const std::vector<int64_t> *additional_stock,
        std::vector<int64_t> *stock_inout,
        bool split_candidates) const {
    plan = ConstructionMaterialPlan{};
    if (cell < 0 || cell >= _cell_count || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size()) || count <= 0 ||
        _building_construction_candidate_offsets.size() !=
            _building_construction_goods.size() + 1) {
        return false;
    }
    const int32_t market = _market.cell_to_market[cell];
    if (market < 0 || market >= _market.market_count) return false;
    int64_t sat = 0;
    const BuildingType &type = _building_types[type_id];
    if (type.construction_begin < 0 || type.construction_count < 0 ||
        type.construction_begin + type.construction_count >
            static_cast<int32_t>(_building_construction_goods.size())) return false;

    std::vector<int64_t> local_stock;
    std::vector<int64_t> *virtual_stock = stock_inout;
    if (virtual_stock == nullptr) {
        local_stock.assign(_good_ids.size(), 0);
        for (int32_t good = 0; good < _market.good_count; ++good) {
            local_stock[static_cast<size_t>(good)] = std::max<int64_t>(0,
                _market.stock[_market.index(market, good)]);
        }
        if (additional_stock != nullptr) {
            for (size_t good = 0; good < local_stock.size() &&
                 good < additional_stock->size(); ++good) {
                local_stock[good] = std::max<int64_t>(0, saturating_add(
                    local_stock[good], (*additional_stock)[good], sat));
            }
        }
        virtual_stock = &local_stock;
    } else if (virtual_stock->size() < _good_ids.size()) {
        virtual_stock->resize(_good_ids.size(), 0);
    }
    auto add_selection = [&](int32_t good, int64_t quantity) {
        for (size_t index = 0; index < plan.good_ids.size(); ++index) {
            if (plan.good_ids[index] == good) {
                plan.quantities[index] = saturating_add(
                    plan.quantities[index], quantity, sat);
                return;
            }
        }
        plan.good_ids.push_back(good);
        plan.quantities.push_back(quantity);
    };
    GoodsBill construction_bill;
    const int32_t cost_factor = std::max<int32_t>(1, cost_factor_q16);
    for (int64_t unit = 0; unit < count; ++unit) {
        for (int32_t group_index = 0; group_index < type.construction_count;
             ++group_index) {
            const int32_t group = type.construction_begin + group_index;
            const GoodAmount &preferred = _building_construction_goods[group];
            const int32_t candidate_begin =
                _building_construction_candidate_offsets[group];
            const int32_t candidate_end =
                _building_construction_candidate_offsets[group + 1];
            const int64_t required = std::max<int64_t>(1, mul_div_sat(
                preferred.quantity, cost_factor, Q16_ONE, sat));
            if (split_candidates) {
                int64_t remaining = required;
                for (int32_t pass = 0; pass < 2 && remaining > 0; ++pass) {
                    for (int32_t candidate_index = candidate_begin;
                         candidate_index < candidate_end && remaining > 0;
                         ++candidate_index) {
                        const ConstructionCandidate &candidate =
                            _building_construction_candidates[candidate_index];
                        const bool preferred_candidate = candidate.good_id ==
                            preferred.good_id;
                        if ((pass == 0) != preferred_candidate ||
                            candidate.good_id < 0 || candidate.good_id >=
                                static_cast<int32_t>(virtual_stock->size()) ||
                            !good_market_available(cell, candidate.good_id, true)) {
                            continue;
                        }
                        const int32_t efficiency = std::max<int32_t>(
                            1, candidate.efficiency_q16);
                        int64_t physical_needed = mul_div_sat(
                            remaining, Q16_ONE, efficiency, sat);
                        if (mul_div_sat(physical_needed, efficiency,
                                Q16_ONE, sat) < remaining) {
                            physical_needed = saturating_add(
                                physical_needed, 1, sat);
                        }
                        const int64_t available = std::max<int64_t>(0,
                            (*virtual_stock)[static_cast<size_t>(candidate.good_id)]);
                        const int64_t physical = std::min(
                            available, physical_needed);
                        if (physical <= 0) continue;
                        (*virtual_stock)[static_cast<size_t>(candidate.good_id)] -=
                            physical;
                        add_selection(candidate.good_id, physical);
                        const int64_t price = _market.price[_market.index(
                            market, candidate.good_id)];
                        plan.total_cost = saturating_add(plan.total_cost,
                            construction_bill.add(physical, price, sat), sat);
                        const int64_t credited = mul_div_sat(
                            physical, efficiency, Q16_ONE, sat);
                        remaining = std::max<int64_t>(0,
                            remaining - std::min(remaining, credited));
                    }
                }
                if (remaining > 0) {
                    plan.failed_group = group_index;
                    return false;
                }
                continue;
            }
            int32_t selected_good = -1;
            int64_t selected_quantity = 0;
            int64_t selected_cost = std::numeric_limits<int64_t>::max();
            for (int32_t candidate_index = candidate_begin;
                 candidate_index < candidate_end; ++candidate_index) {
                const ConstructionCandidate &candidate =
                    _building_construction_candidates[candidate_index];
                if (!good_market_available(cell, candidate.good_id, true)) continue;
                int64_t physical = mul_div_sat(required, Q16_ONE,
                    std::max<int32_t>(1, candidate.efficiency_q16),
                    sat);
                if (mul_div_sat(physical,
                        std::max<int32_t>(1, candidate.efficiency_q16),
                        Q16_ONE, sat) < required) {
                    physical = saturating_add(physical, 1,
                        sat);
                }
                if (candidate.good_id < 0 || candidate.good_id >=
                        static_cast<int32_t>(virtual_stock->size()) ||
                    (*virtual_stock)[static_cast<size_t>(candidate.good_id)] <
                        physical) {
                    continue;
                }
                const int64_t price = _market.price[_market.index(
                    market, candidate.good_id)];
                const int64_t effective_cost = goods_cost(physical, price, sat);
                const bool preferred_candidate = candidate.good_id ==
                    preferred.good_id;
                const bool selected_preferred = selected_good == preferred.good_id;
                if (selected_good < 0 || effective_cost < selected_cost ||
                    (effective_cost == selected_cost &&
                     (preferred_candidate != selected_preferred
                          ? preferred_candidate
                          : candidate.good_id < selected_good))) {
                    selected_good = candidate.good_id;
                    selected_quantity = physical;
                    selected_cost = effective_cost;
                }
            }
            if (selected_good < 0) {
                plan.failed_group = group_index;
                return false;
            }
            (*virtual_stock)[static_cast<size_t>(selected_good)] -=
                selected_quantity;
            add_selection(selected_good, selected_quantity);
            plan.total_cost = saturating_add(plan.total_cost,
                construction_bill.add(selected_quantity,
                    _market.price[_market.index(market, selected_good)], sat), sat);
        }
    }
    plan.feasible = true;
    return true;
}

void NativeEconomyRuntime::stage_construction_receipt(
        const Command &cmd, bool ok, const char *code, int64_t cash_paid,
        int64_t treasury_goods_used, int64_t market_goods_used) {
    _staging_construction_receipts.push_back({0, cmd.sequence,
        cmd.effective_day, _current_day, cmd.target_handle, cmd.i32_0,
        cmd.i32_1, ok, code == nullptr ? "command_rejected" : code,
        cash_paid, treasury_goods_used, market_goods_used});
}

int32_t NativeEconomyRuntime::treasury_build_owner_signature(
        int32_t cell, int32_t type_id) const {
    if (cell < 0 || cell >= _cell_count || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size())) return -1;
    const int32_t owner_profession = _building_types[type_id].owner_profession_id;
    if (_building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)) {
        for (int32_t group = _building_cell_offsets[cell];
             group < _building_cell_offsets[cell + 1]; ++group) {
            const BuildingGroup &candidate = _buildings[group];
            if (candidate.type_id == type_id && candidate.count > 0 &&
                candidate.owner_signature_id >= 0 &&
                candidate.owner_signature_id < static_cast<int32_t>(_signatures.size()) &&
                _signatures[candidate.owner_signature_id].profession_id == owner_profession) {
                return candidate.owner_signature_id;
            }
        }
    }
    std::vector<int64_t> population_by_ethnicity(_ethnicity_ids.size(), 0);
    int64_t local_sat = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
        if (signature < 0 || signature >= static_cast<int32_t>(_signatures.size())) return;
        const int32_t ethnicity = _signatures[signature].ethnicity_id;
        if (ethnicity < 0 || ethnicity >= static_cast<int32_t>(
                population_by_ethnicity.size())) return;
        population_by_ethnicity[ethnicity] = saturating_add(
            population_by_ethnicity[ethnicity],
            std::max<int64_t>(0, _population.population[slot]), local_sat);
    });
    int32_t dominant_ethnicity = -1;
    int64_t dominant_population = -1;
    for (int32_t ethnicity = 0; ethnicity < static_cast<int32_t>(
            population_by_ethnicity.size()); ++ethnicity) {
        const int32_t signature = signature_for_profession_ethnicity(
            owner_profession, ethnicity);
        if (signature < 0) continue;
        if (population_by_ethnicity[ethnicity] > dominant_population) {
            dominant_population = population_by_ethnicity[ethnicity];
            dominant_ethnicity = ethnicity;
        }
    }
    return dominant_ethnicity >= 0
        ? signature_for_profession_ethnicity(owner_profession, dominant_ethnicity)
        : -1;
}

bool NativeEconomyRuntime::apply_treasury_sponsored_build_command(
        const Command &cmd, std::string &error) {
    const int32_t cell = cmd.i32_0;
    const int32_t type_id = cmd.i32_1;
    auto reject = [&](const char *code) {
        _last_building_rejection_reason = code;
        ++_rejected_commands;
        stage_construction_receipt(cmd, false, code);
        return true;
    };
    if (cmd.i64_1 != OWNERSHIP_TREASURY_SPONSORED_PRIVATE)
        return reject("unsupported_ownership_policy");
    if (_country_runtime == nullptr ||
        !_country_runtime->valid_handle(static_cast<int64_t>(cmd.target_handle)) ||
        cell < 0 || cell >= _cell_count || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size()) || cmd.i64_0 != 1)
        return reject("construction_target_invalid");
    if (_country_runtime->country_handle_for_cell(cell) !=
            static_cast<int64_t>(cmd.target_handle))
        return reject("construction_cell_not_owned");
    if (!building_available(cell, type_id, true))
        return reject("construction_technology_locked");
    if (!building_constructible(cell, type_id, true))
        return reject("construction_obsolete");
    if (!evaluate_building_conditions(type_id, cell))
        return reject("construction_conditions_failed");
    if (!family_free_building_resources_legal(cell, type_id, 1))
        return reject("construction_resource_unavailable");

    const int32_t owner_signature = treasury_build_owner_signature(cell, type_id);
    if (owner_signature < 0) return reject("construction_owner_signature_unavailable");
    const int32_t market = _market.cell_to_market[cell];
    if (market < 0 || market >= _market.market_count)
        return reject("construction_market_unavailable");
    const int32_t country_slot = cell < static_cast<int32_t>(
            _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
    const int32_t cost_factor = country_slot >= 0 && country_slot <
            static_cast<int32_t>(_epoch_country_construction_cost_factor_q16.size())
        ? _epoch_country_construction_cost_factor_q16[country_slot] : Q16_ONE;
    std::vector<int64_t> country_stock(_good_ids.size(), 0);
    for (size_t good = 0; good < country_stock.size(); ++good) {
        country_stock[good] = std::max<int64_t>(0,
            _country_runtime->good_for_handle(
                static_cast<int64_t>(cmd.target_handle),
                static_cast<int32_t>(good)));
    }
    ConstructionMaterialPlan material_plan;
    if (!plan_construction_materials(cell, type_id, 1, cost_factor,
                                     material_plan, &country_stock))
        return reject("construction_materials_insufficient");
    const std::vector<int32_t> &good_ids = material_plan.good_ids;
    const std::vector<int64_t> &required = material_plan.quantities;
    const BuildingType &type = _building_types[type_id];

    std::vector<int64_t> treasury_used(good_ids.size(), 0);
    std::vector<int64_t> market_used(good_ids.size(), 0);
    int64_t total_cash = 0;
    GoodsBill treasury_bill;
    int64_t treasury_goods_total = 0;
    int64_t market_goods_total = 0;
    for (size_t i = 0; i < good_ids.size(); ++i) {
        treasury_used[i] = std::min<int64_t>(required[i], std::max<int64_t>(0,
            _country_runtime->good_for_handle(
                static_cast<int64_t>(cmd.target_handle), good_ids[i])));
        market_used[i] = required[i] - treasury_used[i];
        const int64_t lane = _market.index(market, good_ids[i]);
        if (_market.stock[lane] < market_used[i])
            return reject("construction_materials_insufficient");
        total_cash = saturating_add(total_cash, treasury_bill.add(market_used[i], _market.price[lane], _saturation_count), _saturation_count);
        treasury_goods_total = saturating_add(
            treasury_goods_total, treasury_used[i], _saturation_count);
        market_goods_total = saturating_add(
            market_goods_total, market_used[i], _saturation_count);
    }
    if (total_cash > 0 && (_merchant_offsets.size() !=
            static_cast<size_t>(_cell_count + 1) ||
            _merchant_offsets[cell] >= _merchant_offsets[cell + 1]))
        return reject("construction_market_unavailable");
    if (_country_runtime->cash_for_handle(
            static_cast<int64_t>(cmd.target_handle)) < total_cash)
        return reject("construction_treasury_cash_insufficient");
    if (!_country_runtime->spend_treasury_assets(
            static_cast<int64_t>(cmd.target_handle), good_ids.data(),
            treasury_used.data(), good_ids.size(), total_cash))
        return reject("construction_treasury_preflight_drift");

    for (size_t i = 0; i < good_ids.size(); ++i) {
        const int64_t lane = _market.index(market, good_ids[i]);
        audit_touch_market_lane(static_cast<size_t>(lane));
        _market.stock[lane] -= market_used[i];
        _construction_goods_consumed = saturating_add(
            _construction_goods_consumed, required[i], _saturation_count);
        const int32_t signal = ensure_market_signal_index(cell, good_ids[i]);
        if (signal >= 0 && signal < static_cast<int32_t>(
                _epoch_nonhousehold_withdrawals.size())) {
            _epoch_nonhousehold_withdrawals[signal] = saturating_add(
                _epoch_nonhousehold_withdrawals[signal], required[i],
                _saturation_count);
        }
    }
    if (total_cash > 0 && credit_local_merchants(
            cell, total_cash, CASHFLOW_MERCHANT_BUSINESS) != total_cash) {
        error = "construction_merchant_credit_invariant_failed";
        return false;
    }
    const int32_t time_factor = country_slot >= 0 && country_slot <
            static_cast<int32_t>(_epoch_country_construction_time_factor_q16.size())
        ? _epoch_country_construction_time_factor_q16[country_slot] : Q16_ONE;
    const int32_t construction_days = type.construction_days <= 0 ? 0 :
        std::max<int32_t>(1, static_cast<int32_t>(mul_div_sat(
            type.construction_days, time_factor, Q16_ONE, _saturation_count)));
    _pending_construction.push_back({cell, type_id, owner_signature, 1,
        _sample_day + construction_days, cmd.sequence, 0, 0, 0, 0});
    trace_append(EVENT_CONSTRUCTION_STARTED, static_cast<int32_t>(_stage),
        cell, SUBJECT_BUILDING_GROUP, owner_signature, type_id,
        OWNERSHIP_TREASURY_SPONSORED_PRIVATE, 1, total_cash,
        _sample_day + construction_days, cmd.sequence, nullptr);
    stage_construction_receipt(cmd, true, "ok", total_cash,
                               treasury_goods_total, market_goods_total);
    return true;
}

bool NativeEconomyRuntime::apply_build_command(const Command &cmd, int32_t owner_slot,
                                                std::string &error,
                                                bool allow_obsolete_tier) {
    const int32_t cell = cmd.i32_0;
    const int32_t type_id = cmd.i32_1;
    const int64_t count = cmd.i64_0;
    if (cell < 0 || cell >= _cell_count || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size()) || count <= 0 ||
        _population.page_cell[owner_slot / COHORT_PAGE_SIZE] != cell) {
        _last_building_rejection_reason = "building_target_invalid";
        ++_rejected_commands;
        return true;
    }
    const int32_t owner_signature = static_cast<int32_t>(_population.signature_id[owner_slot]);
    const BuildingType &type = _building_types[type_id];
    if (!building_available(cell, type_id, true)) {
        _last_building_rejection_reason = "building_technology_locked";
        ++_rejected_commands;
        return true;
    }
    if (!allow_obsolete_tier && !building_constructible(cell, type_id, true)) {
        _last_building_rejection_reason = "building_tier_obsolete_for_construction";
        ++_rejected_commands;
        return true;
    }
    if (_signatures[owner_signature].profession_id != type.owner_profession_id) {
        _last_building_rejection_reason = "building_owner_profession_mismatch";
        ++_rejected_commands;
        return true;
    }
    if (!evaluate_building_conditions(type_id, cell)) {
        _last_building_rejection_reason = "building_conditions_failed";
        ++_rejected_commands;
        return true;
    }
    const int32_t market = _market.cell_to_market[cell];
    const int32_t country_slot = cell < static_cast<int32_t>(
            _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
    const int32_t construction_cost_factor = country_slot >= 0 &&
            country_slot < static_cast<int32_t>(
                _epoch_country_construction_cost_factor_q16.size())
        ? _epoch_country_construction_cost_factor_q16[country_slot] : Q16_ONE;
    const int32_t construction_time_factor = country_slot >= 0 &&
            country_slot < static_cast<int32_t>(
                _epoch_country_construction_time_factor_q16.size())
        ? _epoch_country_construction_time_factor_q16[country_slot] : Q16_ONE;
    const int32_t effective_construction_days = type.construction_days <= 0 ? 0 :
        std::max<int32_t>(1, static_cast<int32_t>(mul_div_sat(
            type.construction_days, construction_time_factor,
            Q16_ONE, _saturation_count)));
    ConstructionMaterialPlan material_plan;
    if (!plan_construction_materials(cell, type_id, count,
                                     construction_cost_factor, material_plan)) {
        if (material_plan.failed_group >= 0 &&
            material_plan.failed_group < type.construction_count) {
            const GoodAmount &preferred = _building_construction_goods[
                type.construction_begin + material_plan.failed_group];
            const int32_t signal = ensure_market_signal_index(cell,
                preferred.good_id);
            if (signal >= 0 && signal < static_cast<int32_t>(
                    _epoch_desired_business_demand.size())) {
                _epoch_desired_business_demand[signal] = saturating_add(
                    _epoch_desired_business_demand[signal],
                    preferred.quantity * count, _saturation_count);
            }
            if (signal >= 0 && signal < static_cast<int32_t>(
                    _construction_material_reserve.size())) {
                _construction_material_reserve[signal] = std::max(
                    _construction_material_reserve[signal],
                    preferred.quantity * count);
            }
        }
        _last_building_rejection_reason = "building_construction_stock_insufficient";
        ++_rejected_commands;
        return true;
    }
    const std::vector<int32_t> &planned_good_ids = material_plan.good_ids;
    const std::vector<int64_t> &planned_quantities = material_plan.quantities;
    const int64_t total_cost = material_plan.total_cost;
    int64_t construction_debt_principal = 0;
    int64_t construction_debt_premium = 0;
    const int64_t funding_gap = std::max<int64_t>(
        0, total_cost - std::max<int64_t>(0, _population.funds[owner_slot]));
    if (funding_gap > 0) {
        const bool cached_investment_credit =
            _investment_merchant_cash_by_cell.size() ==
                static_cast<size_t>(_cell_count) &&
            _investment_outstanding_credit_by_cell.size() ==
                static_cast<size_t>(_cell_count) &&
            static_cast<size_t>(cell) <
                _investment_cell_finance_stamp.size() &&
            _investment_cell_finance_stamp[cell] ==
                _investment_scratch_generation;
        int64_t merchant_cash = cached_investment_credit
            ? investment_merchant_cash(cell) : 0;
        if (!cached_investment_credit) {
            for (int32_t k = _merchant_offsets[cell];
                 k < _merchant_offsets[cell + 1]; ++k) {
                merchant_cash = saturating_add(merchant_cash,
                    std::max<int64_t>(
                        0, _population.funds[_merchant_slots[k]]),
                    _saturation_count);
            }
        }
        int64_t outstanding = cached_investment_credit
            ? investment_outstanding_credit(cell) : 0;
        if (!cached_investment_credit) {
            for (const BuildingGroup &group : _buildings) {
                if (group.cell == cell) outstanding = saturating_add(
                    outstanding,
                    std::max<int64_t>(0, group.merchant_debt_principal),
                    _saturation_count);
            }
            for (const PendingConstruction &pending :
                 _pending_construction) {
                if (pending.cell == cell) outstanding = saturating_add(
                    outstanding,
                    std::max<int64_t>(
                        0, pending.merchant_debt_principal),
                    _saturation_count);
            }
        }
        const int64_t exposure = mul_div_sat(
            merchant_cash, _merchant_credit_exposure_q16,
            Q16_ONE, _saturation_count);
        const int64_t reserve = mul_div_sat(
            merchant_cash, _merchant_procurement_cash_reserve_q16,
            Q16_ONE, _saturation_count);
        const int64_t available = std::max<int64_t>(0, std::min(
            exposure - std::min(exposure, outstanding),
            merchant_cash - std::min(merchant_cash, reserve)));
        if (_merchant_credit_runtime_mode != 2 || funding_gap > available ||
            debit_local_merchants(cell, funding_gap, CASHFLOW_MERCHANT_BUSINESS,
                                  &_saturation_count) != funding_gap) {
            _last_building_rejection_reason = "building_owner_funds_insufficient";
            ++_rejected_commands;
            return true;
        }
        touch_accounting_slot(owner_slot);
        _population.funds[owner_slot] = saturating_add(
            _population.funds[owner_slot], funding_gap, _saturation_count);
        trace_record_cashflow(cell, _population.handle_for_slot(owner_slot),
                              CASHFLOW_OTHER, funding_gap, 0);
        construction_debt_principal = funding_gap;
        construction_debt_premium = saturating_add(saturating_mul(
            funding_gap, _merchant_credit_premium_q16, _saturation_count),
            Q16_ONE - 1, _saturation_count) / Q16_ONE;
        if (cached_investment_credit) {
            _investment_outstanding_credit_by_cell[cell] =
                saturating_add(
                    _investment_outstanding_credit_by_cell[cell],
                    funding_gap, _saturation_count);
        }
        _merchant_credit_drawn = saturating_add(
            _merchant_credit_drawn, funding_gap, _saturation_count);
        if (cell >= 0 && cell < static_cast<int32_t>(
                _merchant_credit_drawn_by_cell.size())) {
            _merchant_credit_drawn_by_cell[cell] = saturating_add(
                _merchant_credit_drawn_by_cell[cell], funding_gap,
                _saturation_count);
        }
    }
    std::vector<EventLeg> event_legs;
    const bool trace_detail = trace_detail_for_cell(cell);
    const int64_t owner_handle = static_cast<int64_t>(_population.handle_for_slot(owner_slot));
    const int64_t owner_funds_before = _population.funds[owner_slot];
    const int64_t owner_expense_before = _population.epoch_expense[owner_slot];
    std::vector<int32_t> merchant_trace_slots;
    std::vector<int64_t> merchant_trace_funds;
    std::vector<int64_t> merchant_trace_income;
    if (trace_detail) {
        for (int32_t k = _merchant_offsets[cell]; k < _merchant_offsets[cell + 1]; ++k) {
            const int32_t merchant_slot = _merchant_slots[k];
            merchant_trace_slots.push_back(merchant_slot);
            merchant_trace_funds.push_back(_population.funds[merchant_slot]);
            merchant_trace_income.push_back(_population.epoch_income[merchant_slot]);
        }
        for (size_t i = 0; i < planned_good_ids.size(); ++i) {
            const int32_t good_id = planned_good_ids[i];
            const int64_t idx = _market.index(market, good_id);
            const int64_t qty = planned_quantities[i];
            event_legs.push_back({FIELD_MARKET_STOCK, SUBJECT_MARKET, market, good_id,
                                  _market.stock[idx], _market.stock[idx] - qty});
        }
    }
    touch_accounting_slot(owner_slot);
    for (size_t i = 0; i < planned_good_ids.size(); ++i) {
        const int32_t good_id = planned_good_ids[i];
        const int64_t qty = planned_quantities[i];
        const int64_t stock_index = _market.index(market, good_id);
        audit_touch_market_lane(static_cast<size_t>(stock_index));
        _market.stock[stock_index] -= qty;
        _construction_goods_consumed = saturating_add(_construction_goods_consumed, qty,
                                                       _saturation_count);
        const int32_t signal = ensure_market_signal_index(cell, good_id);
        if (signal >= 0 && signal < static_cast<int32_t>(
                _epoch_nonhousehold_withdrawals.size())) {
            _epoch_nonhousehold_withdrawals[signal] = saturating_add(
                _epoch_nonhousehold_withdrawals[signal], qty, _saturation_count);
        }
    }
    _population.funds[owner_slot] -= total_cost;
    _population.epoch_expense[owner_slot] = saturating_add(
        _population.epoch_expense[owner_slot], total_cost, _saturation_count);
    trace_record_cashflow(cell, _population.handle_for_slot(owner_slot),
                          CASHFLOW_CONSTRUCTION, 0, total_cost);
    if (credit_local_merchants(cell, total_cost, CASHFLOW_MERCHANT_BUSINESS) != total_cost) {
        error = "building_construction_has_no_merchant_owner";
        return false;
    }
    if (_investment_merchant_cash_by_cell.size() ==
            static_cast<size_t>(_cell_count) &&
        static_cast<size_t>(cell) < _investment_cell_finance_stamp.size() &&
        _investment_cell_finance_stamp[cell] ==
            _investment_scratch_generation) {
        _investment_merchant_cash_by_cell[cell] = saturating_add(
            _investment_merchant_cash_by_cell[cell],
            total_cost - funding_gap, _saturation_count);
    }
    _pending_construction.push_back({cell, type_id, owner_signature, count,
        _sample_day + effective_construction_days, cmd.sequence,
        construction_debt_principal, construction_debt_premium,
        static_cast<uint16_t>(construction_debt_principal > 0
            ? _merchant_credit_term_cycles : 0),
        sponsor_family_for_cohort(_population.handle_for_slot(owner_slot),
                                  cell)});
    if (trace_detail && owner_funds_before != _population.funds[owner_slot]) {
        event_legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, owner_handle, -1,
                              owner_funds_before, _population.funds[owner_slot]});
    }
    if (trace_detail && owner_expense_before != _population.epoch_expense[owner_slot]) {
        event_legs.push_back({FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, owner_handle, -1,
                              owner_expense_before, _population.epoch_expense[owner_slot]});
    }
    if (trace_detail) {
        for (size_t i = 0; i < merchant_trace_slots.size(); ++i) {
            const int32_t merchant_slot = merchant_trace_slots[i];
            const int64_t handle = static_cast<int64_t>(
                _population.handle_for_slot(merchant_slot));
            if (merchant_trace_funds[i] != _population.funds[merchant_slot]) {
                event_legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, handle, -1,
                                      merchant_trace_funds[i],
                                      _population.funds[merchant_slot]});
            }
            if (merchant_trace_income[i] != _population.epoch_income[merchant_slot]) {
                event_legs.push_back({FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, handle, -1,
                                      merchant_trace_income[i],
                                      _population.epoch_income[merchant_slot]});
            }
        }
    }
    trace_append(EVENT_CONSTRUCTION_STARTED, static_cast<int32_t>(_stage),
                 cell, SUBJECT_BUILDING_GROUP, owner_signature, type_id, -1,
                 count, total_cost, _sample_day + effective_construction_days, cmd.sequence,
                 event_legs.empty() ? nullptr : &event_legs);
    return true;
}

bool NativeEconomyRuntime::apply_demolish_command(const Command &cmd, int32_t owner_slot,
                                                   std::string &) {
    const int32_t cell = cmd.i32_0;
    const int32_t type_id = cmd.i32_1;
    const int64_t count = cmd.i64_0;
    if (cell < 0 || cell >= _cell_count || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size()) || count <= 0 ||
        _population.page_cell[owner_slot / COHORT_PAGE_SIZE] != cell) {
        _last_building_rejection_reason = "demolish_target_invalid";
        ++_rejected_commands;
        return true;
    }
    const int32_t signature = static_cast<int32_t>(_population.signature_id[owner_slot]);
    const int32_t group_id = find_building_group(cell, type_id, signature);
    if (group_id < 0 || _buildings[group_id].count < count) {
        _last_building_rejection_reason = "demolish_owned_count_insufficient";
        ++_rejected_commands;
        return true;
    }
    const int64_t before = _buildings[group_id].count;
    _buildings[group_id].count -= count;
    _building_handle_index_clean = false;
    std::vector<EventLeg> event_legs;
    if (trace_detail_for_cell(cell)) {
        event_legs.push_back({FIELD_BUILDING_COUNT, SUBJECT_BUILDING_GROUP, signature,
                              type_id, before, _buildings[group_id].count});
    }
    trace_append(EVENT_BUILDING_DEMOLISHED, static_cast<int32_t>(Stage::LEDGER_APPLY),
                 cell, SUBJECT_BUILDING_GROUP, signature, type_id, -1,
                 count, before, _buildings[group_id].count, cmd.sequence,
                 event_legs.empty() ? nullptr : &event_legs);
    _structural_touched_cells.push_back(cell);
    return true;
}

} // namespace pk
