#include "economy_record_source.h"
#include "economy_runtime.h"
#include <algorithm>
#include <cmath>
#include <limits>

namespace pk {
using SummaryRow = EconomyCsvRecorder::SummaryRow;
using CohortRow = EconomyCsvRecorder::CohortRow;
using BuildingRow = EconomyCsvRecorder::BuildingRow;
using ResourceRow = EconomyCsvRecorder::ResourceRow;
using MarketRow = EconomyCsvRecorder::MarketRow;
using CommonCell = EconomyCsvRecorder::CommonCell;
constexpr auto DIM_COUNT = EconomyCsvRecorder::DIM_COUNT;
constexpr auto SUMMARY = EconomyCsvRecorder::SUMMARY;
constexpr auto COHORTS = EconomyCsvRecorder::COHORTS;
constexpr auto BUILDINGS = EconomyCsvRecorder::BUILDINGS;
constexpr auto RESOURCES = EconomyCsvRecorder::RESOURCES;
constexpr auto MARKET = EconomyCsvRecorder::MARKET;

bool EconomyRecordSource::configure(const Config &config, const NativeEconomyRuntime &runtime,
        std::array<Batch, 2> &_buffers, std::string &error) {
    if (!runtime._configured || !runtime._bootstrapped || runtime._fatal) {
        error = "economy_not_ready";
        return false;
    }
    if (config.q.size() != static_cast<size_t>(runtime._cell_count.get()) ||
        config.r.size() != config.q.size() || config.s.size() != config.q.size()) {
        error = "coordinate_size_mismatch";
        return false;
    }
    bool any = false;
    for (int32_t i = 0; i < DIM_COUNT; ++i) {
        if (!config.enabled[i]) continue;
        any = true;
        if (config.paths[i].empty()) {
            error = "enabled_path_missing";
            return false;
        }
    }
    if (!any) {
        error = "no_dimensions_enabled";
        return false;
    }
    if (config.resource_slot_ids.size() != config.resource_ids.size()) {
        error = "resource_config_size_mismatch";
        return false;
    }

    _config = config;
    _config.cell_stride = std::max(1, _config.cell_stride);
    _config.max_rows = std::max<int64_t>(1, _config.max_rows);
    if (!_config.cell_indices.empty()) {
        std::sort(_config.cell_indices.begin(), _config.cell_indices.end());
        _config.cell_indices.erase(
            std::unique(_config.cell_indices.begin(), _config.cell_indices.end()),
            _config.cell_indices.end());
        for (const int32_t cell : _config.cell_indices) {
            if (cell < 0 || cell >= runtime._cell_count.get()) {
                error = "cell_index_out_of_range";
                return false;
            }
        }
        _sample_cells = _config.cell_indices;
    } else {
        _sample_cells.clear();
        _sample_cells.reserve(static_cast<size_t>(
            (runtime._cell_count.get() + _config.cell_stride - 1) / _config.cell_stride));
        for (int32_t cell = 0; cell < runtime._cell_count.get(); cell += _config.cell_stride)
            _sample_cells.push_back(cell);
    }
    _sample_cell_positions.assign(static_cast<size_t>(runtime._cell_count.get()), -1);
    for (int32_t i = 0; i < static_cast<int32_t>(_sample_cells.size()); ++i)
        _sample_cell_positions[_sample_cells[i]] = i;
    _resource_runtime_indices.assign(_config.resource_ids.size(), -1);
    for (size_t resource = 0; resource < _config.resource_ids.size(); ++resource) {
        const auto it = std::lower_bound(runtime._resource_ids.begin(),
                                         runtime._resource_ids.end(),
                                         _config.resource_ids[resource]);
        if (it == runtime._resource_ids.end() || *it != _config.resource_ids[resource]) {
            error = "resource_id_not_in_runtime";
            return false;
        }
        _resource_runtime_indices[resource] = static_cast<int32_t>(
            std::distance(runtime._resource_ids.begin(), it));
    }
    const size_t resource_history_size = static_cast<size_t>(runtime._cell_count.get()) *
        _config.resource_ids.size();
    _previous_resource_reserve.assign(resource_history_size, 0.0f);
    _pending_resource_artificial.assign(resource_history_size, 0);
    _resource_history_valid.assign(resource_history_size, uint8_t{0});
    _good_ids = runtime._good_ids;
    _good_category_ids = runtime._good_category_ids;
    _good_storage_modes = runtime._good_storage_modes;
    const size_t sampled_cells = _sample_cells.size();
    size_t sampled_cohorts = 0;
    size_t sampled_buildings = 0;
    for (const int32_t cell : _sample_cells) {
        if (_config.enabled[COHORTS])
            runtime.population_store().for_each_in_cell(cell, [&](int32_t) { ++sampled_cohorts; });
        if (_config.enabled[BUILDINGS]) {
            if (runtime._building_cell_offsets.size() ==
                static_cast<size_t>(runtime._cell_count.get() + 1)) {
                sampled_buildings += static_cast<size_t>(
                    runtime._building_cell_offsets[cell + 1] -
                    runtime._building_cell_offsets[cell]);
            }
            for (const auto pending : runtime.pending_construction())
                if (pending.cell == cell) ++sampled_buildings;
        }
    }
    for (Batch &batch : _buffers) {
        batch.clear_rows();
        batch.summary.reserve(_config.enabled[SUMMARY] ? 1 : 0);
        batch.cohorts.reserve(_config.enabled[COHORTS] ? sampled_cohorts : 0);
        batch.buildings.reserve(_config.enabled[BUILDINGS] ? sampled_buildings : 0);
        batch.resources.reserve(_config.enabled[RESOURCES]
            ? sampled_cells * _config.resource_ids.size() : 0);
        batch.market.reserve(_config.enabled[MARKET]
            ? sampled_cells * static_cast<size_t>(runtime.market_store().good_count.get()) : 0);
        const size_t trade_cells = _config.enabled[MARKET]
            ? sampled_cells * runtime.market_store().good_count.get() : 0;
        batch.scratch_trade_inbound.reserve(trade_cells);
        batch.scratch_trade_outbound.reserve(trade_cells);
    }
    return true;
}

int64_t EconomyRecordSource::committed_epoch(const NativeEconomyRuntime &runtime) {
    return runtime._bootstrapped && !runtime._epoch_active && !runtime._fatal && runtime._commit_day >= 0
        ? runtime._epoch_id.get() : -1;
}
int64_t EconomyRecordSource::projected_rows(const NativeEconomyRuntime &runtime) const {
    int64_t rows = _config.enabled[SUMMARY] ? 1 : 0;
    for (const int32_t cell : _sample_cells) {
        if (_config.enabled[COHORTS]) {
            runtime.population_store().for_each_in_cell(cell, [&](int32_t) { ++rows; });
        }
        if (_config.enabled[BUILDINGS]) {
            if (runtime._building_cell_offsets.size() == static_cast<size_t>(runtime._cell_count.get() + 1)) {
                for (int32_t i = runtime._building_cell_offsets[cell];
                     i < runtime._building_cell_offsets[cell + 1]; ++i) {
                    if (runtime.buildings_store().group_units[i] > 0) ++rows;
                }
            }
            for (const auto pending : runtime.pending_construction())
                if (pending.cell == cell) ++rows;
            if (runtime._investment_diagnostic_cell == cell) {
                rows += static_cast<int64_t>(
                    runtime._investment_diagnostics.size());
            }
            if (runtime._employment_diagnostic_cell == cell) {
                rows += static_cast<int64_t>(
                    runtime._employment_diagnostics.size());
            }
        }
        if (_config.enabled[MARKET]) rows += runtime.market_store().good_count.get();
    }
    if (_config.enabled[RESOURCES]) {
        rows += static_cast<int64_t>(_sample_cells.size()) *
                static_cast<int64_t>(_config.resource_ids.size());
    }
    return rows;
}

void EconomyRecordSource::worker_resources(const NativeEconomyRuntime &runtime,
        std::vector<std::vector<float>> &lanes) const {
    // Worker must read its authoritative resource ledger, never Godot slots.
    lanes.resize(_resource_runtime_indices.size());

    const auto &stock = runtime.resource_stock_lanes();
    for (size_t r = 0; r < lanes.size(); ++r) {
        const int32_t source = _resource_runtime_indices[r];
        if (source < 0 || (static_cast<size_t>(source) + 1) * runtime._cell_count.get() > stock.size()) continue;
        lanes[r].resize(runtime._cell_count.get());
        for (int32_t c = 0; c < runtime._cell_count.get(); ++c)
            lanes[r][c] = static_cast<float>(stock[static_cast<size_t>(source) * runtime._cell_count.get() + c]) /
                static_cast<float>(NativeEconomyRuntime::GOODS_SCALE);
    }
}
bool EconomyRecordSource::fill_batch(
        Batch &batch, NativeEconomyRuntime &runtime,
        const std::vector<const float *> &resource_arrays,
        int64_t epoch_row_id, int64_t expected_rows, std::string &error) {
    if (_config.enabled[RESOURCES] && resource_arrays.size() != _config.resource_ids.size()) {
        error = "resource_array_count_mismatch";
        return false;
    }
    batch.epoch_id = runtime._epoch_id.get();
    const int64_t day = runtime._commit_day;

    if (_config.enabled[SUMMARY]) {
        SummaryRow row;
        row.epoch_row_id = epoch_row_id; row.epoch_id = runtime._epoch_id.get(); row.day_index = day;
        row.epoch_active = runtime._epoch_active; row.stage = static_cast<int32_t>(runtime._stage);
        row.progress_q16 = runtime.stage_progress_q16(); row.sample_day = runtime._sample_day;
        row.commit_day = runtime._commit_day; row.cohort_count = runtime.population_store().active_count;
        row.market_count = runtime.market_store().market_count.get(); row.good_count = runtime.market_store().good_count.get();
        row.building_type_count = runtime._building_types.size();
        row.building_group_count = runtime.building_count();
        row.pending_construction_count = runtime.pending_construction_count();
        row.filled_owner_jobs = runtime._filled_owner_jobs;
        row.filled_employee_jobs = runtime._filled_employee_jobs;
        row.unemployed_population = runtime._unemployed_population;
        row.births = runtime._births;
        row.deaths = runtime._deaths;
        row.production_inputs_consumed = runtime._production_inputs_consumed;
        row.production_output_stock = runtime._production_output_stock;
        row.production_output_discarded = runtime._production_output_discarded;
        row.production_output_retained = runtime._production_output_retained;
        row.production_output_supported = runtime._production_output_supported;
        row.owner_output_consumed = runtime._owner_output_consumed;
        row.producer_revenue = runtime._producer_revenue;
        row.producer_support_money_issued = runtime._producer_support_money_issued;
        row.bullion_money_issued = runtime._bullion_money_issued;
        row.bullion_stock_consumed = runtime._bullion_stock_consumed;
        row.gold_accepted = runtime._gold_accepted;
        row.silver_accepted = runtime._silver_accepted;
        row.gold_money_issued = runtime._gold_money_issued;
        row.silver_money_issued = runtime._silver_money_issued;
        row.bullion_quota_initial = runtime._epoch_bullion_quota_initial_total;
        row.bullion_quota_remaining = runtime._epoch_bullion_quota_remaining_total;
        row.bullion_quota_remainder_units =
            runtime._epoch_bullion_quota_remainder_units;
        row.cycle_flow_produced = runtime._cycle_flow_produced;
        row.cycle_flow_consumed = runtime._cycle_flow_consumed;
        row.cycle_flow_discarded = runtime._cycle_flow_discarded;
        row.building_wages_paid = runtime._building_wages_paid;
        row.building_wages_unpaid = runtime._building_wages_unpaid;
        row.building_resource_generated = runtime._building_resource_generated;
        row.building_resource_consumed = runtime._building_resource_consumed;
        row.building_resource_net_delta = runtime._building_resource_generated -
                                          runtime._building_resource_consumed;
        row.loss_suspended_building_groups = runtime._loss_suspended_building_groups;
        row.climate_profiled_building_groups =
            runtime._climate_profiled_building_groups;
        row.climate_limited_building_groups =
            runtime._climate_limited_building_groups;
        row.average_climate_capacity_q16 =
            runtime._climate_profiled_building_groups > 0
            ? runtime._climate_capacity_sum_q16 /
                runtime._climate_profiled_building_groups
            : NativeEconomyRuntime::Q16_ONE;
        row.merchant_procurement_budget = runtime._merchant_procurement_budget;
        row.merchant_procurement_opportunity = runtime._merchant_procurement_opportunity;
        row.merchant_procurement_allocated = runtime._merchant_procurement_allocated;
        row.merchant_procurement_unspent_allocated = runtime._merchant_procurement_unspent_allocated;
        row.merchant_procurement_reserved = runtime._merchant_procurement_reserved;
        row.merchant_procurement_spent = runtime._merchant_procurement_spent;
        row.owner_working_capital_reserved = runtime._owner_working_capital_reserved;
        row.production_input_reserved = runtime._production_input_reserved;
        row.production_input_reserve_shortfall =
            runtime._production_input_reserve_shortfall;
        row.construction_material_reserved = runtime._construction_material_reserved;
        row.maintenance_goods_consumed = runtime._maintenance_goods_consumed;
        row.maintenance_unmet = runtime._maintenance_unmet;
        row.construction_goods_consumed = runtime._construction_goods_consumed;
        row.building_investment_candidates = runtime._building_investment_candidates;
        row.building_owner_mobility = runtime._building_owner_mobility;
        row.building_owner_job_reallocations =
            runtime._building_owner_job_reallocations;
        row.building_owner_job_profession_changes =
            runtime._building_owner_job_profession_changes;
        row.building_owner_job_probability_skips =
            runtime._building_owner_job_probability_skips;
        row.building_employee_to_owner_reallocations =
            runtime._building_employee_to_owner_reallocations;
        row.building_investments_started = runtime._building_investments_started;
        row.building_investment_blocked_funds =
            runtime._building_investment_blocked_funds;
        row.building_investment_blocked_materials =
            runtime._building_investment_blocked_materials;
        row.building_investment_blocked_sponsor_capital =
            runtime._building_investment_blocked_sponsor_capital;
        row.building_investment_blocked_resources =
            runtime._building_investment_blocked_resources;
        row.building_investment_probability_skips =
            runtime._building_investment_probability_skips;
        row.building_investment_capital_transferred =
            runtime._building_investment_capital_transferred;
        row.building_investment_buildings_started =
            runtime._building_investment_buildings_started;
        row.building_investment_portfolios_started =
            runtime._building_investment_portfolios_started;
        row.building_investment_types_started =
            runtime._building_investment_types_started;
        row.building_investment_owner_population_moved =
            runtime._building_investment_owner_population_moved;
        row.building_investment_max_type_owner_share_q16 =
            runtime._building_investment_max_type_owner_share_q16;
        row.building_investment_demand_limited =
            runtime._building_investment_demand_limited;
        row.building_investment_material_limited =
            runtime._building_investment_material_limited;
        row.building_investment_capital_limited =
            runtime._building_investment_capital_limited;
        row.building_investment_owner_population_limited =
            runtime._building_investment_owner_population_limited;
        row.building_investment_jobs_started =
            runtime._building_investment_jobs_started;
        row.building_investment_employment_gap =
            runtime._building_investment_employment_gap;
        row.building_investment_employment_catchup_cells =
            runtime._building_investment_employment_catchup_cells;
        row.building_investment_displacement_starts =
            runtime._building_investment_displacement_starts;
        row.investment_displacement_type_evaluations =
            runtime._investment_displacement_type_evaluations;
        row.desired_business_demand = runtime._desired_business_demand;
        row.funded_business_demand = runtime._funded_business_demand;
        row.unfunded_business_demand = runtime._unfunded_business_demand;
        row.owner_working_capital_allocated =
            runtime._owner_working_capital_allocated;
        row.trade_signal_max_age_days = runtime._trade_signal_max_age_days;
        row.trade_first_dispatch_delay_max_days =
            runtime._trade_first_dispatch_delay_max_days;
        row.trade_response_deadline_misses =
            runtime._trade_response_deadline_misses;
        row.trade_response_deadline_misses_cumulative =
            runtime._trade_response_deadline_misses_cumulative;
        row.trade_unresolved_no_attempt = runtime._trade_unresolved_no_attempt;
        row.trade_unresolved_no_spread = runtime._trade_unresolved_no_spread;
        row.trade_unresolved_margin = runtime._trade_unresolved_margin;
        row.trade_unresolved_route = runtime._trade_unresolved_route;
        row.trade_unresolved_stock = runtime._trade_unresolved_stock;
        row.trade_unresolved_capacity = runtime._trade_unresolved_capacity;
        row.trade_unresolved_cash = runtime._trade_unresolved_cash;
        row.trade_unresolved_order_cap = runtime._trade_unresolved_order_cap;
        row.trade_runtime_mode = runtime._trade_runtime_mode.get();
        row.trade_topology_ready = runtime._trade_topology.ready;
        row.trade_topology_generation = runtime._trade_topology.topology_generation;
        row.trade_topology_hash = runtime._trade_topology.topology_hash;
        row.trade_country_generation = runtime._trade_topology.component_country_hash;
        row.trade_plan_phase = runtime._trade_plan.phase;
        row.trade_scan_cursor = runtime._trade_plan.scan_cursor;
        row.trade_scan_total = runtime._trade_plan.scan_total;
        row.trade_route_cursor = runtime._trade_plan.route_cursor;
        row.trade_route_total = runtime._trade_plan.sources.size();
        row.trade_completed_scans = runtime._trade_plan.completed_scans;
        row.trade_plan_reset_count = runtime._trade_plan_reset_count;
        row.trade_topology_content_change_count =
            runtime._trade_topology_content_change_count;
        row.trade_last_plan_reset_reason = runtime._trade_last_plan_reset_reason;
        row.trade_source_signals = runtime._trade_plan.sources.size();
        row.trade_destination_signals = runtime._trade_plan.destinations.size();
        row.trade_ready_candidates = runtime._trade_plan.ready_candidates.size();
        row.trade_route_expansions = runtime._trade_route_expansions;
        row.trade_route_cache_hits = runtime._trade_route_cache_hits;
        row.trade_route_cache_misses = runtime._trade_route_cache_misses;
        row.trade_candidates_generated = runtime._trade_candidates_generated;
        row.trade_candidates_accepted = runtime._trade_candidates_accepted;
        row.trade_rejected_profit = runtime._trade_rejected_profit;
        row.trade_rejected_no_spread = runtime._trade_rejected_no_spread;
        row.trade_rejected_margin = runtime._trade_rejected_margin;
        row.trade_quantity_profit_clips = runtime._trade_quantity_profit_clips;
        row.trade_relief_candidates = runtime._trade_relief_candidates;
        row.trade_rejected_capacity = runtime._trade_rejected_capacity;
        row.trade_rejected_stock = runtime._trade_rejected_stock;
        row.trade_rejected_cash = runtime._trade_rejected_cash;
        row.trade_rejected_route = runtime._trade_rejected_route;
        row.trade_rejected_order_cap = runtime._trade_rejected_order_cap;
        row.trade_orders_in_flight = runtime.trade_orders_store().size();
        row.trade_orders_dispatched = runtime._trade_orders_dispatched;
        row.trade_orders_arrived = runtime._trade_orders_arrived;
        row.trade_unclaimed_orders = runtime._trade_unclaimed_orders;
        row.trade_capacity_available = runtime._trade_capacity_available;
        row.trade_capacity_used = runtime._trade_capacity_used;
        row.merchant_credit_budget = runtime._merchant_credit_budget;
        row.merchant_credit_committed = runtime._merchant_credit_committed;
        row.merchant_credit_drawn = runtime._merchant_credit_drawn;
        row.merchant_credit_repaid = runtime._merchant_credit_repaid;
        row.merchant_credit_premium_repaid = runtime._merchant_credit_premium_repaid;
        row.merchant_credit_bad_debt = runtime._merchant_credit_bad_debt;
        row.recovery_candidates = runtime._recovery_candidates;
        row.recovery_approved = runtime._recovery_approved;
        row.recovery_restarted = runtime._recovery_restarted;
        row.recovery_failed = runtime._recovery_failed;
        row.recovery_liquidated_buildings = runtime._recovery_liquidated_buildings;
        row.recovery_partially_liquidated_buildings =
            runtime._recovery_partially_liquidated_buildings;
        row.recovery_fully_liquidated_groups =
            runtime._recovery_fully_liquidated_groups;
        row.merchant_survival_procurement_required =
            runtime._merchant_survival_procurement_required;
        row.merchant_survival_procurement_allocated =
            runtime._merchant_survival_procurement_allocated;
        row.merchant_input_procurement_required =
            runtime._merchant_input_procurement_required;
        row.merchant_input_procurement_allocated =
            runtime._merchant_input_procurement_allocated;
        row.trade_active_keys_pruned = runtime._trade_active_keys_pruned;
        row.trade_deficit_episodes_started = runtime._trade_deficit_episodes_started;
        row.trade_deficit_episodes_resolved = runtime._trade_deficit_episodes_resolved;
        row.trade_candidates_stale_generation = runtime._trade_candidates_stale_generation;
        row.trade_candidates_arbitrated_out = runtime._trade_candidates_arbitrated_out;
        row.trade_true_source_stock_failures = runtime._trade_true_source_stock_failures;
        int64_t liquidity_sat = 0;
        row.merchant_cash = runtime._closing_totals.merchant_cash;
        row.merchant_inventory_retail_value =
            runtime._closing_totals.merchant_inventory_retail_value;
        row.merchant_inventory_liquidation_value =
            runtime._closing_totals.merchant_inventory_liquidation_value;
        row.merchant_economic_assets = runtime.saturating_add(
            row.merchant_cash, row.merchant_inventory_liquidation_value,
            liquidity_sat);
        row.merchant_procurement_margin_value = std::max<int64_t>(
            0, runtime._merchant_procurement_retail_value -
                runtime._merchant_procurement_spent);
        row.merchant_trade_purchase_cash =
            runtime._merchant_trade_purchase_cash;
        row.merchant_trade_sale_cash = runtime._merchant_trade_sale_cash;
        row.merchant_operating_outflow = runtime.saturating_add(
            runtime.saturating_add(runtime._merchant_procurement_spent,
                runtime._merchant_trade_purchase_cash, liquidity_sat),
            runtime._merchant_credit_drawn, liquidity_sat);
        row.merchant_liquidity_coverage_q16 =
            row.merchant_operating_outflow > 0
                ? runtime.mul_div_sat(row.merchant_cash,
                    NativeEconomyRuntime::Q16_ONE,
                    row.merchant_operating_outflow, liquidity_sat)
                : NativeEconomyRuntime::Q16_ONE;
        row.merchant_effective_buy_factor_q16 =
            runtime._merchant_procurement_spent > 0
                ? static_cast<int32_t>(std::clamp<int64_t>(
                    runtime._merchant_procurement_factor_weighted_cash_q16 /
                        runtime._merchant_procurement_spent,
                    0, NativeEconomyRuntime::Q16_ONE))
                : NativeEconomyRuntime::Q16_ONE;
        for (size_t pk_row = 0; pk_row < runtime.building_count(); ++pk_row) {
            const auto group = runtime.building_at(pk_row);
            row.merchant_credit_outstanding += group.merchant_debt_principal +
                group.merchant_debt_premium;
        }
        for (const auto pending : runtime.pending_construction()) {
            row.merchant_credit_outstanding += pending.merchant_debt_principal +
                pending.merchant_debt_premium;
        }
        batch.summary.push_back(row);
    }

    std::vector<int64_t> &inbound = batch.scratch_trade_inbound;
    std::vector<int64_t> &outbound = batch.scratch_trade_outbound;
    if (_config.enabled[MARKET]) {
        const size_t total = _sample_cells.size() * runtime.market_store().good_count.get();
        inbound.assign(total, 0); outbound.assign(total, 0);
        for (int32_t order = 0; order < runtime.trade_orders_store().size(); ++order) {
            if (runtime.trade_orders_store().cargo_delivered[order] != 0) continue;
            const int32_t src = runtime.trade_orders_store().sources[order];
            const int32_t dst = runtime.trade_orders_store().destinations[order];
            for (int32_t line = runtime.trade_orders_store().line_offsets[order];
                 line < runtime.trade_orders_store().line_offsets[order + 1]; ++line) {
                const int32_t good = runtime.trade_orders_store().line_goods[line];
                const int64_t qty = runtime.trade_orders_store().line_quantities[line];
                const int32_t src_pos = src >= 0 && src < runtime._cell_count.get()
                    ? _sample_cell_positions[src] : -1;
                const int32_t dst_pos = dst >= 0 && dst < runtime._cell_count.get()
                    ? _sample_cell_positions[dst] : -1;
                if (src_pos >= 0)
                    outbound[static_cast<size_t>(src_pos) * runtime.market_store().good_count.get() + good] += qty;
                if (dst_pos >= 0)
                    inbound[static_cast<size_t>(dst_pos) * runtime.market_store().good_count.get() + good] += qty;
            }
        }
    }

    batch.cohorts.reserve(_config.enabled[COHORTS] ? runtime.population_store().active_count : 0);
    batch.buildings.reserve(_config.enabled[BUILDINGS]
        ? runtime.building_count() + runtime.pending_construction_count() : 0);
    if (_config.enabled[MARKET]) batch.market.reserve(
        _sample_cells.size() * runtime.market_store().good_count.get());
    if (_config.enabled[RESOURCES]) batch.resources.reserve(
        _sample_cells.size() * resource_arrays.size());

    for (const int32_t cell : _sample_cells) {
        CommonCell common{epoch_row_id, runtime._epoch_id.get(), day, cell,
                          _config.q[cell], _config.r[cell], _config.s[cell]};
        if (_config.enabled[COHORTS]) {
            int32_t cohort_index = 0;
            runtime.population_store().for_each_in_cell(cell, [&](int32_t slot) {
                CohortRow row;
                row.c = common; row.cohort_index = cohort_index++;
                row.handle = runtime.population_store().handle_for_slot(slot);
                row.signature_id = static_cast<int32_t>(runtime.population_store().signature_id[slot]);
                const auto &signature = runtime._signatures[row.signature_id];
                row.profession_id = signature.profession_id; row.ethnicity_id = signature.ethnicity_id;
                row.population = runtime.population_store().population[slot];
                row.funds = runtime.population_store().funds[slot];
        row.epoch_income = runtime.population_store().epoch_income[slot];
        row.epoch_expense = runtime.population_store().epoch_expense[slot];
        row.epoch_tax_paid = runtime.population_store().epoch_tax_paid[slot];
        row.epoch_subsidy_received = runtime.population_store().epoch_subsidy_received[slot];
        row.epoch_in_kind_income = runtime.population_store().epoch_in_kind_income[slot];
        row.cash_expense_coverage_q16 = row.epoch_expense > 0
            ? runtime.mul_div_sat(row.epoch_income, 65536, row.epoch_expense, runtime._saturation_count) : 65536;
        const int64_t livelihood_income = runtime.saturating_add(
            row.epoch_income, row.epoch_in_kind_income, runtime._saturation_count);
        const int64_t livelihood_expense = runtime.saturating_add(
            row.epoch_expense, row.epoch_in_kind_income, runtime._saturation_count);
        row.livelihood_coverage_q16 = livelihood_expense > 0
            ? runtime.mul_div_sat(livelihood_income, 65536, livelihood_expense,
                                  runtime._saturation_count) : 65536;
                row.income_ema = runtime.population_store().income_ema[slot];
                row.satisfaction_q16 = runtime.population_store().needs_satisfaction[slot];
                const uint16_t worst = runtime.population_store().worst_need_id[slot];
                row.worst_need_id = worst == std::numeric_limits<uint16_t>::max() ? -1 : worst;
                row.merchant = runtime.is_merchant_slot(slot);
                row.owner_employed = runtime.population_store().owner_employed[slot];
                row.employee_employed = runtime.population_store().employee_employed[slot];
                row.unemployed = std::max<int64_t>(0, row.population - row.owner_employed - row.employee_employed);
                if (cell >= 0 && cell < runtime._cell_count.get() &&
                    cell < static_cast<int32_t>(runtime._cell_births.size()) &&
                    cell < static_cast<int32_t>(runtime._cell_deaths.size()) &&
                    cell < static_cast<int32_t>(runtime._cell_moved_in.size()) &&
                    cell < static_cast<int32_t>(runtime._cell_moved_out.size())) {
                    row.cell_births = runtime._cell_births[static_cast<size_t>(cell)];
                    row.cell_deaths = runtime._cell_deaths[static_cast<size_t>(cell)];
                    row.cell_moved_in = runtime._cell_moved_in[static_cast<size_t>(cell)];
                    row.cell_moved_out = runtime._cell_moved_out[static_cast<size_t>(cell)];
                }
                batch.cohorts.push_back(row);
            });
        }
        if (_config.enabled[BUILDINGS]) {
            int32_t group_index = 0;
            if (runtime._building_cell_offsets.size() == static_cast<size_t>(runtime._cell_count.get() + 1)) {
                for (int32_t index = runtime._building_cell_offsets[cell];
                     index < runtime._building_cell_offsets[cell + 1]; ++index) {
                    const auto group = runtime.building_at(static_cast<size_t>(index));
                    if (group.count <= 0) continue;
                    BuildingRow row;
                    row.c = common; row.group_index = group_index++; row.type_id = group.type_id;
                    row.owner_signature_id = group.owner_signature_id; row.count = group.count;
                    const auto &type = runtime._building_types[group.type_id];
                    int64_t snapshot_sat = 0;
                    row.owner_capacity = runtime.saturating_mul(
                        group.count, type.owner_slots_per_building, snapshot_sat);
                    int64_t employment_utilization_q16 = group.operating_state == 1
                        ? 0 : group.planned_utilization_q16;
                    row.planned_owner_equivalent = runtime.mul_div_sat(
                        row.owner_capacity, employment_utilization_q16,
                        NativeEconomyRuntime::Q16_ONE, snapshot_sat);
                    if (row.planned_owner_equivalent == 0 && row.owner_capacity > 0 &&
                        employment_utilization_q16 > 0) row.planned_owner_equivalent = 1;
                    row.owner_required = runtime.planned_owner_demand(
                        group, snapshot_sat);
                    row.filled_owner = group.filled_owner;
                    row.owner_openings = std::max<int64_t>(
                        0, row.owner_required - row.filled_owner);
                    row.wage_suspended = group.wage_suspended != 0;
                    row.capacity_q16 = group.last_capacity_q16; row.last_input = group.last_input;
                    row.last_temperature_fit_q16 = group.last_temperature_fit_q16;
                    row.last_water_fit_q16 = group.last_water_fit_q16;
                    row.last_climate_capacity_q16 = group.last_climate_capacity_q16;
                    row.last_climate_lost_output = group.last_climate_lost_output;
                    row.purchase_intent_capacity_q16 = group.purchase_intent_capacity_q16;
                    row.funded_capacity_q16 = index < static_cast<int32_t>(
                        runtime._building_funded_capacity_q16.size())
                        ? runtime._building_funded_capacity_q16[index] : group.last_capacity_q16;
                    row.owner_working_capital_allocated = index < static_cast<int32_t>(
                        runtime._building_working_capital_allocated.size())
                        ? runtime._building_working_capital_allocated[index] : 0;
                    row.investment_score_q16 = index < static_cast<int32_t>(
                        runtime._building_investment_score_q16.size())
                        ? runtime._building_investment_score_q16[index] : 0;
                    row.investment_payback_days = index < static_cast<int32_t>(
                        runtime._building_investment_payback_days.size())
                        ? runtime._building_investment_payback_days[index] : 0;
                    row.investment_rejection_reason = index < static_cast<int32_t>(
                        runtime._building_investment_rejection.size())
                        ? runtime._building_investment_rejection[index] : 0;
                    if (runtime._investment_diagnostic_cell == cell) {
                        for (const auto &item : runtime._investment_diagnostics) {
                            if (item.type_id != group.type_id) continue;
                            row.investment_shortage_q16 = item.shortage_q16;
                            row.investment_utilization_q16 = item.utilization_q16;
                            row.investment_driver_good_id = item.driver_good_id;
                            row.investment_driver_pressure_q16 = item.driver_pressure_q16;
                            row.investment_driver_utilization_q16 = item.driver_utilization_q16;
                            row.investment_driver_sellable = item.driver_sellable;
                            row.investment_driver_merchant_sold = item.driver_merchant_sold;
                            row.investment_driver_sell_through_q16 = item.driver_sell_through_q16;
                            row.investment_driver_discard_q16 = item.driver_discard_q16;
                            row.investment_monetary_quota_initial =
                                item.monetary_quota_initial;
                            row.investment_monetary_quota_daily =
                                item.monetary_quota_daily;
                            row.investment_monetary_units = item.monetary_units;
                            row.investment_monetary_candidate_slots =
                                item.monetary_candidate_slots;
                            row.investment_monetary_request_money_per_day =
                                item.monetary_request_money_per_day;
                            row.investment_monetary_expected_revenue_per_day =
                                item.monetary_expected_revenue_per_day;
                            row.investment_stealable = item.stealable;
                            row.investment_challenger_unit_cost =
                                item.challenger_unit_cost;
                            row.investment_incumbent_unit_cost =
                                item.incumbent_unit_cost;
                            row.investment_return_on_capital_q16 =
                                item.return_on_capital_q16;
                            row.investment_cost_advantage_q16 =
                                item.cost_advantage_q16;
                            row.investment_failed_material_group =
                                item.failed_material_group;
                            for (size_t material = 0;
                                 material < item.selected_material_good_ids.size();
                                 ++material) {
                                if (material > 0) {
                                    row.investment_selected_material_good_ids += "|";
                                    row.investment_selected_material_quantities += "|";
                                }
                                const int32_t good =
                                    item.selected_material_good_ids[material];
                                row.investment_selected_material_good_ids +=
                                    good >= 0 && good < static_cast<int32_t>(
                                        _good_ids.size())
                                        ? _good_ids[good] : "invalid";
                                row.investment_selected_material_quantities +=
                                    std::to_string(material <
                                        item.selected_material_quantities.size()
                                        ? item.selected_material_quantities[material]
                                        : 0);
                            }
                            break;
                        }
                    }
                    row.realized_profit_margin_q16 = group.realized_profit_margin_q16;
                    row.severe_loss_cycles = group.severe_loss_cycles;
                    row.recovery_cycles = group.recovery_cycles;
                    row.operating_state = group.operating_state;
                    row.merchant_debt_principal = group.merchant_debt_principal;
                    row.merchant_debt_premium = group.merchant_debt_premium;
                    row.merchant_debt_term_cycles_left =
                        group.merchant_debt_term_cycles_left;
                    row.merchant_debt_delinquent_cycles =
                        group.merchant_debt_delinquent_cycles;
                    row.last_in_kind_livelihood_value =
                        group.last_in_kind_livelihood_value;
                    row.recovery_failed_reviews = group.recovery_failed_reviews;
                    row.last_output = group.last_output; row.last_sold = group.last_sold;
                    row.last_discarded = group.last_discarded;
                    row.last_retained = std::max<int64_t>(0, group.last_output - group.last_sold - group.last_discarded);
                    row.last_resource = group.last_resource;
                    row.last_resource_generated = group.last_resource_generated;
                    row.last_revenue = group.last_revenue; row.last_input_cost = group.last_input_cost;
                    row.last_wages_paid = group.last_wages_paid; row.last_wages_due = group.last_wages_due;
                    row.last_expected_revenue = group.last_expected_revenue;
                    row.last_operating_cost = group.last_operating_cost;
                    row.last_margin_gap_q16 = group.last_margin_gap_q16;
                    row.planned_utilization_q16 = group.planned_utilization_q16;
                    row.last_base_wages_due = group.last_base_wages_due;
                    row.last_base_wages_paid = group.last_base_wages_paid;
                    row.last_bonus_due = group.last_bonus_due; row.last_bonus_paid = group.last_bonus_paid;
                    row.owner_living_cost_per_day = runtime.living_cost_for_signature(
                        cell, group.owner_signature_id, -1, snapshot_sat);
                    row.owner_livelihood_required = runtime.saturating_mul(
                        runtime.saturating_mul(row.owner_living_cost_per_day,
                            std::max<int64_t>(0, group.filled_owner), snapshot_sat),
                        std::max(1, runtime._epoch_days.get()), snapshot_sat);
                    row.viability_operating_cost = runtime.saturating_add(
                        runtime.saturating_add(group.last_input_cost,
                            group.last_base_wages_due, snapshot_sat),
                        runtime.saturating_add(group.last_maintenance_cost,
                            row.owner_livelihood_required, snapshot_sat), snapshot_sat);
                    row.viability_income_gap = runtime.saturating_sub(
                        runtime.saturating_add(group.last_revenue,
                            std::max<int64_t>(0,
                                group.last_in_kind_livelihood_value), snapshot_sat),
                        row.viability_operating_cost,
                        snapshot_sat);
                    row.projected_owner_income_per_day =
                        runtime.projected_owner_income_per_day(group, snapshot_sat);
                    for (int32_t role = 0; role < type.employee_count; ++role) {
                        const auto &job = runtime._building_employee_roles[type.employee_begin + role];
                        const int64_t full = runtime.saturating_mul(group.count, job.slots_per_building, snapshot_sat);
                        int64_t required = runtime.mul_div_sat(full, employment_utilization_q16,
                            NativeEconomyRuntime::Q16_ONE, snapshot_sat);
                        if (required == 0 && full > 0 && employment_utilization_q16 > 0)
                            required = 1;
                        row.employee_required += required;
                        row.employee_filled += runtime._building_employee_filled[group.employee_fill_begin + role];
                    }
                    const int64_t owner_fillability_q16 = NativeEconomyRuntime::Q16_ONE;
                    const int64_t employee_fillability_q16 = row.employee_required > 0
                        ? runtime.mul_div_sat(row.employee_filled,
                            NativeEconomyRuntime::Q16_ONE, row.employee_required,
                            snapshot_sat)
                        : NativeEconomyRuntime::Q16_ONE;
                    const auto opportunity = runtime.owner_opportunity_quote(
                        group, owner_fillability_q16, employee_fillability_q16,
                        snapshot_sat);
                    row.opportunity_owner_income_per_day =
                        opportunity.owner_income_per_day;
                    row.opportunity_disposable_survival_power_per_day =
                        opportunity.disposable_survival_power_per_day;
                    row.opportunity_executable_capacity_q16 =
                        opportunity.executable_capacity_q16;
                    row.opportunity_in_kind_retail_value =
                        opportunity.in_kind_retail_value;
                    row.survival_priority = opportunity.survival_priority;
                    const int32_t market = runtime.market_store().cell_to_market[cell];
                    for (int32_t output = 0; output < type.output_count; ++output) {
                        const int32_t good = runtime._building_outputs[
                            type.output_begin + output].good_id;
                        if (good >= 0 && good < static_cast<int32_t>(
                                runtime._survival_food_good_mask.size()) &&
                            runtime._survival_food_good_mask[good] != 0) {
                            row.survival_shortage_q16 = std::max<int64_t>(
                                row.survival_shortage_q16,
                                runtime.market_store().last_shortage_q16[
                                    runtime.market_store().index(market, good)]);
                        }
                    }
                    row.monetary_quota_absorption_q16 =
                        opportunity.monetary_quota_absorption_q16;
                    row.monetary_quote_capped = opportunity.monetary_quote_capped;
                    batch.buildings.push_back(row);
                }
            }
            int32_t construction_index = 0;
            for (const auto pending : runtime.pending_construction()) {
                if (pending.cell != cell) continue;
                BuildingRow row;
                row.c = common; row.construction = true; row.group_index = construction_index++;
                row.type_id = pending.type_id; row.owner_signature_id = pending.owner_signature_id;
                row.count = pending.count; row.construction_ready_day = pending.ready_day;
                row.merchant_debt_principal = pending.merchant_debt_principal;
                row.merchant_debt_premium = pending.merchant_debt_premium;
                row.merchant_debt_term_cycles_left =
                    pending.merchant_debt_term_cycles_left;
                batch.buildings.push_back(row);
            }
            if (runtime._investment_diagnostic_cell == cell) {
                for (const auto &item : runtime._investment_diagnostics) {
                    BuildingRow row;
                    row.c = common;
                    row.group_index = -1;
                    row.type_id = item.type_id;
                    row.investment_candidate = true;
                    row.investment_score_q16 = item.score_q16;
                    row.investment_payback_days = item.payback_days;
                    row.investment_rejection_reason = item.rejection_reason;
                    row.investment_shortage_q16 = item.shortage_q16;
                    row.investment_utilization_q16 = item.utilization_q16;
                    row.investment_required_capital = item.required_capital;
                    row.investment_projected_profit_per_day =
                        item.projected_profit_per_day;
                    row.investment_driver_good_id = item.driver_good_id;
                    row.investment_driver_pressure_q16 = item.driver_pressure_q16;
                    row.investment_driver_utilization_q16 = item.driver_utilization_q16;
                    row.investment_driver_sellable = item.driver_sellable;
                    row.investment_driver_merchant_sold = item.driver_merchant_sold;
                    row.investment_driver_sell_through_q16 = item.driver_sell_through_q16;
                    row.investment_driver_discard_q16 = item.driver_discard_q16;
                    row.investment_monetary_quota_initial =
                        item.monetary_quota_initial;
                    row.investment_monetary_quota_daily =
                        item.monetary_quota_daily;
                    row.investment_monetary_units = item.monetary_units;
                    row.investment_monetary_candidate_slots =
                        item.monetary_candidate_slots;
                    row.investment_monetary_request_money_per_day =
                        item.monetary_request_money_per_day;
                    row.investment_monetary_expected_revenue_per_day =
                        item.monetary_expected_revenue_per_day;
                    row.investment_stealable = item.stealable;
                    row.investment_challenger_unit_cost =
                        item.challenger_unit_cost;
                    row.investment_incumbent_unit_cost =
                        item.incumbent_unit_cost;
                    row.investment_return_on_capital_q16 =
                        item.return_on_capital_q16;
                    row.investment_cost_advantage_q16 =
                        item.cost_advantage_q16;
                    row.investment_failed_material_group =
                        item.failed_material_group;
                    for (size_t material = 0;
                         material < item.selected_material_good_ids.size();
                         ++material) {
                        if (material > 0) {
                            row.investment_selected_material_good_ids += "|";
                            row.investment_selected_material_quantities += "|";
                        }
                        const int32_t good =
                            item.selected_material_good_ids[material];
                        row.investment_selected_material_good_ids +=
                            good >= 0 && good < static_cast<int32_t>(
                                _good_ids.size())
                                ? _good_ids[good] : "invalid";
                        row.investment_selected_material_quantities +=
                            std::to_string(material <
                                item.selected_material_quantities.size()
                                ? item.selected_material_quantities[material]
                                : 0);
                    }
                    batch.buildings.push_back(row);
                }
            }
            if (runtime._employment_diagnostic_cell == cell) {
                for (const auto &item : runtime._employment_diagnostics) {
                    BuildingRow row;
                    row.c = common;
                    row.group_index = -2;
                    row.type_id = item.type_id;
                    row.owner_signature_id = item.target_signature;
                    row.employment_candidate = true;
                    row.employment_diagnostic_day =
                        runtime._employment_diagnostic_day;
                    row.employment_role = item.role;
                    row.employment_target_signature = item.target_signature;
                    row.employment_profession_id = item.profession_id;
                    row.employment_source_ethnicity = item.source_ethnicity;
                    row.employment_pool_slot = item.pool_slot;
                    row.employment_pool_signature = item.pool_signature;
                    row.employment_pool_population = item.pool_population;
                    row.employment_vacancy = item.vacancy;
                    row.employment_target_disposable = item.target_disposable;
                    row.employment_source_disposable = item.source_disposable;
                    row.employment_improvement_q16 = item.improvement_q16;
                    row.employment_hurdle_q16 = item.hurdle_q16;
                    row.employment_weight_q16 = item.weight_q16;
                    row.employment_budget = item.budget;
                    row.employment_allocation = item.allocation;
                    row.employment_take = item.take;
                    row.employment_eligible = item.eligible;
                    row.employment_rejection_reason = item.rejection_reason;
                    row.employment_group = item.group_index;
                    row.employment_owner_target = item.owner_target;
                    row.employment_filled_before_clamp = item.filled_before_clamp;
                    row.employment_filled_after_profession_clamp =
                        item.filled_after_profession_clamp;
                    row.employment_filled_after_family_clamp =
                        item.filled_after_family_clamp;
                    row.employment_family_owned = item.family_owned;
                    row.employment_family_member_people =
                        item.family_member_people;
                    row.employment_anonymous_people = item.anonymous_people;
                    row.employment_owner_cohort_population =
                        item.owner_cohort_population;
                    row.employment_shed_surplus = item.shed_surplus;
                    batch.buildings.push_back(row);
                }
            }
        }
        if (_config.enabled[RESOURCES]) {
            for (int32_t resource = 0; resource < static_cast<int32_t>(resource_arrays.size()); ++resource) {
                if (resource_arrays[resource] == nullptr) {
                    error = "resource_slot_unavailable";
                    return false;
                }
                const size_t flat = static_cast<size_t>(resource) *
                    runtime._cell_count.get() + cell;
                const float closing = resource_arrays[resource][cell];
                const bool valid = flat < _resource_history_valid.size() &&
                    _resource_history_valid[flat] != 0;
                const float opening = valid ? _previous_resource_reserve[flat] : closing;
                const int64_t applied_fixed = valid
                    ? _pending_resource_artificial[flat] : 0;
                const int32_t runtime_resource = resource <
                        static_cast<int32_t>(_resource_runtime_indices.size())
                    ? _resource_runtime_indices[resource] : -1;
                const size_t runtime_flat = runtime_resource >= 0
                    ? static_cast<size_t>(runtime_resource) * runtime._cell_count.get() + cell
                    : runtime._last_published_resource_deltas.size();
                const int64_t pending_fixed = runtime_flat <
                        runtime._last_published_resource_deltas.size()
                    ? runtime._last_published_resource_deltas[runtime_flat] : 0;
                const float applied = static_cast<float>(applied_fixed) /
                    static_cast<float>(NativeEconomyRuntime::GOODS_SCALE);
                ResourceRow row;
                row.c = common;
                row.resource_index = resource;
                row.opening_reserve = opening;
                row.artificial_change_applied = applied;
                row.artificial_change_pending = static_cast<float>(pending_fixed) /
                    static_cast<float>(NativeEconomyRuntime::GOODS_SCALE);
                row.reserve = closing;
                    row.stock_density_q16 =
                        runtime.resource_stock_density_q16(resource, cell);
                    row.managed_harvest_enabled =
                        runtime._resource_safe_harvest_q16 > 0 ? 1 : 0;
                row.natural_net_change = closing - opening - applied;
                row.natural_positive_change = std::max(0.0f, row.natural_net_change);
                row.natural_negative_change = std::max(0.0f, -row.natural_net_change);
                row.artificial_generation_applied = std::max(0.0f, applied);
                row.artificial_extraction_applied = std::max(0.0f, -applied);
                row.artificial_generation_pending = std::max(
                    0.0f, row.artificial_change_pending);
                row.artificial_extraction_pending = std::max(
                    0.0f, -row.artificial_change_pending);
                if (runtime_resource >= 0) {
                    int64_t resource_sat = 0;
                    const int64_t capacity = runtime._resource_ecology_capacity[
                        runtime_resource];
                    const int64_t growth = runtime._resource_ecology_growth_q16[
                        runtime_resource];
                    int64_t harvest = 0;
                    if (runtime._building_cell_offsets.size() == static_cast<size_t>(
                            runtime._cell_count.get() + 1)) {
                        for (int32_t group_index = runtime._building_cell_offsets[cell];
                             group_index < runtime._building_cell_offsets[cell + 1];
                             ++group_index) {
                            const auto group = runtime.building_at(static_cast<size_t>(group_index));
                            const auto &type = runtime._building_types[group.type_id];
                            for (int32_t edge = 0; edge < type.resource_count; ++edge) {
                                const auto &item = runtime._building_resources[
                                    type.resource_begin + edge];
                                if (item.mode == 0 && item.resource_id == runtime_resource) {
                                    harvest += item.quantity * group.count;
                                }
                            }
                        }
                    }
                    if (capacity > 0 && growth > 0) {
                        const int64_t closing_fixed = static_cast<int64_t>(
                            std::max(0.0f, closing) *
                            NativeEconomyRuntime::GOODS_SCALE);
                        const int64_t reserve_floor = runtime.mul_div_sat(
                            closing_fixed, runtime._resource_min_reserve_q16,
                            NativeEconomyRuntime::Q16_ONE, resource_sat);
                        const int64_t yield_biomass = std::min<int64_t>(
                            capacity / 8,
                            std::max<int64_t>(0, closing_fixed - reserve_floor));
                        row.safe_yield = runtime.mul_div_sat(runtime.mul_div_sat(
                            yield_biomass, growth, NativeEconomyRuntime::Q16_ONE,
                            resource_sat), runtime._resource_safe_harvest_q16,
                            NativeEconomyRuntime::Q16_ONE, resource_sat);
                        const int64_t overshoot = std::max<int64_t>(
                            0, harvest - row.safe_yield);
                        row.projected_life_days = overshoot > 0
                            ? std::max<int64_t>(0, closing_fixed - reserve_floor) /
                                overshoot
                            : -1;
                    } else {
                        row.projected_life_days = harvest > 0
                            ? static_cast<int64_t>(closing * NativeEconomyRuntime::GOODS_SCALE) /
                                harvest : 0;
                    }
                }
                batch.resources.push_back(row);
                _previous_resource_reserve[flat] = closing;
                _pending_resource_artificial[flat] = pending_fixed;
                _resource_history_valid[flat] = 1;
            }
        }
        if (_config.enabled[MARKET]) {
            const int32_t market = runtime.market_store().cell_to_market[cell];
            int64_t liquidity_sat = 0;
            int64_t merchant_cash = 0;
            runtime.population_store().for_each_in_cell(cell, [&](int32_t slot) {
                if (!runtime.is_merchant_slot(slot)) return;
                merchant_cash = runtime.saturating_add(
                    merchant_cash,
                    std::max<int64_t>(0, runtime.population_store().funds[slot]),
                    liquidity_sat);
            });
            int64_t inventory_retail_value = 0;
            int64_t inventory_liquidation_value = 0;
            for (int32_t good = 0; good < runtime.market_store().good_count.get(); ++good) {
                const int64_t mi = runtime.market_store().index(market, good);
                const int64_t retail_value = runtime.mul_div_sat(
                    std::max<int64_t>(0, runtime.market_store().stock[mi]),
                    std::max<int64_t>(0, runtime.market_store().price[mi]),
                    NativeEconomyRuntime::GOODS_SCALE, liquidity_sat);
                inventory_retail_value = runtime.saturating_add(
                    inventory_retail_value, retail_value, liquidity_sat);
                inventory_liquidation_value = runtime.saturating_add(
                    inventory_liquidation_value,
                    runtime.mul_div_sat(retail_value, std::clamp<int64_t>(
                        runtime._good_merchant_buy_factor_q16[good], 0,
                        NativeEconomyRuntime::Q16_ONE),
                        NativeEconomyRuntime::Q16_ONE, liquidity_sat),
                    liquidity_sat);
            }
            const int64_t procurement_paid =
                cell < static_cast<int32_t>(
                    runtime._merchant_procurement_paid_by_cell.size())
                    ? runtime._merchant_procurement_paid_by_cell[cell] : 0;
            const int64_t procurement_retail =
                cell < static_cast<int32_t>(
                    runtime._merchant_procurement_retail_by_cell.size())
                    ? runtime._merchant_procurement_retail_by_cell[cell] : 0;
            const int64_t procurement_factor_weighted_cash =
                cell < static_cast<int32_t>(
                    runtime._merchant_procurement_factor_weighted_cash_by_cell.size())
                    ? runtime._merchant_procurement_factor_weighted_cash_by_cell[cell]
                    : 0;
            const int64_t trade_purchase =
                cell < static_cast<int32_t>(
                    runtime._merchant_trade_purchase_by_cell.size())
                    ? runtime._merchant_trade_purchase_by_cell[cell] : 0;
            const int64_t trade_sale =
                cell < static_cast<int32_t>(
                    runtime._merchant_trade_sale_by_cell.size())
                    ? runtime._merchant_trade_sale_by_cell[cell] : 0;
            const int64_t credit_drawn =
                cell < static_cast<int32_t>(
                    runtime._merchant_credit_drawn_by_cell.size())
                    ? runtime._merchant_credit_drawn_by_cell[cell] : 0;
            const int64_t operating_outflow = runtime.saturating_add(
                runtime.saturating_add(procurement_paid, trade_purchase,
                    liquidity_sat), credit_drawn, liquidity_sat);
            for (int32_t good = 0; good < runtime.market_store().good_count.get(); ++good) {
                MarketRow row;
                row.c = common; row.good_index = good;
                const int64_t mi = runtime.market_store().index(market, good);
                row.stock = runtime.market_store().stock[mi]; row.price = runtime.market_store().price[mi];
                row.demand_ema = runtime.market_store().demand_ema[mi];
                row.shortage_q16 = runtime.market_store().last_shortage_q16[mi];
                const int32_t signal = runtime.market_signal_index(cell, good);
                row.business_demand_ema = signal >= 0 ? runtime._market_signals.business_demand_ema[signal] : 0;
                row.desired_business_demand = signal >= 0 && signal < static_cast<int32_t>(
                        runtime._epoch_desired_business_demand.size())
                    ? runtime._epoch_desired_business_demand[signal] : 0;
                row.funded_business_demand = signal >= 0 && signal < static_cast<int32_t>(
                        runtime._epoch_funded_business_demand.size())
                    ? runtime._epoch_funded_business_demand[signal] : 0;
                row.unfunded_business_demand = std::max<int64_t>(0,
                    row.desired_business_demand - row.funded_business_demand);
                row.offered_supply_ema = signal >= 0 ? runtime._market_signals.offered_supply_ema[signal] : 0;
                row.realized_withdrawal_ema = signal >= 0
                    ? runtime._market_signals.realized_withdrawal_ema[signal] : 0;
                row.production_input_reserve = signal >= 0 && signal <
                        static_cast<int32_t>(runtime._production_input_reserve.size())
                    ? runtime._production_input_reserve[signal] : 0;
                row.construction_material_reserve = signal >= 0 && signal <
                        static_cast<int32_t>(runtime._construction_material_reserve.size())
                    ? runtime._construction_material_reserve[signal] : 0;
                row.household_available_stock = std::max<int64_t>(
                    0, row.stock - std::max(row.production_input_reserve,
                        row.construction_material_reserve));
                row.cost_anchor_price = signal >= 0 ? runtime._market_signals.cost_anchor_price[signal] : 0;
                // Freeze the authoritative diagnostic while holding the same
                // committed boundary as the other columns. The writer only
                // formats this value and never reimplements market rules.
                int64_t pressure_sat = 0;
                const auto pressure = runtime.price_pressure(market, good,
                    row.demand_ema, row.stock, row.shortage_q16, signal, pressure_sat);
                row.price_pressure_total_q16 = static_cast<int32_t>(
                    std::clamp<int64_t>(pressure.total_q16,
                        std::numeric_limits<int32_t>::min(),
                        std::numeric_limits<int32_t>::max()));
                row.category_index = good; row.storage_mode = runtime._good_storage_modes[good];
                row.trade_enabled = runtime._good_trade_enabled[good] != 0;
                const int32_t flow = runtime.trade_flow_index(cell, good, false);
                row.trade_import_ema = flow >= 0 ? runtime._trade_flows.import_ema[flow] : 0;
                row.trade_export_ema = flow >= 0 ? runtime._trade_flows.export_ema[flow] : 0;
                int64_t target_sat = 0;
                row.merchant_inventory_target = runtime.merchant_inventory_target(
                    market, good, signal, row.realized_withdrawal_ema,
                    row.trade_export_ema, row.offered_supply_ema, target_sat);
                row.merchant_procurement_shortfall = std::max<int64_t>(
                    0, row.merchant_inventory_target - row.stock);
                row.trade_export_safety_stock = runtime.trade_export_floor(
                    market, good, target_sat);
                row.trade_import_fill_target = runtime.trade_local_stock_target(
                    market, good, target_sat);
                row.trade_relief_pressure_q16 = static_cast<int32_t>(
                    runtime.trade_relief_pressure_q16(market, good, target_sat));
                const int32_t signal_clock = runtime.trade_signal_clock_index(cell, good);
                const int64_t first_seen = signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                        runtime._trade_signal_first_seen_day.size())
                    ? runtime._trade_signal_first_seen_day[signal_clock] : -1;
                const int64_t first_dispatch = signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                        runtime._trade_signal_first_dispatch_day.size())
                    ? runtime._trade_signal_first_dispatch_day[signal_clock] : -1;
                row.trade_signal_age_days = first_seen >= 0 ? static_cast<int32_t>(
                    std::clamp<int64_t>(runtime._sample_day - first_seen, 0,
                                        std::numeric_limits<int32_t>::max())) : 0;
                row.trade_first_dispatch_delay_days =
                    first_seen >= 0 && first_dispatch >= first_seen
                        ? static_cast<int32_t>(std::clamp<int64_t>(
                            first_dispatch - first_seen, 0,
                            std::numeric_limits<int32_t>::max())) : -1;
                row.trade_last_attempt_day = signal_clock >= 0 && signal_clock <
                        static_cast<int32_t>(runtime._trade_signal_last_attempt_day.size())
                    ? runtime._trade_signal_last_attempt_day[signal_clock] : -1;
                row.trade_last_rejection_reason = signal_clock >= 0 && signal_clock <
                        static_cast<int32_t>(
                            runtime._trade_signal_last_rejection_reason.size())
                    ? runtime._trade_signal_last_rejection_reason[signal_clock] : 0;
                row.trade_deadline_exceeded = first_seen >= 0 && first_dispatch < 0 &&
                    runtime._sample_day - first_seen > runtime._trade_response_days;
                const size_t flat = static_cast<size_t>(_sample_cell_positions[cell]) *
                                    runtime.market_store().good_count.get() + good;
                row.trade_inbound = inbound[flat]; row.trade_outbound = outbound[flat];
                row.merchant_cash = merchant_cash;
                row.merchant_inventory_retail_value =
                    inventory_retail_value;
                row.merchant_inventory_liquidation_value =
                    inventory_liquidation_value;
                row.merchant_economic_assets = runtime.saturating_add(
                    merchant_cash, inventory_liquidation_value,
                    liquidity_sat);
                row.merchant_procurement_margin_value =
                    std::max<int64_t>(0,
                        procurement_retail - procurement_paid);
                row.merchant_trade_purchase_cash = trade_purchase;
                row.merchant_trade_sale_cash = trade_sale;
                row.merchant_operating_outflow = operating_outflow;
                row.merchant_liquidity_coverage_q16 =
                    operating_outflow > 0
                        ? runtime.mul_div_sat(merchant_cash,
                            NativeEconomyRuntime::Q16_ONE,
                            operating_outflow, liquidity_sat)
                        : NativeEconomyRuntime::Q16_ONE;
                row.merchant_effective_buy_factor_q16 =
                    procurement_paid > 0
                        ? static_cast<int32_t>(std::clamp<int64_t>(
                            procurement_factor_weighted_cash /
                                procurement_paid,
                            0, NativeEconomyRuntime::Q16_ONE))
                        : NativeEconomyRuntime::Q16_ONE;
                batch.market.push_back(row);
            }
        }
    }
    batch.row_count = static_cast<int64_t>(batch.summary.size() + batch.cohorts.size() +
        batch.buildings.size() + batch.resources.size() + batch.market.size());
    if (batch.row_count != expected_rows) {
        error = "projected_row_count_changed";
        return false;
    }
    return true;
}

}
