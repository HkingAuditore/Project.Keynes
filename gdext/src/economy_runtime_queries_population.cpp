#include "economy_runtime.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;

Dictionary NativeEconomyRuntime::named_settlement_snapshot() const {
    std::vector<SettlementChange> changes;
    changes.reserve(_settlements.active_names.size());
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (_settlements.name_active[cell] != 0)
            changes.push_back({cell, _settlements.tier[cell], 1});
    }
    return settlement_rows(changes, true);
}

Dictionary NativeEconomyRuntime::settlement_delta(int64_t since_revision) const {
    if (since_revision == _settlements.revision)
        return settlement_rows({}, false);
    if (_settlements.revisions.empty() ||
        since_revision < _settlements.revisions.front().revision - 1)
        return named_settlement_snapshot();
    std::vector<SettlementChange> changes;
    for (const SettlementRevision &revision : _settlements.revisions) {
        if (revision.revision > since_revision)
            changes.insert(changes.end(), revision.changes.begin(),
                           revision.changes.end());
    }
    std::sort(changes.begin(), changes.end(),
        [](const SettlementChange &a, const SettlementChange &b) {
            return a.cell < b.cell;
        });
    std::vector<SettlementChange> compact;
    for (const SettlementChange &change : changes) {
        if (!compact.empty() && compact.back().cell == change.cell)
            compact.back() = change;
        else compact.push_back(change);
    }
    return settlement_rows(compact, false);
}

Dictionary NativeEconomyRuntime::population_cell_summary(int32_t cell_idx) const {
    Dictionary out;
    out["cell_idx"] = cell_idx;
    out["committed"] = !_epoch_active && !_fatal;
    out["busy"] = _epoch_active;
    out["snapshot_source"] = "rolling_committed";
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    const CellSummary summary = build_cell_summary(cell_idx);
    out["ok"] = true;
    out["state_day"] = _cell_last_settlement_day[cell_idx];
    out["age_days"] = std::max<int64_t>(0,
        _current_day - _cell_last_settlement_day[cell_idx]);
    out["settlement_generation"] = static_cast<int64_t>(
        _cell_settlement_generation[cell_idx]);
    out["population"] = summary.population;
    out["funds"] = summary.funds;
    out["epoch_income"] = summary.epoch_income;
    out["epoch_expense"] = summary.epoch_expense;
    out["cohort_count"] = summary.cohort_count;
    out["satisfaction_q16"] = summary.satisfaction_q16;
    out["survival_satisfaction_q16"] = summary.satisfaction_q16;
    out["epoch_id"] = _epoch_id;
    append_settlement_fields(out, cell_idx);
    append_population_employment_fields(out, cell_idx);
    return out;
}

void NativeEconomyRuntime::append_population_employment_fields(
        Dictionary &out, int32_t cell_idx) const {
    int64_t job_capacity = 0;
    int64_t jobs_filled = 0;
    int64_t snapshot_sat = 0;
    if (_building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)) {
        for (int32_t group_index = _building_cell_offsets[cell_idx];
             group_index < _building_cell_offsets[cell_idx + 1];
             ++group_index) {
            const BuildingGroup &group = _buildings[group_index];
            if (group.count <= 0 || group.operating_state == 1 ||
                group.type_id < 0 || group.type_id >= static_cast<int32_t>(
                    _building_types.size())) continue;
            const BuildingType &type = _building_types[group.type_id];
            const int64_t owner_required = planned_owner_demand(
                group, snapshot_sat);
            job_capacity = saturating_add(
                job_capacity, owner_required, snapshot_sat);
            jobs_filled = saturating_add(jobs_filled,
                std::min(std::max<int64_t>(0, group.filled_owner),
                         owner_required), snapshot_sat);
            const int64_t utilization_q16 = std::clamp<int64_t>(
                group.planned_utilization_q16, 0, Q16_ONE);
            for (int32_t role = 0; role < type.employee_count; ++role) {
                const JobRole &job = _building_employee_roles[
                    type.employee_begin + role];
                const int64_t full = saturating_mul(
                    group.count, job.slots_per_building, snapshot_sat);
                int64_t required = mul_div_sat(
                    full, utilization_q16, Q16_ONE, snapshot_sat);
                if (required == 0 && full > 0 && utilization_q16 > 0)
                    required = 1;
                job_capacity = saturating_add(
                    job_capacity, required, snapshot_sat);
                const int32_t fill_index = group.employee_fill_begin + role;
                const int64_t filled = fill_index >= 0 && fill_index <
                        static_cast<int32_t>(_building_employee_filled.size())
                    ? _building_employee_filled[fill_index] : 0;
                jobs_filled = saturating_add(jobs_filled,
                    std::min(std::max<int64_t>(0, filled), required),
                    snapshot_sat);
            }
        }
    }
    out["job_capacity"] = job_capacity;
    out["jobs_filled"] = jobs_filled;
    out["job_openings"] = std::max<int64_t>(0,
        job_capacity - jobs_filled);
    out["investment_last_review_day"] =
        _investment_diagnostic_cell == cell_idx
            ? _investment_diagnostic_day : -1;
    int32_t dominant_reason = INVESTMENT_REJECTION_NONE;
    int32_t failed_material_group = -1;
    std::array<int64_t, INVESTMENT_REJECTION_UNSUPPORTED_KIND + 1> counts{};
    const InvestmentDiagnostic *best_market_candidate = nullptr;
    int64_t best_market_strength = -1;
    int64_t best_market_profit = -1;
    int64_t best_market_capital = std::numeric_limits<int64_t>::max();
    out["investment_last_driver_good_id"] = -1;
    out["investment_last_driver_pressure_q16"] = 0;
    out["investment_last_driver_utilization_q16"] = 0;
    out["investment_last_required_capital"] = 0;
    out["investment_last_projected_profit_per_day"] = 0;
    if (_investment_diagnostic_cell == cell_idx) {
        for (const InvestmentDiagnostic &item : _investment_diagnostics) {
            if (item.rejection_reason > INVESTMENT_REJECTION_NONE &&
                item.rejection_reason <= INVESTMENT_REJECTION_UNSUPPORTED_KIND) {
                ++counts[static_cast<size_t>(item.rejection_reason)];
            }
            if (item.rejection_reason == INVESTMENT_REJECTION_MATERIALS &&
                failed_material_group < 0) {
                failed_material_group = item.failed_material_group;
            }
            const int64_t market_strength = std::max(
                item.driver_pressure_q16, item.driver_utilization_q16);
            // A type with no positive shortage/utilization is not a useful
            // explanation for an employment stall. Ignore those zero-signal
            // rows even when they are numerous, then rank the strongest real
            // market opportunity and expose its actual rejection reason.
            if (item.driver_good_id < 0 || market_strength <= 0) continue;
            if (best_market_candidate == nullptr ||
                market_strength > best_market_strength ||
                (market_strength == best_market_strength &&
                 item.projected_profit_per_day > best_market_profit) ||
                (market_strength == best_market_strength &&
                 item.projected_profit_per_day == best_market_profit &&
                 item.required_capital < best_market_capital) ||
                (market_strength == best_market_strength &&
                 item.projected_profit_per_day == best_market_profit &&
                 item.required_capital == best_market_capital &&
                 item.type_id < best_market_candidate->type_id)) {
                best_market_candidate = &item;
                best_market_strength = market_strength;
                best_market_profit = item.projected_profit_per_day;
                best_market_capital = item.required_capital;
            }
        }
        if (best_market_candidate != nullptr) {
            dominant_reason = best_market_candidate->rejection_reason;
            failed_material_group = best_market_candidate->rejection_reason ==
                INVESTMENT_REJECTION_MATERIALS
                ? best_market_candidate->failed_material_group : -1;
            out["investment_last_driver_good_id"] =
                best_market_candidate->driver_good_id;
            out["investment_last_driver_pressure_q16"] =
                best_market_candidate->driver_pressure_q16;
            out["investment_last_driver_utilization_q16"] =
                best_market_candidate->driver_utilization_q16;
            out["investment_last_required_capital"] =
                best_market_candidate->required_capital;
            out["investment_last_projected_profit_per_day"] =
                best_market_candidate->projected_profit_per_day;
        } else {
            for (int32_t reason = INVESTMENT_REJECTION_NONE + 1;
                 reason <= INVESTMENT_REJECTION_UNSUPPORTED_KIND; ++reason) {
                if (counts[static_cast<size_t>(reason)] >
                    counts[static_cast<size_t>(dominant_reason)]) {
                    dominant_reason = reason;
                }
            }
        }
    }
    out["investment_last_block_reason"] = dominant_reason;
    out["investment_last_failed_material_group"] = failed_material_group;
}

Dictionary NativeEconomyRuntime::population_cell_snapshot(int32_t cell_idx) const {
    return population_cell_snapshot_impl(cell_idx, environment_sample_for_cell(cell_idx));
}

Dictionary NativeEconomyRuntime::population_cell_snapshot(
        int32_t cell_idx, float temperature, float moisture, float snow_cover,
        float weather_intensity, bool environment_ready) const {
    EnvironmentSample sample = environment_sample_from_float(
        temperature, moisture, snow_cover, weather_intensity, environment_ready);
    if (!environment_ready) {
        const EnvironmentSample frozen = environment_sample_for_cell(cell_idx);
        if (frozen.ready) sample = frozen;
    }
    return population_cell_snapshot_impl(cell_idx, sample);
}

Dictionary NativeEconomyRuntime::population_cell_snapshot_impl(
        int32_t cell_idx, const EnvironmentSample &sample) const {
    Dictionary out;
    out["cell_idx"] = cell_idx;
    out["committed"] = !_epoch_active && !_fatal;
    out["busy"] = _epoch_active;
    out["snapshot_source"] = "rolling_committed";
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    // Selected-cell queries run synchronously between native slices. Build the
    // bounded cell summary from the current SoA so UI never needs a global
    // cohort snapshot or waits for the next commit boundary.
    const CellSummary summary = build_cell_summary(cell_idx);
    out["ok"] = true;
    out["state_day"] = _cell_last_settlement_day[cell_idx];
    out["age_days"] = std::max<int64_t>(0,
        _current_day - _cell_last_settlement_day[cell_idx]);
    out["settlement_generation"] = static_cast<int64_t>(
        _cell_settlement_generation[cell_idx]);
    out["population"] = summary.population;
    out["funds"] = summary.funds;
    out["epoch_income"] = summary.epoch_income;
    out["epoch_expense"] = summary.epoch_expense;
    out["cohort_count"] = summary.cohort_count;
    out["satisfaction_q16"] = summary.satisfaction_q16;
    out["survival_satisfaction_q16"] = summary.satisfaction_q16;
    out["epoch_id"] = _epoch_id;
    append_settlement_fields(out, cell_idx);
    append_population_employment_fields(out, cell_idx);
    PackedInt64Array handles;
    PackedInt32Array signatures;
    PackedInt32Array professions;
    PackedInt32Array ethnicities;
    PackedInt64Array populations;
    PackedInt64Array funds;
    PackedInt64Array incomes;
    PackedInt64Array expenses;
    PackedInt64Array in_kind_income;
    PackedInt64Array cash_expense_coverage_q16;
    PackedInt64Array livelihood_coverage_q16;
    PackedInt64Array income_ema;
    PackedInt32Array satisfaction;
    PackedInt32Array worst_need_ids;
    PackedByteArray merchant_flags;
    PackedInt64Array owner_employed;
    PackedInt64Array employee_employed;
    PackedInt64Array unemployed;
    std::vector<int32_t> slots;
    _population.for_each_in_cell(cell_idx, [&](int32_t slot) { slots.push_back(slot); });
    for (int32_t slot : slots) {
        handles.push_back(static_cast<int64_t>(_population.handle_for_slot(slot)));
        const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
        signatures.push_back(signature);
        professions.push_back(_signatures[signature].profession_id);
        ethnicities.push_back(_signatures[signature].ethnicity_id);
        populations.push_back(_population.population[slot]);
        funds.push_back(_population.funds[slot]);
        incomes.push_back(_population.epoch_income[slot]);
        expenses.push_back(_population.epoch_expense[slot]);
        const int64_t in_kind = _population.epoch_in_kind_income[slot];
        in_kind_income.push_back(in_kind);
        int64_t diagnostic_sat = 0;
        cash_expense_coverage_q16.push_back(_population.epoch_expense[slot] > 0
            ? mul_div_sat(_population.epoch_income[slot], Q16_ONE,
                          _population.epoch_expense[slot], diagnostic_sat) : Q16_ONE);
        const int64_t livelihood_income = saturating_add(
            _population.epoch_income[slot], in_kind, diagnostic_sat);
        const int64_t livelihood_expense = saturating_add(
            _population.epoch_expense[slot], in_kind, diagnostic_sat);
        livelihood_coverage_q16.push_back(livelihood_expense > 0
            ? mul_div_sat(livelihood_income, Q16_ONE,
                          livelihood_expense, diagnostic_sat) : Q16_ONE);
        income_ema.push_back(_population.income_ema[slot]);
        satisfaction.push_back(_population.needs_satisfaction[slot]);
        worst_need_ids.push_back(_population.worst_need_id[slot] == std::numeric_limits<uint16_t>::max()
                                     ? -1 : _population.worst_need_id[slot]);
        merchant_flags.push_back(is_merchant_slot(slot) ? 1 : 0);
        owner_employed.push_back(_population.owner_employed[slot]);
        employee_employed.push_back(_population.employee_employed[slot]);
        unemployed.push_back(std::max<int64_t>(0, _population.population[slot] -
            _population.owner_employed[slot] - _population.employee_employed[slot]));
    }
    out["handles"] = handles;
    out["signature_ids"] = signatures;
    out["profession_ids"] = professions;
    out["ethnicity_ids"] = ethnicities;
    out["populations"] = populations;
    out["funds_by_cohort"] = funds;
    out["epoch_income_by_cohort"] = incomes;
    out["epoch_expense_by_cohort"] = expenses;
    out["epoch_in_kind_income_by_cohort"] = in_kind_income;
    out["cash_expense_coverage_by_cohort_q16"] = cash_expense_coverage_q16;
    out["livelihood_coverage_by_cohort_q16"] = livelihood_coverage_q16;
    out["income_ema_by_cohort"] = income_ema;
    out["satisfaction_by_cohort_q16"] = satisfaction;
    out["survival_satisfaction_by_cohort_q16"] = satisfaction;
    out["worst_need_ids"] = worst_need_ids;
    out["merchant_flags"] = merchant_flags;
    out["owner_employed_by_cohort"] = owner_employed;
    out["employee_employed_by_cohort"] = employee_employed;
    out["unemployed_by_cohort"] = unemployed;
    const EventBatch *settlement_batch = nullptr;
    for (auto it = _committed_event_batches.rbegin();
         it != _committed_event_batches.rend(); ++it) {
        if (it->cashflow_complete && it->cashflow_cell == cell_idx) {
            settlement_batch = &(*it);
            break;
        }
    }
    PackedStringArray cashflow_source_ids;
    cashflow_source_ids.push_back("wages");
    cashflow_source_ids.push_back("owner_operations");
    cashflow_source_ids.push_back("merchant_household_sales");
    cashflow_source_ids.push_back("merchant_business_sales");
    cashflow_source_ids.push_back("transfer");
    cashflow_source_ids.push_back("household_consumption");
    cashflow_source_ids.push_back("production_inputs");
    cashflow_source_ids.push_back("owner_wages");
    cashflow_source_ids.push_back("construction");
    cashflow_source_ids.push_back("merchant_procurement");
    cashflow_source_ids.push_back("other");
    cashflow_source_ids.push_back("producer_support_issuance");
    // Indices stay enum-1: tax/subsidy legs recorded via trace_record_cashflow
    // (CASHFLOW_INCOME_TAX..CASHFLOW_FISCAL_ESCROW) resolve to these ids.
    cashflow_source_ids.push_back("income_tax");
    cashflow_source_ids.push_back("consumption_tax");
    cashflow_source_ids.push_back("business_tax");
    cashflow_source_ids.push_back("income_subsidy");
    cashflow_source_ids.push_back("consumption_subsidy");
    cashflow_source_ids.push_back("business_subsidy");
    cashflow_source_ids.push_back("fiscal_escrow");
    out["settlement_cashflow_source_stable_ids"] = cashflow_source_ids;
    out["settlement_detail_available"] = settlement_batch != nullptr;
    out["settlement_detail_pending"] = settlement_batch == nullptr &&
        (_trace_mode == TRACE_SELECTIVE || _trace_mode == TRACE_FULL_DEBUG) &&
        (_inspector_trace_cell == cell_idx ||
         (_inspector_trace_pending && _pending_inspector_trace_cell == cell_idx));
    PackedInt32Array settlement_offsets;
    PackedInt32Array settlement_source_indices;
    PackedInt64Array settlement_income;
    PackedInt64Array settlement_expense;
    PackedInt64Array settlement_income_by_cohort;
    PackedInt64Array settlement_expense_by_cohort;
    int64_t settlement_saturation = 0;
    settlement_offsets.push_back(0);
    for (int32_t slot : slots) {
        const uint64_t handle = _population.handle_for_slot(slot);
        int64_t total_income = 0;
        int64_t total_expense = 0;
        if (settlement_batch != nullptr) {
            for (const CashflowEntry &entry : settlement_batch->cashflows) {
                if (entry.cohort_handle != handle ||
                    (entry.income == 0 && entry.expense == 0)) continue;
                settlement_source_indices.push_back(entry.source - 1);
                settlement_income.push_back(entry.income);
                settlement_expense.push_back(entry.expense);
                total_income = saturating_add(total_income, entry.income,
                                              settlement_saturation);
                total_expense = saturating_add(total_expense, entry.expense,
                                               settlement_saturation);
            }
        }
        settlement_income_by_cohort.push_back(total_income);
        settlement_expense_by_cohort.push_back(total_expense);
        settlement_offsets.push_back(settlement_source_indices.size());
    }
    out["settlement_cashflow_offsets"] = settlement_offsets;
    out["settlement_cashflow_source_indices"] = settlement_source_indices;
    out["settlement_cashflow_income"] = settlement_income;
    out["settlement_cashflow_expense"] = settlement_expense;
    out["settlement_income_by_cohort"] = settlement_income_by_cohort;
    out["settlement_expense_by_cohort"] = settlement_expense_by_cohort;
    if (settlement_batch != nullptr) {
        out["settlement_epoch_id"] = settlement_batch->epoch_id;
        out["settlement_sample_day"] = settlement_batch->sample_day;
        out["settlement_commit_day"] = settlement_batch->commit_day;
        out["settlement_period_days"] = settlement_batch->period_days;
        out["settlement_snapshot_source"] = "committed_trace";
    }
    PackedInt32Array overall_satisfaction;
    PackedInt32Array living_standard_levels;
    PackedInt32Array satisfaction_dims;
    PackedInt32Array worst_dimensions;
    PackedInt32Array worst_needs;
    PackedInt32Array welfare_need_offsets;
    PackedInt32Array welfare_need_ids;
    PackedInt32Array welfare_need_satisfaction;
    PackedInt32Array welfare_need_weights;
    PackedInt32Array welfare_need_tiers;
    PackedInt64Array wealth_demand_deltas;
    PackedInt64Array price_demand_deltas;
    welfare_need_offsets.push_back(0);
    bool welfare_complete = settlement_batch != nullptr &&
        settlement_batch->welfare_entries.size() == slots.size();
    for (int32_t slot : slots) {
        const uint64_t handle = _population.handle_for_slot(slot);
        const CohortWelfareEntry *welfare = nullptr;
        if (settlement_batch != nullptr) {
            for (const CohortWelfareEntry &candidate : settlement_batch->welfare_entries) {
                if (candidate.cohort_handle == handle) {
                    welfare = &candidate;
                    break;
                }
            }
        }
        if (welfare == nullptr) welfare_complete = false;
        // The composite and its dimensions are authoritative columns now, so
        // they are always available; only the per-need breakdown still needs a
        // traced settlement batch.
        const int64_t composite_q16 = _population.composite_satisfaction[slot];
        overall_satisfaction.push_back(static_cast<int32_t>(composite_q16));
        living_standard_levels.push_back(living_standard_level_for(composite_q16));
        const size_t dims_base = static_cast<size_t>(slot) *
            static_cast<size_t>(SAT_DIM_COUNT);
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
            satisfaction_dims.push_back(static_cast<int32_t>(
                _population.satisfaction_dims[dims_base + static_cast<size_t>(dim)]));
        worst_dimensions.push_back(
            _population.worst_dimension_id[slot] ==
                    std::numeric_limits<uint8_t>::max()
                ? -1 : static_cast<int32_t>(_population.worst_dimension_id[slot]));
        worst_needs.push_back(
            _population.worst_need_id[slot] == std::numeric_limits<uint16_t>::max()
                ? -1 : static_cast<int32_t>(_population.worst_need_id[slot]));
        if (welfare != nullptr) {
            for (int32_t i = 0; i < static_cast<int32_t>(welfare->need_ids.size()); ++i) {
                welfare_need_ids.push_back(welfare->need_ids[i]);
                welfare_need_satisfaction.push_back(welfare->need_satisfaction_q16[i]);
                welfare_need_weights.push_back(
                    i < static_cast<int32_t>(welfare->need_weight_q16.size())
                        ? welfare->need_weight_q16[i] : 0);
                welfare_need_tiers.push_back(
                    i < static_cast<int32_t>(welfare->need_tiers.size())
                        ? welfare->need_tiers[i] : -1);
            }
        }
        welfare_need_offsets.push_back(welfare_need_ids.size());
        for (int32_t good = 0; good < _market.good_count; ++good) {
            wealth_demand_deltas.push_back(welfare != nullptr &&
                    good < static_cast<int32_t>(welfare->wealth_demand_delta_per_capita_daily.size())
                ? welfare->wealth_demand_delta_per_capita_daily[good] : 0);
            price_demand_deltas.push_back(welfare != nullptr &&
                    good < static_cast<int32_t>(welfare->price_demand_delta_per_capita_daily.size())
                ? welfare->price_demand_delta_per_capita_daily[good] : 0);
        }
    }
    out["welfare_detail_available"] = welfare_complete;
    out["overall_satisfaction_by_cohort_q16"] = overall_satisfaction;
    out["living_standard_level_by_cohort"] = living_standard_levels;
    out["satisfaction_dimension_count"] = SAT_DIM_COUNT;
    out["satisfaction_dims_by_cohort_q16"] = satisfaction_dims;
    out["worst_satisfaction_dimension_by_cohort"] = worst_dimensions;
    out["worst_need_by_cohort"] = worst_needs;
    out["welfare_need_offsets"] = welfare_need_offsets;
    out["welfare_need_ids"] = welfare_need_ids;
    out["welfare_need_satisfaction_q16"] = welfare_need_satisfaction;
    out["welfare_need_weight_q16"] = welfare_need_weights;
    out["welfare_need_tiers"] = welfare_need_tiers;
    out["demand_attribution_good_count"] = _market.good_count;
    out["demand_wealth_delta_per_capita_daily"] = wealth_demand_deltas;
    out["demand_price_delta_per_capita_daily"] = price_demand_deltas;
    PackedStringArray profession_stable_ids;
    for (const std::string &id : _profession_ids) profession_stable_ids.push_back(String(id.c_str()));
    PackedStringArray ethnicity_stable_ids;
    for (const std::string &id : _ethnicity_ids) ethnicity_stable_ids.push_back(String(id.c_str()));
    out["profession_stable_ids"] = profession_stable_ids;
    out["ethnicity_stable_ids"] = ethnicity_stable_ids;
    PackedStringArray demand_good_stable_ids;
    for (const std::string &id : _good_ids) {
        demand_good_stable_ids.push_back(String(id.c_str()));
    }
    PackedInt32Array demand_good_offsets;
    PackedInt32Array demand_good_indices;
    PackedInt64Array demand_per_capita_daily;
    PackedStringArray demand_need_stable_ids;
    for (const std::string &id : _need_ids) {
        demand_need_stable_ids.push_back(String(id.c_str()));
    }
    PackedInt32Array demand_need_offsets;
    PackedInt32Array demand_need_indices;
    PackedInt32Array demand_need_variant_offsets;
    PackedInt32Array demand_variant_component_offsets;
    PackedInt32Array demand_component_good_indices;
    PackedInt64Array demand_component_per_capita_daily;
    demand_good_offsets.push_back(0);
    demand_need_offsets.push_back(0);
    demand_need_variant_offsets.push_back(0);
    demand_variant_component_offsets.push_back(0);
    const int32_t market = _market.cell_to_market[cell_idx];
    std::vector<int64_t> variant_scores;
    std::vector<int64_t> variant_prices;
    std::vector<int64_t> need_score_sums;
    std::vector<int64_t> need_composites;
    std::vector<int64_t> need_environment;
    std::vector<int64_t> good_quantities(_market.good_count, 0);
    int64_t preview_saturation_count = 0;
    build_demand_basis(market, sample, variant_scores, variant_prices,
                       need_score_sums, need_composites, need_environment,
                       preview_saturation_count);
    for (int32_t slot : slots) {
        std::fill(good_quantities.begin(), good_quantities.end(), int64_t{0});
        const int64_t population = std::max<int64_t>(1, _population.population[slot]);
        const uint32_t signature_id = _population.signature_id[slot];
        if (signature_id < _signatures.size()) {
            const Signature &signature = _signatures[signature_id];
            const Plan &plan = _plans[signature.plan_id];
            for (int32_t n = 0; n < plan.need_count; ++n) {
                const int32_t need_index = plan.need_begin + n;
                const Need &need = _needs[need_index];
                const int64_t score_sum = need_score_sums[need_index];
                if (score_sum <= 0) continue;
                const int64_t desired = desired_need_units(
                    slot, need_index, 1, need_environment[need_index],
                    need_composites[need_index], preview_saturation_count);
                if (desired <= 0) continue;
                demand_need_indices.push_back(need.stable_id);
                int64_t prefix_score = 0;
                int64_t allocated = 0;
                for (int32_t v = 0; v < need.variant_count; ++v) {
                    const int32_t variant_id = need.variant_begin + v;
                    prefix_score = saturating_add(prefix_score, variant_scores[variant_id],
                                                  preview_saturation_count);
                    const int64_t next = mul_div_sat(desired, prefix_score, score_sum,
                                                     preview_saturation_count);
                    const int64_t units = std::max<int64_t>(0, next - allocated);
                    allocated = next;
                    const VariantChoice &variant = _variants[variant_id];
                    for (int32_t c = 0; c < variant.component_count; ++c) {
                        const NeedComponent &component =
                            _components[variant.component_begin + c];
                        const int64_t quantity = units > 0
                            ? mul_div_sat(units, component.qty_per_need, GOODS_SCALE,
                                          preview_saturation_count)
                            : 0;
                        good_quantities[component.good_id] = saturating_add(
                            good_quantities[component.good_id], quantity,
                            preview_saturation_count);
                        demand_component_good_indices.push_back(component.good_id);
                        demand_component_per_capita_daily.push_back(quantity / population);
                    }
                    demand_variant_component_offsets.push_back(
                        demand_component_good_indices.size());
                }
                demand_need_variant_offsets.push_back(
                    demand_variant_component_offsets.size() - 1);
            }
        }
        demand_need_offsets.push_back(demand_need_indices.size());
        for (int32_t good = 0; good < _market.good_count; ++good) {
            const int64_t per_capita = good_quantities[good] / population;
            if (per_capita <= 0) continue;
            demand_good_indices.push_back(good);
            demand_per_capita_daily.push_back(per_capita);
        }
        demand_good_offsets.push_back(demand_good_indices.size());
    }
    out["demand_good_offsets"] = demand_good_offsets;
    out["demand_good_indices"] = demand_good_indices;
    out["demand_per_capita_daily"] = demand_per_capita_daily;
    out["demand_good_stable_ids"] = demand_good_stable_ids;
    out["demand_need_stable_ids"] = demand_need_stable_ids;
    out["demand_need_offsets"] = demand_need_offsets;
    out["demand_need_indices"] = demand_need_indices;
    out["demand_need_variant_offsets"] = demand_need_variant_offsets;
    out["demand_variant_component_offsets"] = demand_variant_component_offsets;
    out["demand_component_good_indices"] = demand_component_good_indices;
    out["demand_component_per_capita_daily"] = demand_component_per_capita_daily;
    out["demand_preview_basis"] = _epoch_active
        ? "live_slice_economy_current_environment_daily"
        : "committed_economy_current_environment_daily";
    out["demand_preview_environment_ready"] = sample.ready;
    out["demand_preview_saturation_count"] = preview_saturation_count;
    return out;
}


} // namespace pk
