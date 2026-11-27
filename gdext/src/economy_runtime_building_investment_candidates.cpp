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
            return essential_living_cost_for_signature(cell, signature_id, -1, sat);
        int64_t &cached = investment_living_cost_cache[key];
        if (cached >= 0) return cached;
        const int64_t saturation_before = sat;
        const int64_t value = essential_living_cost_for_signature(cell, signature_id, -1, sat);
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
    const auto sparse_filter = prepare_investment_sparse_filter(ctx);
    const bool sparse_filter_active = sparse_filter.active;
    const bool sparse_mask_ready = sparse_filter.ready;
    const uint32_t investment_review_stamp = sparse_filter.stamp;

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
                investment_living_cost(group.owner_signature_id,
                    _saturation_count),
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
        ctx.begin_type_review(*this, existing);
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
#include "economy_runtime_building_investment_candidates_output_demand.inc"
#include "economy_runtime_building_investment_candidates_resource_and_input_quotes.inc"
#include "economy_runtime_building_investment_candidates_viability.inc"
#include "economy_runtime_building_investment_candidates_sponsor_evaluation.inc"
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
