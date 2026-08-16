#include "economy_runtime.h"

#include <algorithm>
#include <chrono>
#include <numeric>

namespace pk {

namespace {
using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

int32_t NativeEconomyRuntime::find_building_group(int32_t cell, int32_t type_id,
                                                   int32_t owner_signature_id) const {
    ++_scan_calls_find_building_group;
    for (int32_t i = 0; i < static_cast<int32_t>(_buildings.size()); ++i) {
        const BuildingGroup &group = _buildings[i];
        if (group.cell == cell && group.type_id == type_id &&
            group.owner_signature_id == owner_signature_id) {
            _scan_steps_find_building_group += i + 1;
            note_scan_steps(i + 1);
            return i;
        }
    }
    _scan_steps_find_building_group += static_cast<int64_t>(_buildings.size());
    note_scan_steps(static_cast<int64_t>(_buildings.size()));
    return -1;
}

void NativeEconomyRuntime::initialize_building_role_span(BuildingGroup &group) {
    if (group.type_id < 0 ||
        group.type_id >= static_cast<int32_t>(_building_types.size())) return;
    if (_building_free_role_spans_by_type.size() < _building_types.size())
        _building_free_role_spans_by_type.resize(_building_types.size());
    const BuildingType &type = _building_types[group.type_id];
    auto &free_spans = _building_free_role_spans_by_type[group.type_id];
    BuildingRoleSpan span;
    if (!free_spans.empty()) {
        span = free_spans.back();
        free_spans.pop_back();
        ++_building_structure_role_span_reuses;
    } else {
        span.employee_begin = static_cast<int32_t>(_building_employee_filled.size());
        span.input_begin = static_cast<int32_t>(
            _building_last_input_selected_goods.size());
        const size_t role_end = static_cast<size_t>(span.employee_begin) +
            static_cast<size_t>(type.employee_count);
        const size_t input_end = static_cast<size_t>(span.input_begin) +
            static_cast<size_t>(type.input_count);
        _building_employee_filled.resize(role_end, 0);
        _building_role_contract_wage.resize(role_end, 0);
        _building_role_base_living_cost.resize(role_end, 0);
        _building_role_living_cost.resize(role_end, 0);
        _building_role_local_average_wage.resize(role_end, 0);
        _building_role_base_wage_due.resize(role_end, 0);
        _building_role_base_wage_paid.resize(role_end, 0);
        _building_role_bonus_due.resize(role_end, 0);
        _building_role_bonus_paid.resize(role_end, 0);
        _building_last_input_selected_goods.resize(input_end, -1);
        ++_building_structure_role_span_appends;
    }
    group.employee_fill_begin = span.employee_begin;
    group.last_input_selection_begin = span.input_begin;
    for (int32_t role_index = 0; role_index < type.employee_count; ++role_index) {
        const int32_t lane = span.employee_begin + role_index;
        const JobRole &role = _building_employee_roles[
            type.employee_begin + role_index];
        _building_employee_filled[lane] = 0;
        _building_role_contract_wage[lane] = role.reference_wage_per_day;
        _building_role_base_living_cost[lane] = 0;
        _building_role_living_cost[lane] = 0;
        _building_role_local_average_wage[lane] = 0;
        _building_role_base_wage_due[lane] = 0;
        _building_role_base_wage_paid[lane] = 0;
        _building_role_bonus_due[lane] = 0;
        _building_role_bonus_paid[lane] = 0;
    }
    std::fill(_building_last_input_selected_goods.begin() + span.input_begin,
              _building_last_input_selected_goods.begin() + span.input_begin +
                  type.input_count, -1);
}

void NativeEconomyRuntime::release_building_role_span(
        const BuildingGroup &group) {
    if (group.type_id < 0 ||
        group.type_id >= static_cast<int32_t>(_building_types.size()) ||
        group.employee_fill_begin < 0 || group.last_input_selection_begin < 0)
        return;
    if (_building_free_role_spans_by_type.size() < _building_types.size())
        _building_free_role_spans_by_type.resize(_building_types.size());
    _building_free_role_spans_by_type[group.type_id].push_back({
        group.employee_fill_begin, group.last_input_selection_begin});
}

void NativeEconomyRuntime::rebuild_building_role_storage() {
    const auto merge_started = Clock::now();
    struct RoleStorageTimer {
        NativeEconomyRuntime *self;
        const std::chrono::steady_clock::time_point &start;
        ~RoleStorageTimer() {
            self->_building_role_storage_ms += elapsed_ms(start);
        }
    } role_storage_timer{this, merge_started};
    auto key = [&](int32_t index) {
        const BuildingGroup &group = _buildings[index];
        return std::tuple(group.cell, group.type_id, group.owner_signature_id);
    };
    _building_existing_indices_scratch.clear();
    _building_new_indices_scratch.clear();
    for (int32_t index = 0; index < static_cast<int32_t>(_buildings.size()); ++index) {
        const BuildingGroup &group = _buildings[index];
        if (group.count <= 0) {
            release_building_role_span(group);
        } else if (group.employee_fill_begin >= 0 &&
                   group.last_input_selection_begin >= 0) {
            _building_existing_indices_scratch.push_back(index);
        } else {
            _building_new_indices_scratch.push_back(index);
        }
    }
    const auto index_less = [&](int32_t a, int32_t b) {
        return key(a) < key(b);
    };
    if (!std::is_sorted(_building_existing_indices_scratch.begin(),
                        _building_existing_indices_scratch.end(), index_less)) {
        std::stable_sort(_building_existing_indices_scratch.begin(),
                         _building_existing_indices_scratch.end(), index_less);
    }
    std::stable_sort(_building_new_indices_scratch.begin(),
                     _building_new_indices_scratch.end(), index_less);

    const size_t active_count = _building_existing_indices_scratch.size() +
        _building_new_indices_scratch.size();
    _building_groups_rebuild_scratch.clear();
    _building_groups_rebuild_scratch.reserve(active_count);
    _building_investment_score_rebuild_scratch.clear();
    _building_investment_score_rebuild_scratch.reserve(active_count);
    _building_investment_payback_rebuild_scratch.clear();
    _building_investment_payback_rebuild_scratch.reserve(active_count);
    _building_investment_rejection_rebuild_scratch.clear();
    _building_investment_rejection_rebuild_scratch.reserve(active_count);
    _building_factor_cache_rebuild_scratch.clear();
    _building_factor_cache_rebuild_scratch.reserve(active_count);

    auto append_group = [&](int32_t index, bool is_new) {
        BuildingGroup group = _buildings[index];
        if (is_new) initialize_building_role_span(group);
        _building_groups_rebuild_scratch.push_back(group);
        _building_investment_score_rebuild_scratch.push_back(
            !is_new && index < static_cast<int32_t>(
                _building_investment_score_q16.size())
                ? _building_investment_score_q16[index] : 0);
        _building_investment_payback_rebuild_scratch.push_back(
            !is_new && index < static_cast<int32_t>(
                _building_investment_payback_days.size())
                ? _building_investment_payback_days[index] : 0);
        _building_investment_rejection_rebuild_scratch.push_back(
            !is_new && index < static_cast<int32_t>(
                _building_investment_rejection.size())
                ? _building_investment_rejection[index]
                : INVESTMENT_REJECTION_NONE);
        // The factor cache is keyed by group index, so it must follow the
        // permutation applied here; otherwise every group looks stale after a
        // single construction completes.
        _building_factor_cache_rebuild_scratch.push_back(
            index < static_cast<int32_t>(_building_factor_cache.size())
                ? _building_factor_cache[index] : BuildingFactorCacheEntry{});
    };
    size_t existing_cursor = 0;
    size_t new_cursor = 0;
    while (existing_cursor < _building_existing_indices_scratch.size() ||
           new_cursor < _building_new_indices_scratch.size()) {
        if (new_cursor >= _building_new_indices_scratch.size() ||
            (existing_cursor < _building_existing_indices_scratch.size() &&
             key(_building_existing_indices_scratch[existing_cursor]) <
                 key(_building_new_indices_scratch[new_cursor]))) {
            append_group(
                _building_existing_indices_scratch[existing_cursor++], false);
        } else {
            append_group(_building_new_indices_scratch[new_cursor++], true);
        }
    }
    _buildings.swap(_building_groups_rebuild_scratch);
    _building_handle_index_clean = false;
    _building_investment_score_q16.swap(
        _building_investment_score_rebuild_scratch);
    _building_investment_payback_days.swap(
        _building_investment_payback_rebuild_scratch);
    _building_investment_rejection.swap(
        _building_investment_rejection_rebuild_scratch);
    _building_factor_cache.swap(_building_factor_cache_rebuild_scratch);
    rebuild_building_cell_offsets();
    _building_structure_group_merge_ms += elapsed_ms(merge_started);

    const auto market_started = Clock::now();
    rebuild_market_signals();
    _building_structure_market_cache_ms += elapsed_ms(market_started);
    const auto labor_started = Clock::now();
    rebuild_labor_signals();
    _building_structure_labor_cache_ms += elapsed_ms(labor_started);
}

void NativeEconomyRuntime::rebuild_building_cell_offsets() {
    _building_cell_offsets.assign(static_cast<size_t>(std::max(0, _cell_count)) + 1, 0);
    _building_active_cells.clear();
    for (const BuildingGroup &group : _buildings) {
        if (group.cell >= 0 && group.cell < _cell_count && group.count > 0) {
            ++_building_cell_offsets[group.cell + 1];
        }
    }
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        _building_cell_offsets[cell + 1] += _building_cell_offsets[cell];
        if (_building_cell_offsets[cell + 1] > _building_cell_offsets[cell]) {
            _building_active_cells.push_back(cell);
        }
    }
    rebuild_building_review_buckets();
}

void NativeEconomyRuntime::rebuild_building_review_buckets() {
    // Lifecycle review is a market-settlement concern, not an investment-plan
    // concern. Every five-day settlement must inspect every suspended group;
    // partitioning by cell modulo five would skip four fifths of the groups
    // because committed sample days are normally 0, 5, 10, ... . Keep one
    // stable review bucket and let the continuation cursor provide slicing.
    _building_review_phase_offsets.assign(2, 0);
    _building_review_group_indices.clear();
    _building_special_reset_group_indices.clear();

    for (int32_t group_index = 0;
         group_index < static_cast<int32_t>(_buildings.size()); ++group_index) {
        const BuildingGroup &group = _buildings[group_index];
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count ||
            group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size())) continue;
        if (_building_types[group.type_id].kind == 2) {
            _building_special_reset_group_indices.push_back(group_index);
            continue;
        }
        ++_building_review_phase_offsets[1];
    }
    _building_review_phase_offsets[1] += _building_review_phase_offsets[0];

    _building_review_group_indices.resize(
        static_cast<size_t>(_building_review_phase_offsets.back()));
    int32_t cursor = _building_review_phase_offsets[0];
    for (int32_t group_index = 0;
         group_index < static_cast<int32_t>(_buildings.size()); ++group_index) {
        const BuildingGroup &group = _buildings[group_index];
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count ||
            group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size()) ||
            _building_types[group.type_id].kind == 2) continue;
        _building_review_group_indices[cursor++] = group_index;
    }
}

} // namespace pk
