#include "economy_runtime.h"
#include "economy_runtime_building_investment_internal.h"
#include "country_api.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <tuple>


namespace pk {

namespace {
// Derived-demand price conduction is on by default. Setting
// PK_ECONOMY_DERIVED_PRICE_CONDUCTION=0 restores the old price formation;
// PK_ECONOMY_DERIVED_STARTUP=0 disables only the investment-side absorption.
// The two switches let a rerun separate "price did not rise" from "price rose
// but the producer still would not start".
bool derived_price_conduction_enabled() {
    static const bool value = [] {
        const char *flag = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_DERIVED_PRICE_CONDUCTION);
        return !(flag && std::strcmp(flag, "0") == 0);
    }();
    return value;
}

bool derived_startup_absorption_enabled() {
    static const bool value = [] {
        const char *flag = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_DERIVED_STARTUP);
        return !(flag && std::strcmp(flag, "0") == 0);
    }();
    return value;
}
} // namespace

bool NativeEconomyRuntime::investment_evaluate_cell_types(
        BuildingInvestmentCellContext &ctx) {
    auto &cell = ctx.cell;
    auto &capture_investment_diagnostics = ctx.capture_investment_diagnostics;
    auto &cell_population = ctx.cell_population;
    auto &cell_profession_population = ctx.cell_profession_population;
    auto &employment_gap = ctx.employment_gap;
    auto &cell_request = ctx.cell_request;
    auto &portfolio = ctx.portfolio;
    auto &portfolio_size = ctx.portfolio_size;
    auto &eligible_but_unfunded = ctx.eligible_but_unfunded;
    auto &market = ctx.market;
    auto &country = ctx.country;
    auto &available_begin = ctx.available_begin;
    auto &available_end = ctx.available_end;
    using Candidate = BuildingInvestmentCellContext::Candidate;
    portfolio = {};
    portfolio_size = 0;
    eligible_but_unfunded = false;
    market = market_store().cell_to_market[cell];
    // Prices, environment and household-good factors stay frozen throughout
    // this cell's candidate evaluation. living_cost_for_signature depends
    // only on the plan and ethnicity, not on the prospective building.
    // Reset per cell (including continuation re-entry), so no generation or
    // catalog-index cache can survive into another market or settlement.
    thread_local std::vector<int64_t> investment_living_cost_cache;
    investment_living_cost_cache.assign(_plans.size() * _ethnicity_ids.size(), -1);
    auto investment_living_cost = [&](int32_t signature_id, int64_t &sat) -> int64_t {
        if (signature_id < 0 || signature_id >= static_cast<int32_t>(_signatures.size()))
            return 0;
        const Signature &signature = _signatures[signature_id];
        if (signature.plan_id < 0 || signature.plan_id >= static_cast<int32_t>(_plans.size()))
            return 0;
        const size_t key = static_cast<size_t>(signature.plan_id) * _ethnicity_ids.size() +
            static_cast<size_t>(signature.ethnicity_id);
        if (key >= investment_living_cost_cache.size())
            return living_cost_for_signature(cell, signature_id, -1, sat);
        int64_t &cached = investment_living_cost_cache[key];
        if (cached >= 0) return cached;
        const int64_t saturation_before = sat;
        const int64_t value = living_cost_for_signature(cell, signature_id, -1, sat);
        // Saturation diagnostics are per evaluation. Exceptional values are
        // recomputed, preserving their original event counts as well.
        if (sat == saturation_before) cached = value;
        return value;
    };
    country = _epoch_cell_country.size() ==
                static_cast<size_t>(_cell_count.get())
            ? _epoch_cell_country[static_cast<size_t>(cell)] : -1;
    available_begin = country >= 0 &&
            country + 1 < static_cast<int32_t>(
                _epoch_country_building_type_offsets.size())
        ? _epoch_country_building_type_offsets[country] : 0;
    available_end = country >= 0 &&
            country + 1 < static_cast<int32_t>(
                _epoch_country_building_type_offsets.size())
        ? _epoch_country_building_type_offsets[country + 1] : 0;
    uint32_t investment_review_stamp = 0;
    bool sparse_mask_ready = false;
    if (_investment_sparse_mode != 0 &&
        _investment_type_stamp.size() == _building_types.size() &&
        _investment_good_stamp.size() == _good_ids.size() &&
        _investment_good_type_offsets.size() == _good_ids.size() + 1) {
        ++_investment_review_stamp_generation;
        if (_investment_review_stamp_generation == 0) {
            std::fill(_investment_type_stamp.begin(),
                      _investment_type_stamp.end(), 0);
            std::fill(_investment_good_stamp.begin(),
                      _investment_good_stamp.end(), 0);
            _investment_review_stamp_generation = 1;
        }
        investment_review_stamp = _investment_review_stamp_generation;
        _investment_good_queue_scratch.clear();
        auto country_type_available = [&](int32_t type_id) {
            const size_t index = country >= 0
                ? static_cast<size_t>(country) * _building_types.size() +
                    static_cast<size_t>(type_id)
                : std::numeric_limits<size_t>::max();
            return index < _epoch_country_building_available.size() &&
                _epoch_country_building_available[index] != 0;
        };
        auto enqueue_good = [&](int32_t good) {
            if (good < 0 || good >= static_cast<int32_t>(_good_ids.size()) ||
                _investment_good_stamp[good] == investment_review_stamp)
                return;
            _investment_good_stamp[good] = investment_review_stamp;
            _investment_good_queue_scratch.push_back(good);
        };
        auto mark_type = [&](int32_t type_id) {
            if (type_id < 0 ||
                type_id >= static_cast<int32_t>(_building_types.size()) ||
                !country_type_available(type_id) ||
                _investment_type_stamp[type_id] == investment_review_stamp)
                return;
            _investment_type_stamp[type_id] = investment_review_stamp;
            const BuildingType &marked_type = _building_types[type_id];
            for (int32_t edge = 0; edge < marked_type.construction_count;
                 ++edge) {
                const int32_t group = marked_type.construction_begin + edge;
                enqueue_good(_building_construction_goods[group].good_id);
                if (group >= 0 && group + 1 < static_cast<int32_t>(
                        _building_construction_candidate_offsets.size())) {
                    for (int32_t candidate =
                             _building_construction_candidate_offsets[group];
                         candidate < _building_construction_candidate_offsets[group + 1];
                         ++candidate) {
                        enqueue_good(_building_construction_candidates[candidate].good_id);
                    }
                }
            }
        };
        const size_t words_per_market =
            (static_cast<size_t>(market_store().good_count.get()) + 63U) / 64U;
        sparse_mask_ready = market >= 0 &&
            words_per_market <=
                _investment_active_good_words.size();
        if (sparse_mask_ready) {
            for (const int32_t good : _investment_active_goods_scratch)
                enqueue_good(good);
            if (_building_cell_offsets.size() ==
                    static_cast<size_t>(_cell_count.get() + 1)) {
                for (int32_t group = _building_cell_offsets[cell];
                     group < _building_cell_offsets[cell + 1]; ++group) {
                    const int32_t local_type = buildings_store().type_id[group];
                    mark_type(local_type);
                    if (local_type < 0 ||
                        local_type >= static_cast<int32_t>(
                            _building_types.size())) continue;
                    const BuildingType &local_outputs =
                        _building_types[local_type];
                    for (int32_t output = 0;
                         output < local_outputs.output_count; ++output) {
                        enqueue_good(_building_outputs[
                            local_outputs.output_begin + output].good_id);
                    }
                }
            }
            if (_pending_construction_cell_offsets.size() ==
                    static_cast<size_t>(_cell_count.get() + 1)) {
                for (int32_t cursor =
                         _pending_construction_cell_offsets[cell];
                     cursor < _pending_construction_cell_offsets[cell + 1];
                     ++cursor) {
                    const int32_t pending_index =
                        _pending_construction_cell_indices[cursor];
                    if (pending_index >= 0 &&
                        pending_index < static_cast<int32_t>(
                            pending_construction_count())) {
                        mark_type(buildings_store().pending_type_id[
                            static_cast<size_t>(pending_index)]);
                    }
                }
            }
            size_t good_cursor = 0;
            while (good_cursor <
                   _investment_good_queue_scratch.size()) {
                const int32_t good =
                    _investment_good_queue_scratch[good_cursor++];
                for (int32_t cursor =
                         _investment_good_type_offsets[good];
                     cursor < _investment_good_type_offsets[good + 1];
                     ++cursor) {
                    mark_type(_investment_good_type_indices[cursor]);
                }
            }
        }
    }
    const bool sparse_full_verification =
        _full_audit_verify_interval_days > 0 &&
        _current_day.get() % _full_audit_verify_interval_days == 0;
    bool sparse_filter_active = _investment_sparse_mode == 2 &&
        !_investment_sparse_runtime_disabled && sparse_mask_ready &&
        !capture_investment_diagnostics && !sparse_full_verification &&
        cell_request.reason != INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP;
    // An empty sparse workset means "no observed signals yet", not
    // "all industries are impossible".  Disable the filter so unlocked
    // greenfield types receive their bounded prior and can bootstrap a
    // previously absent good/profession/building chain.
    if (_investment_active_goods_scratch.empty())
        sparse_filter_active = false;
    if (sparse_filter_active) {
        int32_t selected_available_types = 0;
        const int32_t available_type_count =
            std::max(0, available_end - available_begin);
        for (int32_t available_index = available_begin;
             available_index < available_end; ++available_index) {
            const int32_t type_id =
                _epoch_country_building_type_indices[available_index];
            if (type_id >= 0 &&
                type_id < static_cast<int32_t>(
                    _investment_type_stamp.size()) &&
                _investment_type_stamp[type_id] ==
                    investment_review_stamp) {
                ++selected_available_types;
            }
        }
        if (available_type_count > 0 &&
            static_cast<int64_t>(selected_available_types) * 100 >
                static_cast<int64_t>(available_type_count) * 95) {
            sparse_filter_active = false;
            ++_investment_sparse_dense_fallbacks;
        }
    }
    // Capital-feasibility gate precomputation. A candidate always needs one
    // local sponsor cohort whose transferable funds (funds minus a
    // 30-day living-cost reserve, hence <= raw funds) cover
    // required_capital (>= construction_cost), or merchant credit covering
    // construction_cost outright. When neither can cover even
    // construction_cost, every sponsor search for this (cell, type) is
    // guaranteed to fail; the gate below skips such types after materials
    // pricing and reports them exactly like sponsor-capital rejects.
    // Use the same protected 30-day livelihood reserve as
    // find_entrepreneur_source. Raw cash is too weak a bound at tiny prices:
    // it admits hundreds of bundles whose sponsors cannot transfer a tick.
    int64_t cell_max_sponsor_funds = 0;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        const int64_t funds = std::max<int64_t>(0, population_store().funds[slot]);
        int64_t probe_sat = 0; // same non-authoritative quote as the sponsor search
        const int64_t living_cost = investment_living_cost(
            static_cast<int32_t>(population_store().signature_id[slot]), probe_sat);
        const int64_t reserve = saturating_mul(saturating_mul(living_cost,
            std::max<int64_t>(0, population_store().population[slot]), probe_sat), 30, probe_sat);
        cell_max_sponsor_funds = std::max(cell_max_sponsor_funds,
            std::max<int64_t>(0, funds - reserve));
    });
    int64_t cell_credit_construction_cover = 0;
    if (_merchant_credit_runtime_mode.get() == 2) {
        const int64_t merchant_cash = investment_merchant_cash(cell);
        const int64_t outstanding = investment_outstanding_credit(cell);
        const int64_t exposure = mul_div_sat(merchant_cash,
            _merchant_credit_exposure_q16.get(), Q16_ONE, _saturation_count);
        const int64_t reserve = mul_div_sat(merchant_cash,
            _merchant_procurement_cash_reserve_q16.get(), Q16_ONE,
            _saturation_count);
        cell_credit_construction_cover = std::max<int64_t>(0, std::min(
            exposure - std::min(exposure, outstanding),
            merchant_cash - std::min(merchant_cash, reserve)));
    }
    std::vector<InvestmentIncumbentLane> &incumbent_lanes =
        _investment_incumbent_lanes_scratch;
    incumbent_lanes.clear();
    auto upsert_incumbent_record = [&](const InvestmentIncumbentRecord &rec) {
        if (rec.cell < 0 || rec.output_good < 0 || rec.type_id < 0 ||
            rec.daily_offered_capacity <= 0 || rec.settled_unit_cost <= 0) {
            return;
        }
        for (InvestmentIncumbentRecord &existing :
             _investment_incumbent_records) {
            if (existing.cell == rec.cell &&
                existing.output_good == rec.output_good &&
                existing.type_id == rec.type_id) {
                existing = rec;
                return;
            }
        }
        _investment_incumbent_records.push_back(rec);
    };
    auto push_incumbent_lane = [&](const InvestmentIncumbentLane &lane) {
        if (lane.good_id < 0 || lane.type_id < 0 ||
            lane.daily_offered <= 0 || lane.unit_cost <= 0) return;
        for (InvestmentIncumbentLane &existing : incumbent_lanes) {
            if (existing.good_id == lane.good_id &&
                existing.type_id == lane.type_id) {
                if (lane.unit_cost < existing.unit_cost)
                    existing.unit_cost = lane.unit_cost;
                existing.daily_offered = saturating_add(
                    existing.daily_offered, lane.daily_offered,
                    _saturation_count);
                existing.stealable_capacity = saturating_add(
                    existing.stealable_capacity, lane.stealable_capacity,
                    _saturation_count);
                return;
            }
        }
        incumbent_lanes.push_back(lane);
    };
    // Prefer the persistent settled incumbent table. Current-cycle last_*
    // fields may be zero mid-review and must not erase prior evidence.
    for (const InvestmentIncumbentRecord &rec :
         _investment_incumbent_records) {
        if (rec.cell != cell) continue;
        InvestmentIncumbentLane lane;
        lane.good_id = rec.output_good;
        lane.type_id = rec.type_id;
        lane.unit_cost = rec.settled_unit_cost;
        lane.daily_offered = rec.daily_offered_capacity;
        lane.stealable_capacity = std::max<int64_t>(
            rec.stealable_capacity, rec.daily_offered_capacity);
        lane.owner_fill = rec.owner_fill;
        lane.employee_fill = rec.employee_fill;
        push_incumbent_lane(lane);
    }
    if (_building_cell_offsets.size() ==
            static_cast<size_t>(_cell_count.get() + 1)) {
        const int64_t epoch_days = std::max(1, _epoch_days.get());
        for (int32_t group_index = _building_cell_offsets[cell];
             group_index < _building_cell_offsets[cell + 1];
             ++group_index) {
            const auto group = building_view(static_cast<size_t>(group_index));
            if (group.count <= 0 || group.operating_state == 1 ||
                group.type_id < 0 ||
                group.type_id >= static_cast<int32_t>(
                    _building_types.size())) continue;
            const BuildingType &incumbent_type =
                _building_types[group.type_id];
            const int64_t building_days = saturating_mul(
                group.count, epoch_days, _saturation_count);
            int64_t employee_fill = 0;
            for (int32_t r = 0; r < incumbent_type.employee_count; ++r) {
                const int32_t role_index = group.employee_fill_begin + r;
                if (role_index >= 0 && role_index < static_cast<int32_t>(
                        _building_employee_filled.size())) {
                    employee_fill = saturating_add(employee_fill,
                        std::max<int64_t>(0,
                            _building_employee_filled[role_index]),
                        _saturation_count);
                }
            }
            const int64_t owner_livelihood = saturating_mul(
                living_cost_for_signature(cell, group.owner_signature_id,
                    -1, _saturation_count),
                std::max<int64_t>(0, group.filled_owner), _saturation_count);
            const int64_t period_livelihood = saturating_mul(
                owner_livelihood, epoch_days, _saturation_count);
            const int64_t settled_operating = saturating_sub(
                saturating_add(saturating_add(saturating_add(
                    std::max<int64_t>(0, group.last_input_cost),
                    std::max<int64_t>(0, group.last_base_wages_paid),
                    _saturation_count),
                    std::max<int64_t>(0, group.last_maintenance_cost),
                    _saturation_count),
                    period_livelihood, _saturation_count),
                std::max<int64_t>(0, group.last_in_kind_livelihood_value),
                _saturation_count);
            for (int32_t output = 0;
                 output < incumbent_type.output_count; ++output) {
                const GoodAmount &item = _building_outputs[
                    incumbent_type.output_begin + output];
                const int64_t qty = std::max<int64_t>(0, group.last_output) > 0
                    ? effective_building_output_quantity(
                        group, item.good_id, item.quantity,
                        std::max<int64_t>(1, group.last_capacity_q16),
                        building_days, _saturation_count)
                    : 0;
                if (qty <= 0 || settled_operating <= 0) continue;
                const int64_t allocated = allocated_output_operating_cost(
                    incumbent_type, output, settled_operating,
                    _saturation_count);
                InvestmentIncumbentLane lane;
                lane.good_id = item.good_id;
                lane.type_id = group.type_id;
                lane.unit_cost = mul_div_sat(
                    allocated, GOODS_SCALE, qty, _saturation_count);
                lane.daily_offered = (qty + epoch_days - 1) / epoch_days;
                if (lane.daily_offered <= 0 || lane.unit_cost <= 0) continue;
                lane.stealable_capacity = lane.daily_offered;
                lane.owner_fill = std::max<int64_t>(0, group.filled_owner);
                lane.employee_fill = employee_fill;
                push_incumbent_lane(lane);
                InvestmentIncumbentRecord rec;
                rec.cell = cell;
                rec.type_id = group.type_id;
                rec.output_good = item.good_id;
                rec.settled_unit_cost = lane.unit_cost;
                rec.daily_offered_capacity = lane.daily_offered;
                rec.owner_fill = lane.owner_fill;
                rec.employee_fill = lane.employee_fill;
                rec.settled_day = _current_day.get();
                rec.generation = static_cast<int64_t>(_committed_generation);
                rec.stealable_capacity = lane.stealable_capacity;
                upsert_incumbent_record(rec);
            }
        }
        std::stable_sort(incumbent_lanes.begin(), incumbent_lanes.end(),
            [](const InvestmentIncumbentLane &a,
               const InvestmentIncumbentLane &b) {
                if (a.good_id != b.good_id) return a.good_id < b.good_id;
                if (a.unit_cost != b.unit_cost)
                    return a.unit_cost < b.unit_cost;
                return a.type_id < b.type_id;
            });
    }
    // Greenfield types compete on market signal, margin, payback, and sponsor
    // capital. Do not hard-block every new industry merely because some other
    // installed type still has owner openings: a cell-wide gate deadlocks chains
    // such as tools behind permanently unfillable merchant/gatherer vacancies.
    // Same-type expansion still waits on its own openings below.
    for (int32_t available_index = available_begin;
         available_index < available_end; ++available_index) {
        const int32_t type_id =
            _epoch_country_building_type_indices[available_index];
        ++_investment_sparse_considered_types;
        const auto existing_it = _investment_existing_by_cell_type.find(
            BuildingInvestmentCellContext::cell_key(cell, type_id));
        const InvestmentExistingType *existing = existing_it !=
                _investment_existing_by_cell_type.end()
            ? &existing_it->second : nullptr;
        const auto pending_it = _investment_pending_by_cell_type.find(
            BuildingInvestmentCellContext::cell_key(cell, type_id));
        const int64_t pending_count = pending_it !=
                _investment_pending_by_cell_type.end()
            ? std::max<int64_t>(0, pending_it->second) : 0;
        // Sparse discovery is an optimization for established flows. A
        // type with neither installed nor pending capacity is a legitimate
        // greenfield candidate even when no signal has touched its goods.
        const bool greenfield = existing == nullptr && pending_count <= 0;
        // Military v1: state-owned types are built and demolished only by
        // the state commands. Private capital never reviews them, including
        // the employment-catchup and recovery lanes.
        if (type_id >= 0 && type_id < static_cast<int32_t>(
                _building_types.size()) &&
            _building_types[type_id].kind == 3) {
            ++_investment_sparse_skipped_types;
            if (capture_investment_diagnostics) {
                _investment_diagnostics.push_back({});
                _investment_diagnostics.back().type_id = type_id;
                _investment_diagnostics.back().rejection_reason =
                    INVESTMENT_REJECTION_STATE_OWNED;
            }
            continue;
        }
        // A zero growth share is an explicit ordinary-investment off
        // switch. Catch-up remains a separate lane and may still evaluate
        // candidates when unemployment policy asks it to do so.
        if (_investment_max_growth_share_q16.get() <= 0 &&
            cell_request.reason != INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP) {
            ++_investment_sparse_skipped_types;
            if (capture_investment_diagnostics) {
                _investment_diagnostics.push_back({});
                _investment_diagnostics.back().type_id = type_id;
                _investment_diagnostics.back().rejection_reason =
                    INVESTMENT_REJECTION_PROBABILITY;
            }
            continue;
        }
        const bool sparse_selected = !sparse_mask_ready ||
            (type_id >= 0 && type_id < static_cast<int32_t>(
                _investment_type_stamp.size()) &&
             _investment_type_stamp[type_id] == investment_review_stamp);
        if (sparse_selected) {
            ++_investment_sparse_selected_types;
        } else {
            ++_investment_sparse_skipped_types;
            if (sparse_filter_active) continue;
        }
        ++_investment_type_evaluations;
        const BuildingType &type = _building_types[type_id];
        InvestmentDiagnostic *diagnostic = nullptr;
        bool type_has_viable_candidate = false;
        Candidate type_best;
        if (capture_investment_diagnostics) {
            _investment_diagnostics.push_back({});
            diagnostic = &_investment_diagnostics.back();
            diagnostic->type_id = type_id;
        }
        auto reject = [&](int32_t reason) {
            if (type_has_viable_candidate) return;
            investment_mark_rejection(existing, reason);
            if (diagnostic != nullptr) diagnostic->rejection_reason = reason;
        };
        // Every unlocked building type enters the same economic review.
        // Types without a marketable output naturally fail the market-signal
        // gate; collectors continue through resource, material, viability,
        // payback, and sponsor-capital checks instead of being hard-disabled.
        const int32_t existing_group = existing != nullptr
            ? existing->representative_group : -1;
        const bool vacancy = existing != nullptr &&
            existing->filled_owner < existing->owner_required;
        if (vacancy) {
            reject(INVESTMENT_REJECTION_ACTIVE_OWNER_VACANCY);
            continue;
        }
        if (existing != nullptr && existing->suspended_count > 0) {
            reject(INVESTMENT_REJECTION_SUSPENDED_CAPACITY);
            continue;
        }
        std::vector<OutputInvestmentSignal> &output_signals =
            _investment_output_signals_scratch;
        output_signals.clear();
        int32_t driver_index = -1;
        for (int32_t i = 0; i < type.output_count; ++i) {
            const GoodAmount &output = _building_outputs[type.output_begin + i];
            const int32_t representative_owner = existing_group >= 0
                ? buildings_store().owner_signature_id[existing_group]
                : signature_for_profession_ethnicity(
                    type.owner_profession_id, 0);
            int64_t effective_unit_output = existing_group >= 0
                ? effective_building_output_quantity(
                    building_view(static_cast<size_t>(existing_group)), output.good_id,
                    output.quantity,
                    Q16_ONE, 1, _saturation_count)
                : effective_building_output_quantity_for_target(
                    cell, type_id, representative_owner,
                    output.good_id, output.quantity, Q16_ONE, 1,
                    _saturation_count);
            const int64_t index = market_store().index(market, output.good_id);
            const int32_t signal = market_signal_index(cell, output.good_id);
            const bool monetary_issue =
                _good_monetary_issue_values[output.good_id] > 0;
            const int64_t research_demand =
                epoch_procurement_demand_daily(cell, output.good_id);
            const int64_t demand = saturating_add(
                saturating_add(
                    market_store().demand_ema[index],
                    saturating_add(
                        signal >= 0 ? _market_signals.business_demand_ema[signal] : 0,
                        research_demand, _saturation_count),
                    _saturation_count),
                saturating_add(
                    signal >= 0 && signal < static_cast<int32_t>(
                            _epoch_substitute_business_demand.size())
                        ? std::max<int64_t>(0,
                            _epoch_substitute_business_demand[signal]) : 0,
                    signal >= 0
                        ? mul_div_sat(merchant_protected_reserve(signal), Q16_ONE,
                            std::max<int64_t>(Q16_ONE,
                                _good_target_inventory_days_q16[output.good_id]),
                            _saturation_count) : 0,
                    _saturation_count),
                _saturation_count);
            const int64_t supply = signal >= 0
                ? _market_signals.offered_supply_ema[signal] : 0;
            const int64_t realized_withdrawal = signal >= 0
                ? _market_signals.realized_withdrawal_ema[signal] : 0;
            const int32_t output_flow = trade_flow_index(
                cell, output.good_id, false);
            const int64_t export_ema = output_flow >= 0
                ? _trade_flows.export_ema[output_flow] : 0;
            const int64_t inventory_target = merchant_inventory_target(
                market, output.good_id, signal, realized_withdrawal,
                export_ema, supply, _saturation_count);
            const int64_t inventory_gap = std::max<int64_t>(
                0, inventory_target - market_store().stock[index]);
            const int64_t gap_daily = inventory_gap > 0
                ? mul_div_sat(inventory_gap, Q16_ONE,
                    std::max<int64_t>(Q16_ONE,
                        _good_target_inventory_days_q16[output.good_id]),
                    _saturation_count) : 0;
            int64_t output_deficit = std::max<int64_t>(
                std::max<int64_t>(0, demand - supply), gap_daily);
            int64_t output_pressure_q16 =
                market_store().last_shortage_q16[index];
            if (monetary_issue) {
                // Mint clears at face. Executable output (labor + ore), not
                // the cell bullion pool, decides whether a gold lot can run.
                bool employee_supply = type.employee_count == 0;
                for (int32_t role_index = 0; role_index < type.employee_count;
                     ++role_index) {
                    const JobRole &role = _building_employee_roles[
                        type.employee_begin + role_index];
                    employee_supply = employee_supply ||
                        (role.profession_id >= 0 &&
                         role.profession_id < static_cast<int32_t>(
                             cell_profession_population.size()) &&
                         cell_profession_population[role.profession_id] > 0);
                }
                int64_t resource_capacity_q16 = Q16_ONE;
                const int64_t resource_days = std::max<int64_t>(1, _epoch_days.get());
                for (int32_t resource_index = 0;
                     resource_index < type.resource_count; ++resource_index) {
                    const ResourceAmount &resource = _building_resources[
                        type.resource_begin + resource_index];
                    const int64_t raw = resource.mode == 1
                        ? saturating_mul(1, resource.quantity, _saturation_count)
                        : saturating_mul(resource_days, resource.quantity,
                            _saturation_count);
                    const int64_t required = effective_resource_use_quantity(
                        cell, resource.resource_id, raw, _saturation_count);
                    if (required <= 0) continue;
                    resource_capacity_q16 = std::min(resource_capacity_q16,
                        std::clamp<int64_t>(mul_div_sat(
                            available_resource_amount(resource, cell), Q16_ONE,
                            required, _saturation_count), 0, Q16_ONE));
                }
                if (!employee_supply || resource_capacity_q16 <= 0)
                    effective_unit_output = 0;
                else if (resource_capacity_q16 < Q16_ONE)
                    effective_unit_output = mul_div_sat(effective_unit_output,
                        resource_capacity_q16, Q16_ONE, _saturation_count);
                const int64_t executable_output = employee_supply
                    ? effective_unit_output : 0;
                // Mint clears at face value, so executable output is the
                // absorbable demand — not the cell bullion pool.
                output_deficit = std::max(output_deficit, executable_output);
                if (executable_output > 0)
                    output_pressure_q16 = Q16_ONE;
            } else if (research_demand > 0 && supply <= 0) {
                // Government procurement is a cash-backed buyer even before
                // the first research producer exists. Seed one building of
                // entry pressure; absorption later still caps revenue at
                // the demand-covered share.
                output_deficit = std::max<int64_t>(
                    output_deficit, effective_unit_output);
                output_pressure_q16 = Q16_ONE;
            }
            const int64_t local_startup = startup_demand_for(
                cell, output.good_id);
            const int64_t remote_startup = remote_startup_demand_for(
                cell, output.good_id);
            // A completely new output has no EMA, stock gap, or startup
            // chain to identify it. Give only a greenfield candidate a
            // small structural absorption prior so a new profession or
            // good can be discovered; all capital, input, resource,
            // margin, payback, and tax gates still apply below. This is a
            // bounded discovery prior, never a full-capacity receipt.
            constexpr int64_t GREENFIELD_ABSORPTION_Q16 = Q16_ONE / 16;
            const bool no_market_evidence = demand <= 0 && supply <= 0 &&
                realized_withdrawal <= 0 && output_deficit <= 0 &&
                local_startup <= 0 && remote_startup <= 0;
            if (greenfield && no_market_evidence && effective_unit_output > 0) {
                const int64_t structural_deficit = std::max<int64_t>(
                    1, mul_div_sat(effective_unit_output,
                        GREENFIELD_ABSORPTION_Q16, Q16_ONE,
                        _saturation_count));
                output_deficit = structural_deficit;
                output_pressure_q16 = GREENFIELD_ABSORPTION_Q16;
            }
            const int64_t organic_output_deficit = output_deficit;
            output_deficit = std::max(output_deficit, local_startup);
            // Offered supply already contains the utilized portion of the
            // installed stock. Reserve the remaining installed capacity and
            // all construction in flight before treating a shortage as an
            // entry signal; otherwise each review reinvests into capacity
            // that merely has not started producing yet.
            int64_t reserved_capacity_q16 = pending_count > 0
                ? saturating_mul(pending_count, Q16_ONE,
                    _saturation_count) : 0;
            if (existing != nullptr) {
                reserved_capacity_q16 = saturating_add(
                    reserved_capacity_q16,
                    std::max<int64_t>(0, existing->idle_capacity_q16),
                    _saturation_count);
            }
            const int64_t reserved_output = mul_div_sat(
                effective_unit_output, reserved_capacity_q16, Q16_ONE,
                _saturation_count);
            output_deficit = std::max<int64_t>(
                0, output_deficit - std::min(output_deficit, reserved_output));
            const int64_t organic_after_reserved = std::max<int64_t>(
                0, organic_output_deficit -
                    std::min(organic_output_deficit, reserved_output));
            // Remote preparation already deducted executable capacity for
            // the component, so merge that lane after local reservations.
            output_deficit = std::max(output_deficit, remote_startup);
            // Derived-demand bootstrap: a scarce downstream recipe whose
            // price has conducted into this input is a committed indirect
            // buyer for its FIRST producer. Fold a bounded share of that
            // shadow quantity into the demand-backed deficit so the
            // absorption and revenue gates can see it. Price conduction
            // alone leaves expected sales at zero on an empty shelf, so
            // the upstream would still fail the owner-livelihood gate.
            if (greenfield && derived_startup_absorption_enabled() &&
                derived_price_conduction_enabled() && signal >= 0 &&
                signal < static_cast<int32_t>(
                    _epoch_derived_business_demand.size()) &&
                signal < static_cast<int32_t>(
                    _epoch_derived_anchor_price.size()) &&
                _epoch_derived_anchor_price[signal] > 0) {
                const int64_t derived_qty = std::max<int64_t>(0,
                    _epoch_derived_business_demand[signal]);
                if (derived_qty > 0) {
                    const int64_t committed = mul_div_sat(
                        derived_qty,
                        std::clamp<int64_t>(
                            _derived_startup_absorption_q16, 0, Q16_ONE),
                        Q16_ONE, _saturation_count);
                    output_deficit = std::max(output_deficit, committed);
                }
            }
            const int64_t anticipated_demand = std::max(
                local_startup, remote_startup);
            const int64_t demand_for_pressure = std::max(
                demand, anticipated_demand);
            if (output_deficit <= 0) output_pressure_q16 = 0;
            if (output_deficit > 0 && demand_for_pressure > 0) {
                output_pressure_q16 = std::max<int64_t>(
                    output_pressure_q16,
                    std::min<int64_t>(Q16_ONE, mul_div_sat(
                        output_deficit, Q16_ONE, demand_for_pressure,
                        _saturation_count)));
            }
            if (inventory_gap > 0 && inventory_target > 0) {
                output_pressure_q16 = std::max<int64_t>(output_pressure_q16,
                    std::min<int64_t>(Q16_ONE, mul_div_sat(
                        inventory_gap, Q16_ONE, inventory_target,
                        _saturation_count)));
            }
            OutputInvestmentSignal item;
            item.good_id = output.good_id;
            item.pressure_q16 = output_pressure_q16;
            item.deficit = output_deficit;
            item.utilization_q16 = effective_unit_output > 0
                ? std::clamp<int64_t>(mul_div_sat(
                    output_deficit, Q16_ONE, effective_unit_output,
                    _saturation_count), 0, Q16_ONE)
                : 0;
            if (signal >= 0 && signal < static_cast<int32_t>(
                    _epoch_producer_sellable_current.size())) {
                item.sellable = std::max<int64_t>(
                    0, _epoch_producer_sellable_current[signal]);
                item.merchant_sold = std::max<int64_t>(
                    0, _epoch_producer_merchant_sold_current[signal]);
                item.discarded = std::max<int64_t>(
                    0, _epoch_producer_discarded_current[signal]);
            }
            if (item.sellable > 0) {
                // Monetary output is fully supported at face value. For
                // ordinary goods, use the factual merchant purchase share.
                item.sell_through_q16 = monetary_issue
                    ? Q16_ONE
                    : std::clamp<int64_t>(mul_div_sat(
                        item.merchant_sold, Q16_ONE, item.sellable,
                        _saturation_count), 0, Q16_ONE);
                item.discard_q16 = std::clamp<int64_t>(mul_div_sat(
                    item.discarded, Q16_ONE, item.sellable,
                    _saturation_count), 0, Q16_ONE);
            }
            const int64_t unit_price = std::max<int64_t>(1,
                market_store().price[market_store().index(market, output.good_id)]);
            int64_t expected_absorption_q16 = 0;
            if (monetary_issue) {
                expected_absorption_q16 = effective_unit_output > 0
                    ? Q16_ONE
                    : 0;
            } else if (effective_unit_output > 0) {
                // Value only the quantity that has a factual or
                // demand-backed buyer. Demand itself is a daily flow;
                // converting it to a share of one candidate's output
                // avoids ranking a huge recipe by demand dollars that the
                // recipe cannot actually sell.
                const int64_t demand_absorption = std::clamp<int64_t>(
                    mul_div_sat(std::max<int64_t>(0, demand), Q16_ONE,
                        effective_unit_output, _saturation_count),
                    0, Q16_ONE);
                const int64_t startup_absorption = std::clamp<int64_t>(
                    mul_div_sat(std::max<int64_t>(0, output_deficit), Q16_ONE,
                        effective_unit_output, _saturation_count),
                    0, Q16_ONE);
                expected_absorption_q16 = std::max({
                    item.sell_through_q16, demand_absorption,
                    startup_absorption});
            }
            const int64_t expected_quantity = mul_div_sat(
                effective_unit_output, expected_absorption_q16,
                Q16_ONE, _saturation_count);
            const int64_t expected_price = monetary_issue
                ? _good_monetary_issue_values[output.good_id] : unit_price;
            item.expected_cash_value = mul_div_sat(expected_quantity,
                expected_price, GOODS_SCALE, _saturation_count);
            item.driver_strength_q16 = item.expected_cash_value;
            item.nameplate_output = effective_unit_output;
            item.demand = demand;
            item.startup_demand = local_startup;
            item.remote_startup_demand = remote_startup;
            item.startup_incremental = output_deficit >
                organic_after_reserved;
            output_signals.push_back(item);
            const OutputInvestmentSignal &candidate = output_signals.back();
            if (driver_index < 0) {
                driver_index = i;
            } else {
                const OutputInvestmentSignal &current =
                    output_signals[driver_index];
                if (candidate.expected_cash_value > current.expected_cash_value ||
                    (candidate.expected_cash_value == current.expected_cash_value &&
                     candidate.good_id < current.good_id)) {
                    driver_index = i;
                }
            }
        }
        OutputInvestmentSignal driver = driver_index >= 0
            ? output_signals[driver_index] : OutputInvestmentSignal{};
        int64_t shortage_q16 = driver.pressure_q16;
        int64_t utilization_q16 = driver.utilization_q16;
        int64_t driver_deficit = driver.deficit;
        // Shadow-derived demand is only a pricing/investment pressure
        // signal.  It must not by itself justify a normal greenfield or
        // expansion candidate, even when an incumbent has already left
        // output stock in the market.  Use only committed buyer evidence
        // for this gate; catch-up startup remains an explicit exception.
        bool driver_real_evidence = false;
        if (driver.good_id >= 0) {
            const int64_t output_index = market_store().index(
                market, driver.good_id);
            const int32_t signal = market_signal_index(cell, driver.good_id);
            const int64_t household_demand = output_index >= 0 &&
                    output_index < static_cast<int64_t>(
                        market_store().demand_ema.size())
                ? std::max<int64_t>(0, market_store().demand_ema[output_index]) : 0;
            const int64_t business_demand = signal >= 0 && signal <
                    static_cast<int32_t>(_market_signals.business_demand_ema.size())
                ? std::max<int64_t>(0, _market_signals.business_demand_ema[signal]) : 0;
            const int64_t withdrawal = signal >= 0 && signal <
                    static_cast<int32_t>(_market_signals.realized_withdrawal_ema.size())
                ? std::max<int64_t>(0, _market_signals.realized_withdrawal_ema[signal]) : 0;
            const int64_t epoch_real = signal >= 0 && signal <
                    static_cast<int32_t>(_epoch_desired_business_demand.size())
                ? std::max<int64_t>(0, _epoch_desired_business_demand[signal]) : 0;
            const int64_t epoch_substitute = signal >= 0 && signal <
                    static_cast<int32_t>(_epoch_substitute_business_demand.size())
                ? std::max<int64_t>(0, _epoch_substitute_business_demand[signal]) : 0;
            const int64_t epoch_funded = signal >= 0 && signal <
                    static_cast<int32_t>(_epoch_funded_business_demand.size())
                ? std::max<int64_t>(0, _epoch_funded_business_demand[signal]) : 0;
            const int64_t research = epoch_procurement_demand_daily(
                cell, driver.good_id);
            const int64_t startup = std::max<int64_t>(
                startup_demand_for(cell, driver.good_id),
                remote_startup_demand_for(cell, driver.good_id));
            const int32_t flow = trade_flow_index(cell, driver.good_id, false);
            const int64_t exports = flow >= 0 && flow < static_cast<int32_t>(
                    _trade_flows.export_ema.size())
                ? std::max<int64_t>(0, _trade_flows.export_ema[flow]) : 0;
            // A priced Leontief shadow demand is a claim from a real
            // downstream shortage, not a speculative ranking signal.
            // Accept it as buyer evidence only for the first producer of
            // that input, and only once conduction has actually priced it.
            const int32_t boot_signal = market_signal_index(
                cell, driver.good_id);
            const bool derived_boot_evidence =
                greenfield && derived_startup_absorption_enabled() &&
                derived_price_conduction_enabled() && boot_signal >= 0 &&
                boot_signal < static_cast<int32_t>(
                    _epoch_derived_business_demand.size()) &&
                boot_signal < static_cast<int32_t>(
                    _epoch_derived_anchor_price.size()) &&
                _epoch_derived_business_demand[boot_signal] > 0 &&
                _epoch_derived_anchor_price[boot_signal] > 0;
            driver_real_evidence = household_demand > 0 || business_demand > 0 ||
                withdrawal > 0 || epoch_real > 0 || epoch_substitute > 0 ||
                epoch_funded > 0 ||
                research > 0 || startup > 0 || exports > 0 ||
                derived_boot_evidence;
        }
        const int32_t driver_signal = driver.good_id >= 0
            ? market_signal_index(cell, driver.good_id) : -1;
        const bool driver_shadow_only =
            driver_signal >= 0 && driver_signal < static_cast<int32_t>(
                _epoch_derived_business_demand.size()) &&
              _epoch_derived_business_demand[driver_signal] > 0 &&
              !driver_real_evidence;
        int64_t stealable = 0;
        int64_t challenger_unit_cost = 0;
        int64_t incumbent_unit_cost = 0;
        bool displaces_incumbents = false;
        if (diagnostic != nullptr) {
            diagnostic->shortage_q16 = shortage_q16;
            diagnostic->utilization_q16 = utilization_q16;
            diagnostic->driver_good_id = driver.good_id;
            diagnostic->driver_pressure_q16 = driver.pressure_q16;
            diagnostic->driver_utilization_q16 = driver.utilization_q16;
            diagnostic->driver_sellable = driver.sellable;
            diagnostic->driver_merchant_sold = driver.merchant_sold;
            diagnostic->driver_sell_through_q16 = driver.sell_through_q16;
            diagnostic->driver_discard_q16 = driver.discard_q16;
        }
        if (driver.good_id < 0) {
            ++_investment_market_signal_rejections;
            reject(INVESTMENT_REJECTION_MARKET_SIGNAL);
            continue;
        }
        if (driver_shadow_only) {
            ++_investment_market_signal_rejections;
            reject(INVESTMENT_REJECTION_MARKET_SIGNAL);
            continue;
        }
        if (!evaluate_building_conditions(type_id, cell)) {
            ++_building_investment_blocked_resources;
            reject(INVESTMENT_REJECTION_RESOURCE);
            continue;
        }
        bool resource_budget_ready = true;
        for (int32_t edge = 0; edge < type.resource_count; ++edge) {
            const ResourceAmount &item = _building_resources[
                type.resource_begin + edge];
            if (item.quantity <= 0) continue;
            const size_t resource_idx = static_cast<size_t>(
                item.resource_id) * _cell_count.get() + cell;
            const int64_t committed =
                investment_resource_committed(resource_idx);
            const int64_t effective_quantity =
                effective_resource_use_quantity(
                    cell, item.resource_id, item.quantity,
                    _saturation_count);
            if (effective_quantity <= 0) continue;
            if (item.mode == 1) {
                // Capacity edges claim standing habitat against reserve.
                // Skipping them let wild_wheat_stand expand past fertile_soil.
                const int64_t available =
                    available_resource_amount(item, cell);
                if (committed > available ||
                    effective_quantity > available - committed) {
                    resource_budget_ready = false;
                    break;
                }
                continue;
            }
            if (item.mode != 0 || _resource_safe_harvest_q16.get() <= 0) continue;
            int64_t daily_budget = 0;
            if (resource_is_renewable(item.resource_id)) {
                daily_budget = renewable_safe_harvest(
                    item.resource_id, cell);
            } else if (resource_idx <
                       resource_remaining_lanes().size()) {
                daily_budget = std::max<int64_t>(0,
                    resource_remaining_lanes()[resource_idx]) /
                    std::max<int64_t>(1, _resource_min_horizon_days.get());
            }
            if (committed > daily_budget ||
                effective_quantity > daily_budget - committed) {
                resource_budget_ready = false;
                break;
            }
        }
        if (!resource_budget_ready) {
            ++_building_investment_blocked_resources;
            reject(INVESTMENT_REJECTION_RESOURCE);
            continue;
        }
        const int32_t country_cost_factor = country >= 0 &&
                country < static_cast<int32_t>(
                    _epoch_country_construction_cost_factor_q16.size())
            ? _epoch_country_construction_cost_factor_q16[country] : Q16_ONE;
        ConstructionMaterialPlan material_plan;
        const bool materials_ready = plan_construction_materials(
            cell, type_id, 1, country_cost_factor, material_plan);
        const int32_t failed_material_group = material_plan.failed_group;
        if (!materials_ready) {
            // 缺货仍按完整材料账单评估利润/出资人；虚拟库存仅用于报价。
            std::vector<int64_t> quote_stock(_good_ids.size(),
                std::numeric_limits<int64_t>::max() / 4);
            if (!plan_construction_materials(cell, type_id, 1,
                    country_cost_factor, material_plan, nullptr, &quote_stock)) {
                reject(INVESTMENT_REJECTION_MATERIALS);
                continue;
            }
        }
        if (diagnostic != nullptr) {
            diagnostic->failed_material_group = materials_ready ? -1 : failed_material_group;
            diagnostic->selected_material_good_ids = material_plan.good_ids;
            diagnostic->selected_material_quantities = material_plan.quantities;
        }
        const int64_t construction_cost = material_plan.total_cost;
        // Capital-feasibility gate (see precomputation above): without an
        // affordable construction bundle this type can never find a
        // sponsor. required_capital >= construction_cost and transferable
        // funds <= raw funds make this an exact no-false-negative skip.
        if (construction_cost > 0 &&
            construction_cost > cell_max_sponsor_funds &&
            construction_cost > cell_credit_construction_cover) {
            ++_investment_gate_capital_type_skips;
            eligible_but_unfunded = true;
            reject(INVESTMENT_REJECTION_SPONSOR_CAPITAL);
            continue;
        }
        int64_t daily_input_cost = 0;
        int64_t daily_input_base_cost = 0;
        // Hard inputs may ceiling entry utilization. Soft tools only cut
        // throughput efficiency (and bill the covered share) — matching
        // production's optional-productivity path.
        int64_t hard_input_coverage_bound_q16 = Q16_ONE;
        int64_t soft_efficiency_q16 = Q16_ONE;
        // Value of one full daily recipe's outputs at the frozen local
        // prices. This is used only for the optional-input decision: a
        // soft input is purchased when its marginal output value exceeds
        // its full purchase cost, otherwise the investment is evaluated
        // at bare efficiency with zero soft-input cost.
        int64_t daily_output_value = 0;
        for (int32_t output_edge = 0;
             output_edge < type.output_count; ++output_edge) {
            const GoodAmount &output = _building_outputs[
                type.output_begin + output_edge];
            if (output.good_id < 0 || output.good_id >= market_store().good_count.get())
                continue;
            const int64_t price = std::max<int64_t>(0,
                market_store().price[market_store().index(
                    market, output.good_id)]);
            daily_output_value = saturating_add(daily_output_value,
                goods_cost(std::max<int64_t>(0, output.quantity), price,
                    _saturation_count), _saturation_count);
        }
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &input = _building_inputs[type.input_begin + i];
            int64_t best_price = std::numeric_limits<int64_t>::max();
            int64_t best_base_price = 0;
            int64_t best_coverage_q16 = -1;
            int64_t best_cold_cover = -1;
            int32_t best_efficiency_q16 = Q16_ONE;
            for (int32_t c = input.candidate_begin;
                 c < input.candidate_begin + input.candidate_count; ++c) {
                const InputCandidate &candidate = _building_input_candidates[c];
                if (!good_input_candidate_available(cell, candidate.good_id, true)) continue;
                int64_t physical_daily = mul_div_sat(
                    input.quantity, Q16_ONE, candidate.efficiency_q16,
                    _saturation_count);
                if (mul_div_sat(physical_daily, candidate.efficiency_q16,
                                Q16_ONE, _saturation_count) < input.quantity) {
                    physical_daily = saturating_add(
                        physical_daily, 1, _saturation_count);
                }
                const int64_t input_index = market_store().index(
                    market, candidate.good_id);
                const int32_t input_signal = market_signal_index(
                    cell, candidate.good_id);
                const int64_t reserved = input_signal >= 0 && input_signal <
                        static_cast<int32_t>(_production_input_reserve.size())
                    ? _production_input_reserve[input_signal] : 0;
                const int64_t free_stock = std::max<int64_t>(
                    0, market_store().stock[input_index] - reserved);
                const int64_t offered = input_signal >= 0
                    ? _market_signals.offered_supply_ema[input_signal] : 0;
                const int64_t effective_period_supply = saturating_add(
                    free_stock, saturating_mul(offered,
                        std::max(1, _epoch_days.get()), _saturation_count),
                    _saturation_count);
                const int64_t required_period = saturating_mul(
                    physical_daily, std::max(1, _epoch_days.get()), _saturation_count);
                const int64_t coverage_q16 = required_period > 0
                    ? std::min<int64_t>(Q16_ONE, mul_div_sat(
                        effective_period_supply, Q16_ONE, required_period,
                        _saturation_count)) : Q16_ONE;
                const int64_t cold_cover = (free_stock <= 0 && offered <= 0)
                    ? startup_producer_hard_input_cover_q16(
                        cell, candidate.good_id, _saturation_count)
                    : Q16_ONE;
                const int64_t base_effective_price = mul_div_sat(
                    market_store().price[market_store().index(market, candidate.good_id)], Q16_ONE,
                    candidate.efficiency_q16, _saturation_count);
                const TransactionQuote input_quote = quote_transaction(
                    cell, candidate.good_id, base_effective_price,
                    false, true, _saturation_count, GOODS_SCALE);
                const int64_t effective_price = input_quote.buyer_outlay;
                if (coverage_q16 > best_coverage_q16 ||
                    (coverage_q16 == best_coverage_q16 &&
                     cold_cover > best_cold_cover) ||
                    (coverage_q16 == best_coverage_q16 &&
                     cold_cover == best_cold_cover &&
                     effective_price < best_price)) {
                    best_coverage_q16 = coverage_q16;
                    best_cold_cover = cold_cover;
                    best_price = effective_price;
                    best_base_price = base_effective_price;
                    best_efficiency_q16 = std::max<int32_t>(1,
                        candidate.efficiency_q16);
                }
            }
            const int64_t required_q16 = std::clamp<int64_t>(
                input.required_q16, 0, Q16_ONE);
            // Soft inputs match production: missing every candidate is
            // zero coverage / zero bill, not a hard INPUT_CHAIN reject.
            // Hard-required edges with no priced SKU still fail the chain.
            if (best_price == std::numeric_limits<int64_t>::max()) {
                if (required_q16 >= Q16_ONE) {
                    daily_input_cost = std::numeric_limits<int64_t>::max();
                    break;
                }
                soft_efficiency_q16 = std::min<int64_t>(
                    soft_efficiency_q16,
                    std::clamp<int64_t>(Q16_ONE - required_q16, 0, Q16_ONE));
                continue;
            }
            if (required_q16 >= Q16_ONE) {
                hard_input_coverage_bound_q16 = std::min<int64_t>(
                    hard_input_coverage_bound_q16,
                    std::clamp<int64_t>(
                        std::max<int64_t>(0, best_coverage_q16), 0, Q16_ONE));
            } else if (required_q16 > 0) {
                // Evaluate both soft-input choices. The bare branch keeps
                // only (1 - required) productivity and pays nothing. The
                // tooled branch restores full productivity and pays the
                // complete physical input bill. This makes investment
                // profitability use max(bare, tooled), rather than
                // treating a partially available tool as mandatory cost.
                const int64_t physical_daily = mul_div_sat(
                    input.quantity, Q16_ONE,
                    best_efficiency_q16,
                    _saturation_count);
                const int64_t tooled_cost = goods_cost(
                    std::max<int64_t>(1, physical_daily), best_price,
                    _saturation_count);
                const int64_t marginal_output_value = mul_div_sat(
                    daily_output_value, required_q16, Q16_ONE,
                    _saturation_count);
                const bool buy_soft = tooled_cost > 0 &&
                    marginal_output_value >= tooled_cost;
                if (buy_soft) {
                    daily_input_cost = saturating_add(daily_input_cost,
                        tooled_cost, _saturation_count);
                    daily_input_base_cost = saturating_add(
                        daily_input_base_cost,
                        goods_cost(std::max<int64_t>(1, physical_daily),
                            best_base_price, _saturation_count),
                        _saturation_count);
                } else {
                    soft_efficiency_q16 = std::min<int64_t>(
                        soft_efficiency_q16,
                        std::clamp<int64_t>(Q16_ONE - required_q16,
                            0, Q16_ONE));
                }
                continue;
            }
            // Hard inputs bill their full physical recipe quantity;
            // utilization scales the period bill later.
            const int64_t bill_quantity = input.quantity;
            daily_input_cost = saturating_add(daily_input_cost,
                goods_cost(bill_quantity, best_price, _saturation_count),
                _saturation_count);
            daily_input_base_cost = saturating_add(
                daily_input_base_cost, goods_cost(bill_quantity, best_base_price, _saturation_count), _saturation_count);
        }
        if (daily_input_cost == std::numeric_limits<int64_t>::max()) {
            // A hard production input shortage must still expose the
            // construction BOM.  Otherwise a producer such as the
            // knapping workshop is rejected before the material pass and
            // its flint/log demand never reaches the upstream producer.
            // The reserve update is monotonic, so repeated review passes
            // do not multiply the same demand.
            record_investment_material_demand(cell, type_id, 1,
                country_cost_factor);
            reject(INVESTMENT_REJECTION_INPUT_CHAIN);
            continue;
        }
        int64_t daily_wages = 0;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            const int32_t signal = labor_signal_index(cell, role.profession_id);
            const int64_t living_floor = signal >= 0
                ? std::max(_labor_signals.base_living_cost[signal],
                    _labor_signals.role_living_cost[signal]) : 0;
            const int64_t market_quote = signal >= 0 && signal <
                    static_cast<int32_t>(_labor_signals.contract_wage_ema.size())
                ? std::max(_labor_signals.contract_wage_ema[signal],
                    _labor_signals.paid_wage_ema[signal]) : 0;
            const int64_t dynamic_wage = std::max(living_floor, market_quote);
            daily_wages = saturating_add(daily_wages, saturating_mul(
                role.slots_per_building, dynamic_wage,
                _saturation_count), _saturation_count);
        }
        const int64_t daily_maintenance = daily_maintenance_cost_for_type(
            cell, type, _saturation_count);
        if (daily_maintenance == std::numeric_limits<int64_t>::max()) {
            reject(INVESTMENT_REJECTION_INPUT_CHAIN);
            continue;
        }
        const int64_t nameplate_output = std::max<int64_t>(
            0, driver.nameplate_output);
        const int64_t full_operating_cost = saturating_add(
            saturating_add(daily_input_cost, daily_wages, _saturation_count),
            daily_maintenance, _saturation_count);
        const int64_t allocated_driver_cost = driver_index >= 0
            ? allocated_output_operating_cost(
                type, driver_index, full_operating_cost, _saturation_count)
            : 0;
        challenger_unit_cost = nameplate_output > 0
            ? mul_div_sat(allocated_driver_cost, GOODS_SCALE,
                nameplate_output, _saturation_count)
            : 0;
        const int64_t cost_threshold = mul_div_sat(
            challenger_unit_cost,
            saturating_add(Q16_ONE,
                std::max<int32_t>(0,
                    _investment_displacement_min_advantage_q16),
                _saturation_count),
            Q16_ONE, _saturation_count);
        for (const InvestmentIncumbentLane &lane : incumbent_lanes) {
            if (lane.good_id != driver.good_id ||
                lane.type_id == type_id) continue;
            if (lane.unit_cost <= cost_threshold) continue;
            const int64_t lane_stealable = std::max<int64_t>(
                lane.stealable_capacity, lane.daily_offered);
            stealable = saturating_add(
                stealable, lane_stealable, _saturation_count);
            if (incumbent_unit_cost <= 0 ||
                lane.unit_cost < incumbent_unit_cost) {
                incumbent_unit_cost = lane.unit_cost;
            }
        }
        if (stealable > 0)
            ++_investment_displacement_type_evaluations;
        // Same-type seat expansion: when local incumbents are already
        // staffed and strongly profitable, allow a catch-up-sized quote so
        // sponsors can buy an owner seat (profession change) even if the
        // market gap is closed. Losing industries stay out via margin.
        bool profitable_incumbent_seat_expansion = false;
        if (existing != nullptr && existing->active_count > 0 &&
            existing->filled_owner >= existing->owner_required &&
            existing->representative_group >= 0 &&
            existing->representative_group < static_cast<int32_t>(
                building_count())) {
            const auto incumbent = building_view(static_cast<size_t>(
                existing->representative_group));
            profitable_incumbent_seat_expansion =
                incumbent.realized_profit_margin_q16 >= Q16_ONE / 4;
        }
        if (driver_deficit > 0 && utilization_q16 > 0) {
            // Keep the ordinary shortage path.
        } else if (stealable > 0 && nameplate_output > 0) {
            utilization_q16 = std::clamp<int64_t>(mul_div_sat(
                stealable, Q16_ONE, nameplate_output, _saturation_count),
                0, Q16_ONE);
            shortage_q16 = std::min<int64_t>(Q16_ONE, mul_div_sat(
                stealable, Q16_ONE,
                std::max<int64_t>(1, driver.demand), _saturation_count));
            driver_deficit = stealable;
            driver.deficit = stealable;
            driver.pressure_q16 = shortage_q16;
            driver.utilization_q16 = utilization_q16;
            driver.sellable = 0;
            displaces_incumbents = true;
            if (driver_index >= 0 &&
                driver_index < static_cast<int32_t>(output_signals.size())) {
                output_signals[driver_index].deficit = stealable;
                output_signals[driver_index].pressure_q16 = shortage_q16;
                output_signals[driver_index].utilization_q16 =
                    utilization_q16;
                output_signals[driver_index].sellable = 0;
            }
        } else if (nameplate_output > 0 &&
                   (cell_request.reason ==
                        INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP ||
                    profitable_incumbent_seat_expansion)) {
            // 位移必须先于 catch-up：高失业格上的低成本挑战者仍要走 stealable。
            // Profitable full incumbents share the same bounded util so
            // seat-creation cannot outrun ordinary catch-up.
            utilization_q16 = std::max<int64_t>(
                utilization_q16, Q16_ONE / 6);
            shortage_q16 = std::max<int64_t>(
                shortage_q16, Q16_ONE / 8);
            if (driver_deficit <= 0) {
                driver_deficit = mul_div_sat(
                    nameplate_output, utilization_q16, Q16_ONE,
                    _saturation_count);
                driver.deficit = driver_deficit;
                if (driver_index >= 0 &&
                    driver_index < static_cast<int32_t>(
                        output_signals.size())) {
                    output_signals[driver_index].deficit = driver_deficit;
                }
            }
            driver.utilization_q16 = utilization_q16;
            driver.pressure_q16 = shortage_q16;
        } else {
            reject(INVESTMENT_REJECTION_NO_COST_ADVANTAGE);
            if (diagnostic != nullptr) {
                diagnostic->stealable = stealable;
                diagnostic->challenger_unit_cost = challenger_unit_cost;
                diagnostic->incumbent_unit_cost = incumbent_unit_cost;
            }
            continue;
        }
        const int64_t climate_capacity_q16 = production_climate_capacity_q16(
            type, cell, nullptr, nullptr, _saturation_count);
        int64_t revealed_util_q16 = 0;
        if (existing != nullptr && existing->active_count > 0 &&
            existing->sum_last_output > 0) {
            int64_t recipe_qty = 0;
            for (int32_t i = 0; i < type.output_count; ++i) {
                recipe_qty = saturating_add(recipe_qty,
                    std::max<int64_t>(0,
                        _building_outputs[type.output_begin + i].quantity),
                    _saturation_count);
            }
            const int64_t nameplate = saturating_mul(
                saturating_mul(existing->active_count, recipe_qty,
                    _saturation_count),
                std::max<int64_t>(1, _epoch_days.get()), _saturation_count);
            if (recipe_qty > 0 && nameplate > 0) {
                revealed_util_q16 = std::clamp<int64_t>(mul_div_sat(
                    existing->sum_last_output, Q16_ONE, nameplate,
                    _saturation_count), 0, Q16_ONE);
            }
        }
        // Market/climate and hard-input stock may still bind expansion.
        // Soft-tool coverage lowers throughput via soft_efficiency below,
        // and must not undercut the executable intensity incumbents already
        // revealed in this cell.
        utilization_q16 = std::min(utilization_q16, climate_capacity_q16);
        if (revealed_util_q16 > 0) {
            utilization_q16 = std::min(utilization_q16,
                std::max(hard_input_coverage_bound_q16, revealed_util_q16));
        } else {
            utilization_q16 = std::min(utilization_q16,
                hard_input_coverage_bound_q16);
        }
        if (utilization_q16 <= 0) {
            // Preserve upstream construction pressure even when the
            // first executable utilization is currently zero.  This is
            // needed for hard-input bootstrap chains whose producer must
            // be built before utilization can become positive.
            record_investment_material_demand(cell, type_id, 1,
                country_cost_factor);
            reject(INVESTMENT_REJECTION_INPUT_CHAIN);
            continue;
        }
        const int64_t throughput_q16 = mul_div_sat(
            utilization_q16, soft_efficiency_q16, Q16_ONE, _saturation_count);
        if (diagnostic != nullptr) {
            diagnostic->shortage_q16 = shortage_q16;
            diagnostic->utilization_q16 = throughput_q16;
            diagnostic->driver_pressure_q16 = driver.pressure_q16;
            diagnostic->driver_utilization_q16 = driver.utilization_q16;
            diagnostic->stealable = stealable;
            diagnostic->challenger_unit_cost = challenger_unit_cost;
            diagnostic->incumbent_unit_cost = incumbent_unit_cost;
        }
        int64_t quoted_daily_variable_cost = mul_div_sat(saturating_add(
            saturating_add(daily_input_cost, daily_wages, _saturation_count),
            daily_maintenance, _saturation_count), utilization_q16,
            Q16_ONE, _saturation_count);
        for (int32_t ethnicity = 0; ethnicity < static_cast<int32_t>(
                _ethnicity_ids.size()); ++ethnicity) {
            ++_investment_ethnicity_evaluations;
            const int32_t target_signature = signature_for_profession_ethnicity(
                type.owner_profession_id, ethnicity);
            if (target_signature < 0) continue;
            const int64_t living_cost = investment_living_cost(target_signature, _saturation_count);
            const int64_t owner_livelihood = saturating_mul(
                living_cost, std::max<int64_t>(1,
                    type.owner_slots_per_building), _saturation_count);
            int64_t daily_cash_revenue = 0;
            int64_t daily_merchant_cash_revenue = 0;
            int64_t daily_producer_support_revenue = 0;
            int64_t monetary_request_money_per_day = 0;
            int64_t monetary_expected_revenue_per_day = 0;
            int64_t daily_in_kind_livelihood = 0;
            int64_t driver_absorption_q16 = 0;
            for (int32_t i = 0; i < type.output_count; ++i) {
                const GoodAmount &output =
                    _building_outputs[type.output_begin + i];
                const OutputInvestmentSignal &output_signal = output_signals[i];
                const int64_t research_demand =
                    epoch_procurement_demand_daily(cell, output.good_id);
                const int64_t prospective_quantity =
                    effective_building_output_quantity_for_target(
                        cell, type_id, target_signature,
                        output.good_id, output.quantity, throughput_q16, 1,
                        _saturation_count);
                const int64_t retail_price = market_store().price[
                    market_store().index(market, output.good_id)];
                int64_t retained_quantity = 0;
                if (prospective_quantity > 0 && retail_price > 0 &&
                    (_survival_food_good_mask[output.good_id] != 0 ||
                     _survival_clothing_good_mask[output.good_id] != 0)) {
                    const int64_t livelihood_gap = std::max<int64_t>(0,
                        owner_livelihood - daily_in_kind_livelihood);
                    retained_quantity = std::min(prospective_quantity,
                        saturating_add(saturating_mul(livelihood_gap,
                            GOODS_SCALE, _saturation_count), retail_price - 1,
                            _saturation_count) / retail_price);
                    const int64_t retained_value = std::min(livelihood_gap,
                        mul_div_sat(retained_quantity, retail_price,
                            GOODS_SCALE, _saturation_count));
                    daily_in_kind_livelihood = saturating_add(
                        daily_in_kind_livelihood, retained_value,
                        _saturation_count);
                }
                const int64_t sellable_quantity = std::max<int64_t>(
                    0, prospective_quantity - retained_quantity);
                const int64_t issue_value =
                    _good_monetary_issue_values[output.good_id];
                const bool government_research_output =
                    output.good_id == _epoch_research_good_id &&
                    research_demand > 0;
                int64_t absorption_q16 = 0;
                if (issue_value > 0 && sellable_quantity > 0) {
                    // Face × sellable output. Investment must not treat the
                    // cell bullion pool as a demand ceiling.
                    absorption_q16 = Q16_ONE;
                }
                if (issue_value <= 0 && government_research_output &&
                    sellable_quantity > 0) {
                    // Government research procurement is a cash-backed
                    // buyer even before the first producer exists. Use
                    // only the demand-covered share so a large research
                    // institution cannot project revenue from points the
                    // country has neither queued nor budgeted.
                    absorption_q16 = std::min<int64_t>(Q16_ONE,
                        mul_div_sat(research_demand, Q16_ONE,
                            sellable_quantity, _saturation_count));
                } else if (issue_value <= 0 && output_signal.sellable > 0) {
                    absorption_q16 = output_signal.sell_through_q16;
                    // Installed producers can still face a real deficit
                    // with a 0 sell-through print (quota/cash timing).
                    // Restrict the deficit fallback to types that already
                    // have a local group so greenfield challengers keep
                    // using the normal absorption path.
                    if (absorption_q16 <= 0 && output_signal.deficit > 0 &&
                        sellable_quantity > 0 &&
                        (existing != nullptr || cell_request.reason ==
                            INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP)) {
                        absorption_q16 = std::clamp<int64_t>(mul_div_sat(
                            output_signal.deficit, Q16_ONE, sellable_quantity,
                            _saturation_count), 0, Q16_ONE);
                    }
                } else if (issue_value <= 0 && sellable_quantity > 0) {
                    absorption_q16 = std::clamp<int64_t>(mul_div_sat(
                        output_signal.deficit, Q16_ONE, sellable_quantity,
                        _saturation_count), 0, Q16_ONE);
                }
                if (i == driver_index)
                    driver_absorption_q16 = absorption_q16;
                const int64_t absorbed_quantity = mul_div_sat(
                    sellable_quantity, absorption_q16, Q16_ONE,
                    _saturation_count);
                const int64_t settlement_price = issue_value > 0
                    ? issue_value
                    : government_research_output ? retail_price
                    : mul_div_sat(retail_price,
                        _good_merchant_buy_factor_q16[output.good_id], Q16_ONE,
                        _saturation_count);
                const int64_t merchant_revenue = mul_div_sat(
                    absorbed_quantity, settlement_price, GOODS_SCALE,
                    _saturation_count);
                daily_merchant_cash_revenue = saturating_add(
                    daily_merchant_cash_revenue, merchant_revenue,
                    _saturation_count);
                // Production settlement sends the sellable remainder to
                // producer support after merchant procurement.
                const int64_t support_quantity = issue_value > 0 ? 0 :
                    std::max<int64_t>(0,
                        sellable_quantity - absorbed_quantity);
                daily_producer_support_revenue = saturating_add(
                    daily_producer_support_revenue,
                    producer_support_receipt_value(cell, output.good_id,
                        support_quantity, _saturation_count),
                    _saturation_count);
                daily_cash_revenue = saturating_add(
                    daily_merchant_cash_revenue,
                    daily_producer_support_revenue, _saturation_count);
                if (issue_value > 0) {
                    monetary_request_money_per_day = saturating_add(
                        monetary_request_money_per_day,
                        mul_div_sat(sellable_quantity, issue_value,
                            GOODS_SCALE, _saturation_count),
                        _saturation_count);
                    monetary_expected_revenue_per_day = saturating_add(
                        monetary_expected_revenue_per_day,
                        mul_div_sat(absorbed_quantity, settlement_price,
                            GOODS_SCALE, _saturation_count),
                        _saturation_count);
                }
            }
            // Let the same expected revenue that drives the investment
            // decision fund a bounded profit share for labour.  This keeps
            // investment from pricing a scarce role at an obsolete catalog
            // wage while preserving the living-cost and market floors.
            const int64_t employee_slots = [&]() {
                int64_t total = 0;
                for (int32_t r = 0; r < type.employee_count; ++r)
                    total = saturating_add(total,
                        _building_employee_roles[type.employee_begin + r].slots_per_building,
                        _saturation_count);
                return total;
            }();
            const int64_t wage_profit_pool = std::max<int64_t>(0,
                saturating_sub(daily_cash_revenue,
                    saturating_add(daily_input_cost, daily_maintenance,
                        _saturation_count), _saturation_count));
            const int64_t profit_share_per_employee = employee_slots > 0
                ? mul_div_sat(wage_profit_pool, Q16_ONE / 4,
                    saturating_mul(employee_slots, Q16_ONE,
                        _saturation_count), _saturation_count) : 0;
            daily_wages = 0;
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[
                    type.employee_begin + r];
                const int32_t signal = labor_signal_index(cell,
                    role.profession_id);
                const int64_t living_floor = signal >= 0
                    ? std::max(_labor_signals.base_living_cost[signal],
                        _labor_signals.role_living_cost[signal]) : 0;
                const int64_t market_quote = signal >= 0 && signal <
                        static_cast<int32_t>(_labor_signals.contract_wage_ema.size())
                    ? std::max(_labor_signals.contract_wage_ema[signal],
                        _labor_signals.paid_wage_ema[signal]) : 0;
                const int64_t wage = std::max({living_floor, market_quote,
                    profit_share_per_employee});
                daily_wages = saturating_add(daily_wages,
                    saturating_mul(role.slots_per_building, wage,
                        _saturation_count), _saturation_count);
            }
            quoted_daily_variable_cost = mul_div_sat(saturating_add(
                saturating_add(daily_input_cost, daily_wages, _saturation_count),
                daily_maintenance, _saturation_count), utilization_q16,
                Q16_ONE, _saturation_count);
            int64_t daily_variable_cost = quoted_daily_variable_cost;
            int64_t daily_after_tax_cash_revenue = daily_cash_revenue;
            const uint8_t investment_tax_mask = static_cast<uint8_t>(
                (1U << CountryApi::TAX_INCOME) |
                (1U << CountryApi::TAX_BUSINESS));
            if ((_epoch_active_tax_mask & investment_tax_mask) != 0) {
                const int64_t eligible_cost_base = mul_div_sat(
                    saturating_add(saturating_add(
                        daily_input_base_cost, daily_wages,
                        _saturation_count), daily_maintenance,
                        _saturation_count),
                    utilization_q16, Q16_ONE, _saturation_count);
                const BuildingTaxQuote tax_quote =
                    expected_building_tax_quote(
                        cell, type_id, type.owner_profession_id,
                        daily_merchant_cash_revenue,
                        daily_producer_support_revenue,
                        eligible_cost_base, daily_variable_cost,
                        owner_livelihood, 1, 1, _saturation_count);
                daily_after_tax_cash_revenue = tax_quote.after_tax_cash;
            }
            // Incumbent expansion: forecast the marginal building from
            // revealed local unit economics so soft-input stock quotes
            // cannot contradict already-settled same-type camps.
            if (existing != nullptr && existing->active_count > 0 &&
                existing->sum_last_output > 0 && revealed_util_q16 > 0) {
                const int64_t days = std::max<int64_t>(1, _epoch_days.get());
                const int64_t buildings = existing->active_count;
                const int64_t unit_cash = existing->sum_last_revenue /
                    buildings / days;
                const int64_t unit_inkind =
                    existing->sum_last_in_kind_livelihood /
                    buildings / days;
                const int64_t unit_var =
                    saturating_add(saturating_add(
                        existing->sum_last_input_cost,
                        existing->sum_last_base_wages_due,
                        _saturation_count),
                        existing->sum_last_maintenance_cost,
                        _saturation_count) / buildings / days;
                int64_t absorption_q16 = driver_absorption_q16;
                if (absorption_q16 <= 0 && driver.good_id >= 0) {
                    absorption_q16 = std::max<int64_t>(
                        driver.sell_through_q16,
                        driver.deficit > 0 && driver.nameplate_output > 0
                            ? std::clamp<int64_t>(mul_div_sat(
                                driver.deficit, Q16_ONE,
                                driver.nameplate_output, _saturation_count),
                                0, Q16_ONE)
                            : 0);
                }
                absorption_q16 = std::clamp<int64_t>(absorption_q16, 0, Q16_ONE);
                daily_after_tax_cash_revenue = mul_div_sat(
                    unit_cash, absorption_q16, Q16_ONE, _saturation_count);
                daily_cash_revenue = daily_after_tax_cash_revenue;
                daily_in_kind_livelihood = std::min(unit_inkind,
                    owner_livelihood);
                daily_variable_cost = unit_var;
                monetary_expected_revenue_per_day =
                    daily_after_tax_cash_revenue;
            }
            const int64_t daily_economic_revenue = saturating_add(
                daily_after_tax_cash_revenue, daily_in_kind_livelihood,
                _saturation_count);
            const int64_t daily_operating_cost = saturating_add(
                daily_variable_cost, owner_livelihood, _saturation_count);
            const int64_t required_revenue = saturating_add(
                daily_operating_cost, mul_div_sat(daily_operating_cost,
                    type.target_operating_margin_q16, Q16_ONE,
                    _saturation_count), _saturation_count);
            const int64_t daily_profit = saturating_sub(
                daily_economic_revenue, daily_operating_cost,
                _saturation_count);
            // Preserve the economic quote even when a candidate is
            // rejected by a downstream livelihood/margin gate. The
            // inspector uses this to distinguish a real unprofitable
            // catch-up lane from a missing sponsor/material lane.
            if (diagnostic != nullptr) {
                diagnostic->projected_profit_per_day = daily_profit;
            }
            if (daily_economic_revenue < daily_operating_cost) {
                reject(INVESTMENT_REJECTION_OWNER_LIVELIHOOD);
                continue;
            }
            if (daily_economic_revenue < required_revenue || daily_profit <= 0) {
                reject(INVESTMENT_REJECTION_TARGET_MARGIN);
                continue;
            }
            const int64_t margin_q16 = daily_operating_cost > 0
                ? mul_div_sat(daily_profit, Q16_ONE,
                    daily_operating_cost, _saturation_count)
                : Q16_ONE;
            // Investment and employment compare one building's economic
            // signal. Self-use value remains in that same total; do not
            // dilute it by the number of owner slots.
            const int64_t projected_owner_income = saturating_add(
                std::max<int64_t>(0, saturating_sub(
                    daily_after_tax_cash_revenue, daily_variable_cost,
                    _saturation_count)),
                daily_in_kind_livelihood, _saturation_count);
            const int64_t required_capital = saturating_add(construction_cost,
                saturating_add(saturating_mul(daily_input_cost,
                    _investment_operating_cycles.get() * std::max(1, _epoch_days.get()),
                    _saturation_count), saturating_add(saturating_mul(
                        daily_wages, std::max(1, _epoch_days.get()), _saturation_count),
                        saturating_add(saturating_mul(owner_livelihood, 30,
                            _saturation_count), saturating_mul(
                                daily_maintenance, 30, _saturation_count),
                            _saturation_count),
                        _saturation_count), _saturation_count), _saturation_count);
            if (diagnostic != nullptr) {
                diagnostic->required_capital = required_capital;
                diagnostic->projected_profit_per_day = daily_profit;
                diagnostic->monetary_quota_initial = 0;
                diagnostic->monetary_quota_daily = 0;
                diagnostic->monetary_units = 0;
                diagnostic->monetary_candidate_slots = 0;
                diagnostic->monetary_request_money_per_day =
                    monetary_request_money_per_day;
                diagnostic->monetary_expected_revenue_per_day =
                    monetary_expected_revenue_per_day;
                // Publish the first shared quote/plan record.  The
                // legacy diagnostic fields remain populated for existing
                // UI/CSV consumers, while new callers can consume one
                // normalized economic decomposition.
                EconomicOpportunityQuote &quote =
                    diagnostic->opportunity_quote;
                quote.cell = cell;
                quote.type_id = type_id;
                quote.owner_signature_id = target_signature;
                quote.utilization_q16 = throughput_q16;
                quote.owner_use_value_per_day = daily_in_kind_livelihood;
                quote.cash_revenue_per_day = daily_after_tax_cash_revenue;
                quote.merchant_revenue_per_day = daily_merchant_cash_revenue;
                quote.producer_support_revenue_per_day =
                    daily_producer_support_revenue;
                quote.economic_revenue_per_day = daily_economic_revenue;
                quote.input_cost_per_day = daily_input_cost;
                quote.wage_cost_per_day = daily_wages;
                quote.maintenance_cost_per_day = daily_maintenance;
                quote.owner_living_cost_per_day = owner_livelihood;
                quote.after_tax_revenue_per_day = daily_after_tax_cash_revenue;
                quote.profit_per_day = daily_profit;
                quote.affordable_wage_per_day = employee_slots > 0
                    ? mul_div_sat(std::max<int64_t>(0, wage_profit_pool),
                        Q16_ONE, employee_slots, _saturation_count) : 0;
                quote.owner_slots = type.owner_slots_per_building;
                quote.employee_slots = employee_slots;
                quote.owner_jobs_filled = type.owner_slots_per_building;
                quote.employee_jobs_filled = employee_slots;
                InvestmentCandidatePlan &plan = diagnostic->candidate_plan;
                plan.cell = cell;
                plan.type_id = type_id;
                plan.owner_signature_id = target_signature;
                plan.utilization_q16 = throughput_q16;
                plan.construction_cost = construction_cost;
                plan.required_capital = required_capital;
                plan.target_profit_per_day = daily_profit;
                plan.target_return_on_capital_q16 = 0;
                plan.employee_slots = employee_slots;
                plan.owner_slots = type.owner_slots_per_building;
                plan.material_good_ids = material_plan.good_ids;
                plan.material_quantities = material_plan.quantities;
                plan.quote = quote;
            }
            const int64_t payback = daily_profit > 0
                ? (required_capital + daily_profit - 1) / daily_profit
                : std::numeric_limits<int64_t>::max();
            const int64_t return_on_capital_q16 = daily_profit > 0
                ? mul_div_sat(daily_profit, Q16_ONE,
                    std::max<int64_t>(1, required_capital),
                    _saturation_count)
                : 0;
            const int64_t cost_advantage_q16 = incumbent_unit_cost > 0 &&
                    challenger_unit_cost < incumbent_unit_cost
                ? mul_div_sat(incumbent_unit_cost - challenger_unit_cost,
                    Q16_ONE, incumbent_unit_cost, _saturation_count)
                : 0;
            if (diagnostic != nullptr) {
                diagnostic->return_on_capital_q16 =
                    return_on_capital_q16;
                diagnostic->cost_advantage_q16 = cost_advantage_q16;
                diagnostic->candidate_plan.payback_days = payback;
                diagnostic->candidate_plan.target_return_on_capital_q16 =
                    return_on_capital_q16;
            }
            const bool displacement_candidate = stealable > 0 &&
                cost_advantage_q16 > 0;
            if (payback > _investment_max_payback_days.get() &&
                !displacement_candidate) {
                reject(INVESTMENT_REJECTION_PAYBACK);
                continue;
            }
            bool had_eligible_sponsor = false;
            int64_t sponsor_capital = required_capital;
            int64_t merchant_credit = 0;
            int64_t willing_population = 0;
            int64_t transferable_capital = 0;
            int64_t income_improvement_q16 = 0;
            uint64_t sponsor_family_handle = 0;
            int32_t sponsor = find_entrepreneur_source(
                cell, target_signature, required_capital,
                std::max<int64_t>(1, projected_owner_income), living_cost,
                std::max<int64_t>(1, type.owner_slots_per_building),
                type_id, had_eligible_sponsor, willing_population,
                transferable_capital, income_improvement_q16,
                sponsor_family_handle, &investment_living_cost_cache);
            bool uses_merchant_credit = false;
            if (sponsor < 0 && _merchant_credit_runtime_mode.get() == 2 &&
                construction_cost > 0) {
                const int64_t merchant_cash =
                    investment_merchant_cash(cell);
                const int64_t outstanding =
                    investment_outstanding_credit(cell);
                const int64_t exposure = mul_div_sat(
                    merchant_cash, _merchant_credit_exposure_q16.get(),
                    Q16_ONE, _saturation_count);
                const int64_t reserve = mul_div_sat(
                    merchant_cash, _merchant_procurement_cash_reserve_q16.get(),
                    Q16_ONE, _saturation_count);
                const int64_t available_credit = std::max<int64_t>(0, std::min(
                    exposure - std::min(exposure, outstanding),
                    merchant_cash - std::min(merchant_cash, reserve)));
                if (available_credit >= construction_cost) {
                    // Credit may fund the bounded startup reserve as well as
                    // construction during employment catch-up. Ordinary
                    // reviews retain the existing construction-only credit
                    // contract.
                    const int64_t credit_cover = cell_request.reason ==
                            INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP
                        ? std::min(required_capital, available_credit)
                        : construction_cost;
                    sponsor_capital = std::max<int64_t>(
                        0, required_capital - credit_cover);
                    bool credit_sponsor_eligible = false;
                    sponsor = find_entrepreneur_source(
                        cell, target_signature, sponsor_capital,
                        std::max<int64_t>(1, projected_owner_income), living_cost,
                        std::max<int64_t>(1, type.owner_slots_per_building),
                        type_id, credit_sponsor_eligible, willing_population,
                        transferable_capital, income_improvement_q16,
                        sponsor_family_handle, &investment_living_cost_cache);
                    had_eligible_sponsor = had_eligible_sponsor ||
                        credit_sponsor_eligible;
                    uses_merchant_credit = sponsor >= 0;
                    if (uses_merchant_credit) {
                        merchant_credit = std::max<int64_t>(
                            0, required_capital - sponsor_capital);
                    }
                }
            }
            if (sponsor < 0) {
                if (had_eligible_sponsor) {
                    ++_building_investment_probability_skips;
                    reject(INVESTMENT_REJECTION_PROBABILITY);
                } else {
                    eligible_but_unfunded = true;
                    reject(INVESTMENT_REJECTION_SPONSOR_CAPITAL);
                }
                continue;
            }
            if (!materials_ready) {
                ++_building_investment_blocked_materials;
                record_investment_material_demand(cell, type_id, 1,
                    country_cost_factor);
                reject(INVESTMENT_REJECTION_MATERIALS);
                continue;
            }
            Candidate candidate;
            EconomicOpportunityQuote candidate_quote;
            candidate_quote.owner_use_value_per_day =
                daily_in_kind_livelihood;
            candidate_quote.cash_revenue_per_day =
                daily_after_tax_cash_revenue;
            candidate_quote.merchant_revenue_per_day =
                daily_merchant_cash_revenue;
            candidate_quote.producer_support_revenue_per_day =
                daily_producer_support_revenue;
            candidate_quote.economic_revenue_per_day =
                daily_economic_revenue;
            candidate_quote.input_cost_per_day = daily_input_cost;
            candidate_quote.wage_cost_per_day = daily_wages;
            candidate_quote.maintenance_cost_per_day = daily_maintenance;
            candidate_quote.owner_living_cost_per_day = owner_livelihood;
            candidate_quote.after_tax_revenue_per_day =
                daily_after_tax_cash_revenue;
            candidate_quote.profit_per_day = daily_profit;
            candidate_quote.owner_slots = type.owner_slots_per_building;
            candidate_quote.employee_slots = employee_slots;
            initialize_investment_candidate_plan(candidate.plan, cell,
                type_id, target_signature, throughput_q16,
                construction_cost, required_capital, payback, daily_profit,
                return_on_capital_q16, type.owner_slots_per_building,
                employee_slots, candidate_quote);
            candidate.plan.funding_capital = sponsor_capital;
            candidate.plan.merchant_credit = merchant_credit;
            candidate.plan.sponsor = sponsor;
            candidate.plan.sponsor_family_handle = sponsor_family_handle;
            candidate.shortage_q16 = shortage_q16;
            candidate.driver_good_id = driver.good_id;
            candidate.driver_deficit = driver_deficit;
            candidate.stealable = stealable;
            candidate.challenger_unit_cost = challenger_unit_cost;
            candidate.incumbent_unit_cost = incumbent_unit_cost;
            candidate.cost_advantage_q16 = cost_advantage_q16;
            candidate.displaces_incumbents = displaces_incumbents;
            candidate.startup_driven = driver.startup_incremental;
            for (int32_t i = 0; i < type.output_count; ++i) {
                const GoodAmount &output =
                    _building_outputs[type.output_begin + i];
                if (output.good_id != driver.good_id) continue;
                candidate.driver_output_per_building =
                    effective_building_output_quantity_for_target(
                        cell, type_id, target_signature,
                        output.good_id, output.quantity, throughput_q16, 1,
                        _saturation_count);
                break;
            }
            candidate.willing_population = willing_population;
            candidate.transferable_capital = transferable_capital;
            candidate.income_improvement_q16 = income_improvement_q16;
            candidate.plan.uses_merchant_credit = uses_merchant_credit;
            if (sponsor >= 0 &&
                sponsor < static_cast<int32_t>(
                    population_store().signature_id.size()) &&
                static_cast<int32_t>(
                    population_store().signature_id[sponsor]) !=
                    target_signature &&
                population_store().owner_employed[sponsor] > 0) {
                candidate.reallocates_owner_seat = true;
            }
            candidate.plan.request = cell_request;
            if (driver.startup_incremental && cell_request.reason !=
                    INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP)
                candidate.plan.request.reason =
                    INVESTMENT_REQUEST_STARTUP_DEMAND;
            else if (driver.good_id == _epoch_research_good_id &&
                     cell_request.reason !=
                        INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP)
                candidate.plan.request.reason =
                    INVESTMENT_REQUEST_RESEARCH_DEMAND;
            candidate.plan.request.demand_pressure = std::max<int64_t>(
                candidate.plan.request.demand_pressure,
                std::max<int64_t>(0, driver_deficit));
            candidate.plan.request.allow_reallocation =
                cell_request.allow_reallocation ||
                candidate.reallocates_owner_seat;
            const int64_t target_gap = mul_div_sat(
                std::max<int64_t>(0, driver_deficit),
                _investment_gap_fill_share_q16.get(), Q16_ONE,
                _saturation_count);
            candidate.desired_count =
                candidate.driver_output_per_building > 0 && target_gap > 0
                    ? std::max<int64_t>(1,
                        saturating_add(target_gap,
                            candidate.driver_output_per_building - 1,
                            _saturation_count) /
                            candidate.driver_output_per_building)
                    : 1;
            if (existing != nullptr && existing->installed_count > 0) {
                const int64_t scaled = saturating_mul(
                    existing->installed_count,
                    _investment_max_growth_share_q16.get(), _saturation_count);
                candidate.plan.max_batch_count = std::max<int64_t>(
                    1, saturating_add(scaled, Q16_ONE - 1,
                        _saturation_count) / Q16_ONE);
            } else {
            candidate.plan.max_batch_count =
                    _investment_new_type_seed_buildings.get();
            }
            candidate.plan.request.max_batch_count =
                candidate.plan.max_batch_count;
            candidate.jobs_per_building = std::max<int64_t>(
                1, type.owner_slots_per_building);
            // Portfolio ranking is a monetary return decision. Output
            // pressure and utilization have already informed the revenue
            // forecast and capacity; they are not additional preferences.
            candidate.score_q16 = std::max<int64_t>(
                return_on_capital_q16, margin_q16);
            if (candidate.plan.sponsor_family_handle != 0) {
                const int32_t stable_preference =
                    family_trait_behavior_factor_q16(
                        candidate.plan.sponsor_family_handle, 0, 0, type_id, cell);
                const int32_t sector_preference =
                    family_trait_behavior_factor_q16(
                        candidate.plan.sponsor_family_handle, 0, 1,
                        type.economic_sector, cell);
                candidate.score_q16 = mul_div_sat(candidate.score_q16,
                    stable_preference, Q16_ONE, _saturation_count);
                candidate.score_q16 = mul_div_sat(candidate.score_q16,
                    sector_preference, Q16_ONE, _saturation_count);
                int32_t family_index = -1;
                if (families_store().valid_handle(candidate.plan.sponsor_family_handle,
                        family_index) &&
                    family_index >= 0 && family_index < static_cast<int32_t>(
                        _family_investment_factor_q16.size())) {
                    candidate.score_q16 = mul_div_sat(candidate.score_q16,
                        _family_investment_factor_q16[
                            static_cast<size_t>(family_index)],
                        Q16_ONE, _saturation_count);
                }
                auto mix_score_term = [&](int32_t term, int32_t signal_q16) {
                    const int32_t factor = family_behavior_score_term_q16(
                        candidate.plan.sponsor_family_handle, cell, term);
                    if (factor == Q16_ONE) return;
                    const int64_t mix = saturating_add(Q16_ONE,
                        mul_div_sat(static_cast<int64_t>(factor) - Q16_ONE,
                            std::clamp<int32_t>(signal_q16, 0,
                                static_cast<int32_t>(Q16_ONE)),
                            Q16_ONE, _saturation_count),
                        _saturation_count);
                    candidate.score_q16 = mul_div_sat(candidate.score_q16,
                        mix, Q16_ONE, _saturation_count);
                };
                if (daily_cash_revenue > 0) {
                    const int32_t after_share = static_cast<int32_t>(
                        std::clamp<int64_t>(mul_div_sat(
                            daily_after_tax_cash_revenue, Q16_ONE,
                            daily_cash_revenue, _saturation_count),
                            0, Q16_ONE));
                    mix_score_term(FAMILY_SCORE_TAX_SENSITIVITY, after_share);
                }
                mix_score_term(FAMILY_SCORE_LOCAL_RESOURCE_ABUNDANCE,
                    building_local_resource_abundance_q16(cell, type_id));
                if (_max_building_upgrade_tier > 0)
                    mix_score_term(FAMILY_SCORE_UPGRADE_TIER,
                        static_cast<int32_t>(mul_div_sat(
                            type.upgrade_tier, Q16_ONE,
                            _max_building_upgrade_tier, _saturation_count)));
                mix_score_term(FAMILY_SCORE_LOCAL_POPULARITY,
                    static_cast<int32_t>(std::clamp<int64_t>(
                        margin_q16, 0, Q16_ONE)));
            }
            type_has_viable_candidate = true;
        if (diagnostic != nullptr) {
                diagnostic->rejection_reason = INVESTMENT_REJECTION_NONE;
                diagnostic->score_q16 = candidate.score_q16;
                diagnostic->payback_days = payback;
                diagnostic->required_capital = required_capital;
                diagnostic->projected_profit_per_day = daily_profit;
                diagnostic->return_on_capital_q16 = return_on_capital_q16;
                diagnostic->cost_advantage_q16 = cost_advantage_q16;
                diagnostic->stealable = stealable;
                diagnostic->challenger_unit_cost = challenger_unit_cost;
                diagnostic->incumbent_unit_cost = incumbent_unit_cost;
            }
            if (existing_group >= 0) {
                investment_mark_rejection(existing, INVESTMENT_REJECTION_NONE);
                for (int32_t group = existing->first_group;
                     group <= existing->last_group; ++group) {
                    if (buildings_store().cell[group] != cell ||
                        buildings_store().type_id[group] != type_id) break;
                    _building_investment_score_q16[group] = candidate.score_q16;
                    _building_investment_payback_days[group] = payback;
                }
            }
            if (BuildingInvestmentCellContext::better(candidate, type_best))
                type_best = candidate;
        }
        if (type_best.plan.type_id >= 0) {
            if (!sparse_selected) {
                ++_investment_sparse_mismatches;
                _investment_sparse_runtime_disabled = true;
            }
            ctx.insert_candidate(type_best, _investment_portfolio_max_types.get());
        }
    }
    if (portfolio_size <= 0) {
        if (eligible_but_unfunded)
            ++_building_investment_blocked_sponsor_capital;
        return false;
    }
    return true;
}

} // namespace pk
