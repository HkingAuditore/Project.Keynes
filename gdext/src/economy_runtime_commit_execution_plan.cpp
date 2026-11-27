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

bool NativeEconomyRuntime::evaluate_building_plan_range(
        int32_t active_begin, int32_t end, std::string &error) {
    error.clear();
    if (active_begin >= end) return true;
    static const bool force_serial = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_STAGE_PLAN_SERIAL);
        return value && std::strcmp(value, "1") == 0;
    }();
    const int32_t cell_count = end - active_begin;
    int64_t estimated_work = 0;
    _production_cell_weights_scratch.resize(
        static_cast<size_t>(cell_count));
    for (int32_t relative = 0; relative < cell_count; ++relative) {
        const int32_t cell = _epoch_plan_cells[
            active_begin + relative];
        int64_t cell_work = 1;
        for (int32_t group = _building_cell_offsets[cell];
             group < _building_cell_offsets[cell + 1]; ++group) {
            const int32_t type_id = buildings_store().type_id[group];
            if (type_id < 0 || type_id >= static_cast<int32_t>(
                    _building_types.size())) {
                ++cell_work;
                continue;
            }
            const BuildingType &type = _building_types[type_id];
            cell_work += 8 +
                static_cast<int64_t>(type.input_count) * 4 +
                static_cast<int64_t>(type.output_count) * 3 +
                static_cast<int64_t>(type.employee_count) * 2 +
                static_cast<int64_t>(type.resource_count) * 2;
        }
        _production_cell_weights_scratch[relative] = cell_work;
        estimated_work += cell_work;
    }
    const int32_t default_tasks = _worker_task_cap <= 1
        ? 1
        : static_cast<int32_t>(std::clamp<int64_t>(
            (estimated_work + 1023) / 1024, 2,
            _worker_task_cap));
    const int32_t task_count = !force_serial && _worker_enabled &&
            cell_count >= 2 && estimated_work >= 128 &&
            parallel_has_real_worker_threads()
        ? std::min({cell_count, _worker_task_cap,
            _worker_tasks_hint > 0
            ? _worker_tasks_hint : default_tasks})
        : 1;
    _building_plan_worker_tasks_max = std::max(
        _building_plan_worker_tasks_max, task_count);
    if (task_count > 1)
        ++_building_plan_worker_parallel_dispatches;
    _building_plan_results_scratch.resize(
        static_cast<size_t>(task_count));
    _production_task_offsets_scratch.assign(
        static_cast<size_t>(task_count + 1), 0);
    _production_task_offsets_scratch[task_count] = cell_count;
    int32_t previous = 0;
    int64_t prefix_work = 0;
    for (int32_t task = 1; task < task_count; ++task) {
        const int64_t target =
            (estimated_work * task + task_count - 1) / task_count;
        const int32_t last_allowed =
            cell_count - (task_count - task);
        int32_t boundary = previous;
        while (boundary < last_allowed &&
               prefix_work < target) {
            prefix_work +=
                _production_cell_weights_scratch[boundary];
            ++boundary;
        }
        if (boundary <= previous) {
            prefix_work +=
                _production_cell_weights_scratch[previous];
            boundary = previous + 1;
        }
        _production_task_offsets_scratch[task] = boundary;
        previous = boundary;
    }
    auto run_plan_tasks = [&](int32_t task_begin,
                              int32_t task_end) {
        for (int32_t task = task_begin; task < task_end; ++task) {
            BuildingPlanResult &task_result =
                _building_plan_results_scratch[task];
            std::string task_error;
            const auto task_started = Clock::now();
            task_result.ok = prepare_building_economic_plan(
                active_begin +
                    _production_task_offsets_scratch[task],
                active_begin +
                    _production_task_offsets_scratch[task + 1],
                &_epoch_plan_cells, task_result, task_error);
            task_result.worker_ms = elapsed_ms(task_started);
            if (!task_result.ok)
                task_result.error = std::move(task_error);
        }
    };
    if (task_count > 1) {
        parallel_for_range("pk_economy_building_plan",
                           task_count, task_count, 1,
                           run_plan_tasks);
    } else {
        run_plan_tasks(0, 1);
    }
    for (int32_t task = 0; task < task_count; ++task) {
        const BuildingPlanResult &task_result =
            _building_plan_results_scratch[task];
        _building_plan_worker_cpu_ms += task_result.worker_ms;
        _saturation_count += task_result.saturation_count;
        _merchant_credit_budget = saturating_add(
            _merchant_credit_budget,
            task_result.merchant_credit_budget,
            _saturation_count);
        _merchant_credit_committed = saturating_add(
            _merchant_credit_committed,
            task_result.merchant_credit_committed,
            _saturation_count);
        _recovery_candidates = saturating_add(
            _recovery_candidates,
            task_result.recovery_candidates,
            _saturation_count);
        _recovery_approved = saturating_add(
            _recovery_approved,
            task_result.recovery_approved,
            _saturation_count);
        _loss_suspended_building_groups = saturating_add(
            _loss_suspended_building_groups,
            task_result.loss_suspended_building_groups,
            _saturation_count);
        _unprofitable_building_groups = saturating_add(
            _unprofitable_building_groups,
            task_result.unprofitable_building_groups,
            _saturation_count);
        _utilization_sum_q16 = saturating_add(
            _utilization_sum_q16,
            task_result.utilization_sum_q16,
            _saturation_count);
        if (!task_result.ok && !_fatal) {
            error = task_result.error.empty() ? "building_plan_failed" : task_result.error;
            fail(task_result.error.empty()
                ? "building_plan_failed"
                : task_result.error);
        }
    }
    return !_fatal;
}

bool NativeEconomyRuntime::run_building_plan_drain(int64_t &work_done,
                                                    std::string &error) {
    LivingCostMemoScope memo(*this, true);
    error.clear();
    if (!_bootstrapped || _fatal) {
        return true;
    }
    if (_stage == Stage::TRADE_SETTLE || _stage == Stage::LEDGER_APPLY ||
        _stage == Stage::BUILDING_EMPLOYMENT ||
        _stage == Stage::BUILDING_PRODUCTION ||
        _stage == Stage::HOUSEHOLD_MARKET ||
        _stage == Stage::GOVERNMENT_RESEARCH_PROCUREMENT ||
        _stage == Stage::TRADE_DISPATCH ||
        _stage == Stage::STRUCTURAL_COMMIT ||
        _stage == Stage::BUILDING_COMMIT ||
        _stage == Stage::FISCAL_SETTLEMENT ||
        _stage == Stage::FAMILY_COMMIT ||
        _stage == Stage::PERSON_COMMIT ||
        _stage == Stage::AGGREGATE_PUBLISH) {
        return true;
    }
    if (building_count() == 0) {
        publish_shadow_graph_stage_reference(
            RuntimeEconomyGraphStage::BUILDING_PLAN);
        _stage = Stage::TRADE_SETTLE;
        return true;
    }
    if (_stage != Stage::BUILDING_PLAN) {
        _stage = Stage::BUILDING_PLAN;
    }
    const auto plan_started = Clock::now();
    _building_plan_phase = 0;
    _plan_evaluate_cursor = 0;
    constexpr int kMaxChunks = 1 << 20;
    for (int guard = 0; guard < kMaxChunks && !_fatal; ++guard) {
        if (_plan_evaluate_cursor >=
            static_cast<int32_t>(_epoch_plan_cells.size())) {
            break;
        }
        const int32_t end = plan_evaluate_slice_end(_plan_evaluate_cursor);
        if (!evaluate_building_plan_range(_plan_evaluate_cursor, end, error)) {
            fail(error.empty() ? "building_plan_failed" : error);
            return false;
        }
        work_done += end - _plan_evaluate_cursor;
        _plan_evaluate_cursor = end;
    }
    if (_fatal) {
        error = error.empty() ? "building_plan_evaluate_fatal" : error;
        return false;
    }
    if (_plan_evaluate_cursor < static_cast<int32_t>(_epoch_plan_cells.size())) {
        error = "building_plan_evaluate_guard_exhausted";
        fail(error);
        return false;
    }
    const double plan_evaluate_ms = elapsed_ms(plan_started);
    _building_plan_evaluate_ms += plan_evaluate_ms;
    const auto reserve_started = Clock::now();
    _building_plan_phase = 1;
    _building_cell_cursor = 0;
    for (int guard = 0; guard < kMaxChunks && !_fatal; ++guard) {
        if (_building_cell_cursor >=
            static_cast<int32_t>(_epoch_building_cells.size())) {
            break;
        }
        const int32_t end = building_plan_slice_end(_building_cell_cursor);
        rebuild_production_input_reserves(_building_cell_cursor, end, false);
        work_done += end - _building_cell_cursor;
        _building_cell_cursor = end;
    }
    if (_fatal) {
        error = error.empty() ? "building_plan_reserve_fatal" : error;
        return false;
    }
    if (_building_cell_cursor <
        static_cast<int32_t>(_epoch_building_cells.size())) {
        error = "building_plan_reserve_guard_exhausted";
        fail(error);
        return false;
    }
    _building_cell_cursor = 0;
    _plan_evaluate_cursor = 0;
    _building_plan_phase = 0;
    _building_plan_reserve_ms += elapsed_ms(reserve_started);
    _building_plan_ms += elapsed_ms(plan_started);
    publish_shadow_graph_stage_reference(
        RuntimeEconomyGraphStage::BUILDING_PLAN);
    _stage = Stage::TRADE_SETTLE;
    return true;
}

} // namespace pk
