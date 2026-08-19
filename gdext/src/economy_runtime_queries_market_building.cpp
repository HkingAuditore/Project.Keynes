#include "economy_runtime.h"
#include "country_runtime.h"
#include "economy_runtime_variant_helpers.h"
#include "trigger_runtime.h"

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
using namespace variant_helpers;

Dictionary NativeEconomyRuntime::market_cell_snapshot(int32_t cell_idx) const {
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
    const int32_t market = _market.cell_to_market[cell_idx];
    out["ok"] = true;
    out["state_day"] = _cell_last_settlement_day[cell_idx];
    out["age_days"] = std::max<int64_t>(0,
        _current_day - _cell_last_settlement_day[cell_idx]);
    out["settlement_generation"] = static_cast<int64_t>(
        _cell_settlement_generation[cell_idx]);
    out["market_id"] = market;
    out["epoch_id"] = _epoch_id;
    PackedStringArray good_ids;
    PackedInt64Array stock;
    PackedInt64Array demand_ema;
    PackedInt64Array business_demand_ema;
    PackedInt64Array desired_business_demand;
    PackedInt64Array funded_business_demand;
    PackedInt64Array unfunded_business_demand;
    PackedInt64Array offered_supply_ema;
    PackedInt64Array realized_withdrawal_ema;
    PackedInt64Array production_input_reserve;
    PackedInt64Array household_available_stock;
    PackedInt64Array merchant_inventory_target;
    PackedInt64Array merchant_procurement_shortfall;
    PackedInt64Array trade_export_safety_stock;
    PackedInt64Array trade_import_fill_target;
    PackedInt32Array trade_relief_pressure_values_q16;
    PackedInt32Array trade_signal_age_days;
    PackedInt32Array trade_first_dispatch_delay_days;
    PackedInt64Array trade_last_attempt_day;
    PackedInt32Array trade_last_rejection_reason;
    PackedByteArray trade_deadline_exceeded;
    PackedInt32Array cost_anchor_price;
    PackedInt32Array price;
    PackedInt32Array shortage_q16;
    PackedInt32Array pressure_excess_q16;
    PackedInt64Array price_inventory_target;
    PackedInt32Array pressure_inventory_q16;
    PackedInt32Array pressure_shortage_q16;
    PackedInt32Array pressure_cost_q16;
    PackedInt32Array pressure_idle_q16;
    PackedInt32Array pressure_total_q16;
    PackedInt32Array price_change_q16;
	PackedByteArray trade_enabled;
	PackedInt32Array transport_load_per_unit_q16;
	PackedInt64Array trade_import_ema;
	PackedInt64Array trade_export_ema;
	PackedInt64Array trade_inbound;
	PackedInt64Array trade_outbound;
	PackedStringArray category_ids;
	PackedInt32Array storage_modes;
	PackedInt64Array monetary_issue_values;
	PackedInt32Array technology_tag_offsets;
	PackedStringArray technology_tags;
	PackedByteArray technology_available;
	technology_tag_offsets.push_back(0);
    int64_t snapshot_saturation = 0;
    int64_t merchant_inventory_retail_value = 0;
    int64_t merchant_inventory_liquidation_value = 0;
    std::vector<int64_t> inbound(static_cast<size_t>(_market.good_count), 0);
    std::vector<int64_t> outbound(static_cast<size_t>(_market.good_count), 0);
    int64_t next_arrival = -1;
    int64_t inbound_escrow = 0;
    int64_t outbound_escrow = 0;
    for (int32_t order = 0; order < _trade_orders.size(); ++order) {
        const bool destination_order = _trade_orders.destinations[order] == cell_idx;
        const bool source_order = _trade_orders.sources[order] == cell_idx;
        const bool is_inbound = destination_order &&
            _trade_orders.cargo_delivered[order] == 0;
        const bool is_outbound = source_order &&
            _trade_orders.cargo_delivered[order] == 0;
        if (!destination_order && !source_order) continue;
        if ((is_inbound || is_outbound) &&
            (next_arrival < 0 || _trade_orders.arrival_days[order] < next_arrival))
            next_arrival = _trade_orders.arrival_days[order];
        if (destination_order) inbound_escrow += _trade_orders.cash_escrow[order];
        if (source_order) outbound_escrow += _trade_orders.cash_escrow[order];
        for (int32_t line = _trade_orders.line_offsets[order];
             line < _trade_orders.line_offsets[order + 1]; ++line) {
            const int32_t good = _trade_orders.line_goods[line];
            if (is_inbound) inbound[good] += _trade_orders.line_quantities[line];
            if (is_outbound) outbound[good] += _trade_orders.line_quantities[line];
        }
    }
    for (int32_t g = 0; g < _market.good_count; ++g) {
        const int64_t market_index = _market.index(market, g);
        const int64_t retail_value = mul_div_sat(
            std::max<int64_t>(0, _market.stock[market_index]),
            std::max<int64_t>(0, _market.price[market_index]),
            GOODS_SCALE, snapshot_saturation);
        merchant_inventory_retail_value = saturating_add(
            merchant_inventory_retail_value, retail_value,
            snapshot_saturation);
        merchant_inventory_liquidation_value = saturating_add(
            merchant_inventory_liquidation_value,
            mul_div_sat(retail_value, std::clamp<int64_t>(
                _good_merchant_buy_factor_q16[g], 0, Q16_ONE),
                Q16_ONE, snapshot_saturation), snapshot_saturation);
        good_ids.push_back(String(_good_ids[g].c_str()));
        technology_available.push_back(good_available(cell_idx, g, false) ? 1 : 0);
        stock.push_back(_market.stock[_market.index(market, g)]);
        price.push_back(_market.price[_market.index(market, g)]);
        demand_ema.push_back(_market.demand_ema[_market.index(market, g)]);
        shortage_q16.push_back(_market.last_shortage_q16[_market.index(market, g)]);
        const int32_t signal = market_signal_index(cell_idx, g);
        business_demand_ema.push_back(signal >= 0 ?
            _market_signals.business_demand_ema[signal] : 0);
        const int64_t desired_business = signal >= 0 && signal < static_cast<int32_t>(
                _epoch_desired_business_demand.size())
            ? _epoch_desired_business_demand[signal] : 0;
        const int64_t funded_business = signal >= 0 && signal < static_cast<int32_t>(
                _epoch_funded_business_demand.size())
            ? _epoch_funded_business_demand[signal] : 0;
        desired_business_demand.push_back(desired_business);
        funded_business_demand.push_back(funded_business);
        unfunded_business_demand.push_back(std::max<int64_t>(
            0, desired_business - funded_business));
        offered_supply_ema.push_back(signal >= 0 ?
            _market_signals.offered_supply_ema[signal] : 0);
        const int64_t realized = signal >= 0 ?
            _market_signals.realized_withdrawal_ema[signal] : 0;
        realized_withdrawal_ema.push_back(realized);
        const int64_t input_reserve = signal >= 0 && signal <
                static_cast<int32_t>(_production_input_reserve.size())
            ? _production_input_reserve[signal] : 0;
        production_input_reserve.push_back(input_reserve);
        household_available_stock.push_back(std::max<int64_t>(0,
            _market.stock[_market.index(market, g)] - input_reserve));
        const int32_t flow = const_cast<NativeEconomyRuntime *>(this)->trade_flow_index(
            cell_idx, g, false);
        const int64_t export_ema = flow >= 0 ? _trade_flows.export_ema[flow] : 0;
        const int64_t inventory_target = this->merchant_inventory_target(
            market, g, signal, realized, export_ema,
            signal >= 0 ? _market_signals.offered_supply_ema[signal] : 0,
            snapshot_saturation);
        merchant_inventory_target.push_back(inventory_target);
        merchant_procurement_shortfall.push_back(std::max<int64_t>(
            0, inventory_target - _market.stock[_market.index(market, g)]));
        trade_export_safety_stock.push_back(trade_export_floor(
            market, g, snapshot_saturation));
        trade_import_fill_target.push_back(trade_local_stock_target(
            market, g, snapshot_saturation));
        trade_relief_pressure_values_q16.push_back(static_cast<int32_t>(
            this->trade_relief_pressure_q16(market, g, snapshot_saturation)));
        const int32_t signal_clock = trade_signal_clock_index(cell_idx, g);
        const int64_t first_seen = signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                _trade_signal_first_seen_day.size())
            ? _trade_signal_first_seen_day[signal_clock] : -1;
        const int64_t first_dispatch = signal_clock >= 0 && signal_clock < static_cast<int32_t>(
                _trade_signal_first_dispatch_day.size())
            ? _trade_signal_first_dispatch_day[signal_clock] : -1;
        trade_signal_age_days.push_back(first_seen >= 0 ? static_cast<int32_t>(
            std::clamp<int64_t>(_sample_day - first_seen, 0,
                                std::numeric_limits<int32_t>::max())) : 0);
        trade_first_dispatch_delay_days.push_back(
            first_seen >= 0 && first_dispatch >= first_seen
                ? static_cast<int32_t>(std::clamp<int64_t>(
                    first_dispatch - first_seen, 0,
                    std::numeric_limits<int32_t>::max())) : -1);
        trade_last_attempt_day.push_back(signal_clock >= 0 && signal_clock <
                static_cast<int32_t>(_trade_signal_last_attempt_day.size())
            ? _trade_signal_last_attempt_day[signal_clock] : -1);
        trade_last_rejection_reason.push_back(signal_clock >= 0 && signal_clock <
                static_cast<int32_t>(_trade_signal_last_rejection_reason.size())
            ? _trade_signal_last_rejection_reason[signal_clock] :
                TRADE_SIGNAL_DIAG_NONE);
        trade_deadline_exceeded.push_back(first_seen >= 0 && first_dispatch < 0 &&
            _sample_day - first_seen > _trade_response_days ? 1 : 0);
        cost_anchor_price.push_back(signal >= 0 ?
            _market_signals.cost_anchor_price[signal] : 0);
        const PricePressure pressure = price_pressure(
            market, g, _market.demand_ema[_market.index(market, g)],
            _market.stock[_market.index(market, g)],
            _market.last_shortage_q16[_market.index(market, g)], signal,
            snapshot_saturation);
        pressure_excess_q16.push_back(static_cast<int32_t>(pressure.excess_q16));
        price_inventory_target.push_back(pressure.inventory_target);
        pressure_inventory_q16.push_back(static_cast<int32_t>(pressure.inventory_q16));
        pressure_shortage_q16.push_back(static_cast<int32_t>(pressure.shortage_q16));
        pressure_cost_q16.push_back(static_cast<int32_t>(pressure.cost_q16));
        pressure_idle_q16.push_back(static_cast<int32_t>(pressure.idle_q16));
        pressure_total_q16.push_back(static_cast<int32_t>(std::clamp<int64_t>(
            pressure.total_q16, std::numeric_limits<int32_t>::min(),
            std::numeric_limits<int32_t>::max())));
        price_change_q16.push_back(static_cast<int32_t>(std::clamp<int64_t>(
            pressure.change_q16, std::numeric_limits<int32_t>::min(),
            std::numeric_limits<int32_t>::max())));
		trade_enabled.push_back(_good_trade_enabled[g]);
		transport_load_per_unit_q16.push_back(_good_transport_load_per_unit_q16[g]);
		trade_import_ema.push_back(flow >= 0 ? _trade_flows.import_ema[flow] : 0);
		trade_export_ema.push_back(flow >= 0 ? _trade_flows.export_ema[flow] : 0);
		trade_inbound.push_back(inbound[g]);
		trade_outbound.push_back(outbound[g]);
		category_ids.push_back(String(_good_category_ids[g].c_str()));
		storage_modes.push_back(_good_storage_modes[g]);
		monetary_issue_values.push_back(_good_monetary_issue_values[g]);
		for (int32_t k = _good_technology_tag_offsets[g];
			 k < _good_technology_tag_offsets[g + 1]; ++k) {
			technology_tags.push_back(String(_good_technology_tags[k].c_str()));
		}
		technology_tag_offsets.push_back(technology_tags.size());
    }
    out["good_ids"] = good_ids;
    out["stock"] = stock;
    out["price"] = price;
    out["demand_ema"] = demand_ema;
    out["business_demand_ema"] = business_demand_ema;
    out["desired_business_demand"] = desired_business_demand;
    out["funded_business_demand"] = funded_business_demand;
    out["unfunded_business_demand"] = unfunded_business_demand;
    out["offered_supply_ema"] = offered_supply_ema;
    out["realized_withdrawal_ema"] = realized_withdrawal_ema;
    out["production_input_reserve"] = production_input_reserve;
    out["household_available_stock"] = household_available_stock;
    out["merchant_inventory_target"] = merchant_inventory_target;
    out["merchant_procurement_shortfall"] = merchant_procurement_shortfall;
    out["trade_export_safety_stock"] = trade_export_safety_stock;
    out["trade_import_fill_target"] = trade_import_fill_target;
    out["trade_relief_pressure_q16"] = trade_relief_pressure_values_q16;
    out["trade_signal_age_days"] = trade_signal_age_days;
    out["trade_first_dispatch_delay_days"] = trade_first_dispatch_delay_days;
    out["trade_last_attempt_day"] = trade_last_attempt_day;
    out["trade_last_rejection_reason"] = trade_last_rejection_reason;
    out["trade_deadline_exceeded"] = trade_deadline_exceeded;
    out["cost_anchor_price"] = cost_anchor_price;
    out["shortage_q16"] = shortage_q16;
    out["price_pressure_excess_q16"] = pressure_excess_q16;
    out["price_inventory_target"] = price_inventory_target;
    out["price_pressure_inventory_q16"] = pressure_inventory_q16;
    out["price_pressure_shortage_q16"] = pressure_shortage_q16;
    out["price_pressure_cost_q16"] = pressure_cost_q16;
    out["price_pressure_idle_q16"] = pressure_idle_q16;
    out["price_pressure_total_q16"] = pressure_total_q16;
    out["price_change_q16"] = price_change_q16;
    out["price_preview_saturation_count"] = snapshot_saturation;
	out["good_category_ids"] = category_ids;
	out["good_storage_modes"] = storage_modes;
	out["good_monetary_issue_values"] = monetary_issue_values;
	out["good_technology_tag_offsets"] = technology_tag_offsets;
	out["good_technology_tags"] = technology_tags;
	out["good_technology_available"] = technology_available;
	out["good_trade_enabled"] = trade_enabled;
	out["good_transport_load_per_unit_q16"] = transport_load_per_unit_q16;
	out["trade_import_ema"] = trade_import_ema;
	out["trade_export_ema"] = trade_export_ema;
	out["trade_inbound"] = trade_inbound;
	out["trade_outbound"] = trade_outbound;
	out["trade_next_arrival_day"] = next_arrival;
	out["trade_inbound_escrow_cash"] = inbound_escrow;
	out["trade_outbound_escrow_cash"] = outbound_escrow;
    PackedInt64Array merchant_handles;
    PackedInt64Array merchant_population;
    PackedInt64Array merchant_funds;
    int64_t merchant_cash = 0;
    // Merchant CSR is rebuilt only after structural commit. Scan this one
    // selected cell so a live query remains valid between structural slices.
    _population.for_each_in_cell(cell_idx, [&](int32_t slot) {
        if (!is_merchant_slot(slot)) return;
        merchant_handles.push_back(static_cast<int64_t>(_population.handle_for_slot(slot)));
        merchant_population.push_back(_population.population[slot]);
        merchant_funds.push_back(_population.funds[slot]);
        merchant_cash = saturating_add(
            merchant_cash, std::max<int64_t>(0, _population.funds[slot]),
            snapshot_saturation);
    });
    const int64_t procurement_paid =
        cell_idx < static_cast<int32_t>(_merchant_procurement_paid_by_cell.size())
            ? _merchant_procurement_paid_by_cell[cell_idx] : 0;
    const int64_t procurement_retail =
        cell_idx < static_cast<int32_t>(_merchant_procurement_retail_by_cell.size())
            ? _merchant_procurement_retail_by_cell[cell_idx] : 0;
    const int64_t procurement_factor_weighted_cash =
        cell_idx < static_cast<int32_t>(
            _merchant_procurement_factor_weighted_cash_by_cell.size())
            ? _merchant_procurement_factor_weighted_cash_by_cell[cell_idx] : 0;
    const int64_t trade_purchase =
        cell_idx < static_cast<int32_t>(_merchant_trade_purchase_by_cell.size())
            ? _merchant_trade_purchase_by_cell[cell_idx] : 0;
    const int64_t trade_sale =
        cell_idx < static_cast<int32_t>(_merchant_trade_sale_by_cell.size())
            ? _merchant_trade_sale_by_cell[cell_idx] : 0;
    const int64_t credit_drawn =
        cell_idx < static_cast<int32_t>(_merchant_credit_drawn_by_cell.size())
            ? _merchant_credit_drawn_by_cell[cell_idx] : 0;
    const int64_t operating_outflow = saturating_add(
        saturating_add(procurement_paid, trade_purchase,
            snapshot_saturation), credit_drawn, snapshot_saturation);
    out["merchant_handles"] = merchant_handles;
    out["merchant_population"] = merchant_population;
    out["merchant_funds"] = merchant_funds;
    out["merchant_cash"] = merchant_cash;
    out["merchant_inventory_retail_value"] =
        merchant_inventory_retail_value;
    out["merchant_inventory_liquidation_value"] =
        merchant_inventory_liquidation_value;
    out["merchant_economic_assets"] = saturating_add(
        merchant_cash, merchant_inventory_liquidation_value,
        snapshot_saturation);
    out["merchant_procurement_margin_value"] = std::max<int64_t>(
        0, procurement_retail - procurement_paid);
    out["merchant_trade_purchase_cash"] = trade_purchase;
    out["merchant_trade_sale_cash"] = trade_sale;
    out["merchant_operating_outflow"] = operating_outflow;
    out["merchant_liquidity_coverage_q16"] = operating_outflow > 0
        ? mul_div_sat(merchant_cash, Q16_ONE, operating_outflow,
            snapshot_saturation)
        : Q16_ONE;
    out["merchant_effective_buy_factor_q16"] = procurement_paid > 0
        ? std::clamp<int64_t>(
            procurement_factor_weighted_cash / procurement_paid,
            0, Q16_ONE)
        : Q16_ONE;
    out["merchant_snapshot_saturation_count"] = snapshot_saturation;
    return out;
}


Dictionary NativeEconomyRuntime::explain_cohort_satisfaction(
        int64_t cohort_handle) const {
    Dictionary out;
    int32_t slot = -1;
    if (!_configured ||
        !_population.valid_handle(static_cast<uint64_t>(cohort_handle), slot)) {
        out["ok"] = false;
        out["reason"] = !_configured ? "economy_not_configured"
                                     : "cohort_handle_invalid";
        return out;
    }
    const int32_t cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
    const Signature &signature = _signatures[_population.signature_id[slot]];
    const size_t base = static_cast<size_t>(slot) *
        static_cast<size_t>(SAT_DIM_COUNT);
    PackedInt32Array dim_ids, dim_values, dim_weights, dim_contributions;
    int64_t weighted_total = 0;
    int64_t weight_total = 0;
    int64_t diagnostic_sat = 0;
    for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
        const int64_t value = _population.satisfaction_dims[
            base + static_cast<size_t>(dim)];
        const int64_t weight =
            signature.satisfaction_weights_q16[static_cast<size_t>(dim)];
        dim_ids.push_back(dim);
        dim_values.push_back(static_cast<int32_t>(value));
        dim_weights.push_back(static_cast<int32_t>(weight));
        // The shortfall each dimension contributes to the composite, which is
        // what makes one of them the worst.
        dim_contributions.push_back(static_cast<int32_t>(std::clamp<int64_t>(
            mul_div_sat(Q16_ONE - 1 - value, weight, Q16_ONE, diagnostic_sat),
            0, Q16_ONE)));
        if (weight <= 0) continue;
        weighted_total = saturating_add(weighted_total,
            saturating_mul(value, weight, diagnostic_sat), diagnostic_sat);
        weight_total = saturating_add(weight_total, weight, diagnostic_sat);
    }
    const int64_t subsistence_q16 = _population.satisfaction_dims[
        base + static_cast<size_t>(SAT_DIM_SUBSISTENCE)];
    const int64_t raw_q16 = weight_total > 0
        ? std::clamp<int64_t>(weighted_total / weight_total, 0, Q16_ONE - 1)
        : Q16_ONE - 1;
    const int64_t ceiling_q16 = saturating_add(subsistence_q16,
        mul_div_sat(Q16_ONE - 1 - subsistence_q16,
                    _satisfaction_subsistence_gate_slack_q16, Q16_ONE,
                    diagnostic_sat), diagnostic_sat);
    out["ok"] = true;
    out["cohort_handle"] = cohort_handle;
    out["cell_index"] = cell;
    out["signature_id"] = static_cast<int32_t>(_population.signature_id[slot]);
    out["profession_id"] = signature.profession_id;
    out["population"] = _population.population[slot];
    out["dim_ids"] = dim_ids;
    out["dim_values_q16"] = dim_values;
    out["dim_weights_q16"] = dim_weights;
    out["dim_contributions_q16"] = dim_contributions;
    out["raw_q16"] = raw_q16;
    out["ceiling_q16"] = ceiling_q16;
    out["composite_q16"] =
        static_cast<int32_t>(_population.composite_satisfaction[slot]);
    out["worst_dimension_id"] = _population.worst_dimension_id[slot] ==
            std::numeric_limits<uint8_t>::max()
        ? -1 : static_cast<int32_t>(_population.worst_dimension_id[slot]);
    out["worst_need_id"] = _population.worst_need_id[slot] ==
            std::numeric_limits<uint16_t>::max()
        ? -1 : static_cast<int32_t>(_population.worst_need_id[slot]);
    out["living_standard_level"] = living_standard_level_for(
        _population.composite_satisfaction[slot]);
    out["social_pressure_level"] = social_pressure_level_for(
        _population.composite_satisfaction[slot]);
    // Raw dimension inputs, so a designer can see why a dimension scored badly
    // rather than only that it did.
    out["income_ema"] = _population.income_ema[slot];
    out["income_baseline_ema"] = _population.income_baseline_ema[slot];
    out["funds"] = _population.funds[slot];
    out["epoch_income"] = _population.epoch_income[slot];
    out["epoch_in_kind_income"] = _population.epoch_in_kind_income[slot];
    out["epoch_tax_paid"] = _population.epoch_tax_paid[slot];
    out["epoch_subsidy_received"] = _population.epoch_subsidy_received[slot];
    out["living_cost_per_capita"] = cell >= 0 && cell < static_cast<int32_t>(
            _cell_living_cost_per_capita.size())
        ? _cell_living_cost_per_capita[cell] : 0;
    out["settlement_tier"] = cell >= 0 && cell < static_cast<int32_t>(
            _settlements.tier.size())
        ? static_cast<int32_t>(_settlements.tier[cell]) : 0;
    out["development_q16"] = cell >= 0 && cell < static_cast<int32_t>(
            _epoch_cell_development_q16.size())
        ? _epoch_cell_development_q16[cell] : 0;
    out["savings_target_months_q16"] = _satisfaction_savings_target_months_q16;
    out["tax_tolerance_q16"] = _satisfaction_tax_tolerance_q16;
    out["subsistence_gate_slack_q16"] =
        _satisfaction_subsistence_gate_slack_q16;
    return out;
}

Dictionary NativeEconomyRuntime::cell_satisfaction_attractiveness(
        int32_t cell_idx) const {
    Dictionary out;
    if (!_configured || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_configured ? "economy_not_configured"
                                     : "cell_index_invalid";
        return out;
    }
    int64_t population = 0;
    int64_t weighted = 0;
    std::array<int64_t, SAT_DIM_COUNT> dim_weighted{};
    int32_t cohort_count = 0;
    _population.for_each_in_cell(cell_idx, [&](int32_t slot) {
        const int64_t people = std::max<int64_t>(0, _population.population[slot]);
        ++cohort_count;
        if (people <= 0) return;
        int64_t diagnostic_sat = 0;
        population = saturating_add(population, people, diagnostic_sat);
        weighted = saturating_add(weighted, saturating_mul(
            _population.composite_satisfaction[slot], people, diagnostic_sat),
            diagnostic_sat);
        const size_t base = static_cast<size_t>(slot) *
            static_cast<size_t>(SAT_DIM_COUNT);
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
            dim_weighted[static_cast<size_t>(dim)] = saturating_add(
                dim_weighted[static_cast<size_t>(dim)],
                saturating_mul(_population.satisfaction_dims[
                    base + static_cast<size_t>(dim)], people, diagnostic_sat),
                diagnostic_sat);
    });
    const int64_t composite_q16 = population > 0
        ? std::clamp<int64_t>(weighted / population, 0, Q16_ONE - 1)
        : Q16_ONE - 1;
    PackedInt32Array dims;
    for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
        dims.push_back(static_cast<int32_t>(population > 0
            ? std::clamp<int64_t>(
                  dim_weighted[static_cast<size_t>(dim)] / population, 0,
                  Q16_ONE - 1)
            : Q16_ONE - 1));
    out["ok"] = true;
    out["cell_index"] = cell_idx;
    out["population"] = population;
    out["cohort_count"] = cohort_count;
    out["composite_q16"] = static_cast<int32_t>(composite_q16);
    out["dim_values_q16"] = dims;
    out["living_standard_level"] = living_standard_level_for(composite_q16);
    out["social_pressure_level"] = social_pressure_level_for(composite_q16);
    out["published_pressure_level"] = cell_idx < static_cast<int32_t>(
            _cell_social_pressure_level.size())
        ? static_cast<int32_t>(_cell_social_pressure_level[cell_idx]) : 0;
    out["development_q16"] = cell_idx < static_cast<int32_t>(
            _epoch_cell_development_q16.size())
        ? _epoch_cell_development_q16[cell_idx] : 0;
    out["living_cost_per_capita"] = cell_idx < static_cast<int32_t>(
            _cell_living_cost_per_capita.size())
        ? _cell_living_cost_per_capita[cell_idx] : 0;
    return out;
}

Dictionary NativeEconomyRuntime::fiscal_snapshot(int64_t country_handle) const {
    Dictionary out;
    const auto found = std::find(
        _epoch_country_handles.begin(), _epoch_country_handles.end(),
        static_cast<uint64_t>(country_handle));
    if (!_configured || found == _epoch_country_handles.end()) {
        out["ok"] = false;
        out["reason"] = !_configured ? "economy_not_configured" :
            "country_handle_invalid";
        return out;
    }
    const int32_t country = static_cast<int32_t>(
        found - _epoch_country_handles.begin());
    PackedStringArray kinds;
    for (const char *kind : {"income", "consumption", "business",
                             "import", "export"})
        kinds.push_back(kind);
    const auto pack = [&](const std::vector<int64_t> &source) {
        PackedInt64Array values;
        values.resize(NativeCountryRuntime::TAX_KIND_COUNT);
        for (int32_t kind = 0;
             kind < NativeCountryRuntime::TAX_KIND_COUNT; ++kind) {
            const size_t index = static_cast<size_t>(country) *
                NativeCountryRuntime::TAX_KIND_COUNT + kind;
            values[kind] = index < source.size() ? source[index] : 0;
        }
        return values;
    };
    const PackedInt64Array bases = pack(_fiscal_last_bases);
    const PackedInt64Array assessed = pack(_fiscal_last_assessed);
    const PackedInt64Array collected = pack(_fiscal_last_collected);
    const PackedInt64Array requests = pack(_fiscal_last_requests);
    const PackedInt64Array reserved = pack(_fiscal_last_reserved);
    const PackedInt64Array paid = pack(_fiscal_last_paid);
    const PackedInt64Array unmet = pack(_fiscal_last_unmet);
    PackedInt32Array fulfillment_q16;
    fulfillment_q16.resize(NativeCountryRuntime::TAX_KIND_COUNT);
    for (int32_t kind = 0;
         kind < NativeCountryRuntime::TAX_KIND_COUNT; ++kind) {
        fulfillment_q16[kind] = requests[kind] <= 0
            ? (reserved[kind] <= 0 ? 0 : Q16_ONE)
            : static_cast<int32_t>(std::clamp<int64_t>(
                (paid[kind] * Q16_ONE) / requests[kind], 0, Q16_ONE));
    }
    out["ok"] = true;
    out["country_handle"] = country_handle;
    out["sample_day"] = _sample_day;
    out["tax_policy_version"] = static_cast<int64_t>(
        _epoch_tax_policy_version);
    out["tax_kinds"] = kinds;
    out["tax_base"] = bases;
    out["assessed"] = assessed;
    out["collected"] = collected;
    out["subsidy_requested"] = requests;
    out["subsidy_reserved"] = reserved;
    out["subsidy_paid"] = paid;
    out["subsidy_unmet"] = unmet;
    out["fulfillment_q16"] = fulfillment_q16;
    out["cumulative_tax_base"] = pack(_fiscal_cumulative_bases);
    out["cumulative_collected"] = pack(_fiscal_cumulative_collected);
    out["cumulative_subsidy_requested"] =
        pack(_fiscal_cumulative_requests);
    out["cumulative_subsidy_paid"] = pack(_fiscal_cumulative_paid);
    const size_t import_summary = static_cast<size_t>(country) *
        NativeCountryRuntime::TAX_KIND_COUNT + NativeCountryRuntime::TAX_IMPORT;
    const size_t export_summary = static_cast<size_t>(country) *
        NativeCountryRuntime::TAX_KIND_COUNT + NativeCountryRuntime::TAX_EXPORT;
    const int64_t tariff_events =
        import_summary < _fiscal_last_events.size()
            ? _fiscal_last_events[import_summary] : 0;
    const int64_t export_events =
        export_summary < _fiscal_last_events.size()
            ? _fiscal_last_events[export_summary] : 0;
    PackedInt64Array tariff_event_counts;
    tariff_event_counts.resize(NativeCountryRuntime::TAX_KIND_COUNT);
    tariff_event_counts[NativeCountryRuntime::TAX_IMPORT] = tariff_events;
    tariff_event_counts[NativeCountryRuntime::TAX_EXPORT] = export_events;
    out["tariff_event_counts"] = tariff_event_counts;
    out["tariff_events"] = tariff_events + export_events;
    out["tariffs_active"] = tariff_events > 0 || export_events > 0;
    return out;
}

Dictionary NativeEconomyRuntime::country_trade_snapshot(
        int64_t country_handle, const String &view, int32_t offset,
        int32_t limit) const {
    Dictionary out;
    if (_country_runtime == nullptr ||
        !_country_runtime->valid_handle(country_handle)) {
        out["ok"] = false;
        out["reason"] = "country_handle_invalid";
        return out;
    }
    const auto found = std::find(_epoch_country_handles.begin(),
        _epoch_country_handles.end(), static_cast<uint64_t>(country_handle));
    if (!_configured || found == _epoch_country_handles.end()) {
        out["ok"] = false;
        out["reason"] = !_configured ? "economy_not_configured" :
            "country_handle_invalid";
        return out;
    }
    const int32_t country = static_cast<int32_t>(
        found - _epoch_country_handles.begin());
    const int32_t page_limit = std::clamp(limit, 1, 64);
    const int32_t page_offset = std::max(0, offset);
    out["ok"] = true;
    out["country_handle"] = country_handle;
    out["view"] = view;
    out["revision"] = static_cast<int64_t>(_country_trade_revision);
    if (view == "summary") {
        const auto fiscal_value = [&](int32_t kind, const std::vector<int64_t> &values) {
            const size_t index = static_cast<size_t>(country) *
                NativeCountryRuntime::TAX_KIND_COUNT + kind;
            return index < values.size() ? values[index] : int64_t{0};
        };
        const int64_t imports = fiscal_value(NativeCountryRuntime::TAX_IMPORT,
            _fiscal_last_bases);
        const int64_t exports = fiscal_value(NativeCountryRuntime::TAX_EXPORT,
            _fiscal_last_bases);
        const int64_t tariff_income = fiscal_value(
            NativeCountryRuntime::TAX_IMPORT, _fiscal_last_collected) +
            fiscal_value(NativeCountryRuntime::TAX_EXPORT, _fiscal_last_collected) -
            fiscal_value(NativeCountryRuntime::TAX_IMPORT, _fiscal_last_paid) -
            fiscal_value(NativeCountryRuntime::TAX_EXPORT, _fiscal_last_paid);
        out["previous_import_base"] = imports;
        out["previous_export_base"] = exports;
        out["previous_net_export_base"] = exports - imports;
        out["previous_tariff_net_income"] = tariff_income;
        out["cumulative_import_base"] = fiscal_value(
            NativeCountryRuntime::TAX_IMPORT, _fiscal_cumulative_bases);
        out["cumulative_export_base"] = fiscal_value(
            NativeCountryRuntime::TAX_EXPORT, _fiscal_cumulative_bases);
        out["cumulative_tariff_net_income"] =
            fiscal_value(NativeCountryRuntime::TAX_IMPORT,
                _fiscal_cumulative_collected) +
            fiscal_value(NativeCountryRuntime::TAX_EXPORT,
                _fiscal_cumulative_collected) -
            fiscal_value(NativeCountryRuntime::TAX_IMPORT,
                _fiscal_cumulative_paid) -
            fiscal_value(NativeCountryRuntime::TAX_EXPORT,
                _fiscal_cumulative_paid);
        return out;
    }
    if (view == "goods") {
        std::vector<int32_t> fallback_rows;
        const std::vector<int32_t> *rows = nullptr;
        if (country < static_cast<int32_t>(_country_good_display_rows.size()) &&
            country < static_cast<int32_t>(_country_good_display_dirty.size()) &&
            _country_good_display_dirty[static_cast<size_t>(country)] == 0) {
            rows = &_country_good_display_rows[static_cast<size_t>(country)];
        } else {
            for (int32_t i = 0; i < static_cast<int32_t>(
                    _country_good_trade.countries.size()); ++i)
                if (_country_good_trade.countries[i] == country)
                    fallback_rows.push_back(i);
            std::sort(fallback_rows.begin(), fallback_rows.end(),
                [&](int32_t a, int32_t b) {
                    if (_country_good_trade.goods[a] !=
                            _country_good_trade.goods[b])
                        return _country_good_trade.goods[a] <
                            _country_good_trade.goods[b];
                    return a < b;
                });
            rows = &fallback_rows;
        }
        const int32_t total = static_cast<int32_t>(rows->size());
        const int32_t begin = std::min(page_offset, total);
        const int32_t end = std::min(total, begin + page_limit);
        PackedInt32Array goods;
        PackedInt64Array imports, exports, import_base, export_base,
            import_tariff, export_tariff, cumulative_imports,
            cumulative_exports, cumulative_import_base, cumulative_export_base,
            cumulative_import_tariff, cumulative_export_tariff;
        for (int32_t p = begin; p < end; ++p) {
            const int32_t i = (*rows)[static_cast<size_t>(p)];
            goods.push_back(_country_good_trade.goods[i]);
            const bool current_batch = i < static_cast<int32_t>(
                _country_good_trade.batch_epoch.size()) &&
                _country_good_trade.batch_epoch[i] == _epoch_id;
            imports.push_back(current_batch ?
                _country_good_trade.batch_import_quantity[i] : 0);
            exports.push_back(current_batch ?
                _country_good_trade.batch_export_quantity[i] : 0);
            import_base.push_back(current_batch ?
                _country_good_trade.batch_import_base[i] : 0);
            export_base.push_back(current_batch ?
                _country_good_trade.batch_export_base[i] : 0);
            import_tariff.push_back(current_batch ?
                _country_good_trade.batch_import_tariff[i] : 0);
            export_tariff.push_back(current_batch ?
                _country_good_trade.batch_export_tariff[i] : 0);
            cumulative_imports.push_back(_country_good_trade.import_quantity[i]);
            cumulative_exports.push_back(_country_good_trade.export_quantity[i]);
            cumulative_import_base.push_back(_country_good_trade.import_base[i]);
            cumulative_export_base.push_back(_country_good_trade.export_base[i]);
            cumulative_import_tariff.push_back(_country_good_trade.import_tariff[i]);
            cumulative_export_tariff.push_back(_country_good_trade.export_tariff[i]);
        }
        out["total"] = total;
        out["offset"] = begin;
        out["limit"] = page_limit;
        out["has_more"] = end < total;
        out["goods"] = goods;
        out["import_quantity"] = imports;
        out["export_quantity"] = exports;
        out["import_base"] = import_base;
        out["export_base"] = export_base;
        out["import_tariff"] = import_tariff;
        out["export_tariff"] = export_tariff;
        out["cumulative_import_quantity"] = cumulative_imports;
        out["cumulative_export_quantity"] = cumulative_exports;
        out["cumulative_import_base"] = cumulative_import_base;
        out["cumulative_export_base"] = cumulative_export_base;
        out["cumulative_import_tariff"] = cumulative_import_tariff;
        out["cumulative_export_tariff"] = cumulative_export_tariff;
        return out;
    }
    if (view == "partners") {
        std::vector<int32_t> fallback_rows;
        const std::vector<int32_t> *rows = nullptr;
        if (country < static_cast<int32_t>(
                _country_partner_display_rows.size()) &&
            country < static_cast<int32_t>(
                _country_partner_display_dirty.size()) &&
            _country_partner_display_dirty[static_cast<size_t>(country)] == 0) {
            rows = &_country_partner_display_rows[static_cast<size_t>(country)];
        } else {
            for (int32_t i = 0; i < static_cast<int32_t>(
                    _country_partner_trade.countries.size()); ++i)
                if (_country_partner_trade.countries[i] == country)
                    fallback_rows.push_back(i);
            std::sort(fallback_rows.begin(), fallback_rows.end(),
                [&](int32_t a, int32_t b) {
                    if (_country_partner_trade.partners[a] !=
                            _country_partner_trade.partners[b])
                        return _country_partner_trade.partners[a] <
                            _country_partner_trade.partners[b];
                    return a < b;
                });
            rows = &fallback_rows;
        }
        const int32_t total = static_cast<int32_t>(rows->size());
        const int32_t begin = std::min(page_offset, total);
        const int32_t end = std::min(total, begin + page_limit);
        PackedInt32Array partners;
        PackedInt64Array partner_handles;
        PackedInt64Array imports, exports, import_base, export_base, orders,
            cumulative_imports, cumulative_exports, cumulative_import_base,
            cumulative_export_base, cumulative_orders;
        for (int32_t p = begin; p < end; ++p) {
            const int32_t i = (*rows)[static_cast<size_t>(p)];
            partners.push_back(_country_partner_trade.partners[i]);
            const int32_t partner_slot = _country_partner_trade.partners[i];
            partner_handles.push_back(
                partner_slot >= 0 && partner_slot < static_cast<int32_t>(
                    _epoch_country_handles.size())
                    ? static_cast<int64_t>(_epoch_country_handles[partner_slot]) : 0);
            const bool current_batch = i < static_cast<int32_t>(
                _country_partner_trade.batch_epoch.size()) &&
                _country_partner_trade.batch_epoch[i] == _epoch_id;
            imports.push_back(current_batch ?
                _country_partner_trade.batch_import_quantity[i] : 0);
            exports.push_back(current_batch ?
                _country_partner_trade.batch_export_quantity[i] : 0);
            import_base.push_back(current_batch ?
                _country_partner_trade.batch_import_base[i] : 0);
            export_base.push_back(current_batch ?
                _country_partner_trade.batch_export_base[i] : 0);
            orders.push_back(current_batch ?
                _country_partner_trade.batch_order_count[i] : 0);
            cumulative_imports.push_back(_country_partner_trade.import_quantity[i]);
            cumulative_exports.push_back(_country_partner_trade.export_quantity[i]);
            cumulative_import_base.push_back(_country_partner_trade.import_base[i]);
            cumulative_export_base.push_back(_country_partner_trade.export_base[i]);
            cumulative_orders.push_back(_country_partner_trade.order_count[i]);
        }
        out["total"] = total;
        out["offset"] = begin;
        out["limit"] = page_limit;
        out["has_more"] = end < total;
        out["partners"] = partners;
        out["partner_handles"] = partner_handles;
        out["import_quantity"] = imports;
        out["export_quantity"] = exports;
        out["import_base"] = import_base;
        out["export_base"] = export_base;
        out["order_count"] = orders;
        out["cumulative_import_quantity"] = cumulative_imports;
        out["cumulative_export_quantity"] = cumulative_exports;
        out["cumulative_import_base"] = cumulative_import_base;
        out["cumulative_export_base"] = cumulative_export_base;
        out["cumulative_order_count"] = cumulative_orders;
        return out;
    }
    out["ok"] = false;
    out["reason"] = "country_trade_view_invalid";
    return out;
}


Dictionary NativeEconomyRuntime::building_cell_snapshot(int32_t cell_idx) const {
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
    out["ok"] = true;
    out["state_day"] = _cell_last_settlement_day[cell_idx];
    out["age_days"] = std::max<int64_t>(0,
        _current_day - _cell_last_settlement_day[cell_idx]);
    out["settlement_generation"] = static_cast<int64_t>(
        _cell_settlement_generation[cell_idx]);
    out["epoch_id"] = _epoch_id;
    out["period_days"] = std::max(1, _epoch_days);
    PackedStringArray type_ids;
    PackedInt64Array type_counts;
    PackedInt64Array wage_per_employee_per_day;
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
        wage_per_employee_per_day.push_back(type.wage_per_employee_per_day);
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
    PackedInt64Array employee_reference_wages;
    PackedInt64Array employee_contract_wages;
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
    PackedInt32Array last_margin_gap_q16;
    PackedInt32Array planned_utilization_q16;
    PackedInt64Array last_base_wages_due;
    PackedInt64Array last_base_wages_paid;
    PackedInt64Array last_bonus_due;
    PackedInt64Array last_bonus_paid;
    PackedByteArray wage_suspended;
    PackedInt32Array group_input_selected_offsets;
    PackedInt32Array group_input_selected_good_ids;
    PackedInt32Array family_ownership_offsets;
    PackedInt64Array family_ownership_handles;
    PackedInt64Array family_owned_counts;
    PackedInt64Array family_filled_owner;
    employee_fill_offsets.push_back(0);
    group_input_selected_offsets.push_back(0);
    family_ownership_offsets.push_back(0);
    const int32_t group_begin = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell_idx] : 0;
    const int32_t group_end = _building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)
        ? _building_cell_offsets[cell_idx + 1] : 0;
    auto diagnostic_for_type = [&](int32_t type_id) -> const InvestmentDiagnostic * {
        if (_investment_diagnostic_cell != cell_idx) return nullptr;
        for (const InvestmentDiagnostic &item : _investment_diagnostics) {
            if (item.type_id == type_id) return &item;
        }
        return nullptr;
    };
    for (int32_t group_idx = group_begin; group_idx < group_end; ++group_idx) {
        const BuildingGroup &group = _buildings[group_idx];
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
        employee_tax_retention_q16.push_back(
            projected_employee_tax_retention_q16(group, snapshot_sat));
        filled_owner.push_back(group.filled_owner);
        owner_openings.push_back(std::max<int64_t>(
            0, planned_owner_required - group.filled_owner));
        if (_family_building_offsets.size() == _buildings.size() + 1) {
            for (int32_t p = _family_building_offsets[group_idx];
                 p < _family_building_offsets[group_idx + 1]; ++p) {
                const FamilyBuildingOwnership &ownership =
                    _family_ownerships[_family_building_edge_indices[p]];
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
            employee_reference_wages.push_back(role.reference_wage_per_day);
            employee_contract_wages.push_back(_building_role_contract_wage[role_index]);
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
    for (const PendingConstruction &pending : _pending_construction) {
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
    out["wage_per_employee_per_day_by_type"] = wage_per_employee_per_day;
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
    out["employee_reference_wages_per_day"] = employee_reference_wages;
    out["employee_contract_wages_per_day"] = employee_contract_wages;
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

Dictionary NativeEconomyRuntime::treasury_construction_quotes(
        int64_t country_handle, int32_t cell_idx,
        const PackedInt32Array &requested_type_ids) const {
    Dictionary out;
    out["ok"] = false;
    out["cell_idx"] = cell_idx;
    out["country_handle"] = country_handle;
    out["snapshot_day"] = _current_day;
    out["nonbinding"] = true;
    if (!_bootstrapped || _fatal || _country_runtime == nullptr) {
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" :
            (_fatal ? "economy_fatal" : "country_runtime_required");
        return out;
    }
    if (cell_idx < 0 || cell_idx >= _cell_count ||
        !_country_runtime->valid_handle(country_handle)) {
        out["reason"] = "construction_target_invalid";
        return out;
    }

    PackedInt32Array type_ids;
    PackedByteArray eligible;
    PackedStringArray reason_codes;
    PackedInt64Array cash_required;
    PackedInt64Array treasury_goods_total;
    PackedInt64Array market_goods_total;
    PackedInt32Array material_offsets;
    PackedInt32Array material_good_ids;
    PackedInt64Array material_required;
    PackedInt64Array material_treasury;
    PackedInt64Array material_market;
    PackedInt32Array material_prices;
    material_offsets.push_back(0);

    const int32_t market = _market.cell_to_market[cell_idx];
    const bool owned = _country_runtime->country_handle_for_cell(cell_idx) == country_handle;
    const int32_t country_slot = _country_runtime->country_slot_for_cell(cell_idx);
    const int32_t cost_factor = country_slot >= 0 && country_slot <
            static_cast<int32_t>(_epoch_country_construction_cost_factor_q16.size())
        ? _epoch_country_construction_cost_factor_q16[country_slot] : Q16_ONE;
    std::vector<int64_t> country_stock(_good_ids.size(), 0);
    for (size_t good = 0; good < country_stock.size(); ++good) {
        country_stock[good] = std::max<int64_t>(0,
            _country_runtime->good_for_handle(country_handle,
                static_cast<int32_t>(good)));
    }

    for (int64_t cursor = 0; cursor < requested_type_ids.size(); ++cursor) {
        const int32_t type_id = requested_type_ids[cursor];
        type_ids.push_back(type_id);
        bool can_build = owned;
        std::string reason = owned ? "ok" : "construction_cell_not_owned";
        int64_t quote_cash = 0;
        int64_t quote_treasury = 0;
        int64_t quote_market = 0;
        int64_t quote_sat = 0;
        if (can_build && (type_id < 0 ||
                type_id >= static_cast<int32_t>(_building_types.size()))) {
            can_build = false;
            reason = "construction_target_invalid";
        }
        if (can_build && !building_available(cell_idx, type_id, false)) {
            can_build = false;
            reason = "construction_technology_locked";
        }
        if (can_build && !building_constructible(cell_idx, type_id, false)) {
            can_build = false;
            reason = "construction_obsolete";
        }
        if (can_build && !evaluate_building_conditions(type_id, cell_idx)) {
            can_build = false;
            reason = "construction_conditions_failed";
        }
        if (can_build && !family_free_building_resources_legal(
                cell_idx, type_id, 1)) {
            can_build = false;
            reason = "construction_resource_unavailable";
        }

        if (type_id >= 0 && type_id < static_cast<int32_t>(_building_types.size())) {
            const BuildingType &type = _building_types[type_id];
            std::vector<int32_t> quote_good_ids;
            std::vector<int64_t> quote_required;
            quote_good_ids.reserve(type.construction_count);
            quote_required.reserve(type.construction_count);
            ConstructionMaterialPlan material_plan;
            const bool material_plan_ready = plan_construction_materials(
                cell_idx, type_id, 1, cost_factor, material_plan,
                &country_stock);
            if (!material_plan_ready && can_build) {
                can_build = false;
                reason = "construction_materials_insufficient";
            }
            if (material_plan_ready) {
                quote_good_ids = material_plan.good_ids;
                quote_required = material_plan.quantities;
            } else {
                // Keep a useful quote for locked/invalid entries using the
                // preferred legacy recipe; eligibility remains false above.
                for (int32_t edge = 0; edge < type.construction_count; ++edge) {
                    const GoodAmount &item = _building_construction_goods[
                        type.construction_begin + edge];
                    const int64_t required = std::max<int64_t>(1, mul_div_sat(
                        item.quantity, cost_factor, Q16_ONE, quote_sat));
                    auto found = std::find(quote_good_ids.begin(),
                                           quote_good_ids.end(), item.good_id);
                    if (found == quote_good_ids.end()) {
                        quote_good_ids.push_back(item.good_id);
                        quote_required.push_back(required);
                    } else {
                        const size_t index = static_cast<size_t>(
                            found - quote_good_ids.begin());
                        quote_required[index] = saturating_add(
                            quote_required[index], required, quote_sat);
                    }
                }
            }
            for (size_t item_index = 0; item_index < quote_good_ids.size();
                 ++item_index) {
                const int32_t good_id = quote_good_ids[item_index];
                const int64_t required = quote_required[item_index];
                const int64_t treasury = std::min<int64_t>(required,
                    std::max<int64_t>(0, _country_runtime->good_for_handle(
                        country_handle, good_id)));
                const int64_t shortfall = required - treasury;
                const int64_t local_stock = market >= 0 && market < _market.market_count
                    ? std::max<int64_t>(0, _market.stock[
                        _market.index(market, good_id)]) : 0;
                const int32_t price = market >= 0 && market < _market.market_count
                    ? _market.price[_market.index(market, good_id)] : 0;
                material_good_ids.push_back(good_id);
                material_required.push_back(required);
                material_treasury.push_back(treasury);
                material_market.push_back(shortfall);
                material_prices.push_back(price);
                quote_treasury = saturating_add(
                    quote_treasury, treasury, quote_sat);
                quote_market = saturating_add(
                    quote_market, shortfall, quote_sat);
                quote_cash = saturating_add(quote_cash, mul_div_sat(
                    shortfall, price, GOODS_SCALE, quote_sat), quote_sat);
                if (can_build && local_stock < shortfall) {
                    can_build = false;
                    reason = "construction_materials_insufficient";
                }
            }
        }
        if (can_build && quote_cash > 0 &&
            (_merchant_offsets.size() != static_cast<size_t>(_cell_count + 1) ||
             _merchant_offsets[cell_idx] >= _merchant_offsets[cell_idx + 1])) {
            can_build = false;
            reason = "construction_market_unavailable";
        }
        if (can_build && _country_runtime->cash_for_handle(country_handle) < quote_cash) {
            can_build = false;
            reason = "construction_treasury_cash_insufficient";
        }
        eligible.push_back(can_build ? 1 : 0);
        reason_codes.push_back(String(reason.c_str()));
        cash_required.push_back(quote_cash);
        treasury_goods_total.push_back(quote_treasury);
        market_goods_total.push_back(quote_market);
        material_offsets.push_back(material_good_ids.size());
    }

    out["ok"] = true;
    out["type_ids"] = type_ids;
    out["eligible"] = eligible;
    out["reason_codes"] = reason_codes;
    out["cash_required"] = cash_required;
    out["treasury_goods_used"] = treasury_goods_total;
    out["market_goods_used"] = market_goods_total;
    out["material_offsets"] = material_offsets;
    out["material_good_ids"] = material_good_ids;
    out["material_required"] = material_required;
    out["material_treasury"] = material_treasury;
    out["material_market"] = material_market;
    out["material_prices"] = material_prices;
    return out;
}

Dictionary NativeEconomyRuntime::construction_command_receipts(
        int64_t after_receipt_id, int32_t limit) const {
    Dictionary out;
    limit = std::clamp(limit, 1, 256);
    Array receipts;
    int64_t last_receipt_id = after_receipt_id;
    for (const ConstructionCommandReceipt &receipt :
         _committed_construction_receipts) {
        if (receipt.receipt_id <= after_receipt_id) continue;
        Dictionary row;
        row["receipt_id"] = receipt.receipt_id;
        row["sequence"] = receipt.sequence;
        row["effective_day"] = receipt.effective_day;
        row["settled_day"] = receipt.settled_day;
        row["country_handle"] = static_cast<int64_t>(receipt.country_handle);
        row["cell_idx"] = receipt.cell;
        row["type_id"] = receipt.type_id;
        row["ok"] = receipt.ok;
        row["code"] = String(receipt.code.c_str());
        row["cash_paid"] = receipt.cash_paid;
        row["treasury_goods_used"] = receipt.treasury_goods_used;
        row["market_goods_used"] = receipt.market_goods_used;
        receipts.push_back(row);
        last_receipt_id = receipt.receipt_id;
        if (receipts.size() >= limit) break;
    }
    out["ok"] = true;
    out["receipts"] = receipts;
    out["count"] = receipts.size();
    out["last_receipt_id"] = last_receipt_id;
    return out;
}

Dictionary NativeEconomyRuntime::family_cell_snapshot(
        int32_t cell_idx, int32_t offset, int32_t limit) const {
    Dictionary out;
    out["cell_idx"] = cell_idx;
    out["committed"] = !_epoch_active && !_fatal;
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" :
            "cell_out_of_range";
        return out;
    }
    offset = std::max(0, offset);
    limit = std::clamp(limit, 1, 256);
    std::vector<int32_t> indices;
    if (_family_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)) {
        for (int32_t p = _family_cell_offsets[cell_idx];
             p < _family_cell_offsets[cell_idx + 1]; ++p)
            indices.push_back(_family_cell_indices[p]);
    }
    std::sort(indices.begin(), indices.end(), [&](int32_t a, int32_t b) {
        const uint64_t ah = _families.handle_for_index(a);
        const uint64_t bh = _families.handle_for_index(b);
        const int64_t ap = family_population(ah);
        const int64_t bp = family_population(bh);
        return ap != bp ? ap > bp : _families.stable_id[a] <
            _families.stable_id[b];
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
        const uint64_t handle = _families.handle_for_index(index);
        handles.push_back(static_cast<int64_t>(handle));
        stable_ids.push_back(_families.stable_id[index]);
        const int32_t surname = _families.surname_id[index];
        surnames.push_back(surname >= 0 && surname < static_cast<int32_t>(
            _family_surname_text.size()) ? from_utf8(
                _family_surname_text[surname]) : String());
        disambiguators.push_back(static_cast<int32_t>(
            _families.surname_disambiguator[index]));
        populations.push_back(family_population(handle));
        cash_claims.push_back(family_cash_claim(handle));
        owned_buildings.push_back(family_owned_buildings(handle));
        home_cells.push_back(_families.home_cell[index]);
        origin_cells.push_back(_families.origin_cell[index]);
        origin_ethnicities.push_back(_families.origin_ethnicity[index]);
        culture_groups.push_back(_families.culture_group_id[index]);
        notable_person_counts.push_back(_person_family_offsets.size() ==
                _families.active.size() + 1
            ? _person_family_offsets[index + 1] - _person_family_offsets[index]
            : 0);
        int32_t prestige = 0, score = 0;
        for (int32_t branch = 0; branch < static_cast<int32_t>(
                _family_influences.active.size()); ++branch) {
            if (_family_influences.active[branch] != 0 &&
                _family_influences.family_handle[branch] == handle &&
                _family_influences.cell[branch] == cell_idx) {
                prestige = _family_influences.prestige_level[branch];
                score = _family_influences.score_q16[branch];
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
        const auto trait_it = std::lower_bound(_family_trait_ids.begin(),
            _family_trait_ids.end(), keys[i]);
        int32_t family = -1;
        if (operations[i] < 1 || operations[i] > 3 ||
            trait_it == _family_trait_ids.end() || *trait_it != keys[i] ||
            !_families.valid_handle(static_cast<uint64_t>(handles[i]), family) ||
            days[i] < 0) {
            out["ok"] = false;
            out["reason"] = "family_trait_command_entry_invalid";
            return out;
        }
        const int32_t trait_id = static_cast<int32_t>(
            trait_it - _family_trait_ids.begin());
        if (operations[i] != 2 &&
            (strengths[i] < _family_trait_strength_min_q16[trait_id] ||
             strengths[i] > _family_trait_strength_max_q16[trait_id] ||
             (strengths[i] - _family_trait_strength_min_q16[trait_id]) %
                 _family_trait_strength_step_q16[trait_id] != 0)) {
            out["ok"] = false;
            out["reason"] = "family_trait_command_strength_invalid";
            return out;
        }
        commands.push_back({operations[i], static_cast<uint64_t>(handles[i]),
            trait_id, strengths[i], days[i], priorities[i], sequences[i],
            ++_next_submit_order});
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
    if (!_bootstrapped || !_families.valid_handle(handle, index)) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" :
            "family_handle_invalid";
        return out;
    }
    std::vector<int64_t> profession_people(_profession_ids.size(), 0);
    std::vector<int64_t> profession_owner(_profession_ids.size(), 0);
    std::vector<int64_t> profession_employee(_profession_ids.size(), 0);
    const bool member_csr_ready = _family_member_offsets.size() ==
        _families.active.size() + 1;
    const int32_t member_begin = member_csr_ready
        ? _family_member_offsets[index] : 0;
    const int32_t member_end = member_csr_ready
        ? _family_member_offsets[index + 1]
        : static_cast<int32_t>(_family_memberships.size());
    for (int32_t p = member_begin; p < member_end; ++p) {
        const FamilyMembershipEdge &edge = _family_memberships[
            member_csr_ready ? _family_member_edge_indices[p] : p];
        if (edge.family_handle != handle) continue;
        int32_t slot = -1;
        if (!_population.valid_handle(edge.cohort_handle, slot)) continue;
        const int32_t signature = static_cast<int32_t>(
            _population.signature_id[slot]);
        const int32_t profession = _signatures[signature].profession_id;
        profession_people[profession] += edge.people;
        profession_owner[profession] += edge.owner_employed;
        profession_employee[profession] += edge.employee_employed;
    }
    int64_t transit_population = 0;
    for (size_t expedition = 0; expedition < _family_expeditions.active.size(); ++expedition) {
        if (_family_expeditions.active[expedition] == 0 ||
            _family_expeditions.family_handle[expedition] != handle) continue;
        transit_population += _family_expeditions.population[expedition];
        const uint32_t begin = _family_expeditions.payload_begin[expedition];
        const uint32_t count = _family_expeditions.payload_count[expedition];
        for (uint32_t p = 0; p < count; ++p) {
            const FamilyExpeditionPayload &payload =
                _family_expedition_payloads[begin + p];
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
    int64_t asset_sat = 0;
    const bool owned_csr_ready = _family_owned_offsets.size() ==
        _families.active.size() + 1;
    const int32_t owned_begin = owned_csr_ready
        ? _family_owned_offsets[index] : 0;
    const int32_t owned_end = owned_csr_ready
        ? _family_owned_offsets[index + 1]
        : static_cast<int32_t>(_family_ownerships.size());
    for (int32_t p = owned_begin; p < owned_end; ++p) {
        const FamilyBuildingOwnership &ownership = _family_ownerships[
            owned_csr_ready ? _family_owned_edge_indices[p] : p];
        if (ownership.family_handle != handle) continue;
        const int32_t group = building_index_for_handle(ownership.building_handle);
        if (group < 0 || _buildings[group].count <= 0) continue;
        asset_value += mul_div_sat(std::max<int64_t>(
            _buildings[group].last_expected_revenue,
            _buildings[group].last_operating_cost), ownership.owned_count,
            _buildings[group].count, asset_sat);
    }
    const int64_t cash = family_cash_claim(handle);
    const int32_t surname = _families.surname_id[index];
    out["ok"] = true;
    out["family_handle"] = family_handle_value;
    out["stable_id"] = _families.stable_id[index];
    out["surname_pack_id"] = from_utf8(_family_surname_pack_id);
    out["surname_id"] = surname >= 0 ? from_utf8(
        _family_surname_ids[surname]) : String();
    out["surname"] = surname >= 0 ? from_utf8(
        _family_surname_text[surname]) : String();
    out["surname_disambiguator"] = static_cast<int32_t>(
        _families.surname_disambiguator[index]);
    out["founded_day"] = _families.founded_day[index];
    out["home_cell"] = _families.home_cell[index];
    out["origin_cell"] = _families.origin_cell[index];
    out["origin_ethnicity_id"] = _families.origin_ethnicity[index];
    out["culture_group_id"] = _families.culture_group_id[index];
    out["culture_group_stable_id"] = _families.culture_group_id[index] >= 0 &&
        _families.culture_group_id[index] < static_cast<int32_t>(
            _family_culture_group_ids.size())
        ? from_utf8(_family_culture_group_ids[_families.culture_group_id[index]]) : String();
    out["culture_group_display_name"] = _families.culture_group_id[index] >= 0 &&
        _families.culture_group_id[index] < static_cast<int32_t>(
            _family_culture_group_display_names.size())
        ? from_utf8(_family_culture_group_display_names[_families.culture_group_id[index]]) : String();
    out["culture_group_naming_format"] = _families.culture_group_id[index] >= 0 &&
        _families.culture_group_id[index] < static_cast<int32_t>(
            _family_culture_group_naming_formats.size())
        ? from_utf8(_family_culture_group_naming_formats[_families.culture_group_id[index]]) : String();
    out["culture_group_separator"] = _families.culture_group_id[index] >= 0 &&
        _families.culture_group_id[index] < static_cast<int32_t>(
            _family_culture_group_separators.size())
        ? from_utf8(_family_culture_group_separators[_families.culture_group_id[index]]) : String();
    out["culture_group_suffix"] = _families.culture_group_id[index] >= 0 &&
        _families.culture_group_id[index] < static_cast<int32_t>(
            _family_culture_group_suffixes.size())
        ? from_utf8(_family_culture_group_suffixes[_families.culture_group_id[index]]) : String();
    out["decline_reviews"] = _families.decline_reviews[index];
    out["population"] = family_population(handle);
    out["transit_population"] = transit_population;
    out["cash_claim"] = cash;
    out["productive_asset_value"] = asset_value;
    out["net_worth"] = cash + asset_value;
    out["owned_buildings"] = family_owned_buildings(handle);
    out["profession_ids"] = professions;
    out["profession_people"] = people;
    out["profession_owner_employed"] = owners;
    out["profession_employee_employed"] = employees;
    out["notable_person_count"] = _person_family_offsets.size() ==
            _families.active.size() + 1
        ? _person_family_offsets[index + 1] - _person_family_offsets[index] : 0;
    out["trait_count"] = static_cast<int32_t>(std::count_if(
        _family_traits.begin(), _family_traits.end(),
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
    if (!_families.valid_handle(handle, family)) {
        out["ok"] = false;
        out["reason"] = "family_handle_invalid";
        return out;
    }
    PackedStringArray keys, names;
    PackedInt32Array strengths, behavior_offsets, behavior_axes,
        behavior_selector_kinds, behavior_selector_ids, behavior_factors;
    PackedByteArray core;
    behavior_offsets.push_back(0);
    for (const FamilyTraitRoll &roll : _family_traits) {
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
    out["trait_catalog_version"] = _family_trait_catalog_version;
    out["trait_catalog_hash"] = _family_trait_catalog_hash;
    out["trait_keys"] = keys;
    out["display_names"] = names;
    out["strength_q16"] = strengths;
    out["core"] = core;
    out["behavior_offsets"] = behavior_offsets;
    out["behavior_axes"] = behavior_axes;
    out["behavior_selector_kinds"] = behavior_selector_kinds;
    out["behavior_selector_ids"] = behavior_selector_ids;
    out["behavior_factors_q16"] = behavior_factors;
    return out;
}

Dictionary NativeEconomyRuntime::family_branch_effects(
        int64_t family_handle_value, int32_t cell) const {
    Dictionary out;
    const uint64_t family_handle = static_cast<uint64_t>(family_handle_value);
    int32_t family = -1, branch = -1;
    if (!_families.valid_handle(family_handle, family)) {
        out["ok"] = false;
        out["reason"] = "family_handle_invalid";
        return out;
    }
    for (int32_t i = 0; i < static_cast<int32_t>(
            _family_influences.active.size()); ++i) {
        if (_family_influences.active[i] != 0 &&
            _family_influences.family_handle[i] == family_handle &&
            _family_influences.cell[i] == cell) {
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
        _family_influences.handle_for_index(branch);
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
    out["branch_stable_id"] = _family_influences.stable_id[branch];
    out["cell_idx"] = cell;
    out["population"] = _family_influences.population[branch];
    out["cash_claim"] = _family_influences.cash[branch];
    out["building_asset_value"] = _family_influences.building_asset[branch];
    out["population_share_q16"] =
        _family_influences.population_share_q16[branch];
    out["cash_share_q16"] = _family_influences.cash_share_q16[branch];
    out["building_share_q16"] =
        _family_influences.building_share_q16[branch];
    out["prestige_score_q16"] = _family_influences.score_q16[branch];
    out["satisfaction_q16"] = _family_influences.satisfaction_q16[branch];
    out["prestige_level"] = _family_influences.prestige_level[branch];
    out["pending_target_level"] =
        _family_influences.pending_target_level[branch];
    out["review_streak"] = _family_influences.review_streak[branch];
    out["last_review_day"] = _family_influences.last_review_day[branch];
    out["modifier_definition_keys"] = definition_keys;
    out["modifier_magnitude_q16"] = magnitudes;
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
    if (!_families.valid_handle(handle, index)) {
        out["ok"] = false;
        out["reason"] = "family_handle_invalid";
        return out;
    }
    struct Branch { int32_t cell; int64_t people; int64_t cash; int64_t asset; };
    std::unordered_map<int32_t, Branch> by_cell;
    const bool member_csr_ready = _family_member_offsets.size() ==
        _families.active.size() + 1;
    const int32_t member_begin = member_csr_ready
        ? _family_member_offsets[index] : 0;
    const int32_t member_end = member_csr_ready
        ? _family_member_offsets[index + 1]
        : static_cast<int32_t>(_family_memberships.size());
    for (int32_t p = member_begin; p < member_end; ++p) {
        const FamilyMembershipEdge &edge = _family_memberships[
            member_csr_ready ? _family_member_edge_indices[p] : p];
        if (edge.family_handle != handle) continue;
        int32_t slot = -1;
        if (!_population.valid_handle(edge.cohort_handle, slot)) continue;
        const int32_t cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
        Branch &branch = by_cell[cell];
        branch.cell = cell; branch.people += edge.people;
        branch.cash += edge.cash_claim;
    }
    const bool owned_csr_ready = _family_owned_offsets.size() ==
        _families.active.size() + 1;
    const int32_t owned_begin = owned_csr_ready
        ? _family_owned_offsets[index] : 0;
    const int32_t owned_end = owned_csr_ready
        ? _family_owned_offsets[index + 1]
        : static_cast<int32_t>(_family_ownerships.size());
    for (int32_t p = owned_begin; p < owned_end; ++p) {
        const FamilyBuildingOwnership &edge = _family_ownerships[
            owned_csr_ready ? _family_owned_edge_indices[p] : p];
        if (edge.family_handle != handle) continue;
        const int32_t group = building_index_for_handle(edge.building_handle);
        if (group < 0) continue;
        const int32_t cell = _buildings[group].cell;
        Branch &branch = by_cell[cell];
        branch.cell = cell;
        int64_t sat = 0;
        branch.asset = saturating_add(branch.asset, saturating_mul(
            building_reset_capital_value(_buildings[group]),
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
        building_shares, scores, satisfactions, pending_targets, review_streaks;
    PackedInt64Array branch_handles, branch_stable_ids, populations, cash_claims,
        building_assets, last_review_days;
    for (int32_t i = offset; i < end; ++i) {
        cells.push_back(rows[i].cell);
        populations.push_back(rows[i].people);
        cash_claims.push_back(rows[i].cash);
        building_assets.push_back(rows[i].asset);
        int32_t influence = -1;
        for (int32_t branch = 0; branch < static_cast<int32_t>(
                _family_influences.active.size()); ++branch) {
            if (_family_influences.active[branch] != 0 &&
                _family_influences.family_handle[branch] == handle &&
                _family_influences.cell[branch] == rows[i].cell) {
                influence = branch;
                break;
            }
        }
        branch_handles.push_back(influence >= 0 ? static_cast<int64_t>(
            _family_influences.handle_for_index(influence)) : 0);
        branch_stable_ids.push_back(influence >= 0
            ? _family_influences.stable_id[influence] : 0);
        prestige_levels.push_back(influence >= 0
            ? _family_influences.prestige_level[influence] : 0);
        population_shares.push_back(influence >= 0
            ? _family_influences.population_share_q16[influence] : 0);
        cash_shares.push_back(influence >= 0
            ? _family_influences.cash_share_q16[influence] : 0);
        building_shares.push_back(influence >= 0
            ? _family_influences.building_share_q16[influence] : 0);
        scores.push_back(influence >= 0
            ? _family_influences.score_q16[influence] : 0);
        satisfactions.push_back(influence >= 0
            ? _family_influences.satisfaction_q16[influence] : 0);
        pending_targets.push_back(influence >= 0
            ? _family_influences.pending_target_level[influence] : 0);
        review_streaks.push_back(influence >= 0
            ? _family_influences.review_streak[influence] : 0);
        last_review_days.push_back(influence >= 0
            ? _family_influences.last_review_day[influence] : -1);
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
    return out;
}

Dictionary NativeEconomyRuntime::family_industries(
        int64_t family_handle_value, int32_t offset, int32_t limit) const {
    Dictionary out;
    const uint64_t handle = static_cast<uint64_t>(family_handle_value);
    int32_t index = -1;
    if (!_families.valid_handle(handle, index)) {
        out["ok"] = false; out["reason"] = "family_handle_invalid";
        return out;
    }
    std::vector<const FamilyBuildingOwnership *> rows;
    const bool owned_csr_ready = _family_owned_offsets.size() ==
        _families.active.size() + 1;
    const int32_t owned_begin = owned_csr_ready
        ? _family_owned_offsets[index] : 0;
    const int32_t owned_end = owned_csr_ready
        ? _family_owned_offsets[index + 1]
        : static_cast<int32_t>(_family_ownerships.size());
    for (int32_t p = owned_begin; p < owned_end; ++p) {
        const FamilyBuildingOwnership &edge = _family_ownerships[
            owned_csr_ready ? _family_owned_edge_indices[p] : p];
        if (edge.family_handle == handle) rows.push_back(&edge);
    }
    std::sort(rows.begin(), rows.end(), [&](const auto *a, const auto *b) {
        const int32_t ai = building_index_for_handle(a->building_handle);
        const int32_t bi = building_index_for_handle(b->building_handle);
        const auto ak = ai >= 0 ? std::tuple(_buildings[ai].cell,
            _buildings[ai].type_id, _buildings[ai].owner_signature_id) :
            std::tuple(INT32_MAX, INT32_MAX, INT32_MAX);
        const auto bk = bi >= 0 ? std::tuple(_buildings[bi].cell,
            _buildings[bi].type_id, _buildings[bi].owner_signature_id) :
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
        cells.push_back(_buildings[group].cell);
        types.push_back(_buildings[group].type_id);
        owner_signatures.push_back(_buildings[group].owner_signature_id);
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

Dictionary NativeEconomyRuntime::family_notable_people(
        int64_t family_handle_value, int32_t offset, int32_t limit) const {
    Dictionary out;
    const uint64_t handle = static_cast<uint64_t>(family_handle_value);
    int32_t family = -1;
    if (!_families.valid_handle(handle, family)) {
        out["ok"] = false; out["reason"] = "family_handle_invalid"; return out;
    }
    std::vector<int32_t> rows;
    if (_person_family_offsets.size() == _families.active.size() + 1)
        for (int32_t p = _person_family_offsets[family];
             p < _person_family_offsets[family + 1]; ++p)
            rows.push_back(_person_family_indices[p]);
    offset = std::max(0, offset); limit = std::clamp(limit, 1, 256);
    const int32_t end = std::min<int32_t>(rows.size(), offset + limit);
    PackedInt64Array handles, stable_ids, cash_claims, job_incomes,
        consumption_expenses, building_handles;
    PackedInt32Array given_names, disambiguators, cells, professions, role_indices;
    PackedByteArray job_kinds;
    for (int32_t pos = offset; pos < end; ++pos) {
        const int32_t person = rows[pos];
        int32_t slot = -1;
        const bool cohort_ok = _population.valid_handle(
            _persons.cohort_handle[person], slot);
        const int32_t signature = cohort_ok
            ? static_cast<int32_t>(_population.signature_id[slot]) : -1;
        handles.push_back(static_cast<int64_t>(_persons.handle_for_index(person)));
        stable_ids.push_back(_persons.stable_id[person]);
        given_names.push_back(_persons.given_name_id[person]);
        disambiguators.push_back(static_cast<int32_t>(
            _persons.name_disambiguator[person]));
        cells.push_back(cohort_ok ? _population.page_cell[slot / COHORT_PAGE_SIZE] : -1);
        professions.push_back(signature >= 0 && signature < static_cast<int32_t>(
            _signatures.size()) ? _signatures[signature].profession_id : -1);
        cash_claims.push_back(_persons.cash_claim[person]);
        job_incomes.push_back(_persons.epoch_job_income[person]);
        consumption_expenses.push_back(
            _persons.epoch_consumption_expense[person]);
        building_handles.push_back(static_cast<int64_t>(
            _persons.building_handle[person]));
        job_kinds.push_back(_persons.job_kind[person]);
        role_indices.push_back(_persons.employee_role_index[person]);
    }
    out["ok"] = true; out["family_handle"] = family_handle_value;
    out["total"] = static_cast<int32_t>(rows.size()); out["offset"] = offset;
    out["limit"] = limit; out["has_more"] = end < static_cast<int32_t>(rows.size());
    out["person_handles"] = handles; out["stable_ids"] = stable_ids;
    out["given_name_indices"] = given_names;
    out["name_disambiguators"] = disambiguators; out["cell_indices"] = cells;
    out["profession_ids"] = professions; out["cash_claims"] = cash_claims;
    out["epoch_job_income"] = job_incomes;
    out["epoch_consumption_expense"] = consumption_expenses;
    out["building_handles"] = building_handles; out["job_kinds"] = job_kinds;
    out["employee_role_indices"] = role_indices;
    return out;
}

Dictionary NativeEconomyRuntime::notable_person_snapshot(
        int64_t person_handle_value) const {
    Dictionary out;
    const uint64_t handle = static_cast<uint64_t>(person_handle_value);
    int32_t person = -1;
    if (!_persons.valid_handle(handle, person)) {
        out["ok"] = false; out["reason"] = "person_handle_invalid"; return out;
    }
    int32_t family = -1, slot = -1;
    if (!_families.valid_handle(_persons.family_handle[person], family) ||
        !_population.valid_handle(_persons.cohort_handle[person], slot)) {
        out["ok"] = false; out["reason"] = "person_relation_invalid"; return out;
    }
    const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
    const int32_t profession = signature >= 0 && signature < static_cast<int32_t>(
        _signatures.size()) ? _signatures[signature].profession_id : -1;
    const int32_t surname = _families.surname_id[family];
    const int32_t given = _persons.given_name_id[person];
    const int32_t building = building_index_for_handle(
        _persons.building_handle[person]);
    int64_t family_assets = 0, asset_sat = 0;
    if (_family_owned_offsets.size() == _families.active.size() + 1)
        for (int32_t p = _family_owned_offsets[family];
             p < _family_owned_offsets[family + 1]; ++p) {
            const FamilyBuildingOwnership &ownership = _family_ownerships[
                _family_owned_edge_indices[p]];
            const int32_t group = building_index_for_handle(ownership.building_handle);
            if (group < 0 || _buildings[group].count <= 0) continue;
            family_assets = saturating_add(family_assets, mul_div_sat(
                std::max(_buildings[group].last_expected_revenue,
                         _buildings[group].last_operating_cost),
                ownership.owned_count, _buildings[group].count, asset_sat), asset_sat);
        }
    const int64_t attributed_asset = mul_div_sat(family_assets,
        _persons.family_equity_share_q32[person], Q32_ONE, asset_sat);
    out["ok"] = true; out["person_handle"] = person_handle_value;
    out["stable_id"] = _persons.stable_id[person];
    out["family_handle"] = static_cast<int64_t>(_persons.family_handle[person]);
    out["cohort_handle"] = static_cast<int64_t>(_persons.cohort_handle[person]);
    out["surname_id"] = surname >= 0 ? from_utf8(_family_surname_ids[surname]) : String();
    out["surname"] = surname >= 0 ? from_utf8(_family_surname_text[surname]) : String();
    out["given_name_id"] = given >= 0 ? from_utf8(_person_given_name_ids[given]) : String();
    out["given_name"] = given >= 0 ? from_utf8(_person_given_name_text[given]) : String();
    out["name_disambiguator"] = static_cast<int32_t>(
        _persons.name_disambiguator[person]);
    out["notable_since_day"] = _persons.notable_since_day[person];
    out["cell_idx"] = _population.page_cell[slot / COHORT_PAGE_SIZE];
    out["profession_id"] = profession; out["cash_claim"] = _persons.cash_claim[person];
    out["family_equity_share_q32"] = _persons.family_equity_share_q32[person];
    out["attributed_asset_value"] = attributed_asset;
    out["estimated_net_worth"] = _persons.cash_claim[person] + attributed_asset;
    out["epoch_job_income"] = _persons.epoch_job_income[person];
    out["epoch_business_result"] = _persons.epoch_business_result[person];
    out["epoch_consumption_expense"] = _persons.epoch_consumption_expense[person];
    out["epoch_tax"] = _persons.epoch_tax[person];
    out["income_ema"] = _persons.income_ema[person];
    out["needs_satisfaction_q16"] = _persons.needs_satisfaction[person];
    out["worst_need_id"] = _persons.worst_need_id[person];
    out["building_handle"] = static_cast<int64_t>(_persons.building_handle[person]);
    out["building_type_id"] = building >= 0 ? _buildings[building].type_id : -1;
    out["job_kind"] = _persons.job_kind[person];
    out["employee_role_index"] = _persons.employee_role_index[person];
    out["job_since_day"] = _persons.job_since_day[person];
    out["attribution_model"] = "cohort_realized_attribution_v1";
    out["market_cycle_days"] = locked_market_cycle_days();
    return out;
}

Dictionary NativeEconomyRuntime::notable_person_needs(
        int64_t person_handle_value, int32_t offset, int32_t limit) const {
    Dictionary out;
    const uint64_t handle = static_cast<uint64_t>(person_handle_value);
    int32_t person = -1;
    if (!_persons.valid_handle(handle, person)) {
        out["ok"] = false; out["reason"] = "person_handle_invalid"; return out;
    }
    const int32_t begin = _person_need_offsets.size() == _persons.active.size() + 1
        ? _person_need_offsets[person] : 0;
    const int32_t finish = _person_need_offsets.size() == _persons.active.size() + 1
        ? _person_need_offsets[person + 1] : 0;
    offset = std::max(0, offset); limit = std::clamp(limit, 1, 64);
    const int32_t end = std::min(finish, begin + offset + limit);
    PackedInt32Array need_ids, satisfaction;
    PackedInt64Array desired, spending;
    for (int32_t i = begin + offset; i < end; ++i) {
        need_ids.push_back(_person_needs[i].stable_need_id);
        desired.push_back(_person_needs[i].desired_period_units);
        satisfaction.push_back(_person_needs[i].satisfaction_q16);
        spending.push_back(_person_needs[i].attributed_spend);
    }
    out["ok"] = true; out["person_handle"] = person_handle_value;
    out["total"] = finish - begin; out["offset"] = offset; out["limit"] = limit;
    out["has_more"] = end < finish; out["need_ids"] = need_ids;
    out["desired_period_units"] = desired; out["satisfaction_q16"] = satisfaction;
    out["attributed_spend"] = spending;
    out["attribution_model"] = "cohort_realized_attribution_v1";
    return out;
}

Dictionary NativeEconomyRuntime::building_notable_people(
        int64_t building_handle_value, int32_t offset, int32_t limit) const {
    Dictionary out;
    const int32_t building = building_index_for_handle(
        static_cast<uint64_t>(building_handle_value));
    if (building < 0) {
        out["ok"] = false; out["reason"] = "building_handle_invalid"; return out;
    }
    const int32_t begin = _person_building_offsets.size() == _buildings.size() + 1
        ? _person_building_offsets[building] : 0;
    const int32_t finish = _person_building_offsets.size() == _buildings.size() + 1
        ? _person_building_offsets[building + 1] : 0;
    offset = std::max(0, offset); limit = std::clamp(limit, 1, 256);
    const int32_t end = std::min(finish, begin + offset + limit);
    PackedInt64Array handles;
    PackedInt64Array family_handles;
    PackedInt32Array given_name_indices;
    PackedInt32Array name_disambiguators;
    PackedByteArray job_kinds;
    PackedInt32Array role_indices;
    for (int32_t p = begin + offset; p < end; ++p) {
        const int32_t person = _person_building_indices[p];
        handles.push_back(static_cast<int64_t>(_persons.handle_for_index(person)));
        family_handles.push_back(static_cast<int64_t>(
            _persons.family_handle[person]));
        given_name_indices.push_back(_persons.given_name_id[person]);
        name_disambiguators.push_back(static_cast<int32_t>(
            _persons.name_disambiguator[person]));
        job_kinds.push_back(_persons.job_kind[person]);
        role_indices.push_back(_persons.employee_role_index[person]);
    }
    out["ok"] = true; out["building_handle"] = building_handle_value;
    out["total"] = finish - begin; out["offset"] = offset; out["limit"] = limit;
    out["has_more"] = end < finish; out["person_handles"] = handles;
    out["family_handles"] = family_handles;
    out["given_name_indices"] = given_name_indices;
    out["name_disambiguators"] = name_disambiguators;
    out["job_kinds"] = job_kinds; out["employee_role_indices"] = role_indices;
    return out;
}


Dictionary NativeEconomyRuntime::trade_orders_for_cell(
        int32_t cell_idx, int32_t offset, int32_t limit) const {
    Dictionary out;
    out["cell_idx"] = cell_idx;
    if (!_bootstrapped || cell_idx < 0 || cell_idx >= _cell_count) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" : "cell_out_of_range";
        return out;
    }
    offset = std::max(0, offset);
    limit = std::clamp(limit, 1, 256);
    int32_t total = 0;
    PackedInt64Array order_ids;
    PackedInt32Array directions;
    PackedInt32Array sources;
    PackedInt32Array destinations;
    PackedInt32Array countries;
    PackedInt64Array source_country_handles;
    PackedInt64Array destination_country_handles;
    PackedInt32Array source_country_slots;
    PackedInt32Array destination_country_slots;
    PackedInt64Array departure_days;
    PackedInt64Array arrival_days;
    PackedInt64Array base_cash;
    PackedInt64Array cash_escrow;
    PackedInt64Array capacity_work;
    PackedByteArray order_flags;
    PackedByteArray states;
    PackedByteArray cargo_delivered;
    PackedInt32Array line_offsets;
    PackedInt32Array line_goods;
    PackedInt64Array line_quantities;
    PackedInt32Array line_unit_prices;
    PackedInt32Array line_destination_prices;
    PackedInt64Array line_base_values;
    PackedInt64Array line_retail_values;
    PackedInt64Array line_import_transfers;
    PackedInt64Array line_export_transfers;
    PackedByteArray line_flags;
    line_offsets.push_back(0);
    for (int32_t order = 0; order < _trade_orders.size(); ++order) {
        const bool outbound = _trade_orders.sources[order] == cell_idx;
        const bool inbound = _trade_orders.destinations[order] == cell_idx;
        if (!outbound && !inbound) continue;
        if (total++ < offset || order_ids.size() >= limit) continue;
        order_ids.push_back(_trade_orders.ids[order]);
        directions.push_back(outbound ? -1 : 1);
        sources.push_back(_trade_orders.sources[order]);
        destinations.push_back(_trade_orders.destinations[order]);
        countries.push_back(_trade_orders.countries[order]);
        source_country_handles.push_back(
            static_cast<int64_t>(_trade_orders.source_country_handles[order]));
        destination_country_handles.push_back(
            static_cast<int64_t>(_trade_orders.destination_country_handles[order]));
        source_country_slots.push_back(_trade_orders.source_country_slots[order]);
        destination_country_slots.push_back(
            _trade_orders.destination_country_slots[order]);
        departure_days.push_back(_trade_orders.departure_days[order]);
        arrival_days.push_back(_trade_orders.arrival_days[order]);
        int64_t order_base = 0;
        int64_t query_saturation = 0;
        uint8_t combined_flags = 0;
        cash_escrow.push_back(_trade_orders.cash_escrow[order]);
        capacity_work.push_back(_trade_orders.capacity_work[order]);
        states.push_back(_trade_orders.states[order]);
        cargo_delivered.push_back(_trade_orders.cargo_delivered[order]);
        for (int32_t line = _trade_orders.line_offsets[order];
             line < _trade_orders.line_offsets[order + 1]; ++line) {
            line_goods.push_back(_trade_orders.line_goods[line]);
            line_quantities.push_back(_trade_orders.line_quantities[line]);
            line_unit_prices.push_back(_trade_orders.line_unit_prices[line]);
            line_destination_prices.push_back(
                _trade_orders.line_destination_prices[line]);
            line_base_values.push_back(_trade_orders.line_base_values[line]);
            line_retail_values.push_back(_trade_orders.line_retail_values[line]);
            line_import_transfers.push_back(
                _trade_orders.line_import_transfers[line]);
            line_export_transfers.push_back(
                _trade_orders.line_export_transfers[line]);
            line_flags.push_back(_trade_orders.line_flags[line]);
            order_base = saturating_add(order_base,
                _trade_orders.line_base_values[line], query_saturation);
            combined_flags |= _trade_orders.line_flags[line];
        }
        base_cash.push_back(order_base);
        order_flags.push_back(combined_flags);
        line_offsets.push_back(line_goods.size());
    }
    out["ok"] = true;
    out["offset"] = offset;
    out["limit"] = limit;
    out["total"] = total;
    out["has_more"] = offset + order_ids.size() < total;
    out["order_ids"] = order_ids;
    out["directions"] = directions;
    out["source_cells"] = sources;
    out["destination_cells"] = destinations;
    out["country_slots"] = countries;
    out["source_country_handles"] = source_country_handles;
    out["destination_country_handles"] = destination_country_handles;
    out["source_country_slots"] = source_country_slots;
    out["destination_country_slots"] = destination_country_slots;
    out["departure_days"] = departure_days;
    out["arrival_days"] = arrival_days;
    out["base_cash"] = base_cash;
    out["cash_escrow"] = cash_escrow;
    out["capacity_work"] = capacity_work;
    out["order_flags"] = order_flags;
    out["states"] = states;
    out["cargo_delivered"] = cargo_delivered;
    out["line_offsets"] = line_offsets;
    out["line_good_ids"] = line_goods;
    out["line_quantities"] = line_quantities;
    out["line_unit_prices"] = line_unit_prices;
    out["line_destination_prices"] = line_destination_prices;
    out["line_base_values"] = line_base_values;
    out["line_retail_values"] = line_retail_values;
    out["line_import_transfers"] = line_import_transfers;
    out["line_export_transfers"] = line_export_transfers;
    out["line_flags"] = line_flags;
    return out;
}


} // namespace pk
