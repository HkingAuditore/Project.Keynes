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

// Gathers one group column through `order`. The scratch buffer is reused so a
// topology rebuild does not allocate once per column.
template <typename T>
void gather_column(std::vector<T> &column, const std::vector<int32_t> &order) {
    static thread_local std::vector<T> scratch;
    scratch.clear();
    scratch.reserve(order.size());
    for (const int32_t src : order) {
        scratch.push_back(src >= 0 && static_cast<size_t>(src) < column.size()
                              ? column[static_cast<size_t>(src)]
                              : T{});
    }
    column.swap(scratch);
}
} // namespace

size_t NativeEconomyRuntime::append_building_group(const BuildingGroup &group) {
    RuntimeEconomyBuildingStore &store = buildings_store();
    const size_t row = store.cell.size();
#define PK_BUILDING_GROUP_PUSH(TYPE, NAME, COLUMN) \
    store.COLUMN.push_back(group.NAME);
    PK_BUILDING_GROUP_COLUMNS(PK_BUILDING_GROUP_PUSH)
#undef PK_BUILDING_GROUP_PUSH
    store.role_count.push_back(
        group.type_id >= 0 &&
                group.type_id < static_cast<int32_t>(_building_types.size())
            ? _building_types[static_cast<size_t>(group.type_id)].employee_count
            : 0);
    // Packed projection; refresh_building_store_role_lanes() recomputes it
    // before any wire or ledger read.
    store.role_begin.push_back(0);
    _building_handle_index_clean = false;
    return row;
}

void NativeEconomyRuntime::write_building_group(size_t row,
                                                const BuildingGroup &group) {
    RuntimeEconomyBuildingStore &store = buildings_store();
    if (row >= store.cell.size()) return;
#define PK_BUILDING_GROUP_STORE(TYPE, NAME, COLUMN) \
    store.COLUMN[row] = group.NAME;
    PK_BUILDING_GROUP_COLUMNS(PK_BUILDING_GROUP_STORE)
#undef PK_BUILDING_GROUP_STORE
    _building_handle_index_clean = false;
}

NativeEconomyRuntime::BuildingGroup
NativeEconomyRuntime::building_group_copy(size_t row) const {
    BuildingGroup group;
    const RuntimeEconomyBuildingStore &store = buildings_store();
    if (row >= store.cell.size()) return group;
#define PK_BUILDING_GROUP_READ(TYPE, NAME, COLUMN) \
    group.NAME = static_cast<TYPE>(store.COLUMN[row]);
    PK_BUILDING_GROUP_COLUMNS(PK_BUILDING_GROUP_READ)
#undef PK_BUILDING_GROUP_READ
    return group;
}

void NativeEconomyRuntime::clear_building_groups() {
    RuntimeEconomyBuildingStore &store = buildings_store();
#define PK_BUILDING_GROUP_CLEAR(TYPE, NAME, COLUMN) store.COLUMN.clear();
    PK_BUILDING_GROUP_COLUMNS(PK_BUILDING_GROUP_CLEAR)
#undef PK_BUILDING_GROUP_CLEAR
    store.role_count.clear();
    store.role_begin.clear();
    store.role_filled.clear();
    store.role_contract_wage.clear();
    store.role_base_living_cost.clear();
    store.role_living_cost.clear();
    store.role_local_average_wage.clear();
    store.role_base_wage_due.clear();
    store.role_base_wage_paid.clear();
    store.role_bonus_due.clear();
    store.role_bonus_paid.clear();
    _building_handle_index_clean = false;
}

void NativeEconomyRuntime::reserve_building_groups(size_t capacity) {
    RuntimeEconomyBuildingStore &store = buildings_store();
#define PK_BUILDING_GROUP_RESERVE(TYPE, NAME, COLUMN) \
    store.COLUMN.reserve(capacity);
    PK_BUILDING_GROUP_COLUMNS(PK_BUILDING_GROUP_RESERVE)
#undef PK_BUILDING_GROUP_RESERVE
    store.role_count.reserve(capacity);
    store.role_begin.reserve(capacity);
}

void NativeEconomyRuntime::permute_building_group_columns(
        const std::vector<int32_t> &order) {
    RuntimeEconomyBuildingStore &store = buildings_store();
#define PK_BUILDING_GROUP_GATHER(TYPE, NAME, COLUMN) \
    gather_column(store.COLUMN, order);
    PK_BUILDING_GROUP_COLUMNS(PK_BUILDING_GROUP_GATHER)
#undef PK_BUILDING_GROUP_GATHER
    gather_column(store.role_count, order);
    gather_column(store.role_begin, order);
    _building_handle_index_clean = false;
}

size_t NativeEconomyRuntime::building_group_memory_bytes() const {
    const RuntimeEconomyBuildingStore &store = buildings_store();
    size_t bytes = 0;
#define PK_BUILDING_GROUP_BYTES(TYPE, NAME, COLUMN) \
    bytes += store.COLUMN.capacity() * sizeof(TYPE);
    PK_BUILDING_GROUP_COLUMNS(PK_BUILDING_GROUP_BYTES)
#undef PK_BUILDING_GROUP_BYTES
    bytes += store.role_count.capacity() * sizeof(int32_t);
    bytes += store.role_begin.capacity() * sizeof(int32_t);
    return bytes;
}

void NativeEconomyRuntime::refresh_building_store_role_lanes() const {
    RuntimeEconomyBuildingStore &store = mutable_buildings_store();
    const size_t groups = store.cell.size();
    store.role_count.assign(groups, 0);
    store.role_begin.assign(groups, 0);
    store.role_filled.clear();
    store.role_contract_wage.clear();
    store.role_base_living_cost.clear();
    store.role_living_cost.clear();
    store.role_local_average_wage.clear();
    store.role_base_wage_due.clear();
    store.role_base_wage_paid.clear();
    store.role_bonus_due.clear();
    store.role_bonus_paid.clear();
    store.role_filled.reserve(_building_employee_filled.size());
    for (size_t g = 0; g < groups; ++g) {
        const int32_t type_id = store.type_id[g];
        const int32_t roles =
            (type_id >= 0 &&
             type_id < static_cast<int32_t>(_building_types.size()))
                ? _building_types[static_cast<size_t>(type_id)].employee_count
                : 0;
        store.role_count[g] = roles;
        store.role_begin[g] = static_cast<int32_t>(store.role_filled.size());
        const int32_t begin = store.employee_fill_begin[g];
        for (int32_t r = 0; r < roles; ++r) {
            const int32_t lane = begin + r;
            if (begin < 0 || lane < 0 ||
                lane >= static_cast<int32_t>(_building_employee_filled.size())) {
                store.role_filled.push_back(0);
                store.role_contract_wage.push_back(0);
                store.role_base_living_cost.push_back(0);
                store.role_living_cost.push_back(0);
                store.role_local_average_wage.push_back(0);
                store.role_base_wage_due.push_back(0);
                store.role_base_wage_paid.push_back(0);
                store.role_bonus_due.push_back(0);
                store.role_bonus_paid.push_back(0);
                continue;
            }
            const size_t index = static_cast<size_t>(lane);
            store.role_filled.push_back(_building_employee_filled[index]);
            store.role_contract_wage.push_back(
                _building_role_contract_wage[index]);
            store.role_base_living_cost.push_back(
                _building_role_base_living_cost[index]);
            store.role_living_cost.push_back(_building_role_living_cost[index]);
            store.role_local_average_wage.push_back(
                _building_role_local_average_wage[index]);
            store.role_base_wage_due.push_back(
                _building_role_base_wage_due[index]);
            store.role_base_wage_paid.push_back(
                _building_role_base_wage_paid[index]);
            store.role_bonus_due.push_back(_building_role_bonus_due[index]);
            store.role_bonus_paid.push_back(_building_role_bonus_paid[index]);
        }
    }
}

void NativeEconomyRuntime::refresh_building_store_pending_lanes() const {
    RuntimeEconomyBuildingStore &store = mutable_buildings_store();
    store.pending_cell.clear();
    store.pending_type_id.clear();
    store.pending_owner_signature_id.clear();
    store.pending_count.clear();
    store.pending_ready_day.clear();
    store.pending_sequence.clear();
    store.pending_merchant_debt_principal.clear();
    store.pending_merchant_debt_premium.clear();
    store.pending_merchant_debt_term_cycles_left.clear();
    store.pending_sponsor_family_handle.clear();
    store.pending_cell.reserve(_pending_construction.size());
    for (const PendingConstruction &pending : _pending_construction) {
        store.pending_cell.push_back(pending.cell);
        store.pending_type_id.push_back(pending.type_id);
        store.pending_owner_signature_id.push_back(pending.owner_signature_id);
        store.pending_count.push_back(pending.count);
        store.pending_ready_day.push_back(pending.ready_day);
        store.pending_sequence.push_back(pending.sequence);
        store.pending_merchant_debt_principal.push_back(
            pending.merchant_debt_principal);
        store.pending_merchant_debt_premium.push_back(
            pending.merchant_debt_premium);
        store.pending_merchant_debt_term_cycles_left.push_back(
            pending.merchant_debt_term_cycles_left);
        store.pending_sponsor_family_handle.push_back(
            pending.sponsor_family_handle);
    }
}

int32_t NativeEconomyRuntime::find_building_group(int32_t cell, int32_t type_id,
                                                   int32_t owner_signature_id) const {
    ++_scan_calls_find_building_group;
    for (int32_t i = 0; i < static_cast<int32_t>(building_count()); ++i) {
        const auto group = building_at(static_cast<size_t>(i));
        if (group.cell == cell && group.type_id == type_id &&
            group.owner_signature_id == owner_signature_id) {
            _scan_steps_find_building_group += i + 1;
            note_scan_steps(i + 1);
            return i;
        }
    }
    _scan_steps_find_building_group += static_cast<int64_t>(building_count());
    note_scan_steps(static_cast<int64_t>(building_count()));
    return -1;
}

void NativeEconomyRuntime::initialize_building_role_span(
        BuildingGroupRef group) {
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
        _building_role_forecast_pay_ratio_q16.resize(role_end, 0);
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
        _building_role_forecast_pay_ratio_q16[lane] = 0;
    }
    std::fill(_building_last_input_selected_goods.begin() + span.input_begin,
              _building_last_input_selected_goods.begin() + span.input_begin +
                  type.input_count, -1);
}

void NativeEconomyRuntime::release_building_role_span(
        BuildingGroupConstRef group) {
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
        const auto group = building_at(static_cast<size_t>(index));
        return std::tuple(group.cell, group.type_id, group.owner_signature_id);
    };
    _building_existing_indices_scratch.clear();
    _building_new_indices_scratch.clear();
    for (int32_t index = 0; index < static_cast<int32_t>(building_count()); ++index) {
        const auto group = building_at(static_cast<size_t>(index));
        if (group.count <= 0) {
            if (group.cell >= 0 && group.cell < _cell_count) {
                mark_market_signal_cell_dirty(group.cell);
                mark_labor_signal_cell_dirty(group.cell);
                mark_input_reserve_cell_dirty(group.cell);
            }
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
    _building_group_order_scratch.clear();
    _building_group_order_scratch.reserve(active_count);
    _building_group_is_new_scratch.clear();
    _building_group_is_new_scratch.reserve(active_count);
    _building_investment_score_rebuild_scratch.clear();
    _building_investment_score_rebuild_scratch.reserve(active_count);
    _building_investment_payback_rebuild_scratch.clear();
    _building_investment_payback_rebuild_scratch.reserve(active_count);
    _building_investment_rejection_rebuild_scratch.clear();
    _building_investment_rejection_rebuild_scratch.reserve(active_count);
    _building_factor_cache_rebuild_scratch.clear();
    _building_factor_cache_rebuild_scratch.reserve(active_count);

    // Role spans for new rows are assigned after the permutation, so the
    // sparse employee lanes are written through their final group index.
    auto append_group = [&](int32_t index, bool is_new) {
        _building_group_order_scratch.push_back(index);
        _building_group_is_new_scratch.push_back(is_new ? uint8_t{1}
                                                        : uint8_t{0});
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
    permute_building_group_columns(_building_group_order_scratch);
    for (size_t row = 0; row < _building_group_is_new_scratch.size(); ++row) {
        if (_building_group_is_new_scratch[row] == 0) continue;
        auto group = building_at(row);
        initialize_building_role_span(group);
        if (group.cell >= 0 && group.cell < _cell_count) {
            mark_market_signal_cell_dirty(group.cell);
            mark_labor_signal_cell_dirty(group.cell);
            mark_input_reserve_cell_dirty(group.cell);
        }
    }
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
    for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
        const auto group = building_at(pk_row);
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
    rebuild_building_visual_snapshot();
    rebuild_building_review_buckets();
}

void NativeEconomyRuntime::rebuild_building_visual_snapshot() {
    _building_visual_cell_offsets.assign(
        static_cast<size_t>(std::max(0, _cell_count)) + 1, 0);
    _building_visual_type_indices.clear();
    _building_visual_counts.clear();
    int32_t current_cell = 0;
    int32_t last_cell = -1;
    int32_t last_type = -1;
    for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
        const auto group = building_at(pk_row);
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count ||
            group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size()))
            continue;
        while (current_cell < group.cell) {
            _building_visual_cell_offsets[static_cast<size_t>(++current_cell)] =
                static_cast<int32_t>(_building_visual_type_indices.size());
        }
        if (last_cell == group.cell && last_type == group.type_id) {
            _building_visual_counts.back() = saturating_add(
                _building_visual_counts.back(), group.count, _saturation_count);
        } else {
            _building_visual_type_indices.push_back(group.type_id);
            _building_visual_counts.push_back(group.count);
            last_cell = group.cell;
            last_type = group.type_id;
        }
    }
    while (current_cell < _cell_count) {
        _building_visual_cell_offsets[static_cast<size_t>(++current_cell)] =
            static_cast<int32_t>(_building_visual_type_indices.size());
    }
}

void NativeEconomyRuntime::publish_building_visual_changes(
        const std::vector<int32_t> &changed_cells) {
    if (changed_cells.empty()) return;
    rebuild_building_visual_snapshot();
    _building_visual_dirty_cells.insert(_building_visual_dirty_cells.end(),
                                        changed_cells.begin(), changed_cells.end());
    std::sort(_building_visual_dirty_cells.begin(),
              _building_visual_dirty_cells.end());
    _building_visual_dirty_cells.erase(std::remove_if(
        _building_visual_dirty_cells.begin(), _building_visual_dirty_cells.end(),
        [&](int32_t cell) { return cell < 0 || cell >= _cell_count; }),
        _building_visual_dirty_cells.end());
    _building_visual_dirty_cells.erase(std::unique(
        _building_visual_dirty_cells.begin(), _building_visual_dirty_cells.end()),
        _building_visual_dirty_cells.end());
    ++_building_visual_generation;
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
         group_index < static_cast<int32_t>(building_count()); ++group_index) {
        const auto group = building_at(static_cast<size_t>(group_index));
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
         group_index < static_cast<int32_t>(building_count()); ++group_index) {
        const auto group = building_at(static_cast<size_t>(group_index));
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count ||
            group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size()) ||
            _building_types[group.type_id].kind == 2) continue;
        _building_review_group_indices[cursor++] = group_index;
    }
}

} // namespace pk
