#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "economy_runtime_variant_helpers.h"
#include "parallel_dispatcher.h"
#include "pk_log.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <map>
#include <numeric>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>

#if defined(_MSC_VER) && defined(_M_X64)
#include <intrin.h>
#endif

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
using namespace godot;
using namespace variant_helpers;

namespace {
using Clock = std::chrono::steady_clock;
double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

uint32_t NativeEconomyRuntime::next_stage_ops_stage_index() const noexcept {
    // Native stage/cursors survive a worker restart. Fiscal settlement belongs
    // to BUILDING_COMMIT in the graph; its pending transaction must finish there.
    using Graph = RuntimeEconomyGraphStage;
    if (!_epoch_active) return 0u;
    Graph next = Graph::BUILDING_PLAN;
    switch (_stage) {
        case Stage::TRADE_SETTLE: next = Graph::TRADE_SETTLE; break;
        case Stage::LEDGER_APPLY: next = Graph::LEDGER_APPLY; break;
        case Stage::BUILDING_EMPLOYMENT: next = Graph::BUILDING_EMPLOYMENT; break;
        case Stage::BUILDING_PRODUCTION: next = Graph::BUILDING_PRODUCTION; break;
        case Stage::HOUSEHOLD_MARKET: next = Graph::HOUSEHOLD_MARKET; break;
        case Stage::GOVERNMENT_RESEARCH_PROCUREMENT:
            next = Graph::GOVERNMENT_RESEARCH_PROCUREMENT; break;
        case Stage::TRADE_DISPATCH: next = Graph::TRADE_DISPATCH; break;
        case Stage::STRUCTURAL_COMMIT: next = Graph::STRUCTURAL_COMMIT; break;
        case Stage::WAIT_COMMIT:
        case Stage::BUILDING_COMMIT:
        case Stage::FISCAL_SETTLEMENT: next = Graph::BUILDING_COMMIT; break;
        case Stage::FAMILY_COMMIT: next = Graph::FAMILY_COMMIT; break;
        case Stage::PERSON_COMMIT: next = Graph::PERSON_COMMIT; break;
        case Stage::AGGREGATE_PUBLISH: next = Graph::AGGREGATE_PUBLISH; break;
        default: break;
    }
    return static_cast<uint32_t>(next);
}

bool NativeEconomyRuntime::run_stage_ops_day(int64_t day_index,
                                              std::string &error) {
    error.clear();
    if (!_bootstrapped || _fatal) {
        return true;
    }
    // Soft-retry prelude the same way compact multi-slice does for fiscal /
    // country-asset peer pending. Capture barriers must be fixed by WorldExt
    // before this entry (see run_economy_stage_ops_day).
    constexpr int kMaxPreludeAttempts = 1 << 16;
    bool idle_done = false;
    for (int attempt = 0; attempt < kMaxPreludeAttempts; ++attempt) {
        int64_t prelude_work = 0;
        bool pending_input = false;
        idle_done = false;
        if (!run_epoch_open_prelude_drain(day_index, prelude_work, error,
                                          &pending_input, &idle_done)) {
            return false;
        }
        if (pending_input) {
            if (error == "same_day_environment_not_captured" ||
                error == "same_day_building_context_not_captured") {
                error = "economy_stage_ops_day_pending_input";
                return false;
            }
            continue;
        }
        if (idle_done) {
            return true;
        }
        if (stage_ops_epoch_open_ready()) {
            break;
        }
        error = "economy_stage_ops_prelude_incomplete";
        return false;
    }
    if (idle_done) {
        return true;
    }
    if (!stage_ops_epoch_open_ready()) {
        error = error.empty() ? "economy_stage_ops_prelude_guard_exhausted"
                              : error;
        return false;
    }

    RuntimeEconomyEpochInput input;
    input.sample_day = day_index;
    input.session_epoch = 1;
    input.economy_generation = committed_generation();
    input.input_generation = committed_generation();
    input.country_generation = committed_generation();
    input.catalog_hash = committed_generation();
    input.policy_hash = input.country_generation;
    input.environment_shape_hash =
        input.catalog_hash ^
        static_cast<uint64_t>(std::max<int64_t>(0, day_index));
    input.cell_count =
        static_cast<uint32_t>(std::max(0, cell_count()));
    input.market_cycle_days = 5;
    input.production_cycle_days = 10;
    input.investment_cycle_days = 20;
    input.valid = input.cell_count > 0 && input.input_generation != 0;

    EconomySoAView view;
    if (!bind_soa_view(view, error)) {
        return false;
    }

    EconomyStageCursor cursor;
    for (uint32_t stage_i = next_stage_ops_stage_index();
         stage_i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT;
         ++stage_i) {
        const auto stage = static_cast<RuntimeEconomyGraphStage>(stage_i);
        EconomyStageResult result;
        if (!economy_dispatch_mutate_stage(view, stage, cursor, input, result,
                                           error) ||
            !result.ok) {
            if (error.empty()) {
                error = result.fatal_reason[0] != '\0'
                            ? result.fatal_reason
                            : "economy_stage_ops_day_stage_failed";
            }
            return false;
        }
    }
    return !_fatal;
}

bool NativeEconomyRuntime::run_government_research_drain(int64_t &work_done,
                                                          std::string &error) {
    error.clear();
    if (!_bootstrapped || _fatal) {
        return true;
    }
    if (_stage == Stage::TRADE_DISPATCH ||
        _stage == Stage::STRUCTURAL_COMMIT ||
        _stage == Stage::BUILDING_COMMIT ||
        _stage == Stage::FISCAL_SETTLEMENT ||
        _stage == Stage::FAMILY_COMMIT ||
        _stage == Stage::PERSON_COMMIT ||
        _stage == Stage::AGGREGATE_PUBLISH) {
        return true;
    }
    if (_stage != Stage::GOVERNMENT_RESEARCH_PROCUREMENT) {
        _stage = Stage::GOVERNMENT_RESEARCH_PROCUREMENT;
    }
    constexpr int kMaxChunks = 1 << 20;
    for (int guard = 0; guard < kMaxChunks && !_fatal; ++guard) {
        if (_country_research_procurement_done) {
            break;
        }
        // Host peer terminals land through the same poll path as fiscal.
        if (!service_country_economy_asset_peer(64, error)) {
            if (runtime_country_asset_pending_reason(error)) {
                error = "country_research_peer_results";
                _executed_substage = "country_asset_peer_pending";
                return false;
            }
            fail(error.empty() ? "country_economy_research_peer_failed" : error);
            return false;
        }
        if (!run_government_research_procurement(error)) {
            fail(error.empty() ? "government_research_procurement_failed"
                               : error);
            return false;
        }
        ++work_done;
        if (_country_research_procurement_continuation.active) {
            // Park on an outstanding Host wire request so prepare can run;
            // do not spin the drain guard waiting for a terminal that never
            // arrives without pending_input.
            if (_country_research_procurement_continuation.pending_request_id !=
                    0 ||
                error == "country_economy_asset_host_pending") {
                error = "country_research_peer_results";
                return false;
            }
            // Sync peer phases advance one durable step per iteration.
            continue;
        }
    }
    if (_fatal) {
        error = error.empty() ? "government_research_fatal" : error;
        return false;
    }
    if (!_country_research_procurement_done) {
        error = "government_research_guard_exhausted";
        fail(error);
        return false;
    }
    // Era advancement procurement (same stage, after research procurement).
    for (int guard = 0; guard < kMaxChunks && !_fatal && !_era_procurement_done;
         ++guard) {
        if (_era_procurement_continuation.active &&
            !service_country_economy_asset_peer(64, error)) {
            if (runtime_country_asset_pending_reason(error)) {
                error = "country_research_peer_results";
                _executed_substage = "era_asset_peer_pending";
                return false;
            }
            fail(error.empty() ? "country_economy_era_peer_failed" : error);
            return false;
        }
        if (!run_government_era_procurement(error)) {
            fail(error.empty() ? "government_era_procurement_failed" : error);
            return false;
        }
        ++work_done;
        if (era_procurement_parked()) {
            error = "country_research_peer_results";
            _executed_substage = "era_asset_peer_pending";
            return false;
        }
    }
    if (_fatal) {
        error = error.empty() ? "government_era_procurement_fatal" : error;
        return false;
    }
    commit_price_ceilings();
    publish_shadow_graph_stage_reference(
        RuntimeEconomyGraphStage::GOVERNMENT_RESEARCH_PROCUREMENT);
    if (_stage == Stage::GOVERNMENT_RESEARCH_PROCUREMENT) {
        _stage = Stage::TRADE_DISPATCH;
    }
    return true;
}

bool NativeEconomyRuntime::run_structural_commit_drain(int64_t &work_done,
                                                        std::string &error) {
    LivingCostMemoScope memo(*this);
    error.clear();
    if (!_bootstrapped || _fatal) {
        return true;
    }
    if (_stage == Stage::BUILDING_COMMIT ||
        _stage == Stage::WAIT_COMMIT ||
        _stage == Stage::FISCAL_SETTLEMENT ||
        _stage == Stage::FAMILY_COMMIT ||
        _stage == Stage::PERSON_COMMIT ||
        _stage == Stage::AGGREGATE_PUBLISH) {
        return true;
    }
    if (_stage != Stage::STRUCTURAL_COMMIT) {
        _stage = Stage::STRUCTURAL_COMMIT;
    }
    const int32_t n = static_cast<int32_t>(_structural_commands.size());
    if (_structural_cursor < 0) {
        _structural_cursor = 0;
    }
    constexpr int kMaxChunks = 1 << 20;
    for (int guard = 0; guard < kMaxChunks && !_fatal; ++guard) {
        if (_structural_cursor >= n) {
            break;
        }
        const int32_t end = std::min<int32_t>(
            n, _structural_cursor + _commands_per_slice);
        for (; _structural_cursor < end; ++_structural_cursor) {
            if (!commit_structural(
                    _structural_commands[static_cast<size_t>(
                        _structural_cursor)],
                    error)) {
                if (runtime_country_asset_pending_reason(error)) {
                    // Cursor stays on this command; it replays next pulse.
                    park_on_country_asset_pending(
                        "structural_country_asset_pending");
                    return false;
                }
                fail(error.empty() ? "structural_commit_failed" : error);
                return false;
            }
            ++work_done;
        }
    }
    if (_fatal) {
        error = error.empty() ? "structural_commit_fatal" : error;
        return false;
    }
    if (_structural_cursor < n) {
        error = "structural_commit_guard_exhausted";
        fail(error);
        return false;
    }
    int64_t merchant_repairs = 0;
    for (const int32_t cell : _structural_touched_cells) {
        if (!ensure_merchant_invariant(cell, merchant_repairs, error)) {
            fail(error.empty() ? "merchant_repair_after_structure_failed"
                               : error);
            return false;
        }
    }
    _merchant_repairs = saturating_add(_merchant_repairs, merchant_repairs,
                                       _saturation_count);
    if (!_structural_touched_cells.empty() &&
        !rebuild_merchant_ranges(error)) {
        fail(error.empty() ? "merchant_range_rebuild_after_structure_failed"
                           : error);
        return false;
    }
    _population_changed_cells.insert(_population_changed_cells.end(),
                                     _structural_touched_cells.begin(),
                                     _structural_touched_cells.end());
    if (!_population_changed_cells.empty() &&
        !reconcile_building_employment_after_population_change(
            _population_changed_cells, error)) {
        fail(error.empty() ? "building_employment_reconcile_failed" : error);
        return false;
    }
    _deferred_population_reconcile_cells.clear();
    _structural_reconciled_upto =
        static_cast<int64_t>(_structural_touched_cells.size());
    publish_shadow_graph_stage_reference(
        RuntimeEconomyGraphStage::STRUCTURAL_COMMIT);
    if (_stage == Stage::STRUCTURAL_COMMIT) {
        _stage = Stage::BUILDING_COMMIT;
    }
    return true;
}

bool NativeEconomyRuntime::run_building_employment_drain(int64_t &work_done,
                                                          std::string &error) {
    struct DiagGuard { NativeEconomyRuntime *r; ~DiagGuard() { r->diag_stage_money_probe("employment"); } } diag_guard{this};
    error.clear();
    if (!_bootstrapped || _fatal) {
        return true;
    }
    // StageOps graph owns sequencing; Native stage may still be earlier in the
    // day. Fail closed only when commit stages have already begun (employment
    // must not run after fiscal/family).
    if (_stage == Stage::BUILDING_COMMIT ||
        _stage == Stage::FISCAL_SETTLEMENT ||
        _stage == Stage::FAMILY_COMMIT ||
        _stage == Stage::PERSON_COMMIT ||
        _stage == Stage::AGGREGATE_PUBLISH) {
        error = "building_employment_stage_past";
        return false;
    }
    if (_stage == Stage::BUILDING_PRODUCTION ||
        _stage == Stage::HOUSEHOLD_MARKET ||
        _stage == Stage::GOVERNMENT_RESEARCH_PROCUREMENT ||
        _stage == Stage::TRADE_DISPATCH ||
        _stage == Stage::STRUCTURAL_COMMIT) {
        // Already past employment on the Native cursor machine.
        return true;
    }

    // Keep the workset selection identical to building_slice_end().  The
    // worker can cross the epoch boundary while a compact slice is being
    // resumed; choosing a non-empty stale epoch list while slice_end_over()
    // has already switched to the live list leaves the cursor unchanged and
    // eventually trips the guard as building_employment_guard_exhausted.
    const auto employment_started = Clock::now();
    const std::vector<int32_t> &cells = _epoch_active
        ? _epoch_building_cells : _building_active_cells;
    _building_cell_cursor = 0;
    constexpr int kMaxChunks = 1 << 20;
    for (int guard = 0; guard < kMaxChunks && !_fatal; ++guard) {
        if (_building_cell_cursor >= static_cast<int32_t>(cells.size())) {
            break;
        }
        const int32_t end = building_slice_end(_building_cell_cursor);
        for (; _building_cell_cursor < end; ++_building_cell_cursor) {
            if (!run_building_employment_cell(
                    cells[static_cast<size_t>(_building_cell_cursor)], true,
                    error)) {
                fail(error.empty() ? "building_employment_failed" : error);
                return false;
            }
            ++work_done;
        }
    }
    if (_fatal) {
        error = error.empty() ? "building_employment_fatal" : error;
        return false;
    }
    if (_building_cell_cursor < static_cast<int32_t>(cells.size())) {
        error = "building_employment_guard_exhausted";
        fail(error);
        return false;
    }
    _building_cell_cursor = 0;
    _employment_ms += elapsed_ms(employment_started);
    prepare_due_demand_basis_cache();
    publish_shadow_graph_stage_reference(
        RuntimeEconomyGraphStage::BUILDING_EMPLOYMENT);
    // StageOps may run while Native stage is still early in the day; always
    // advance the cursor machine past employment after a completed drain.
    if (_stage != Stage::BUILDING_COMMIT &&
        _stage != Stage::FISCAL_SETTLEMENT &&
        _stage != Stage::FAMILY_COMMIT &&
        _stage != Stage::PERSON_COMMIT &&
        _stage != Stage::AGGREGATE_PUBLISH &&
        _stage != Stage::HOUSEHOLD_MARKET &&
        _stage != Stage::GOVERNMENT_RESEARCH_PROCUREMENT &&
        _stage != Stage::TRADE_DISPATCH &&
        _stage != Stage::STRUCTURAL_COMMIT) {
        _stage = Stage::BUILDING_PRODUCTION;
    }
    return true;
}

bool NativeEconomyRuntime::run_building_production_drain(int64_t &work_done,
                                                          std::string &error) {
    struct DiagGuard { NativeEconomyRuntime *r; ~DiagGuard() { r->diag_stage_money_probe("production"); } } diag_guard{this};
    error.clear();
    if (!_bootstrapped || _fatal) {
        return true;
    }
    if (_stage == Stage::BUILDING_COMMIT ||
        _stage == Stage::FISCAL_SETTLEMENT ||
        _stage == Stage::FAMILY_COMMIT ||
        _stage == Stage::PERSON_COMMIT ||
        _stage == Stage::AGGREGATE_PUBLISH) {
        error = "building_production_stage_past";
        return false;
    }
    if (_stage == Stage::HOUSEHOLD_MARKET ||
        _stage == Stage::GOVERNMENT_RESEARCH_PROCUREMENT ||
        _stage == Stage::TRADE_DISPATCH ||
        _stage == Stage::STRUCTURAL_COMMIT) {
        return true;
    }
    if (_stage == Stage::BUILDING_EMPLOYMENT) {
        error = "building_production_prior_incomplete";
        return false;
    }
    if (!refresh_merchant_ranges_if_dirty(error)) {
        fail(error.empty() ? "merchant_range_rebuild_before_production_failed" : error);
        return false;
    }

    // Match building_slice_end() across worker epoch transitions; do not
    // process a stale epoch workset after _epoch_active has been cleared.
    const auto production_started = Clock::now();
    const std::vector<int32_t> &cells = _epoch_active
        ? _epoch_building_cells : _building_active_cells;
    _building_cell_cursor = 0;
    _building_funded_capacity_q16.resize(building_count(), 0);
    _building_working_capital_allocated.resize(building_count(), 0);
    _building_recovery_probe_capacity_q16.resize(building_count(), 0);
    _building_recovery_liquidation_eligible.resize(building_count(), 0);
    const int32_t total_cells = static_cast<int32_t>(cells.size());
    if (total_cells > 0) {
        if (_production_results_scratch.size() < static_cast<size_t>(total_cells)) {
            _production_results_scratch.resize(static_cast<size_t>(total_cells));
        }
        for (int32_t relative = 0; relative < total_cells; ++relative) {
            _production_results_scratch[relative].reset();
        }
        int64_t estimated_work = 0;
        bool disjoint_markets = true;
        _production_cell_weights_scratch.resize(static_cast<size_t>(total_cells));
        for (int32_t relative = 0; relative < total_cells; ++relative) {
            const int32_t cell = cells[static_cast<size_t>(relative)];
            const int32_t group_begin = _building_cell_offsets[cell];
            const int32_t group_end = _building_cell_offsets[cell + 1];
            int64_t cell_work = 1;
            for (int32_t group_index = group_begin;
                 group_index < group_end; ++group_index) {
                const auto group = building_view(static_cast<size_t>(group_index));
                if (group.type_id < 0 ||
                    group.type_id >= static_cast<int32_t>(_building_types.size())) {
                    ++cell_work;
                    continue;
                }
                const BuildingType &type = _building_types[group.type_id];
                cell_work += 8 +
                    static_cast<int64_t>(type.employee_count) * 2 +
                    static_cast<int64_t>(type.input_count) * 4 +
                    static_cast<int64_t>(type.output_count) * 2 +
                    static_cast<int64_t>(type.resource_count) * 2 +
                    static_cast<int64_t>(type.generation_count) * 2 +
                    static_cast<int64_t>(type.market_signal_count);
                for (int32_t input_offset = 0;
                     input_offset < type.input_count; ++input_offset) {
                    const int32_t input_index = type.input_begin + input_offset;
                    if (input_index >= 0 &&
                        input_index < static_cast<int32_t>(_building_inputs.size())) {
                        cell_work += _building_inputs[input_index].candidate_count;
                    }
                }
            }
            _production_cell_weights_scratch[relative] = cell_work;
            estimated_work += cell_work;
            disjoint_markets = disjoint_markets &&
                market_store().cell_to_market[cell] == cell;
        }
        static const int32_t production_tasks_env = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_PRODUCTION_TASKS);
            return value != nullptr && *value != '\0' ? std::atoi(value) : 0;
        }();
        const int32_t production_default_tasks = production_tasks_env > 0
            ? std::min(total_cells, production_tasks_env)
            : _worker_task_cap <= 1
            ? 1
            : static_cast<int32_t>(std::clamp<int64_t>(
                (estimated_work + 1023) / 1024, 2, _worker_task_cap));
        const int32_t worker_tasks = _worker_enabled && disjoint_markets &&
                total_cells >= 2 &&
                estimated_work >= 256 &&
                parallel_has_real_worker_threads()
            ? (production_tasks_env > 0
                ? std::min(total_cells, production_tasks_env)
                : std::min({total_cells, _worker_task_cap,
                    _worker_tasks_hint > 0
                    ? _worker_tasks_hint : production_default_tasks}))
            : 1;
        _production_worker_tasks = worker_tasks;
        _production_worker_tasks_max = std::max(_production_worker_tasks_max, worker_tasks);
        _production_worker_task_sum += worker_tasks;
        _production_worker_weight_total += estimated_work;
        if (worker_tasks > 1) ++_production_worker_parallel_dispatches;
        auto run_cells = [&](int32_t range_begin, int32_t range_end) {
            for (int32_t relative = range_begin; relative < range_end; ++relative) {
                ProductionResult &result = _production_results_scratch[relative];
                const int32_t cell = cells[static_cast<size_t>(relative)];
                result.cell = cell;
                const int64_t capacity_before = result.capacity_bytes();
                std::string production_error;
                result.ok = run_building_production_cell(
                    cell, result, production_error);
                result.error = std::move(production_error);
                const int64_t capacity_after = result.capacity_bytes();
                if (capacity_after > capacity_before) {
                    result.allocation_growth_count = 1;
                    result.allocation_growth_bytes =
                        capacity_after - capacity_before;
                }
            }
        };
        const auto compute_started = Clock::now();
        {
            EconomyCostProbe probe("production.compute", _current_day.get(),
                                   static_cast<uint64_t>(total_cells));
            if (worker_tasks > 1) {
                _production_task_offsets_scratch.assign(
                    static_cast<size_t>(worker_tasks + 1), 0);
                _production_task_offsets_scratch[worker_tasks] = total_cells;
                int32_t previous = 0;
                int64_t prefix_work = 0;
                for (int32_t task = 1; task < worker_tasks; ++task) {
                    const int64_t target =
                        (estimated_work * task + worker_tasks - 1) / worker_tasks;
                    const int32_t last_allowed =
                        total_cells - (worker_tasks - task);
                    int32_t boundary = previous;
                    while (boundary < last_allowed && prefix_work < target) {
                        prefix_work += _production_cell_weights_scratch[boundary];
                        ++boundary;
                    }
                    if (boundary <= previous) {
                        prefix_work += _production_cell_weights_scratch[previous];
                        boundary = previous + 1;
                    }
                    _production_task_offsets_scratch[task] = boundary;
                    previous = boundary;
                }
                auto run_tasks = [&](int32_t task_begin, int32_t task_end) {
                    for (int32_t task = task_begin; task < task_end; ++task) {
                        run_cells(_production_task_offsets_scratch[task],
                                  _production_task_offsets_scratch[task + 1]);
                    }
                };
                parallel_for_range("pk_economy_building_production",
                                   worker_tasks, worker_tasks, 1, run_tasks);
            } else {
                run_cells(0, total_cells);
            }
        }
        _production_worker_ms += elapsed_ms(compute_started);
        const auto merge_started = Clock::now();
        {
            EconomyCostProbe probe("production.merge_summary", _current_day.get(),
                                   static_cast<uint64_t>(total_cells));
            for (int32_t relative = 0; relative < total_cells; ++relative) {
                ProductionResult &prod = _production_results_scratch[relative];
                const int32_t produced_cell = cells[static_cast<size_t>(relative)];
                merge_building_production_result(prod);
                stage_cell_summary(
                    produced_cell, build_cell_summary(produced_cell));
                if (!prod.ok) {
                    error = prod.error.empty() ? "building_production_failed"
                                               : prod.error;
                    fail(error);
                    return false;
                }
                ++work_done;
            }
        }
        _production_merge_ms += elapsed_ms(merge_started);
        _building_cell_cursor = total_cells;
    }
    if (_fatal) {
        error = error.empty() ? "building_production_fatal" : error;
        return false;
    }
    if (_building_cell_cursor < static_cast<int32_t>(cells.size())) {
        error = "building_production_guard_exhausted";
        fail(error);
        return false;
    }
    _building_cell_cursor = 0;
    std::stable_sort(
        _owner_retained_outputs.begin(), _owner_retained_outputs.end(),
        [](const OwnerRetainedOutput &a, const OwnerRetainedOutput &b) {
            if (a.owner_slot != b.owner_slot) {
                return a.owner_slot < b.owner_slot;
            }
            if (a.good_id != b.good_id) {
                return a.good_id < b.good_id;
            }
            return a.building_group < b.building_group;
        });
    size_t retained_write = 0;
    for (const OwnerRetainedOutput &entry : _owner_retained_outputs) {
        if (entry.quantity <= 0) {
            continue;
        }
        if (retained_write > 0 &&
            _owner_retained_outputs[retained_write - 1].owner_slot ==
                entry.owner_slot &&
            _owner_retained_outputs[retained_write - 1].good_id ==
                entry.good_id &&
            _owner_retained_outputs[retained_write - 1].building_group ==
                entry.building_group) {
            _owner_retained_outputs[retained_write - 1].quantity =
                saturating_add(
                    _owner_retained_outputs[retained_write - 1].quantity,
                    entry.quantity, _saturation_count);
        } else {
            _owner_retained_outputs[retained_write++] = entry;
        }
    }
    _production_ms += elapsed_ms(production_started);
    _owner_retained_outputs.resize(retained_write);
    publish_shadow_graph_stage_reference(
        RuntimeEconomyGraphStage::BUILDING_PRODUCTION);
    if (_stage != Stage::BUILDING_COMMIT &&
        _stage != Stage::FISCAL_SETTLEMENT &&
        _stage != Stage::FAMILY_COMMIT &&
        _stage != Stage::PERSON_COMMIT &&
        _stage != Stage::AGGREGATE_PUBLISH &&
        _stage != Stage::GOVERNMENT_RESEARCH_PROCUREMENT &&
        _stage != Stage::TRADE_DISPATCH &&
        _stage != Stage::STRUCTURAL_COMMIT) {
        _stage = Stage::HOUSEHOLD_MARKET;
    }
    return true;
}

bool NativeEconomyRuntime::run_family_commit_drain(int64_t &work_done,
                                                    std::string &error) {
    struct DiagGuard { NativeEconomyRuntime *r; ~DiagGuard() { r->diag_stage_money_probe("family_commit"); } } diag_guard{this};
    error.clear();
    if (!_bootstrapped || _fatal) {
        return true;
    }
    if (_stage == Stage::FISCAL_SETTLEMENT) {
        error = "family_commit_fiscal_unsettled";
        return false;
    }
    if (_stage != Stage::FAMILY_COMMIT) {
        return true;
    }
    constexpr int kMaxPhaseChunks = 1 << 20;
    for (int guard = 0;
         guard < kMaxPhaseChunks && _stage == Stage::FAMILY_COMMIT && !_fatal;
         ++guard) {
        if (!run_family_commit_slice(work_done, error)) {
            return false;
        }
    }
    if (_fatal) {
        error = error.empty() ? "family_commit_fatal" : error;
        return false;
    }
    if (_stage == Stage::FAMILY_COMMIT) {
        error = "family_commit_phase_guard_exhausted";
        fail(error);
        return false;
    }
    return true;
}

} // namespace pk
