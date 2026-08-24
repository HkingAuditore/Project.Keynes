#include "economy_runtime.h"
#include "country_runtime.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <limits>

namespace pk {

namespace {
using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

void NativeEconomyRuntime::begin_investment_scratch_generation() {
    const size_t resource_lanes =
        _resource_ids.size() * static_cast<size_t>(_cell_count);
    _investment_resource_committed_by_cell.resize(resource_lanes);
    _investment_merchant_cash_by_cell.resize(static_cast<size_t>(_cell_count));
    _investment_outstanding_credit_by_cell.resize(
        static_cast<size_t>(_cell_count));
    if (_investment_resource_commitment_stamp.size() != resource_lanes)
        _investment_resource_commitment_stamp.assign(resource_lanes, 0);
    if (_investment_cell_finance_stamp.size() !=
            static_cast<size_t>(_cell_count)) {
        _investment_cell_finance_stamp.assign(
            static_cast<size_t>(_cell_count), 0);
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
    if (cell < 0 || cell >= _cell_count ||
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
    return cell >= 0 && cell < _cell_count &&
            static_cast<size_t>(cell) < _investment_cell_finance_stamp.size() &&
            _investment_cell_finance_stamp[cell] ==
                _investment_scratch_generation
        ? _investment_merchant_cash_by_cell[cell] : 0;
}

int64_t NativeEconomyRuntime::investment_outstanding_credit(
        int32_t cell) const {
    return cell >= 0 && cell < _cell_count &&
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
    if (_current_day <= 0 || _cell_count <= 0) {
        _investment_scheduled_review_cells = 0;
        return;
    }
    const int64_t day = _sample_day >= 0 ? _sample_day : _current_day;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (!cell_due_investment_review(cell, day) ||
            _committed_cells[cell].population <= 0) {
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
    if (_building_cell_offsets.size() != static_cast<size_t>(_cell_count + 1))
        return true;
    if (initialize) {
        const auto prepare_lanes_started = Clock::now();
        _building_investment_score_q16.assign(_buildings.size(), 0);
        _building_investment_payback_days.assign(_buildings.size(), 0);
        _building_investment_rejection.assign(_buildings.size(), 0);
        _investment_pending_by_cell_type.clear();
        _investment_existing_by_cell_type.clear();
        const size_t review_divisor = static_cast<size_t>(
            std::max(1, _investment_review_days));
        _investment_pending_by_cell_type.reserve(
            _pending_construction.size() / review_divisor * 2 + 1);
        _investment_existing_by_cell_type.reserve(
            _buildings.size() / review_divisor * 2 + 1);
        begin_investment_scratch_generation();
        if (_merchant_offsets.size() == static_cast<size_t>(_cell_count + 1)) {
            for (const int32_t cell : _investment_review_cell_indices) {
                ensure_investment_cell_finance_lane(cell);
                for (int32_t k = _merchant_offsets[cell];
                     k < _merchant_offsets[cell + 1]; ++k) {
                    const int32_t merchant_slot = _merchant_slots[k];
                    _investment_merchant_cash_by_cell[cell] = saturating_add(
                        _investment_merchant_cash_by_cell[cell],
                        std::max<int64_t>(0, _population.funds[merchant_slot]),
                        _saturation_count);
                }
            }
        }
        _investment_prepare_lanes_ms += elapsed_ms(prepare_lanes_started);
    }
    struct Candidate {
        int32_t type = -1;
        int32_t target_signature = -1;
        int32_t sponsor = -1;
        uint64_t sponsor_family_handle = 0;
        int64_t required_capital = 0;
        int64_t construction_cost = 0;
        int64_t projected_income = 0;
        int64_t shortage_q16 = 0;
        int64_t utilization_q16 = 0;
        int64_t profit_per_day = 0;
        int64_t score_q16 = 0;
        int64_t payback_days = 0;
        int32_t driver_good_id = -1;
        int64_t driver_deficit = 0;
        int64_t driver_output_per_building = 0;
        int64_t willing_population = 0;
        int64_t transferable_capital = 0;
        int64_t income_improvement_q16 = 0;
        int64_t desired_count = 0;
        int64_t max_batch_count = 0;
        int64_t allocated_count = 0;
        int64_t jobs_per_building = 0;
        int64_t merchant_credit = 0;
        bool uses_merchant_credit = false;
        int64_t stealable = 0;
        int64_t challenger_unit_cost = 0;
        int64_t incumbent_unit_cost = 0;
        bool displaces_incumbents = false;
    };
    auto better = [](const Candidate &a, const Candidate &b,
                     bool employment_catchup) {
        if (b.type < 0) return true;
        if (employment_catchup &&
            a.jobs_per_building != b.jobs_per_building) {
            return a.jobs_per_building > b.jobs_per_building;
        }
        if (a.score_q16 != b.score_q16) return a.score_q16 > b.score_q16;
        if (a.income_improvement_q16 != b.income_improvement_q16)
            return a.income_improvement_q16 > b.income_improvement_q16;
        if (a.payback_days != b.payback_days) return a.payback_days < b.payback_days;
        if (a.type != b.type) return a.type < b.type;
        return a.target_signature < b.target_signature;
    };
    auto cell_key = [](int32_t cell, int32_t id) -> uint64_t {
        return (static_cast<uint64_t>(static_cast<uint32_t>(cell)) << 32) |
            static_cast<uint32_t>(id);
    };
    auto mark_rejection = [&](const InvestmentExistingType *existing,
                              int32_t reason) {
        if (existing == nullptr || existing->first_group < 0) return;
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_buildings.size()), existing->last_group + 1);
        for (int32_t group = existing->first_group; group < end; ++group) {
            if (_buildings[group].cell != _buildings[existing->first_group].cell ||
                _buildings[group].type_id != _buildings[existing->first_group].type_id)
                break;
            if (group < static_cast<int32_t>(_building_investment_rejection.size()))
                _building_investment_rejection[group] = reason;
        }
    };
    if (initialize) {
      auto is_review_cell = [&](int32_t cell) {
          return std::binary_search(_investment_review_cell_indices.begin(),
                                    _investment_review_cell_indices.end(), cell);
      };
      const auto prepare_pending_started = Clock::now();
      for (const PendingConstruction &pending : _pending_construction) {
        if (!is_review_cell(pending.cell)) continue;
        ensure_investment_cell_finance_lane(pending.cell);
        const uint64_t key = cell_key(pending.cell, pending.type_id);
        _investment_pending_by_cell_type[key] = saturating_add(
            _investment_pending_by_cell_type[key],
            std::max<int64_t>(0, pending.count), _saturation_count);
        if (pending.cell >= 0 && pending.cell < _cell_count) {
            _investment_outstanding_credit_by_cell[pending.cell] =
                saturating_add(
                    _investment_outstanding_credit_by_cell[pending.cell],
                    std::max<int64_t>(0, pending.merchant_debt_principal),
                    _saturation_count);
            if (pending.type_id >= 0 && pending.type_id < static_cast<int32_t>(
                    _building_types.size()) && pending.count > 0) {
                const BuildingType &type = _building_types[pending.type_id];
                for (int32_t edge = 0; edge < type.resource_count; ++edge) {
                    const ResourceAmount &item = _building_resources[
                        type.resource_begin + edge];
                    if (item.mode != 0 || item.quantity <= 0) continue;
                    const size_t idx = static_cast<size_t>(item.resource_id) *
                        _cell_count + pending.cell;
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
        const BuildingGroup &group = _buildings[g];
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count ||
            group.type_id < 0 || group.type_id >= static_cast<int32_t>(_building_types.size()))
            continue;
       const BuildingType &type = _building_types[group.type_id];
        ensure_investment_cell_finance_lane(group.cell);
        for (int32_t edge = 0; edge < type.resource_count; ++edge) {
            const ResourceAmount &item = _building_resources[
                type.resource_begin + edge];
            if (item.mode != 0 || item.quantity <= 0) continue;
            const size_t idx = static_cast<size_t>(item.resource_id) *
                _cell_count + group.cell;
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
            cell_key(group.cell, group.type_id)];
        if (existing.first_group < 0) existing.first_group = g;
        existing.last_group = g;
        if (existing.representative_group < 0 ||
            (group.operating_state != 1 && _buildings[
                existing.representative_group].operating_state == 1))
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
        const bool capture_investment_diagnostics =
            cell == _inspector_trace_cell;
        if (capture_investment_diagnostics) {
            _investment_diagnostic_cell = cell;
            _investment_diagnostic_day = _current_day;
            _investment_diagnostics.clear();
            _investment_diagnostics.reserve(_building_types.size());
        }
        ++_investment_review_cells;
        int64_t cell_population = 0;
        int64_t cell_unemployed = 0;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const int64_t population = std::max<int64_t>(
                0, _population.population[slot]);
            const int64_t employed = std::max<int64_t>(0,
                saturating_add(_population.owner_employed[slot],
                    _population.employee_employed[slot], _saturation_count));
            cell_population = saturating_add(
                cell_population, population, _saturation_count);
            cell_unemployed = saturating_add(cell_unemployed,
                std::max<int64_t>(0, population - employed),
                _saturation_count);
        });
        const int64_t employment_gap = std::max<int64_t>(
            0, cell_unemployed - cell_population / 4);
        const bool employment_catchup = cell_population > 0 &&
            cell_unemployed > cell_population / 4;
        if (employment_catchup) {
            ++_building_investment_employment_catchup_cells;
            _building_investment_employment_gap = saturating_add(
                _building_investment_employment_gap, employment_gap,
                _saturation_count);
        }
        if (_investment_sparse_mode != 0) {
            refresh_investment_active_goods_for_market(
                _market.cell_to_market[cell], _saturation_count);
        }
        std::array<Candidate, 4> portfolio{};
        int32_t portfolio_size = 0;
        auto insert_portfolio = [&](const Candidate &candidate) {
            int32_t pos = portfolio_size;
            for (int32_t i = 0; i < portfolio_size; ++i) {
                if (better(candidate, portfolio[i], employment_catchup)) {
                    pos = i;
                    break;
                }
            }
            if (pos >= _investment_portfolio_max_types) return;
            const int32_t new_size = std::min(
                _investment_portfolio_max_types, portfolio_size + 1);
            for (int32_t i = new_size - 1; i > pos; --i)
                portfolio[i] = portfolio[i - 1];
            portfolio[pos] = candidate;
            portfolio_size = new_size;
        };
        bool eligible_but_unfunded = false;
        const int32_t market = _market.cell_to_market[cell];
        const int32_t country = _epoch_cell_country.size() ==
                static_cast<size_t>(_cell_count)
            ? _epoch_cell_country[static_cast<size_t>(cell)] : -1;
        const int32_t available_begin = country >= 0 &&
                country + 1 < static_cast<int32_t>(
                    _epoch_country_building_type_offsets.size())
            ? _epoch_country_building_type_offsets[country] : 0;
        const int32_t available_end = country >= 0 &&
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
                (static_cast<size_t>(_market.good_count) + 63U) / 64U;
            const size_t word_begin =
                static_cast<size_t>(std::max(0, market)) * words_per_market;
            sparse_mask_ready = market >= 0 &&
                word_begin + words_per_market <=
                    _investment_active_good_words.size();
            if (sparse_mask_ready) {
                for (int32_t good = 0; good < _market.good_count; ++good) {
                    const uint64_t word = _investment_active_good_words[
                        word_begin + static_cast<size_t>(good / 64)];
                    if ((word & (uint64_t{1} <<
                            static_cast<uint32_t>(good % 64))) != 0) {
                        enqueue_good(good);
                    }
                }
                if (_building_cell_offsets.size() ==
                        static_cast<size_t>(_cell_count + 1)) {
                    for (int32_t group = _building_cell_offsets[cell];
                         group < _building_cell_offsets[cell + 1]; ++group) {
                        const int32_t local_type = _buildings[group].type_id;
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
                        static_cast<size_t>(_cell_count + 1)) {
                    for (int32_t cursor =
                             _pending_construction_cell_offsets[cell];
                         cursor < _pending_construction_cell_offsets[cell + 1];
                         ++cursor) {
                        const int32_t pending_index =
                            _pending_construction_cell_indices[cursor];
                        if (pending_index >= 0 &&
                            pending_index < static_cast<int32_t>(
                                _pending_construction.size())) {
                            mark_type(
                                _pending_construction[pending_index].type_id);
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
            _current_day % _full_audit_verify_interval_days == 0;
        bool sparse_filter_active = _investment_sparse_mode == 2 &&
            !_investment_sparse_runtime_disabled && sparse_mask_ready &&
            !capture_investment_diagnostics && !sparse_full_verification &&
            !employment_catchup;
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
        int64_t cell_max_sponsor_funds = 0;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            cell_max_sponsor_funds = std::max(
                cell_max_sponsor_funds, _population.funds[slot]);
        });
        int64_t cell_credit_construction_cover = 0;
        if (_merchant_credit_runtime_mode == 2) {
            const int64_t merchant_cash = investment_merchant_cash(cell);
            const int64_t outstanding = investment_outstanding_credit(cell);
            const int64_t exposure = mul_div_sat(merchant_cash,
                _merchant_credit_exposure_q16, Q16_ONE, _saturation_count);
            const int64_t reserve = mul_div_sat(merchant_cash,
                _merchant_procurement_cash_reserve_q16, Q16_ONE,
                _saturation_count);
            cell_credit_construction_cover = std::max<int64_t>(0, std::min(
                exposure - std::min(exposure, outstanding),
                merchant_cash - std::min(merchant_cash, reserve)));
        }
        std::vector<InvestmentIncumbentLane> &incumbent_lanes =
            _investment_incumbent_lanes_scratch;
        incumbent_lanes.clear();
        if (_building_cell_offsets.size() ==
                static_cast<size_t>(_cell_count + 1)) {
            const int64_t epoch_days = std::max(1, _epoch_days);
            for (int32_t group_index = _building_cell_offsets[cell];
                 group_index < _building_cell_offsets[cell + 1];
                 ++group_index) {
                const BuildingGroup &group = _buildings[group_index];
                if (group.count <= 0 || group.operating_state == 1 ||
                    group.type_id < 0 ||
                    group.type_id >= static_cast<int32_t>(
                        _building_types.size())) continue;
                const BuildingType &incumbent_type =
                    _building_types[group.type_id];
                const int64_t building_days = saturating_mul(
                    group.count, epoch_days, _saturation_count);
                for (int32_t output = 0;
                     output < incumbent_type.output_count; ++output) {
                    const GoodAmount &item = _building_outputs[
                        incumbent_type.output_begin + output];
                    const int64_t qty = effective_building_output_quantity(
                        group, item.good_id, item.quantity,
                        group.last_capacity_q16, building_days,
                        _saturation_count);
                    if (qty <= 0) continue;
                    const int64_t allocated = allocated_output_operating_cost(
                        incumbent_type, output,
                        std::max<int64_t>(0, group.last_operating_cost),
                        _saturation_count);
                    InvestmentIncumbentLane lane;
                    lane.good_id = item.good_id;
                    lane.type_id = group.type_id;
                    lane.unit_cost = mul_div_sat(
                        allocated, GOODS_SCALE, qty, _saturation_count);
                    lane.daily_offered = qty / epoch_days;
                    if (lane.daily_offered <= 0) continue;
                    incumbent_lanes.push_back(lane);
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
        for (int32_t available_index = available_begin;
             available_index < available_end; ++available_index) {
            const int32_t type_id =
                _epoch_country_building_type_indices[available_index];
            ++_investment_sparse_considered_types;
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
            const InvestmentExistingType *existing = nullptr;
            const auto existing_it = _investment_existing_by_cell_type.find(
                cell_key(cell, type_id));
            if (existing_it != _investment_existing_by_cell_type.end()) {
                existing = &existing_it->second;
            }
            auto reject = [&](int32_t reason) {
                if (type_has_viable_candidate) return;
                mark_rejection(existing, reason);
                if (diagnostic != nullptr) diagnostic->rejection_reason = reason;
            };
            // Every unlocked building type enters the same economic review.
            // Types without a marketable output naturally fail the market-signal
            // gate; collectors continue through resource, material, viability,
            // payback, and sponsor-capital checks instead of being hard-disabled.
            const auto pending_it = _investment_pending_by_cell_type.find(
                cell_key(cell, type_id));
            const int64_t pending_count =
                pending_it != _investment_pending_by_cell_type.end()
                    ? std::max<int64_t>(0, pending_it->second) : 0;
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
                    ? _buildings[existing_group].owner_signature_id
                    : signature_for_profession_ethnicity(
                        type.owner_profession_id, 0);
                const int64_t effective_unit_output = existing_group >= 0
                    ? effective_building_output_quantity(
                        _buildings[existing_group], output.good_id, output.quantity,
                        Q16_ONE, 1, _saturation_count)
                    : effective_building_output_quantity_for_target(
                        cell, type_id, representative_owner,
                        output.good_id, output.quantity, Q16_ONE, 1,
                        _saturation_count);
                const int64_t index = _market.index(market, output.good_id);
                const int32_t signal = market_signal_index(cell, output.good_id);
                const bool monetary_issue =
                    _good_monetary_issue_values[output.good_id] > 0;
                const int64_t research_demand =
                    epoch_research_demand_daily(cell, output.good_id);
                const int64_t demand = saturating_add(
                    _market.demand_ema[index],
                    saturating_add(
                        signal >= 0 ? _market_signals.business_demand_ema[signal] : 0,
                        research_demand, _saturation_count),
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
                    0, inventory_target - _market.stock[index]);
                const int64_t gap_daily = inventory_gap > 0
                    ? mul_div_sat(inventory_gap, Q16_ONE,
                        std::max<int64_t>(Q16_ONE,
                            _good_target_inventory_days_q16[output.good_id]),
                        _saturation_count) : 0;
                int64_t output_deficit = std::max<int64_t>(
                    std::max<int64_t>(0, demand - supply), gap_daily);
                int64_t output_pressure_q16 =
                    _market.last_shortage_q16[index];
                if (monetary_issue) {
                    // The mint is a guaranteed marginal buyer. Seed entry
                    // pressure from one building's physical output even before
                    // the first producer exists; the later issuance-cap and
                    // resource-horizon gates remain authoritative.
                    output_deficit = std::max<int64_t>(
                        output_deficit, effective_unit_output);
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
                if (output_deficit <= 0) output_pressure_q16 = 0;
                if (output_deficit > 0 && demand > 0) {
                    output_pressure_q16 = std::max<int64_t>(
                        output_pressure_q16,
                        std::min<int64_t>(Q16_ONE, mul_div_sat(
                            output_deficit, Q16_ONE, demand,
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
                    // Keep merchant_sold as cash-funded merchant procurement,
                    // but treat audited mint settlement as full economic
                    // absorption for the investment sell-through gate.
                    item.sell_through_q16 = monetary_issue
                        ? Q16_ONE
                        : std::clamp<int64_t>(mul_div_sat(
                            item.merchant_sold, Q16_ONE, item.sellable,
                            _saturation_count), 0, Q16_ONE);
                    item.discard_q16 = std::clamp<int64_t>(mul_div_sat(
                        item.discarded, Q16_ONE, item.sellable,
                        _saturation_count), 0, Q16_ONE);
                }
                item.driver_strength_q16 = std::max(
                    item.pressure_q16, item.utilization_q16);
                item.nameplate_output = effective_unit_output;
                item.demand = demand;
                output_signals.push_back(item);
                const OutputInvestmentSignal &candidate = output_signals.back();
                if (driver_index < 0) {
                    driver_index = i;
                } else {
                    const OutputInvestmentSignal &current =
                        output_signals[driver_index];
                    if (candidate.driver_strength_q16 > current.driver_strength_q16 ||
                        (candidate.driver_strength_q16 == current.driver_strength_q16 &&
                         candidate.pressure_q16 > current.pressure_q16) ||
                        (candidate.driver_strength_q16 == current.driver_strength_q16 &&
                         candidate.pressure_q16 == current.pressure_q16 &&
                         candidate.utilization_q16 > current.utilization_q16) ||
                        (candidate.driver_strength_q16 == current.driver_strength_q16 &&
                         candidate.pressure_q16 == current.pressure_q16 &&
                         candidate.utilization_q16 == current.utilization_q16 &&
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
            int64_t stealable = 0;
            int64_t challenger_unit_cost = 0;
            int64_t incumbent_unit_cost = 0;
            bool displaces_incumbents = false;
            const bool survival_output = driver.good_id >= 0 &&
                (_survival_food_good_mask[driver.good_id] != 0 ||
                 _survival_clothing_good_mask[driver.good_id] != 0);
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
            if (!evaluate_building_conditions(type_id, cell)) {
                ++_building_investment_blocked_resources;
                reject(INVESTMENT_REJECTION_RESOURCE);
                continue;
            }
            bool resource_budget_ready = true;
            if (_resource_safe_harvest_q16 > 0) {
                for (int32_t edge = 0; edge < type.resource_count; ++edge) {
                    const ResourceAmount &item = _building_resources[
                        type.resource_begin + edge];
                    if (item.mode != 0 || item.quantity <= 0) continue;
                    const size_t resource_idx = static_cast<size_t>(
                        item.resource_id) * _cell_count + cell;
                    const int64_t committed =
                        investment_resource_committed(resource_idx);
                    int64_t daily_budget = 0;
                    if (resource_is_renewable(item.resource_id)) {
                        daily_budget = renewable_safe_harvest(
                            item.resource_id, cell);
                    } else if (resource_idx < _resource_remaining.size()) {
                        daily_budget = std::max<int64_t>(0,
                            _resource_remaining[resource_idx]) /
                            std::max<int64_t>(1, _resource_min_horizon_days);
                    }
                    const int64_t effective_quantity =
                        effective_resource_use_quantity(
                            cell, item.resource_id, item.quantity,
                            _saturation_count);
                    if (committed > daily_budget ||
                        effective_quantity > daily_budget - committed) {
                        resource_budget_ready = false;
                        break;
                    }
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
            if (!plan_construction_materials(cell, type_id, 1,
                                             country_cost_factor, material_plan)) {
                if (diagnostic != nullptr) {
                    diagnostic->failed_material_group =
                        material_plan.failed_group;
                }
                ++_building_investment_blocked_materials;
                if (material_plan.failed_group >= 0 &&
                    material_plan.failed_group < type.construction_count) {
                    const GoodAmount &preferred = _building_construction_goods[
                        type.construction_begin + material_plan.failed_group];
                    const int32_t signal = ensure_market_signal_index(
                        cell, preferred.good_id);
                    if (signal >= 0) {
                        _market_signals.business_demand_ema[signal] = std::max(
                            _market_signals.business_demand_ema[signal],
                            std::max<int64_t>(1, preferred.quantity /
                                std::max(1, _epoch_days)));
                    }
                }
                reject(INVESTMENT_REJECTION_MATERIALS);
                continue;
            }
            if (diagnostic != nullptr) {
                diagnostic->failed_material_group = -1;
                diagnostic->selected_material_good_ids = material_plan.good_ids;
                diagnostic->selected_material_quantities =
                    material_plan.quantities;
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
            int64_t input_coverage_bound_q16 = Q16_ONE;
            for (int32_t i = 0; i < type.input_count; ++i) {
                const ProductionInput &input = _building_inputs[type.input_begin + i];
                int64_t best_price = std::numeric_limits<int64_t>::max();
                int64_t best_coverage_q16 = -1;
                for (int32_t c = input.candidate_begin;
                     c < input.candidate_begin + input.candidate_count; ++c) {
                    const InputCandidate &candidate = _building_input_candidates[c];
                    if (!good_market_available(cell, candidate.good_id, true)) continue;
                    int64_t physical_daily = mul_div_sat(
                        input.quantity, Q16_ONE, candidate.efficiency_q16,
                        _saturation_count);
                    if (mul_div_sat(physical_daily, candidate.efficiency_q16,
                                    Q16_ONE, _saturation_count) < input.quantity) {
                        physical_daily = saturating_add(
                            physical_daily, 1, _saturation_count);
                    }
                    const int64_t input_index = _market.index(
                        market, candidate.good_id);
                    const int32_t input_signal = market_signal_index(
                        cell, candidate.good_id);
                    const int64_t reserved = input_signal >= 0 && input_signal <
                            static_cast<int32_t>(_production_input_reserve.size())
                        ? _production_input_reserve[input_signal] : 0;
                    const int64_t free_stock = std::max<int64_t>(
                        0, _market.stock[input_index] - reserved);
                    const int64_t effective_period_supply = saturating_add(
                        free_stock, saturating_mul(input_signal >= 0
                            ? _market_signals.offered_supply_ema[input_signal] : 0,
                            std::max(1, _epoch_days), _saturation_count),
                        _saturation_count);
                    const int64_t required_period = saturating_mul(
                        physical_daily, std::max(1, _epoch_days), _saturation_count);
                    const int64_t coverage_q16 = required_period > 0
                        ? std::min<int64_t>(Q16_ONE, mul_div_sat(
                            effective_period_supply, Q16_ONE, required_period,
                            _saturation_count)) : Q16_ONE;
                    const int64_t effective_price = mul_div_sat(
                        _market.price[_market.index(market, candidate.good_id)], Q16_ONE,
                        candidate.efficiency_q16, _saturation_count);
                    if (coverage_q16 > best_coverage_q16 ||
                        (coverage_q16 == best_coverage_q16 &&
                         effective_price < best_price)) {
                        best_coverage_q16 = coverage_q16;
                        best_price = effective_price;
                    }
                }
                if (best_price == std::numeric_limits<int64_t>::max()) {
                    daily_input_cost = std::numeric_limits<int64_t>::max();
                    break;
                }
                const int64_t required_q16 = std::clamp<int64_t>(
                    input.required_q16, 0, Q16_ONE);
                const int64_t soft_bound_q16 = Q16_ONE - required_q16 +
                    mul_div_sat(std::max<int64_t>(0, best_coverage_q16),
                                required_q16, Q16_ONE, _saturation_count);
                input_coverage_bound_q16 = std::min<int64_t>(
                    input_coverage_bound_q16,
                    std::clamp<int64_t>(soft_bound_q16, 0, Q16_ONE));
                daily_input_cost = saturating_add(daily_input_cost, mul_div_sat(
                    input.quantity, best_price, GOODS_SCALE, _saturation_count),
                    _saturation_count);
            }
            if (daily_input_cost == std::numeric_limits<int64_t>::max()) {
                reject(INVESTMENT_REJECTION_INPUT_CHAIN);
                continue;
            }
            int64_t daily_wages = 0;
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                daily_wages = saturating_add(daily_wages, saturating_mul(
                    role.slots_per_building, role.reference_wage_per_day,
                    _saturation_count), _saturation_count);
            }
            const int64_t nameplate_output = std::max<int64_t>(
                0, driver.nameplate_output);
            const int64_t full_operating_cost = saturating_add(
                daily_input_cost, daily_wages, _saturation_count);
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
                stealable = saturating_add(
                    stealable, lane.daily_offered, _saturation_count);
                if (incumbent_unit_cost <= 0 ||
                    lane.unit_cost < incumbent_unit_cost) {
                    incumbent_unit_cost = lane.unit_cost;
                }
            }
            if (stealable > 0)
                ++_investment_displacement_type_evaluations;
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
            } else if (employment_catchup && nameplate_output > 0) {
                // 位移必须先于 catch-up：高失业格上的低成本挑战者仍要走 stealable。
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
            utilization_q16 = std::min(utilization_q16, input_coverage_bound_q16);
            utilization_q16 = std::min(utilization_q16,
                production_climate_capacity_q16(
                    type, cell, nullptr, nullptr, _saturation_count));
            if (utilization_q16 <= 0) {
                reject(INVESTMENT_REJECTION_INPUT_CHAIN);
                continue;
            }
            if (diagnostic != nullptr) {
                diagnostic->shortage_q16 = shortage_q16;
                diagnostic->utilization_q16 = utilization_q16;
                diagnostic->driver_pressure_q16 = driver.pressure_q16;
                diagnostic->driver_utilization_q16 = driver.utilization_q16;
                diagnostic->stealable = stealable;
                diagnostic->challenger_unit_cost = challenger_unit_cost;
                diagnostic->incumbent_unit_cost = incumbent_unit_cost;
            }
            const int64_t daily_variable_cost = mul_div_sat(saturating_add(
                daily_input_cost, daily_wages, _saturation_count), utilization_q16,
                Q16_ONE, _saturation_count);
            for (int32_t ethnicity = 0; ethnicity < static_cast<int32_t>(
                    _ethnicity_ids.size()); ++ethnicity) {
                ++_investment_ethnicity_evaluations;
                const int32_t target_signature = signature_for_profession_ethnicity(
                    type.owner_profession_id, ethnicity);
                if (target_signature < 0) continue;
                const int64_t living_cost = living_cost_for_signature(
                    cell, target_signature, -1, _saturation_count);
                const int64_t owner_livelihood = saturating_mul(
                    living_cost, std::max<int64_t>(1,
                        type.owner_slots_per_building), _saturation_count);
                int64_t daily_cash_revenue = 0;
                int64_t daily_in_kind_livelihood = 0;
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const GoodAmount &output =
                        _building_outputs[type.output_begin + i];
                    const OutputInvestmentSignal &output_signal = output_signals[i];
                    const int64_t research_demand =
                        epoch_research_demand_daily(cell, output.good_id);
                    const int64_t prospective_quantity =
                        effective_building_output_quantity_for_target(
                            cell, type_id, target_signature,
                            output.good_id, output.quantity, utilization_q16, 1,
                            _saturation_count);
                    const int64_t retail_price = _market.price[
                        _market.index(market, output.good_id)];
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
                    int64_t absorption_q16 = issue_value > 0 ? Q16_ONE : 0;
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
                        // using historical absorption.
                        if (absorption_q16 <= 0 && output_signal.deficit > 0 &&
                            sellable_quantity > 0 &&
                            (existing != nullptr || employment_catchup)) {
                            absorption_q16 = std::clamp<int64_t>(mul_div_sat(
                                output_signal.deficit, Q16_ONE, sellable_quantity,
                                _saturation_count), 0, Q16_ONE);
                        }
                    } else if (issue_value <= 0 && sellable_quantity > 0) {
                        absorption_q16 = std::clamp<int64_t>(mul_div_sat(
                            output_signal.deficit, Q16_ONE, sellable_quantity,
                            _saturation_count), 0, Q16_ONE);
                    }
                    const int64_t absorbed_quantity = mul_div_sat(
                        sellable_quantity, absorption_q16, Q16_ONE,
                        _saturation_count);
                    const int64_t settlement_price = issue_value > 0
                        ? issue_value
                        : government_research_output ? retail_price
                        : mul_div_sat(retail_price,
                            _good_merchant_buy_factor_q16[output.good_id], Q16_ONE,
                            _saturation_count);
                    daily_cash_revenue = saturating_add(daily_cash_revenue,
                        mul_div_sat(absorbed_quantity, settlement_price,
                            GOODS_SCALE, _saturation_count), _saturation_count);
                }
                int64_t daily_after_tax_cash_revenue = daily_cash_revenue;
                const uint8_t investment_tax_mask = static_cast<uint8_t>(
                    (1U << NativeCountryRuntime::TAX_INCOME) |
                    (1U << NativeCountryRuntime::TAX_BUSINESS));
                if ((_epoch_active_tax_mask & investment_tax_mask) != 0) {
                    const int64_t business_transfer =
                        expected_fiscal_transfer(
                            cell, NativeCountryRuntime::TAX_BUSINESS,
                            daily_cash_revenue,
                            frozen_tax_rate(
                                cell, NativeCountryRuntime::TAX_BUSINESS,
                                type_id),
                            _saturation_count);
                    const int64_t taxable_owner_income =
                        std::max<int64_t>(0, saturating_sub(
                            saturating_sub(
                                daily_cash_revenue, daily_variable_cost,
                                _saturation_count),
                            std::max<int64_t>(0, business_transfer),
                            _saturation_count));
                    const int8_t income_rate = frozen_tax_rate(
                        cell, NativeCountryRuntime::TAX_INCOME,
                        type.owner_profession_id);
                    const int64_t income_subsidy_base = income_rate < 0
                        ? std::max(taxable_owner_income, owner_livelihood)
                        : taxable_owner_income;
                    const int64_t income_transfer =
                        expected_fiscal_transfer(
                            cell, NativeCountryRuntime::TAX_INCOME,
                            income_subsidy_base, income_rate,
                            _saturation_count);
                    daily_after_tax_cash_revenue = saturating_sub(
                        saturating_sub(
                            daily_cash_revenue, business_transfer,
                            _saturation_count),
                        income_transfer, _saturation_count);
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
                const int64_t projected_owner_income = saturating_add(
                    std::max<int64_t>(0, saturating_sub(
                        daily_after_tax_cash_revenue, daily_variable_cost,
                        _saturation_count)),
                    daily_in_kind_livelihood, _saturation_count) /
                    std::max<int64_t>(1, type.owner_slots_per_building);
                const int64_t required_capital = saturating_add(construction_cost,
                    saturating_add(saturating_mul(daily_input_cost,
                        _investment_operating_cycles * std::max(1, _epoch_days),
                        _saturation_count), saturating_add(saturating_mul(
                            daily_wages, std::max(1, _epoch_days), _saturation_count),
                            saturating_mul(owner_livelihood, 30,
                                _saturation_count),
                            _saturation_count), _saturation_count), _saturation_count);
                if (diagnostic != nullptr) {
                    diagnostic->required_capital = required_capital;
                    diagnostic->projected_profit_per_day = daily_profit;
                }
                const int64_t payback = daily_profit > 0
                    ? (required_capital + daily_profit - 1) / daily_profit
                    : std::numeric_limits<int64_t>::max();
                if (payback > _investment_max_payback_days) {
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
                    sponsor_family_handle);
                bool uses_merchant_credit = false;
                if (sponsor < 0 && _merchant_credit_runtime_mode == 2 &&
                    construction_cost > 0) {
                    const int64_t merchant_cash =
                        investment_merchant_cash(cell);
                    const int64_t outstanding =
                        investment_outstanding_credit(cell);
                    const int64_t exposure = mul_div_sat(
                        merchant_cash, _merchant_credit_exposure_q16,
                        Q16_ONE, _saturation_count);
                    const int64_t reserve = mul_div_sat(
                        merchant_cash, _merchant_procurement_cash_reserve_q16,
                        Q16_ONE, _saturation_count);
                    const int64_t available_credit = std::max<int64_t>(0, std::min(
                        exposure - std::min(exposure, outstanding),
                        merchant_cash - std::min(merchant_cash, reserve)));
                    if (available_credit >= construction_cost) {
                        // Credit may fund the bounded startup reserve as well as
                        // construction during employment catch-up. Ordinary
                        // reviews retain the existing construction-only credit
                        // contract.
                        const int64_t credit_cover = employment_catchup
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
                            sponsor_family_handle);
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
                if ((_good_ids.size() > 0) && type.kind == 0) {
                    int64_t projected_issue = 0;
                    for (int32_t i = 0; i < type.output_count; ++i) {
                        const GoodAmount &output = _building_outputs[type.output_begin + i];
                        const int64_t monthly_output =
                            effective_building_output_quantity_for_target(
                                cell, type_id, target_signature,
                                output.good_id, output.quantity, Q16_ONE, 30,
                                _saturation_count);
                        projected_issue = saturating_add(projected_issue, mul_div_sat(
                            monthly_output,
                            _good_monetary_issue_values[output.good_id], GOODS_SCALE,
                            _saturation_count), _saturation_count);
                    }
                    const int64_t opening_money = saturating_add(
                        _opening_totals.cohort_funds,
                        saturating_add(_opening_totals.country_cash,
                            _opening_totals.escrow_cash, _saturation_count),
                        _saturation_count);
                    if (projected_issue > 0 && (opening_money <= 0 ||
                        mul_div_sat(projected_issue, Q16_ONE, opening_money,
                                    _saturation_count) > _bullion_monthly_issue_cap_q16)) {
                        ++_building_investment_blocked_resources;
                        reject(INVESTMENT_REJECTION_RESOURCE);
                        continue;
                    }
                }
                Candidate candidate;
                candidate.type = type_id;
                candidate.target_signature = target_signature;
                candidate.sponsor = sponsor;
                candidate.sponsor_family_handle = sponsor_family_handle;
                candidate.required_capital = sponsor_capital;
                candidate.construction_cost = construction_cost;
                candidate.projected_income = projected_owner_income;
                candidate.shortage_q16 = shortage_q16;
                candidate.utilization_q16 = utilization_q16;
                candidate.profit_per_day = daily_profit;
                candidate.payback_days = payback;
                candidate.driver_good_id = driver.good_id;
                candidate.driver_deficit = driver_deficit;
                candidate.stealable = stealable;
                candidate.challenger_unit_cost = challenger_unit_cost;
                candidate.incumbent_unit_cost = incumbent_unit_cost;
                candidate.displaces_incumbents = displaces_incumbents;
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const GoodAmount &output =
                        _building_outputs[type.output_begin + i];
                    if (output.good_id != driver.good_id) continue;
                    candidate.driver_output_per_building =
                        effective_building_output_quantity_for_target(
                            cell, type_id, target_signature,
                            output.good_id, output.quantity, utilization_q16, 1,
                            _saturation_count);
                    break;
                }
                candidate.willing_population = willing_population;
                candidate.transferable_capital = transferable_capital;
                candidate.income_improvement_q16 = income_improvement_q16;
                candidate.merchant_credit = merchant_credit;
                candidate.uses_merchant_credit = uses_merchant_credit;
                const int64_t target_gap = mul_div_sat(
                    std::max<int64_t>(0, driver_deficit),
                    _investment_gap_fill_share_q16, Q16_ONE,
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
                        _investment_max_growth_share_q16, _saturation_count);
                    candidate.max_batch_count = std::max<int64_t>(
                        1, saturating_add(scaled, Q16_ONE - 1,
                            _saturation_count) / Q16_ONE);
                } else {
                candidate.max_batch_count =
                        _investment_new_type_seed_buildings;
                }
                candidate.jobs_per_building = std::max<int64_t>(
                    1, type.owner_slots_per_building);
                candidate.score_q16 = saturating_add(
                    (survival_output ? 4 : 2) * shortage_q16,
                    saturating_add(3 * utilization_q16,
                        margin_q16, _saturation_count), _saturation_count);
                if (candidate.sponsor_family_handle != 0) {
                    const int32_t stable_preference =
                        family_trait_behavior_factor_q16(
                            candidate.sponsor_family_handle, 0, 0, type_id, cell);
                    const int32_t sector_preference =
                        family_trait_behavior_factor_q16(
                            candidate.sponsor_family_handle, 0, 1,
                            type.economic_sector, cell);
                    candidate.score_q16 = mul_div_sat(candidate.score_q16,
                        stable_preference, Q16_ONE, _saturation_count);
                    candidate.score_q16 = mul_div_sat(candidate.score_q16,
                        sector_preference, Q16_ONE, _saturation_count);
                    int32_t family_index = -1;
                    if (_families.valid_handle(candidate.sponsor_family_handle,
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
                            candidate.sponsor_family_handle, cell, term);
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
                            shortage_q16, 0, Q16_ONE)));
                }
                type_has_viable_candidate = true;
            if (diagnostic != nullptr) {
                    diagnostic->rejection_reason = INVESTMENT_REJECTION_NONE;
                    diagnostic->score_q16 = candidate.score_q16;
                    diagnostic->payback_days = payback;
                    diagnostic->required_capital = required_capital;
                    diagnostic->projected_profit_per_day = daily_profit;
                    diagnostic->stealable = stealable;
                    diagnostic->challenger_unit_cost = challenger_unit_cost;
                    diagnostic->incumbent_unit_cost = incumbent_unit_cost;
                }
                if (existing_group >= 0) {
                    mark_rejection(existing, INVESTMENT_REJECTION_NONE);
                    for (int32_t group = existing->first_group;
                         group <= existing->last_group; ++group) {
                        if (_buildings[group].cell != cell ||
                            _buildings[group].type_id != type_id) break;
                        _building_investment_score_q16[group] = candidate.score_q16;
                        _building_investment_payback_days[group] = payback;
                    }
                }
                if (better(candidate, type_best, employment_catchup))
                    type_best = candidate;
            }
            if (type_best.type >= 0) {
                if (!sparse_selected) {
                    ++_investment_sparse_mismatches;
                    _investment_sparse_runtime_disabled = true;
                }
                insert_portfolio(type_best);
            }
        }
        if (portfolio_size <= 0) {
            if (eligible_but_unfunded)
                ++_building_investment_blocked_sponsor_capital;
            continue;
        }
        investment_phase.switch_to(&_investment_allocate_ms);
        _building_investment_candidates = saturating_add(
            _building_investment_candidates, portfolio_size, _saturation_count);

        const int64_t merchant_cash = investment_merchant_cash(cell);
        const int64_t outstanding_credit =
            investment_outstanding_credit(cell);
        const int64_t credit_exposure = mul_div_sat(
            merchant_cash, _merchant_credit_exposure_q16,
            Q16_ONE, _saturation_count);
        const int64_t merchant_reserve = mul_div_sat(
            merchant_cash, _merchant_procurement_cash_reserve_q16,
            Q16_ONE, _saturation_count);
        const int64_t available_credit = std::max<int64_t>(0, std::min(
            credit_exposure - std::min(credit_exposure, outstanding_credit),
            merchant_cash - std::min(merchant_cash, merchant_reserve)));

        auto previously_allocated_owner_population = [&](int32_t sponsor,
                                                          uint64_t family) {
            int64_t used = 0;
            for (int32_t j = 0; j < portfolio_size; ++j) {
                if (portfolio[j].sponsor != sponsor ||
                    portfolio[j].sponsor_family_handle != family) continue;
                used = saturating_add(used, saturating_mul(
                    portfolio[j].allocated_count,
                    std::max<int64_t>(1, _building_types[
                        portfolio[j].type].owner_slots_per_building),
                    _saturation_count), _saturation_count);
            }
            return used;
        };
        auto previously_allocated_capital = [&](int32_t sponsor,
                                                uint64_t family) {
            int64_t used = 0;
            for (int32_t j = 0; j < portfolio_size; ++j) {
                if (portfolio[j].sponsor != sponsor ||
                    portfolio[j].sponsor_family_handle != family) continue;
                used = saturating_add(used, saturating_mul(
                    portfolio[j].allocated_count,
                    portfolio[j].required_capital, _saturation_count),
                    _saturation_count);
            }
            return used;
        };
        auto previously_allocated_credit = [&]() {
            int64_t used = 0;
            for (int32_t j = 0; j < portfolio_size; ++j) {
                if (!portfolio[j].uses_merchant_credit) continue;
                used = saturating_add(used, saturating_mul(
                    portfolio[j].allocated_count,
                    portfolio[j].merchant_credit, _saturation_count),
                    _saturation_count);
            }
            return used;
        };
        auto previously_allocated_driver = [&](int32_t good_id) {
            int64_t used = 0;
            for (int32_t j = 0; j < portfolio_size; ++j) {
                if (portfolio[j].driver_good_id != good_id) continue;
                used = saturating_add(used, saturating_mul(
                    portfolio[j].allocated_count,
                    portfolio[j].driver_output_per_building,
                    _saturation_count), _saturation_count);
            }
            return used;
        };
        auto previously_allocated_resource = [&](int32_t resource_id) {
            int64_t used = 0;
            for (int32_t j = 0; j < portfolio_size; ++j) {
                if (portfolio[j].allocated_count <= 0) continue;
                const BuildingType &allocated_type =
                    _building_types[portfolio[j].type];
                for (int32_t edge = 0;
                     edge < allocated_type.resource_count; ++edge) {
                    const ResourceAmount &item = _building_resources[
                        allocated_type.resource_begin + edge];
                    if (item.mode != 0 || item.resource_id != resource_id) continue;
                    const int64_t effective_quantity =
                        effective_resource_use_quantity(
                            cell, item.resource_id, item.quantity,
                            _saturation_count);
                    used = saturating_add(used, saturating_mul(
                        portfolio[j].allocated_count, effective_quantity,
                        _saturation_count), _saturation_count);
                }
            }
            return used;
        };
        auto previously_allocated_catchup_jobs = [&]() {
            int64_t used = 0;
            for (int32_t j = 0; j < portfolio_size; ++j) {
                used = saturating_add(used, saturating_mul(
                    portfolio[j].allocated_count,
                    portfolio[j].jobs_per_building, _saturation_count),
                    _saturation_count);
            }
            return used;
        };
        const int32_t investment_cost_factor = country >= 0 &&
                country < static_cast<int32_t>(
                    _epoch_country_construction_cost_factor_q16.size())
            ? _epoch_country_construction_cost_factor_q16[country] : Q16_ONE;
        auto reserved_material_adjustment = [&]() {
            std::vector<int64_t> adjustment(_good_ids.size(), 0);
            for (int32_t j = 0; j < portfolio_size; ++j) {
                if (portfolio[j].allocated_count <= 0) continue;
                ConstructionMaterialPlan reserved_plan;
                if (!plan_construction_materials(
                        cell, portfolio[j].type, portfolio[j].allocated_count,
                        investment_cost_factor, reserved_plan, &adjustment)) {
                    adjustment.clear();
                    return adjustment;
                }
                for (size_t item = 0; item < reserved_plan.good_ids.size(); ++item) {
                    const int32_t good = reserved_plan.good_ids[item];
                    if (good >= 0 && good < static_cast<int32_t>(adjustment.size())) {
                        adjustment[good] = saturating_sub(
                            adjustment[good], reserved_plan.quantities[item],
                            _saturation_count);
                    }
                }
            }
            return adjustment;
        };
        auto additional_capacity = [&](int32_t index) {
            Candidate &candidate = portfolio[index];
            const BuildingType &type = _building_types[candidate.type];
            int64_t cap = std::max<int64_t>(
                0, candidate.desired_count - candidate.allocated_count);
            cap = std::min<int64_t>(cap, std::max<int64_t>(
                0, candidate.max_batch_count - candidate.allocated_count));
            if (employment_catchup) {
                const int64_t remaining_jobs = std::max<int64_t>(
                    0, employment_gap - previously_allocated_catchup_jobs());
                if (remaining_jobs <= 0) return int64_t{0};
                const int64_t jobs_per_building = std::max<int64_t>(
                    1, candidate.jobs_per_building);
                cap = std::min<int64_t>(cap,
                    (remaining_jobs + jobs_per_building - 1) /
                        jobs_per_building);
            }
            if (cap <= 0) return int64_t{0};
            const int64_t owner_slots = std::max<int64_t>(
                1, type.owner_slots_per_building);
            const int64_t owner_remaining = std::max<int64_t>(
                0, candidate.willing_population -
                    previously_allocated_owner_population(candidate.sponsor,
                        candidate.sponsor_family_handle));
            const int64_t owner_cap = owner_remaining / owner_slots;
            if (owner_cap < cap) ++_building_investment_owner_population_limited;
            cap = std::min(cap, owner_cap);
            const int64_t capital_remaining = std::max<int64_t>(
                0, candidate.transferable_capital -
                    previously_allocated_capital(candidate.sponsor,
                        candidate.sponsor_family_handle));
            const int64_t capital_cap = candidate.required_capital > 0
                ? capital_remaining / candidate.required_capital
                : cap;
            if (capital_cap < cap) ++_building_investment_capital_limited;
            cap = std::min(cap, capital_cap);
            if (candidate.uses_merchant_credit &&
                candidate.merchant_credit > 0) {
                const int64_t credit_cap = std::max<int64_t>(
                    0, available_credit - previously_allocated_credit()) /
                    candidate.merchant_credit;
                if (credit_cap < cap) ++_building_investment_capital_limited;
                cap = std::min(cap, credit_cap);
            }
            const std::vector<int64_t> adjustment =
                reserved_material_adjustment();
            if (adjustment.empty() && !_good_ids.empty()) {
                ++_building_investment_material_limited;
                return int64_t{0};
            }
            int64_t material_lo = 0;
            int64_t material_hi = cap;
            while (material_lo < material_hi) {
                const int64_t mid = material_lo +
                    (material_hi - material_lo + 1) / 2;
                ConstructionMaterialPlan candidate_plan;
                if (plan_construction_materials(cell, candidate.type, mid,
                        investment_cost_factor, candidate_plan, &adjustment)) {
                    material_lo = mid;
                } else {
                    material_hi = mid - 1;
                }
            }
            if (material_lo < cap) ++_building_investment_material_limited;
            cap = std::min(cap, material_lo);
            if (_resource_safe_harvest_q16 > 0) {
                for (int32_t edge = 0; edge < type.resource_count; ++edge) {
                    const ResourceAmount &item = _building_resources[
                        type.resource_begin + edge];
                    if (item.mode != 0 || item.quantity <= 0) continue;
                    const size_t resource_idx = static_cast<size_t>(
                        item.resource_id) * _cell_count + cell;
                    const int64_t committed =
                        investment_resource_committed(resource_idx);
                    int64_t daily_budget = 0;
                    if (resource_is_renewable(item.resource_id)) {
                        daily_budget = renewable_safe_harvest(
                            item.resource_id, cell);
                    } else if (resource_idx < _resource_remaining.size()) {
                        daily_budget = std::max<int64_t>(0,
                            _resource_remaining[resource_idx]) /
                            std::max<int64_t>(1, _resource_min_horizon_days);
                    }
                    const int64_t effective_quantity = std::max<int64_t>(1,
                        effective_resource_use_quantity(
                            cell, item.resource_id, item.quantity,
                            _saturation_count));
                    const int64_t resource_cap = std::max<int64_t>(0,
                        daily_budget - committed -
                        previously_allocated_resource(item.resource_id)) /
                        effective_quantity;
                    cap = std::min(cap, resource_cap);
                }
            }
            if (candidate.driver_output_per_building > 0) {
                const int64_t target_gap = mul_div_sat(
                    std::max<int64_t>(0, candidate.driver_deficit),
                    _investment_gap_fill_share_q16, Q16_ONE,
                    _saturation_count);
                const int64_t remaining_gap = std::max<int64_t>(
                    0, target_gap - previously_allocated_driver(
                        candidate.driver_good_id));
                const int64_t demand_cap = remaining_gap > 0
                    ? std::max<int64_t>(1, saturating_add(
                        remaining_gap,
                        candidate.driver_output_per_building - 1,
                        _saturation_count) /
                        candidate.driver_output_per_building)
                    : 0;
                if (demand_cap < cap) ++_building_investment_demand_limited;
                cap = std::min(cap, demand_cap);
            }
            return std::max<int64_t>(0, cap);
        };

        // First seed distinct industries, then use four fixed water-fill
        // rounds. Work is bounded by the portfolio width, never by build count.
        bool portfolio_population_changed = false;
        for (int32_t i = 0; i < portfolio_size; ++i) {
            if (employment_catchup &&
                previously_allocated_catchup_jobs() >= employment_gap) break;
            if (additional_capacity(i) > 0)
                portfolio[i].allocated_count = 1;
        }
        for (int32_t round = 0; round < 4; ++round) {
            int64_t weight_sum = 0;
            int64_t remaining_sum = 0;
            std::array<int64_t, 4> caps{};
            for (int32_t i = 0; i < portfolio_size; ++i) {
                caps[i] = additional_capacity(i);
                if (caps[i] <= 0) continue;
                weight_sum = saturating_add(weight_sum,
                    std::max<int64_t>(1, portfolio[i].score_q16),
                    _saturation_count);
                remaining_sum = saturating_add(
                    remaining_sum, caps[i], _saturation_count);
            }
            if (weight_sum <= 0 || remaining_sum <= 0) break;
            const int64_t round_budget = saturating_add(
                remaining_sum, 3 - round, _saturation_count) / (4 - round);
            for (int32_t i = 0; i < portfolio_size; ++i) {
                if (caps[i] <= 0) continue;
                int64_t add = mul_div_sat(
                    round_budget, std::max<int64_t>(
                        1, portfolio[i].score_q16),
                    weight_sum, _saturation_count);
                if (add <= 0) add = 1;
                add = std::min(add, additional_capacity(i));
                portfolio[i].allocated_count = saturating_add(
                    portfolio[i].allocated_count, add, _saturation_count);
            }
        }

        int32_t active_types = 0;
        for (int32_t i = 0; i < portfolio_size; ++i)
            if (portfolio[i].allocated_count > 0) ++active_types;
        if (active_types >= 2 &&
            _investment_max_type_owner_share_q16 < Q16_ONE) {
            for (int32_t pass = 0; pass < 4; ++pass) {
                bool changed = false;
                int64_t total_owner_slots = 0;
                for (int32_t i = 0; i < portfolio_size; ++i) {
                    total_owner_slots = saturating_add(total_owner_slots,
                        saturating_mul(portfolio[i].allocated_count,
                            std::max<int64_t>(1, _building_types[
                                portfolio[i].type].owner_slots_per_building),
                            _saturation_count), _saturation_count);
                }
                for (int32_t i = 0; i < portfolio_size; ++i) {
                    const int64_t owner_slots = std::max<int64_t>(
                        1, _building_types[
                            portfolio[i].type].owner_slots_per_building);
                    const int64_t own = saturating_mul(
                        portfolio[i].allocated_count, owner_slots,
                        _saturation_count);
                    const int64_t other = std::max<int64_t>(
                        0, total_owner_slots - own);
                    const int64_t allowed_owner = mul_div_sat(
                        other, _investment_max_type_owner_share_q16,
                        Q16_ONE - _investment_max_type_owner_share_q16,
                        _saturation_count);
                    const int64_t allowed_count = allowed_owner / owner_slots;
                    if (portfolio[i].allocated_count > allowed_count) {
                        portfolio[i].allocated_count = allowed_count;
                        changed = true;
                    }
                }
                if (!changed) break;
            }
            // A bounded second pass redistributes capacity released by the
            // concentration correction without reopening the candidate scan.
            for (int32_t pass = 0; pass < 4; ++pass) {
                bool changed = false;
                int64_t total_owner_slots = 0;
                for (int32_t i = 0; i < portfolio_size; ++i) {
                    total_owner_slots = saturating_add(total_owner_slots,
                        saturating_mul(portfolio[i].allocated_count,
                            std::max<int64_t>(1, _building_types[
                                portfolio[i].type].owner_slots_per_building),
                            _saturation_count), _saturation_count);
                }
                for (int32_t i = 0; i < portfolio_size; ++i) {
                    const int64_t owner_slots = std::max<int64_t>(
                        1, _building_types[
                            portfolio[i].type].owner_slots_per_building);
                    const int64_t own = saturating_mul(
                        portfolio[i].allocated_count, owner_slots,
                        _saturation_count);
                    const int64_t other = std::max<int64_t>(
                        0, total_owner_slots - own);
                    const int64_t allowed_owner = mul_div_sat(
                        other, _investment_max_type_owner_share_q16,
                        Q16_ONE - _investment_max_type_owner_share_q16,
                        _saturation_count);
                    const int64_t share_add_cap = std::max<int64_t>(
                        0, allowed_owner / owner_slots -
                            portfolio[i].allocated_count);
                    const int64_t add = std::min(
                        share_add_cap, additional_capacity(i));
                    if (add <= 0) continue;
                    portfolio[i].allocated_count = saturating_add(
                        portfolio[i].allocated_count, add,
                        _saturation_count);
                    total_owner_slots = saturating_add(
                        total_owner_slots,
                        saturating_mul(add, owner_slots,
                            _saturation_count), _saturation_count);
                    changed = true;
                }
                if (!changed) break;
            }
        }

        active_types = 0;
        int64_t total_buildings = 0;
        int64_t total_owner_population = 0;
        int64_t max_type_owner_population = 0;
        for (int32_t i = 0; i < portfolio_size; ++i) {
            Candidate &candidate = portfolio[i];
            if (candidate.allocated_count <= 0) continue;
            ++active_types;
            total_buildings = saturating_add(
                total_buildings, candidate.allocated_count,
                _saturation_count);
            const int64_t owner_population = saturating_mul(
                candidate.allocated_count, std::max<int64_t>(
                    1, _building_types[
                        candidate.type].owner_slots_per_building),
                _saturation_count);
            total_owner_population = saturating_add(
                total_owner_population, owner_population, _saturation_count);
            max_type_owner_population = std::max(
                max_type_owner_population, owner_population);
        }
        if (active_types <= 0 || total_buildings <= 0) continue;
        int64_t portfolio_credit_required = 0;
        for (int32_t i = 0; i < portfolio_size; ++i) {
            if (!portfolio[i].uses_merchant_credit ||
                portfolio[i].allocated_count <= 0) continue;
            portfolio_credit_required = saturating_add(
                portfolio_credit_required,
                saturating_mul(portfolio[i].allocated_count,
                    portfolio[i].merchant_credit, _saturation_count),
                _saturation_count);
        }
        if (portfolio_credit_required > available_credit) {
            error = "building_investment_startup_credit_overcommit";
            return false;
        }

        for (int32_t i = 0; i < portfolio_size; ++i) {
            Candidate &candidate = portfolio[i];
            if (candidate.allocated_count <= 0) continue;
            const int64_t source_funds_before =
                _population.funds[candidate.sponsor];
            const int64_t source_population_before =
                _population.population[candidate.sponsor];
            const int64_t source_handle =
                _population.handle_for_slot(candidate.sponsor);
            const bool profession_transition = static_cast<int32_t>(
                _population.signature_id[candidate.sponsor]) !=
                candidate.target_signature;
            const int32_t target_before_slot = find_cohort_slot(
                cell, candidate.target_signature);
            const int64_t target_funds_before = target_before_slot >= 0
                ? _population.funds[target_before_slot] : 0;
            const int64_t target_population_before = target_before_slot >= 0
                ? _population.population[target_before_slot] : 0;
            const int64_t owner_population = saturating_mul(
                candidate.allocated_count, std::max<int64_t>(
                    1, _building_types[
                        candidate.type].owner_slots_per_building),
                _saturation_count);
            const int64_t required_capital = saturating_mul(
                candidate.allocated_count, candidate.required_capital,
                _saturation_count);
            const int64_t merchant_credit = saturating_mul(
                candidate.allocated_count, candidate.merchant_credit,
                _saturation_count);
            bool source_drained = false;
            if (profession_transition && !move_cohort_population(
                    candidate.sponsor, cell, candidate.target_signature,
                    owner_population, error, &source_drained,
                    candidate.sponsor_family_handle)) return false;
            if (source_drained) {
                error = "building_investment_source_unexpectedly_drained";
                return false;
            }
            portfolio_population_changed =
                portfolio_population_changed || profession_transition;
            population_changed = population_changed || profession_transition;
            const int32_t owner_slot = profession_transition
                ? find_cohort_slot(cell, candidate.target_signature)
                : candidate.sponsor;
            if (owner_slot < 0 || owner_slot >= static_cast<int32_t>(
                    _population.active.size()) ||
                    _population.active[owner_slot] == 0) {
                error = "building_investment_owner_transition_failed";
                return false;
            }
            if (profession_transition) {
                const int64_t carried =
                    _population.funds[owner_slot] - target_funds_before;
                const int64_t correction = required_capital - carried;
                if (correction > 0 &&
                    _population.funds[candidate.sponsor] < correction) {
                    error = "building_investment_capital_preflight_drift";
                    return false;
                }
                if (correction < 0 &&
                    _population.funds[owner_slot] < -correction) {
                    error = "building_investment_capital_refund_preflight_drift";
                    return false;
                }
                touch_accounting_slot(candidate.sponsor);
                touch_accounting_slot(owner_slot);
                _population.funds[candidate.sponsor] = saturating_sub(
                    _population.funds[candidate.sponsor], correction,
                    _saturation_count);
                _population.funds[owner_slot] = saturating_add(
                    _population.funds[owner_slot], correction,
                    _saturation_count);
                if (_population.funds[candidate.sponsor] !=
                        source_funds_before - required_capital) {
                    error = "building_investment_capital_transfer_drift";
                    return false;
                }
                ++_building_owner_mobility;
                _building_investment_owner_population_moved = saturating_add(
                    _building_investment_owner_population_moved,
                    owner_population, _saturation_count);
                _building_investment_capital_transferred = saturating_add(
                    _building_investment_capital_transferred,
                    required_capital, _saturation_count);
            }
            if (profession_transition && trace_detail_for_cell(cell)) {
                const int64_t target_handle =
                    _population.handle_for_slot(owner_slot);
                std::vector<EventLeg> legs;
                legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                    source_handle, -1, source_population_before,
                    _population.population[candidate.sponsor]});
                legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    source_handle, -1, source_funds_before,
                    _population.funds[candidate.sponsor]});
                legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                    target_handle, -1, target_population_before,
                    _population.population[owner_slot]});
                legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    target_handle, -1, target_funds_before,
                    _population.funds[owner_slot]});
                trace_append(EVENT_STRUCTURAL_CHANGE,
                    static_cast<int32_t>(Stage::BUILDING_COMMIT), cell,
                    SUBJECT_COHORT, target_handle, candidate.type, -1,
                    required_capital, source_handle, target_handle,
                    -(_epoch_id * std::max<int64_t>(1, _cell_count) +
                      cell * 4 + i + 1), &legs);
            }
            if (merchant_credit > 0) {
                if (debit_local_merchants(cell, merchant_credit,
                                          CASHFLOW_MERCHANT_BUSINESS,
                                          &_saturation_count) != merchant_credit) {
                    error = "building_investment_startup_credit_preflight_drift";
                    return false;
                }
                touch_accounting_slot(owner_slot);
                _population.funds[owner_slot] = saturating_add(
                    _population.funds[owner_slot], merchant_credit,
                    _saturation_count);
                trace_record_cashflow(cell, _population.handle_for_slot(owner_slot),
                                      CASHFLOW_OTHER, merchant_credit, 0);
                _investment_outstanding_credit_by_cell[cell] = saturating_add(
                    _investment_outstanding_credit_by_cell[cell],
                    merchant_credit, _saturation_count);
                _merchant_credit_drawn = saturating_add(
                    _merchant_credit_drawn, merchant_credit, _saturation_count);
                if (cell >= 0 && cell < static_cast<int32_t>(
                        _merchant_credit_drawn_by_cell.size())) {
                    _merchant_credit_drawn_by_cell[cell] = saturating_add(
                        _merchant_credit_drawn_by_cell[cell], merchant_credit,
                        _saturation_count);
                }
            }
        }
        // Population slots are stable and later ordinals never revisit this
        // cell. Defer the global merchant CSR rebuild until the deterministic
        // slice commit below instead of rebuilding it once per changed cell.
        population_changed = population_changed ||
            portfolio_population_changed;

        int64_t started_types = 0;
        for (int32_t i = 0; i < portfolio_size; ++i) {
            Candidate &candidate = portfolio[i];
            if (candidate.allocated_count <= 0) continue;
            const int32_t owner_slot = find_cohort_slot(
                cell, candidate.target_signature);
            if (owner_slot < 0) {
                error = "building_investment_owner_missing_after_portfolio";
                return false;
            }
            Command command;
            command.opcode = COMMAND_BUILD;
            command.effective_day = _current_day;
            command.sequence = -(_epoch_id * std::max<int64_t>(
                1, _cell_count) + cell * 4 + i + 1);
            command.target_handle =
                _population.handle_for_slot(owner_slot);
            command.i32_0 = cell;
            command.i32_1 = candidate.type;
            command.i64_0 = candidate.allocated_count;
            const size_t pending_before = _pending_construction.size();
            const int64_t consumed_before = _construction_goods_consumed;
            if (!apply_build_command(
                    command, owner_slot, error, true)) return false;
            if (_pending_construction.size() != pending_before + 1) {
                error = "building_investment_preflight_drift";
                return false;
            }
            if (candidate.merchant_credit > 0) {
                PendingConstruction &pending = _pending_construction.back();
                const int64_t credit = saturating_mul(
                    candidate.allocated_count, candidate.merchant_credit,
                    _saturation_count);
                pending.merchant_debt_principal = saturating_add(
                    pending.merchant_debt_principal, credit,
                    _saturation_count);
                const int64_t premium = saturating_add(
                    saturating_mul(credit, _merchant_credit_premium_q16,
                                   _saturation_count),
                    Q16_ONE - 1, _saturation_count) / Q16_ONE;
                pending.merchant_debt_premium = saturating_add(
                    pending.merchant_debt_premium, premium,
                    _saturation_count);
                pending.merchant_debt_term_cycles_left = static_cast<uint16_t>(
                    _merchant_credit_term_cycles);
            }
            _pending_construction.back().sponsor_family_handle =
                candidate.sponsor_family_handle;
            const int64_t consumed =
                _construction_goods_consumed - consumed_before;
            _publish_accum.goods_stock = saturating_sub(
                _publish_accum.goods_stock, consumed, _saturation_count);
            ++_building_investments_started;
            if (candidate.displaces_incumbents)
                ++_building_investment_displacement_starts;
            ++started_types;
            const uint64_t pending_key = cell_key(cell, candidate.type);
            _investment_pending_by_cell_type[pending_key] = saturating_add(
                _investment_pending_by_cell_type[pending_key],
                candidate.allocated_count, _saturation_count);
        }
        ++_building_investment_portfolios_started;
        _building_investment_types_started = saturating_add(
            _building_investment_types_started, started_types,
            _saturation_count);
        _building_investment_buildings_started = saturating_add(
            _building_investment_buildings_started, total_buildings,
            _saturation_count);
        _building_investment_jobs_started = saturating_add(
            _building_investment_jobs_started, total_owner_population,
            _saturation_count);
        if (total_owner_population > 0) {
            _building_investment_max_type_owner_share_q16 = std::max(
                _building_investment_max_type_owner_share_q16,
                mul_div_sat(max_type_owner_population, Q16_ONE,
                    total_owner_population, _saturation_count));
        }
    }
    if (population_changed && !rebuild_merchant_ranges(error)) return false;
    return true;
}


} // namespace pk
