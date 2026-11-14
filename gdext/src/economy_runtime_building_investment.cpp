#include "economy_runtime.h"
#include "economy_runtime_building_investment_internal.h"
#include "economy_cost_probe.h"
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
static std::vector<int64_t> &investment_cell_profession_population() {
    thread_local std::vector<int64_t> cell_profession_population;
    return cell_profession_population;
}
} // namespace

NativeEconomyRuntime::BuildingInvestmentCellContext::BuildingInvestmentCellContext(
        int32_t cell_value)
    : cell(cell_value),
      cell_profession_population(investment_cell_profession_population()) {}

void NativeEconomyRuntime::investment_mark_rejection(
        const InvestmentExistingType *existing, int32_t reason) {
    if (existing == nullptr || existing->first_group < 0) return;
    const int32_t end = std::min<int32_t>(
        static_cast<int32_t>(building_count()), existing->last_group + 1);
    for (int32_t group = existing->first_group; group < end; ++group) {
        if (buildings_store().cell[group] != buildings_store().cell[existing->first_group] ||
            buildings_store().type_id[group] != buildings_store().type_id[existing->first_group])
            break;
        if (group < static_cast<int32_t>(_building_investment_rejection.size()))
            _building_investment_rejection[group] = reason;
    }
}

void NativeEconomyRuntime::begin_investment_scratch_generation() {
    const size_t resource_lanes =
        _resource_ids.size() * static_cast<size_t>(_cell_count.get());
    _investment_resource_committed_by_cell.resize(resource_lanes);
    _investment_merchant_cash_by_cell.resize(static_cast<size_t>(_cell_count.get()));
    _investment_outstanding_credit_by_cell.resize(
        static_cast<size_t>(_cell_count.get()));
    if (_investment_resource_commitment_stamp.size() != resource_lanes)
        _investment_resource_commitment_stamp.assign(resource_lanes, 0);
    if (_investment_cell_finance_stamp.size() !=
            static_cast<size_t>(_cell_count.get())) {
        _investment_cell_finance_stamp.assign(
            static_cast<size_t>(_cell_count.get()), 0);
    }
    ++_investment_scratch_generation;
    if (_investment_scratch_generation == 0) {
        std::fill(_investment_resource_commitment_stamp.begin(),
                  _investment_resource_commitment_stamp.end(), 0);
        std::fill(_investment_cell_finance_stamp.begin(),
                  _investment_cell_finance_stamp.end(), 0);
        _investment_scratch_generation = 1;
    }
}

void NativeEconomyRuntime::ensure_investment_cell_finance_lane(int32_t cell) {
    if (cell < 0 || cell >= _cell_count.get() ||
        static_cast<size_t>(cell) >= _investment_cell_finance_stamp.size() ||
        _investment_cell_finance_stamp[cell] ==
            _investment_scratch_generation) {
        return;
    }
    _investment_cell_finance_stamp[cell] = _investment_scratch_generation;
    _investment_merchant_cash_by_cell[cell] = 0;
    _investment_outstanding_credit_by_cell[cell] = 0;
}

void NativeEconomyRuntime::ensure_investment_resource_commitment_lane(
        size_t index) {
    if (index >= _investment_resource_commitment_stamp.size() ||
        _investment_resource_commitment_stamp[index] ==
            _investment_scratch_generation) {
        return;
    }
    _investment_resource_commitment_stamp[index] =
        _investment_scratch_generation;
    _investment_resource_committed_by_cell[index] = 0;
}

int64_t NativeEconomyRuntime::investment_merchant_cash(int32_t cell) const {
    return cell >= 0 && cell < _cell_count.get() &&
            static_cast<size_t>(cell) < _investment_cell_finance_stamp.size() &&
            _investment_cell_finance_stamp[cell] ==
                _investment_scratch_generation
        ? _investment_merchant_cash_by_cell[cell] : 0;
}

int64_t NativeEconomyRuntime::investment_outstanding_credit(
        int32_t cell) const {
    return cell >= 0 && cell < _cell_count.get() &&
            static_cast<size_t>(cell) < _investment_cell_finance_stamp.size() &&
            _investment_cell_finance_stamp[cell] ==
                _investment_scratch_generation
        ? _investment_outstanding_credit_by_cell[cell] : 0;
}

int64_t NativeEconomyRuntime::investment_resource_committed(
        size_t index) const {
    return index < _investment_resource_commitment_stamp.size() &&
            _investment_resource_commitment_stamp[index] ==
                _investment_scratch_generation
        ? _investment_resource_committed_by_cell[index] : 0;
}

void NativeEconomyRuntime::prepare_investment_review_cells() {
    _investment_review_cell_indices.clear();
    if (_current_day.get() <= 0 || _cell_count.get() <= 0) {
        _investment_scheduled_review_cells = 0;
        return;
    }
    const int64_t day = _sample_day >= 0 ? _sample_day : _current_day.get();
    // The epoch preflight has already built the sorted sparse live-cell set.
    // Review only cells that can contain population/buildings/pending work;
    // scanning the full world here would turn an investment batch into a
    // cell-count operation even when the economy is sparse.
    // Employment catch-up is a distinct 30-day lane.  It may wake a sparse
    // cell before its ordinary investment bucket, but never on every daily
    // market pass.  The phase is anchored at day five, which is the first
    // committed settlement after bootstrap, and remains deterministic across
    // continuation slices.
    auto catchup_due = [&](int32_t cell) {
        if (day < 5 || ((day - 5) % 30) != 0) return false;
        int64_t population = 0;
        int64_t unemployed = 0;
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const int64_t pop = std::max<int64_t>(0,
                population_store().population[slot]);
            const int64_t employed = std::max<int64_t>(0,
                saturating_add(population_store().owner_employed[slot],
                    population_store().employee_employed[slot],
                    _saturation_count));
            population = saturating_add(population, pop, _saturation_count);
            unemployed = saturating_add(unemployed,
                std::max<int64_t>(0, pop - employed), _saturation_count);
        });
        return population > 0 && unemployed * 4 > population;
    };
    for (const int32_t cell : _economy_live_cells) {
        if (cell < 0 || cell >= _cell_count.get()) continue;
        const bool due = cell_due_investment_review(cell, day) || catchup_due(cell);
        if (_committed_cells[cell].population <= 0 || !due) {
            continue;
        }
        _investment_review_cell_indices.push_back(cell);
    }
    _investment_scheduled_review_cells = static_cast<int64_t>(
        _investment_review_cell_indices.size());
}


bool NativeEconomyRuntime::run_endogenous_building_investment(
        int32_t ordinal_begin, int32_t ordinal_end, bool initialize,
        bool &population_changed, std::string &error) {
    population_changed = false;
    if (_building_cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1))
        return true;
    // The Track-B spread path carries review cells into later epochs without
    // running the phase-4 prepare, while phase 6 clears the transient incumbent
    // index at every epoch end. Key the prepare off the epoch itself so the
    // first evaluation slice of any epoch always rebuilds that index; otherwise
    // carried cells are reviewed as greenfield, the owner-vacancy gate and the
    // staffing ceiling silently disappear, and empty shells keep expanding.
    const bool need_prepare = initialize ||
        _investment_prepared_epoch != _epoch_id.get();
    if (need_prepare) _investment_prepared_epoch = _epoch_id.get();
    auto type_emits_monetary = [&](int32_t type_id) {
        if (type_id < 0 || type_id >= static_cast<int32_t>(
                _building_types.size())) return false;
        const BuildingType &type = _building_types[type_id];
        for (int32_t output = 0; output < type.output_count; ++output) {
            const int32_t good = _building_outputs[
                type.output_begin + output].good_id;
            if (good >= 0 && good < static_cast<int32_t>(
                    _good_monetary_issue_values.size()) &&
                _good_monetary_issue_values[good] > 0) return true;
        }
        return false;
    };
    if (need_prepare) {
        const auto prepare_lanes_started = Clock::now();
        _building_investment_score_q16.assign(building_count(), 0);
        _building_investment_payback_days.assign(building_count(), 0);
        _building_investment_rejection.assign(building_count(), 0);
        _investment_pending_by_cell_type.clear();
        _investment_existing_by_cell_type.clear();
        const size_t review_divisor = static_cast<size_t>(
            std::max(1, _investment_review_days.get()));
        _investment_pending_by_cell_type.reserve(
            pending_construction_count() / review_divisor * 2 + 1);
        _investment_existing_by_cell_type.reserve(
            building_count() / review_divisor * 2 + 1);
        begin_investment_scratch_generation();
        _investment_monetary_units_by_cell.assign(
            static_cast<size_t>(std::max(0, _cell_count.get())), 0);
        if (_merchant_offsets.size() == static_cast<size_t>(_cell_count.get() + 1)) {
            for (const int32_t cell : _investment_review_cell_indices) {
                ensure_investment_cell_finance_lane(cell);
                for (int32_t k = _merchant_offsets[cell];
                     k < _merchant_offsets[cell + 1]; ++k) {
                    const int32_t merchant_slot = _merchant_slots[k];
                    _investment_merchant_cash_by_cell[cell] = saturating_add(
                        _investment_merchant_cash_by_cell[cell],
                        std::max<int64_t>(0, population_store().funds[merchant_slot]),
                        _saturation_count);
                }
            }
        }
        _investment_prepare_lanes_ms += elapsed_ms(prepare_lanes_started);
    }
    if (need_prepare) {
      auto is_review_cell = [&](int32_t cell) {
          return std::binary_search(_investment_review_cell_indices.begin(),
                                    _investment_review_cell_indices.end(), cell);
      };
      const auto prepare_pending_started = Clock::now();
      for (const auto pending : pending_construction()) {
        if (!is_review_cell(pending.cell)) continue;
        ensure_investment_cell_finance_lane(pending.cell);
        const uint64_t key = BuildingInvestmentCellContext::cell_key(pending.cell, pending.type_id);
        _investment_pending_by_cell_type[key] = saturating_add(
            _investment_pending_by_cell_type[key],
            std::max<int64_t>(0, pending.count), _saturation_count);
        if (pending.cell >= 0 && pending.cell < _cell_count.get()) {
            _investment_outstanding_credit_by_cell[pending.cell] =
                saturating_add(
                    _investment_outstanding_credit_by_cell[pending.cell],
                    std::max<int64_t>(0, pending.merchant_debt_principal),
                    _saturation_count);
            if (pending.type_id >= 0 && pending.type_id < static_cast<int32_t>(
                    _building_types.size()) && pending.count > 0) {
                const BuildingType &type = _building_types[pending.type_id];
                if (type_emits_monetary(pending.type_id)) {
                    _investment_monetary_units_by_cell[pending.cell] =
                        saturating_add(_investment_monetary_units_by_cell[
                            pending.cell], pending.count, _saturation_count);
                }
                for (int32_t edge = 0; edge < type.resource_count; ++edge) {
                    const ResourceAmount &item = _building_resources[
                        type.resource_begin + edge];
                    // mode 0 = extract (daily claim); mode 1 = capacity
                    // (standing claim count × quantity against reserve).
                    if ((item.mode != 0 && item.mode != 1) ||
                        item.quantity <= 0) continue;
                    const size_t idx = static_cast<size_t>(item.resource_id) *
                        _cell_count.get() + pending.cell;
                    ensure_investment_resource_commitment_lane(idx);
                    const int64_t effective_quantity =
                        effective_resource_use_quantity(
                            pending.cell, item.resource_id, item.quantity,
                            _saturation_count);
                    _investment_resource_committed_by_cell[idx] = saturating_add(
                        _investment_resource_committed_by_cell[idx],
                        saturating_mul(pending.count, effective_quantity,
                            _saturation_count), _saturation_count);
                }
            }
        }
      }
      _investment_prepare_pending_ms += elapsed_ms(prepare_pending_started);
      const auto prepare_groups_started = Clock::now();
      for (const int32_t active_cell : _epoch_building_cells) {
       if (!is_review_cell(active_cell)) continue;
       for (int32_t g = _building_cell_offsets[active_cell];
            g < _building_cell_offsets[active_cell + 1]; ++g) {
       const auto group = building_view(static_cast<size_t>(g));
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count.get() ||
            group.type_id < 0 || group.type_id >= static_cast<int32_t>(_building_types.size()))
            continue;
       const BuildingType &type = _building_types[group.type_id];
        if (group.operating_state == 0 && type_emits_monetary(group.type_id)) {
            _investment_monetary_units_by_cell[group.cell] = saturating_add(
                _investment_monetary_units_by_cell[group.cell], group.count,
                _saturation_count);
        }
        ensure_investment_cell_finance_lane(group.cell);
        for (int32_t edge = 0; edge < type.resource_count; ++edge) {
            const ResourceAmount &item = _building_resources[
                type.resource_begin + edge];
            if ((item.mode != 0 && item.mode != 1) || item.quantity <= 0) continue;
            const size_t idx = static_cast<size_t>(item.resource_id) *
                _cell_count.get() + group.cell;
            ensure_investment_resource_commitment_lane(idx);
            const int64_t effective_quantity = effective_resource_use_quantity(
                group.cell, item.resource_id, item.quantity, _saturation_count);
            _investment_resource_committed_by_cell[idx] = saturating_add(
                _investment_resource_committed_by_cell[idx],
                saturating_mul(group.count, effective_quantity,
                    _saturation_count), _saturation_count);
        }
        _investment_outstanding_credit_by_cell[group.cell] =
            saturating_add(
                _investment_outstanding_credit_by_cell[group.cell],
                std::max<int64_t>(0, group.merchant_debt_principal),
                _saturation_count);
        InvestmentExistingType &existing = _investment_existing_by_cell_type[
            BuildingInvestmentCellContext::cell_key(group.cell, group.type_id)];
        if (existing.first_group < 0) existing.first_group = g;
        existing.last_group = g;
        if (existing.representative_group < 0 ||
            (group.operating_state != 1 && buildings_store().operating_state[
                existing.representative_group] == 1))
            existing.representative_group = g;
        existing.installed_count = saturating_add(
            existing.installed_count, group.count, _saturation_count);
        // `last_capacity_q16` is the maximum executable share after inputs,
        // resources, climate, and funding are applied. It is not the share
        // the market currently intends to use. Reserve only the executable
        // capacity that is still genuinely idle; treating the gap to 100%
        // as idle makes climate/resource-limited but fully utilized buildings
        // suppress valid investment and employment catch-up.
        const int64_t physical_capacity_q16 = group.operating_state == 1
            ? 0
            : std::clamp<int64_t>(group.last_capacity_q16, 0, Q16_ONE);
        const int64_t planned_utilization_q16 = group.operating_state == 1
            ? 0
            : std::clamp<int64_t>(group.planned_utilization_q16, 0, Q16_ONE);
        const int64_t idle_capacity_q16 = std::max<int64_t>(
            0, physical_capacity_q16 - planned_utilization_q16);
        existing.idle_capacity_q16 = saturating_add(
            existing.idle_capacity_q16,
            saturating_mul(group.count, idle_capacity_q16,
                _saturation_count),
            _saturation_count);
        if (group.operating_state != 1) {
            existing.active_count = saturating_add(
                existing.active_count, group.count, _saturation_count);
            existing.owner_required = saturating_add(
                existing.owner_required,
                planned_owner_demand(group, _saturation_count),
                _saturation_count);
            existing.sum_last_revenue = saturating_add(
                existing.sum_last_revenue,
                std::max<int64_t>(0, group.last_revenue), _saturation_count);
            existing.sum_last_in_kind_livelihood = saturating_add(
                existing.sum_last_in_kind_livelihood,
                std::max<int64_t>(0, group.last_in_kind_livelihood_value),
                _saturation_count);
            existing.sum_last_input_cost = saturating_add(
                existing.sum_last_input_cost,
                std::max<int64_t>(0, group.last_input_cost), _saturation_count);
            existing.sum_last_base_wages_due = saturating_add(
                existing.sum_last_base_wages_due,
                std::max<int64_t>(0, group.last_base_wages_due),
                _saturation_count);
            existing.sum_last_maintenance_cost = saturating_add(
                existing.sum_last_maintenance_cost,
                std::max<int64_t>(0, group.last_maintenance_cost),
                _saturation_count);
            existing.sum_last_output = saturating_add(
                existing.sum_last_output,
                std::max<int64_t>(0, group.last_output), _saturation_count);
        } else {
            existing.suspended_count = saturating_add(
                existing.suspended_count, group.count, _saturation_count);
        }
        existing.filled_owner = saturating_add(
            existing.filled_owner, std::max<int64_t>(0, group.filled_owner),
            _saturation_count);
        existing.last_sold = saturating_add(
            existing.last_sold, std::max<int64_t>(0, group.last_sold),
            _saturation_count);
        existing.last_discarded = saturating_add(
            existing.last_discarded, std::max<int64_t>(0, group.last_discarded),
            _saturation_count);
       }
      }
      _investment_prepare_groups_ms += elapsed_ms(prepare_groups_started);
      prepare_startup_demand();
    }

    const int32_t investment_cell_count = static_cast<int32_t>(
        _investment_review_cell_indices.size());
    ordinal_begin = std::clamp(ordinal_begin, 0, investment_cell_count);
    ordinal_end = std::clamp(ordinal_end, ordinal_begin, investment_cell_count);
    // Splits the per-cell body into candidate evaluation and capital
    // allocation. The destructor closes the open phase so the many `continue`
    // paths through the body stay accounted for.
    struct PhaseTimer {
        Clock::time_point mark;
        double *sink;
        ~PhaseTimer() { *sink += elapsed_ms(mark); }
        void switch_to(double *next) {
            *sink += elapsed_ms(mark);
            mark = Clock::now();
            sink = next;
        }
    };
    for (int32_t ordinal = ordinal_begin; ordinal < ordinal_end; ++ordinal) {
        PhaseTimer investment_phase{Clock::now(), &_investment_evaluate_ms};
        const int32_t cell = _investment_review_cell_indices[ordinal];
        StartupProducerMemoScope cell_startup_memo(*this);
        BuildingInvestmentCellContext ctx(cell);
        if (!investment_prepare_cell(ctx))
            continue;
        if (!investment_evaluate_cell_types(ctx))
            continue;

        investment_phase.switch_to(&_investment_allocate_ms);
        investment_allocate_portfolio(ctx);

        const InvestmentPreflightResult preflight =
            investment_preflight_portfolio(ctx, error);
        if (preflight == InvestmentPreflightResult::Skip)
            continue;
        if (preflight == InvestmentPreflightResult::Fatal)
            return false;
        if (!investment_commit_portfolio(ctx, population_changed, error))
            return false;
    }
    if (population_changed && !rebuild_merchant_ranges(error)) return false;
    return true;
}

bool NativeEconomyRuntime::investment_prepare_cell(
        BuildingInvestmentCellContext &ctx) {
    auto &cell = ctx.cell;
    auto &capture_investment_diagnostics = ctx.capture_investment_diagnostics;
    auto &cell_population = ctx.cell_population;
    auto &cell_unemployed = ctx.cell_unemployed;
    auto &cell_profession_population = ctx.cell_profession_population;
    auto &employment_gap = ctx.employment_gap;
    auto &cell_request = ctx.cell_request;

    capture_investment_diagnostics = cell == _inspector_trace_cell;
    if (capture_investment_diagnostics) {
        _investment_diagnostic_cell = cell;
        _investment_diagnostic_day = _current_day.get();
        _investment_diagnostics.clear();
        _investment_diagnostics.reserve(_building_types.size());
    }
    ++_investment_review_cells;
    // Construction pays materials to local merchants; a cell whose
    // merchant cohorts all died has no seller and cannot build.
    if (!local_merchants_can_receive(cell)) return false;
    cell_population = 0;
    cell_unemployed = 0;
    cell_profession_population.assign(_profession_ids.size(), 0);
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        const int64_t population = std::max<int64_t>(
            0, population_store().population[slot]);
        const int64_t employed = std::max<int64_t>(0,
            saturating_add(population_store().owner_employed[slot],
                population_store().employee_employed[slot], _saturation_count));
        cell_population = saturating_add(
            cell_population, population, _saturation_count);
        cell_unemployed = saturating_add(cell_unemployed,
            std::max<int64_t>(0, population - employed),
            _saturation_count);
        if (static_cast<int32_t>(population_store().signature_id[slot]) >= 0 &&
            static_cast<int32_t>(population_store().signature_id[slot]) <
                static_cast<int32_t>(_signatures.size())) {
            const int32_t profession = _signatures[
                population_store().signature_id[slot]].profession_id;
            if (profession >= 0 && profession <
                    static_cast<int32_t>(cell_profession_population.size()))
                cell_profession_population[profession] = saturating_add(
                    cell_profession_population[profession], population,
                    _saturation_count);
        }
    });
    employment_gap = std::max<int64_t>(
        0, cell_unemployed - cell_population / 4);
    cell_request = {};
    cell_request.reason = cell_population > 0 &&
            cell_unemployed > cell_population / 4
        ? INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP
        : INVESTMENT_REQUEST_ORDINARY_EXPANSION;
    cell_request.demand_pressure = employment_gap;
    cell_request.allow_credit = true;
    cell_request.allow_reallocation =
        cell_request.reason == INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP;
    if (cell_request.reason == INVESTMENT_REQUEST_EMPLOYMENT_CATCHUP) {
        ++_building_investment_employment_catchup_cells;
        _building_investment_employment_gap = saturating_add(
            _building_investment_employment_gap, employment_gap,
            _saturation_count);
    }
    propagate_startup_demand_for_cell(cell);
    if (_investment_sparse_mode != 0) {
        refresh_investment_active_goods_for_cell(cell, _saturation_count);
    }
    return true;
}


} // namespace pk
