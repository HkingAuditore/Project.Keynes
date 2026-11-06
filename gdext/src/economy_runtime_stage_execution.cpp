#include "economy_cost_probe.h"
#include "economy_effect_forward.h"
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

Dictionary NativeEconomyRuntime::run_slice_internal(const Dictionary &ctx, bool compact) {
    const auto slice_start = Clock::now();
    _executed_stage = _stage;
    _executed_substage.clear();
    struct DiagMoneyGuard {
        NativeEconomyRuntime *runtime;
        ~DiagMoneyGuard() { runtime->diag_stage_money_probe("slice"); }
    } diag_money_guard{this};
    // Report planner wall time for this native slice only. The planner can run
    // before start_epoch(), so epoch metric resets cannot own this counter.
    _trade_plan_ms = 0.0;
    _trade_plan_scan_body_ms = 0.0;
    _trade_plan_scan_finalize_ms = 0.0;
    _trade_plan_route_prepare_ms = 0.0;
    _trade_plan_route_expand_ms = 0.0;
    _trade_plan_route_finalize_ms = 0.0;
    _trade_plan_scan_pairs_slice = 0;
    _trade_plan_route_sources_prepared_slice = 0;
    _trade_plan_route_expansions_slice = 0;
    _trade_plan_candidates_finalized_slice = 0;
    _publish_slice_phase_ms.fill(0.0);
    _publish_slice_phase_work.fill(0);
    _publish_commit_cells_slice_ms = 0.0;
    _publish_commit_prepare_slice_ms = 0.0;
    _publish_commit_finalize_slice_ms = 0.0;
    _building_commit_slice_phase_ms.fill(0.0);
    _building_commit_slice_phase_work.fill(0);
    _household_slice_phase_ms.fill(0.0);
    _household_slice_phase_work.fill(0);
    Dictionary out;
    const int64_t day_index = dict_num<int64_t>(ctx, "day_index", _current_day.get() < 0 ? 0 : _current_day.get());
    const double requested_slice_budget_ms = std::clamp(
        dict_num<double>(ctx, "slice_budget_ms", 0.8), 0.1, 8.0);
    const double speed_scale = std::max(
        0.0, dict_num<double>(ctx, "speed_scale", 1.0));
    const int32_t requested_batch_multiplier =
        _high_speed_batching_enabled && speed_scale >= 20.0 ? 2 : 1;
    if (!_epoch_active)
        _active_batch_multiplier = 1;
    _active_batch_multiplier = std::max(
        _active_batch_multiplier, requested_batch_multiplier);
    const int32_t batch_multiplier = _active_batch_multiplier;
    // At high simulation speeds the bridge/scheduler overhead is larger than
    // the value of yielding every sub-millisecond range. Wall time only
    // controls yielding; it never changes authoritative work order or results.
    const double slice_budget_ms = requested_slice_budget_ms;
    constexpr int32_t MAX_CHUNKS_PER_SLICE = 8;
    int32_t chunks_completed = 0;
    int32_t phase_fusions = 0;
    const char *yield_reason = "stage_boundary";
    // Set when a cursor-driven stage parked on the Country plan window. The
    // cursor did not advance, so the stage must yield the whole slice instead
    // of re-entering and replaying the same command until the budget runs out.
    bool country_asset_window_pending = false;
    const auto slice_budget_exhausted = [&]() {
        return elapsed_ms(slice_start) >= slice_budget_ms;
    };
    const auto finish_chunk_and_should_yield = [&]() {
        ++chunks_completed;
        if (chunks_completed >= MAX_CHUNKS_PER_SLICE) {
            yield_reason = "chunk_cap";
            return true;
        }
        if (slice_budget_exhausted()) {
            yield_reason = "budget";
            return true;
        }
        ++phase_fusions;
        return false;
    };
    _current_day = std::max(_current_day.get(), day_index);
    int64_t work_done = 0;
    int32_t cursor_start = 0;
    int32_t cursor_end = 0;
    std::string error;
    if (!_bootstrapped || _fatal) {
        out = compact ? compact_report() : report();
        out["done"] = true;
        out["work_done"] = 0;
        out["elapsed_ms"] = elapsed_ms(slice_start);
        return out;
    }
    if (!service_country_economy_asset_peer(64, error)) {
        // Country is a separately scheduled unique-writer under the migrated
        // runtime.  A result can legitimately race the Country boundary (the
        // origin request is admitted in the Economy slice, prepared by the
        // next Country slice, and only then consumed here).  The adapter
        // reports this as a retry/pending error after re-queueing the request;
        // it is backpressure, not an economy-fatal condition.  Treating it as
        // fatal leaves the epoch half-open and the next audit observes staged
        // mints without their committed owner funds (the misleading
        // money_error seen in the UI).
        const bool asset_pending = runtime_country_asset_pending_reason(error);
        if (asset_pending) {
            _executed_stage = Stage::EPOCH_BEGIN;
            _executed_substage = "country_asset_peer_pending";
            out = compact ? compact_report() : report();
            out["done"] = false;
            out["pending_input"] = true;
            out["yield_reason"] = String(error.c_str());
            out["fatal"] = false;
            out["fatal_reason"] = "";
            out["work_done"] = 0;
            out["elapsed_ms"] = elapsed_ms(slice_start);
            return out;
        }
        fail(error.empty() ? "country_economy_fiscal_peer_failed" : error);
        out = compact ? compact_report() : report();
        out["done"] = true;
        out["work_done"] = 0;
        out["elapsed_ms"] = elapsed_ms(slice_start);
        return out;
    }
    if (!_epoch_active &&
        (_fiscal_reservation_continuation.active ||
         _epoch_begin_post_fiscal_pending)) {
        _executed_stage = Stage::EPOCH_BEGIN;
        _executed_substage = _fiscal_reservation_continuation.active
            ? "fiscal_reserve" : "fiscal_finalize";
        // The epoch-open fiscal plan is admitted on one deterministic day.
        // A later scheduler pulse is still a continuation of that plan, not
        // a new day. Do not turn normal wall-clock advancement into a fatal
        // protocol error; all request identities and frozen fiscal lanes must
        // continue to use the saved admission day.
        const int64_t fiscal_day = _epoch_begin_pending_day >= 0
            ? _epoch_begin_pending_day : day_index;
        if (_fiscal_reservation_continuation.active) {
            if (!advance_fiscal_reservation(error)) {
                fail(error.empty() ? "fiscal_reservation_failed" : error);
                out = compact ? compact_report() : report();
                out["done"] = true;
                out["work_done"] = 0;
                out["elapsed_ms"] = elapsed_ms(slice_start);
                return out;
            }
            ++work_done;
            if (_fiscal_reservation_continuation.active) {
                // One country per compact pulse (continuation contract). When a
                // peer request is parked, surface pending_input so Host can
                // same-day prepare the Economy-origin asset.
                if (_fiscal_reservation_continuation.pending_request_id != 0) {
                    out = compact ? compact_report() : report();
                    out["done"] = false;
                    out["pending_input"] = true;
                    out["yield_reason"] = "fiscal_reserve_peer_results";
                    out["fatal"] = false;
                    out["fatal_reason"] = "";
                    out["work_done"] = work_done;
                    out["elapsed_ms"] = elapsed_ms(slice_start);
                    return out;
                }
                yield_reason = "fiscal_reserve_peer_results";
            }
        }
        if (!_fiscal_reservation_continuation.active &&
            _epoch_begin_post_fiscal_pending) {
            if (!finish_epoch_start_after_fiscal(fiscal_day, error)) {
                fail(error.empty() ? "fiscal_begin_finalize_failed" : error);
                out = compact ? compact_report() : report();
                out["done"] = true;
                out["work_done"] = work_done;
                out["elapsed_ms"] = elapsed_ms(slice_start);
                return out;
            }
            ++work_done;
        }
    } else if (!_epoch_active) {
        if (!should_run(day_index)) {
            out = compact ? compact_report() : report();
            out["done"] = true;
            out["work_done"] = 0;
            out["elapsed_ms"] = elapsed_ms(slice_start);
            return out;
        }
        // Country ACK happens at priority 255. Pull already-submitted SETTLE
        // into this idle boundary before process_due inspects SETTLING, so a
        // claimed expedition can land immediately instead of waiting another
        // day. process_due itself is what enqueues a newly arrived party, so
        // dispatch again afterwards: SETTLE-only relocate has no Country
        // prerequisite and must not sit in SETTLING until the next freeze.
        // Country CLAIM dispatch stays on the main runtime-graph / Effect
        // adapter path so sync tests and Host receipt ordering stay intact.
        auto pull_due_family_settlements = [this]() {
            if (_effect_runtime != nullptr)
                _effect_runtime->dispatch_native_economy(this);
            recover_lost_family_settlement_commands();
        };
        pull_due_family_settlements();
        if (!process_due_canal_projects(day_index, error) ||
            !process_due_family_expeditions(day_index, error)) {
            fail(error);
            out = compact ? compact_report() : report();
            out["done"] = true;
            out["elapsed_ms"] = elapsed_ms(slice_start);
            return out;
        }
        pull_due_family_settlements();
        const bool cycle_due = day_index > _last_committed_day.get();
        if (cycle_due && trade_planner_should_run()) {
            _stage = Stage::TRADE_PLANNING;
            _executed_stage = Stage::TRADE_PLANNING;
            if (!run_trade_planner_slice(work_done, error)) {
                fail(error);
                out = compact ? compact_report() : report();
                out["done"] = true;
                out["work_done"] = work_done;
                out["elapsed_ms"] = elapsed_ms(slice_start);
                return out;
            }
            // Advance one bounded planner slice every day, then settle the due
            // phase in the same native call. Planning never delays local cadence.
            _stage = Stage::EPOCH_BEGIN;
        }
        if (!cycle_due && trade_planner_should_run()) {
            _stage = Stage::TRADE_PLANNING;
            _executed_stage = Stage::TRADE_PLANNING;
            if (!run_trade_planner_slice(work_done, error)) fail(error);
            if (!_fatal && _trade_plan.phase == TradePlanStore::IDLE)
                _stage = Stage::IDLE;
            out = compact ? compact_report() : report();
            out["done"] = true;
            out["work_done"] = work_done;
            out["elapsed_ms"] = elapsed_ms(slice_start);
            return out;
        }
        _stage = Stage::EPOCH_BEGIN;
        _executed_stage = Stage::EPOCH_BEGIN;
        if (!start_epoch(day_index, error)) {
            // Soft input barrier: missing same-day env/building capture is a
            // main-thread scheduling gap under worker authority, not a ledger
            // fatal. Park the slice until capture_economy_day_inputs runs.
            if (error == "same_day_environment_not_captured" ||
                error == "same_day_building_context_not_captured" ||
                error == "city_factor_shard_pending") {
                _stage = Stage::IDLE;
                _executed_stage = Stage::IDLE;
                out = compact ? compact_report() : report();
                out["done"] = false;
                out["pending_input"] = true;
                out["yield_reason"] = String(error.c_str());
                out["fatal"] = false;
                out["fatal_reason"] = "";
                out["elapsed_ms"] = elapsed_ms(slice_start);
                out["work_done"] = work_done;
                return out;
            }
            fail(error);
            out = compact ? compact_report() : report();
            out["done"] = true;
            out["elapsed_ms"] = elapsed_ms(slice_start);
            return out;
        }
        if (slice_budget_exhausted()) {
            yield_reason = "budget";
        }
    } else {
        // A continuation reuses the frozen epoch workset and prepare state;
        // count this explicitly so diagnostics can expose duplicate prepare
        // work without changing the five-day cadence.
        ++_prepare_reuse_count;
    }
    ++_continuation_slices;

    // Continue through up to MAX_CHUNKS_PER_SLICE deterministic ranges. Range
    // boundaries and work order are state-derived; elapsed time only decides
    // whether the next range runs now or in the continuation.
    bool command_range_used = false;
    bool cell_range_used = false;
    bool structural_range_used = false;
    bool building_range_used = false;
    while (_epoch_active && !_fatal && !slice_budget_exhausted()) {
        if (_stage == Stage::BUILDING_PLAN) {
            _executed_stage = Stage::BUILDING_PLAN;
            const auto start = Clock::now();
            const bool evaluate_phase = _building_plan_phase == 0;
            cursor_start = evaluate_phase ? _plan_evaluate_cursor
                                          : _building_cell_cursor;
            const int32_t end = evaluate_phase
                ? plan_evaluate_slice_end(_plan_evaluate_cursor)
                : building_plan_slice_end(_building_cell_cursor);
            if (evaluate_phase) {
                _executed_substage = "evaluate";
                if (!evaluate_building_plan_range(_plan_evaluate_cursor, end, error)) {
                    fail(error.empty() ? "building_plan_failed" : error);
                }
            } else {
                _executed_substage = "reserve";
                rebuild_production_input_reserves(
                    _building_cell_cursor, end, false);
            }
            if (!_fatal) {
                work_done += end - cursor_start;
                if (evaluate_phase) _plan_evaluate_cursor = end;
                else _building_cell_cursor = end;
            }
            cursor_end = evaluate_phase ? _plan_evaluate_cursor
                                        : _building_cell_cursor;
            const double plan_slice_ms = elapsed_ms(start);
            _building_plan_ms += plan_slice_ms;
            if (evaluate_phase)
                _building_plan_evaluate_ms += plan_slice_ms;
            else
                _building_plan_reserve_ms += plan_slice_ms;
            building_range_used = true;
            if (_fatal) break;
            const bool plan_range_incomplete = evaluate_phase
                ? _plan_evaluate_cursor < static_cast<int32_t>(
                    _epoch_plan_cells.size())
                : _building_cell_cursor < static_cast<int32_t>(
                    _epoch_building_cells.size());
            if (finish_chunk_and_should_yield()) break;
            if (plan_range_incomplete) continue;
            if (evaluate_phase) {
                _plan_evaluate_cursor = 0;
                _building_cell_cursor = 0;
                _building_plan_phase = 1;
            } else {
                _building_cell_cursor = 0;
                _building_plan_phase = 0;
                publish_shadow_graph_stage_reference(
                    RuntimeEconomyGraphStage::BUILDING_PLAN);
                _stage = Stage::TRADE_SETTLE;
            }
            break;
        }
        if (_stage == Stage::TRADE_SETTLE) {
            _executed_stage = Stage::TRADE_SETTLE;
            if (!settle_due_trade_orders(error)) {
                fail(error);
                break;
            }
            publish_shadow_graph_stage_reference(
                RuntimeEconomyGraphStage::TRADE_SETTLE);
            _stage = Stage::LEDGER_APPLY;
            continue;
        }
        if (_stage == Stage::LEDGER_APPLY) {
            _executed_stage = Stage::LEDGER_APPLY;
            const auto start = Clock::now();
            cursor_start = _command_cursor;
            const int32_t end = std::min<int32_t>(static_cast<int32_t>(_epoch_commands.size()),
                                                  _command_cursor + _commands_per_slice);
            for (; _command_cursor < end; ++_command_cursor) {
                const Command &command = _epoch_commands[_command_cursor];
                if (!apply_command(command, error)) {
                    if (runtime_country_asset_pending_reason(error)) {
                        park_on_country_asset_pending(
                            "ledger_country_asset_pending");
                        country_asset_window_pending = true;
                        yield_reason = "country_asset_plan_pending";
                        break;
                    }
                    if (command.effect_request_id != 0) {
                        EffectCommandResult &result = _effect_command_results[
                            command.effect_request_id];
                        result.complete = 1;
                        result.ok = 0;
                        result.reason = error.empty()
                            ? "effect_economy_commit_failed" : error;
                    }
                    fail(error);
                    break;
                }
                if (command.effect_request_id != 0) {
                    EffectCommandResult &result = _effect_command_results[
                        command.effect_request_id];
                    result.complete = 1;
                    result.ok = 1;
                    result.reason.clear();
                }
                ++_processed_commands;
                ++work_done;
            }
            cursor_end = _command_cursor;
            _ledger_ms += elapsed_ms(start);
            command_range_used = true;
            if (country_asset_window_pending) break;
            if (_fatal) break;
            const bool command_range_incomplete =
                _command_cursor < static_cast<int32_t>(_epoch_commands.size());
            if (finish_chunk_and_should_yield()) break;
            if (command_range_incomplete) continue;
            publish_shadow_graph_stage_reference(
                RuntimeEconomyGraphStage::LEDGER_APPLY);
            _stage = building_count() == 0
                ? Stage::HOUSEHOLD_MARKET : Stage::BUILDING_EMPLOYMENT;
            continue;
        }
        if (_stage == Stage::TRADE_DISPATCH) {
            _executed_stage = Stage::TRADE_DISPATCH;
            if (!dispatch_trade_candidates(error)) {
                fail(error);
                break;
            }
            publish_shadow_graph_stage_reference(
                RuntimeEconomyGraphStage::TRADE_DISPATCH);
            _stage = Stage::STRUCTURAL_COMMIT;
            continue;
        }
        if (_stage == Stage::BUILDING_EMPLOYMENT) {
            _executed_stage = Stage::BUILDING_EMPLOYMENT;
            const auto start = Clock::now();
            cursor_start = _building_cell_cursor;
            const int32_t end = building_slice_end(_building_cell_cursor);
            for (; _building_cell_cursor < end; ++_building_cell_cursor) {
                if (!run_building_employment_cell(
                        _epoch_building_cells[_building_cell_cursor], true, error)) {
                    fail(error.empty() ? "building_employment_failed" : error);
                    break;
                }
                ++work_done;
            }
            cursor_end = _building_cell_cursor;
            _employment_ms += elapsed_ms(start);
            building_range_used = true;
            if (_fatal) break;
            const bool employment_range_incomplete =
                _building_cell_cursor < static_cast<int32_t>(
                    _epoch_building_cells.size());
            if (finish_chunk_and_should_yield()) break;
            if (employment_range_incomplete) continue;
            _building_cell_cursor = 0;
            prepare_due_demand_basis_cache();
            publish_shadow_graph_stage_reference(
                RuntimeEconomyGraphStage::BUILDING_EMPLOYMENT);
            _stage = Stage::BUILDING_PRODUCTION;
            continue;
        }
        if (_stage == Stage::BUILDING_PRODUCTION) {
            _executed_stage = Stage::BUILDING_PRODUCTION;
            if (!refresh_merchant_ranges_if_dirty(error)) {
                fail(error.empty() ? "merchant_range_rebuild_before_production_failed" : error);
                break;
            }
            const auto start = Clock::now();
            cursor_start = _building_cell_cursor;
            const int32_t base_end = building_slice_end(_building_cell_cursor);
            const int32_t end = batch_multiplier == 1
                ? base_end
                : building_slice_end(
                    _building_cell_cursor,
                    std::min<int64_t>(
                        std::numeric_limits<int32_t>::max(),
                        static_cast<int64_t>(_building_cells_per_slice) *
                            batch_multiplier),
                    std::min<int64_t>(
                        std::numeric_limits<int32_t>::max(),
                        static_cast<int64_t>(_building_groups_per_slice) *
                            batch_multiplier));
            if (end > base_end)
                ++_high_speed_production_dispatches_saved;
            const int32_t cell_count = end - _building_cell_cursor;
            _building_funded_capacity_q16.resize(building_count(), 0);
            _building_working_capital_allocated.resize(building_count(), 0);
            _building_recovery_probe_capacity_q16.resize(building_count(), 0);
            _building_recovery_liquidation_eligible.resize(building_count(), 0);
            if (_production_results_scratch.size() <
                    static_cast<size_t>(cell_count)) {
                _production_results_scratch.resize(
                    static_cast<size_t>(cell_count));
            }
                for (int32_t relative = 0; relative < cell_count; ++relative)
                    _production_results_scratch[relative].reset();
            int64_t estimated_work = 0;
            bool disjoint_markets = true;
            _production_cell_weights_scratch.resize(
                static_cast<size_t>(cell_count));
            for (int32_t relative = 0; relative < cell_count; ++relative) {
                const int32_t cell = _epoch_building_cells[
                    _building_cell_cursor + relative];
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
                    // Weight the dominant production lanes without inspecting
                    // mutable state. This remains deterministic and cheap:
                    // recipe alternatives and employment roles are the most
                    // expensive inner loops, followed by outputs/resources.
                    cell_work += 8 +
                        static_cast<int64_t>(type.employee_count) * 2 +
                        static_cast<int64_t>(type.input_count) * 4 +
                        static_cast<int64_t>(type.output_count) * 2 +
                        static_cast<int64_t>(type.resource_count) * 2 +
                        static_cast<int64_t>(type.generation_count) * 2 +
                        static_cast<int64_t>(type.market_signal_count);
                    for (int32_t input_offset = 0;
                         input_offset < type.input_count; ++input_offset) {
                        const int32_t input_index =
                            type.input_begin + input_offset;
                        if (input_index >= 0 &&
                            input_index < static_cast<int32_t>(_building_inputs.size())) {
                            cell_work +=
                                _building_inputs[input_index].candidate_count;
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
                ? std::min(cell_count, production_tasks_env)
                : _worker_task_cap <= 1
                ? 1
                : static_cast<int32_t>(std::clamp<int64_t>(
                    (estimated_work + 1023) / 1024, 2,
                    _worker_task_cap));
            _production_worker_tasks = _worker_enabled && disjoint_markets &&
                    cell_count >= 2 &&
                    estimated_work >= 256 &&
                    parallel_has_real_worker_threads()
                ? (production_tasks_env > 0
                    ? std::min(cell_count, production_tasks_env)
                    : std::min({cell_count, _worker_task_cap,
                        _worker_tasks_hint > 0
                        ? _worker_tasks_hint : production_default_tasks}))
                : 1;
            _production_worker_tasks_max = std::max(
                _production_worker_tasks_max, _production_worker_tasks);
            _production_worker_task_sum += _production_worker_tasks;
            ++_production_worker_dispatches;
            _production_worker_weight_total += estimated_work;
            if (_production_worker_tasks > 1)
                ++_production_worker_parallel_dispatches;
            auto run_cells = [&](int32_t range_begin, int32_t range_end) {
                for (int32_t relative = range_begin; relative < range_end; ++relative) {
                    ProductionResult &result =
                        _production_results_scratch[relative];
                    result.cell = _epoch_building_cells[
                        _building_cell_cursor + relative];
                    const int64_t capacity_before = result.capacity_bytes();
                    std::string production_error;
                    result.ok = run_building_production_cell(
                        _epoch_building_cells[_building_cell_cursor + relative],
                        result, production_error);
                    result.error = std::move(production_error);
                    const int64_t capacity_after = result.capacity_bytes();
                    if (capacity_after > capacity_before) {
                        result.allocation_growth_count = 1;
                        result.allocation_growth_bytes =
                            capacity_after - capacity_before;
                    }
                }
            };
            const auto worker_started = Clock::now();
            if (_production_worker_tasks > 1) {
                const int32_t task_count = _production_worker_tasks;
                _production_task_offsets_scratch.assign(
                    static_cast<size_t>(task_count + 1), 0);
                _production_task_weights_scratch.assign(
                    static_cast<size_t>(task_count), 0);
                _production_task_ms_scratch.assign(
                    static_cast<size_t>(task_count), 0.0);
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
                for (int32_t task = 0; task < task_count; ++task) {
                    int64_t task_work = 0;
                    for (int32_t relative =
                             _production_task_offsets_scratch[task];
                         relative <
                             _production_task_offsets_scratch[task + 1];
                         ++relative) {
                        task_work +=
                            _production_cell_weights_scratch[relative];
                    }
                    _production_task_weights_scratch[task] = task_work;
                }
                auto run_tasks = [&](int32_t task_begin, int32_t task_end) {
                    for (int32_t task = task_begin; task < task_end; ++task) {
                        const auto task_started = Clock::now();
                        run_cells(_production_task_offsets_scratch[task],
                                  _production_task_offsets_scratch[task + 1]);
                        _production_task_ms_scratch[task] =
                            elapsed_ms(task_started);
                    }
                };
                parallel_for_range("pk_economy_building_production",
                                   task_count, task_count, 1, run_tasks);
                const auto weight_minmax = std::minmax_element(
                    _production_task_weights_scratch.begin(),
                    _production_task_weights_scratch.end());
                const int64_t task_weight_min = *weight_minmax.first;
                const int64_t task_weight_max = *weight_minmax.second;
                if (_production_worker_task_weight_min == 0) {
                    _production_worker_task_weight_min = task_weight_min;
                } else {
                    _production_worker_task_weight_min = std::min(
                        _production_worker_task_weight_min, task_weight_min);
                }
                _production_worker_task_weight_max = std::max(
                    _production_worker_task_weight_max, task_weight_max);
                const int64_t ideal_weight =
                    (estimated_work + task_count - 1) / task_count;
                if (ideal_weight > 0) {
                    _production_worker_imbalance_q16_max = std::max(
                        _production_worker_imbalance_q16_max,
                        task_weight_max * Q16_ONE / ideal_weight);
                }
                _production_worker_cpu_ms += std::accumulate(
                    _production_task_ms_scratch.begin(),
                    _production_task_ms_scratch.end(), 0.0);
            } else {
                run_cells(0, cell_count);
            }
            _production_worker_ms += elapsed_ms(worker_started);
            const auto merge_started = Clock::now();
            for (int32_t relative = 0; relative < cell_count; ++relative) {
                ProductionResult &result =
                    _production_results_scratch[relative];
                merge_building_production_result(result);
                const int32_t produced_cell = _epoch_building_cells[
                    _building_cell_cursor + relative];
                stage_cell_summary(
                    produced_cell, build_cell_summary(produced_cell));
                if (!result.ok && !_fatal) {
                    fail(result.error.empty() ? "building_production_failed"
                                               : result.error);
                }
                if (result.ok) ++work_done;
            }
            _production_merge_ms += elapsed_ms(merge_started);
            if (!_fatal) _building_cell_cursor = end;
            cursor_end = _building_cell_cursor;
            _production_ms += elapsed_ms(start);
            building_range_used = true;
            if (_fatal) break;
            const bool production_range_incomplete =
                _building_cell_cursor < static_cast<int32_t>(
                    _epoch_building_cells.size());
            if (finish_chunk_and_should_yield()) break;
            if (production_range_incomplete) continue;
            _building_cell_cursor = 0;
            std::stable_sort(_owner_retained_outputs.begin(), _owner_retained_outputs.end(),
                [](const OwnerRetainedOutput &a, const OwnerRetainedOutput &b) {
                    if (a.owner_slot != b.owner_slot) return a.owner_slot < b.owner_slot;
                    if (a.good_id != b.good_id) return a.good_id < b.good_id;
                    return a.building_group < b.building_group;
                });
            size_t retained_write = 0;
            for (const OwnerRetainedOutput &entry : _owner_retained_outputs) {
                if (entry.quantity <= 0) continue;
                if (retained_write > 0 &&
                    _owner_retained_outputs[retained_write - 1].owner_slot == entry.owner_slot &&
                    _owner_retained_outputs[retained_write - 1].good_id == entry.good_id &&
                    _owner_retained_outputs[retained_write - 1].building_group ==
                        entry.building_group) {
                    _owner_retained_outputs[retained_write - 1].quantity = saturating_add(
                        _owner_retained_outputs[retained_write - 1].quantity,
                        entry.quantity, _saturation_count);
                } else {
                    _owner_retained_outputs[retained_write++] = entry;
                }
            }
            _owner_retained_outputs.resize(retained_write);
            publish_shadow_graph_stage_reference(
                RuntimeEconomyGraphStage::BUILDING_PRODUCTION);
            _stage = Stage::HOUSEHOLD_MARKET;
            continue;
        }
        if (_stage == Stage::HOUSEHOLD_MARKET) {
            const HouseholdMarketChunkResult household_result =
                advance_household_market_chunk(
                    work_done, cursor_start, cursor_end, building_range_used,
                    cell_range_used, error, /*yield_enabled=*/true,
                    batch_multiplier, &chunks_completed, MAX_CHUNKS_PER_SLICE,
                    &phase_fusions, &yield_reason, &slice_start,
                    slice_budget_ms);
            if (household_result == HouseholdMarketChunkResult::Fatal) {
                break;
            }
            if (household_result == HouseholdMarketChunkResult::StopSlice) {
                break;
            }
            // ContinueFusing or LeftStage: re-enter the outer while so
            // GOVERNMENT_RESEARCH (or the next HOUSEHOLD chunk) can fuse.
            continue;
        }
        if (_stage == Stage::GOVERNMENT_RESEARCH_PROCUREMENT) {
            _executed_stage = Stage::GOVERNMENT_RESEARCH_PROCUREMENT;
            _executed_substage = "technology_points";
            if (!run_government_research_procurement(error)) {
                fail(error.empty() ? "government_research_procurement_failed" : error);
                break;
            }
            ++work_done;
            if (_country_research_procurement_continuation.active) {
                // The peer bridge is deliberately a real cross-call barrier.
                // Do not fuse another Economy stage into this call: the next
                // invocation must resume the sealed transaction from its
                // durable phase/cursor.
                yield_reason = "country_research_peer_results";
                break;
            }
            // Candidate selection and the fallback ceiling pass are resumable.
            // Keep the Economy stage open until both passes have consumed the
            // sealed candidate list; no later trade stage may observe partial
            // procurement state.
            if (!_country_research_procurement_done) {
                if (finish_chunk_and_should_yield()) break;
                continue;
            }
            // Era advancement procurement runs after research procurement in
            // the same stage (docs/cpp-dots-runtime/era-advancement-runtime.md).
            if (!_era_procurement_done) {
                _executed_substage = "era_procurement";
                if (!run_government_era_procurement(error)) {
                    fail(error.empty() ? "government_era_procurement_failed" : error);
                    break;
                }
                if (era_procurement_parked()) {
                    yield_reason = "country_research_peer_results";
                    break;
                }
                if (!_era_procurement_done) {
                    if (finish_chunk_and_should_yield()) break;
                    continue;
                }
            }
            commit_price_ceilings();
            publish_shadow_graph_stage_reference(
                RuntimeEconomyGraphStage::GOVERNMENT_RESEARCH_PROCUREMENT);
            _stage = Stage::TRADE_DISPATCH;
            if (finish_chunk_and_should_yield()) break;
            continue;
        }
        if (_stage == Stage::STRUCTURAL_COMMIT) {
            _executed_stage = Stage::STRUCTURAL_COMMIT;
            const auto start = Clock::now();
            cursor_start = _structural_cursor;
            const int32_t end = std::min<int32_t>(static_cast<int32_t>(_structural_commands.size()),
                                                  _structural_cursor + _commands_per_slice);
            for (; _structural_cursor < end; ++_structural_cursor) {
                if (!commit_structural(_structural_commands[_structural_cursor], error)) {
                    if (runtime_country_asset_pending_reason(error)) {
                        park_on_country_asset_pending(
                            "structural_country_asset_pending");
                        country_asset_window_pending = true;
                        yield_reason = "country_asset_plan_pending";
                        break;
                    }
                    fail(error);
                    break;
                }
                ++work_done;
            }
            cursor_end = _structural_cursor;
            _structure_ms += elapsed_ms(start);
            structural_range_used = true;
            if (country_asset_window_pending) break;
            if (_fatal) break;
            const bool structural_range_incomplete =
                _structural_cursor < static_cast<int32_t>(
                    _structural_commands.size());
            if (finish_chunk_and_should_yield()) break;
            if (structural_range_incomplete) continue;
            int64_t merchant_repairs = 0;
            for (const int32_t cell : _structural_touched_cells) {
                if (!ensure_merchant_invariant(cell, merchant_repairs, error)) {
                    fail(error.empty() ? "merchant_repair_after_structure_failed" : error);
                    break;
                }
            }
            if (_fatal) break;
            _merchant_repairs = saturating_add(
                _merchant_repairs, merchant_repairs, _saturation_count);
            if (!_structural_touched_cells.empty() && !rebuild_merchant_ranges(error)) {
                fail(error.empty() ? "merchant_range_rebuild_after_structure_failed" : error);
                break;
            }
            _population_changed_cells.insert(_population_changed_cells.end(),
                _structural_touched_cells.begin(), _structural_touched_cells.end());
            if (!_population_changed_cells.empty() &&
                !reconcile_building_employment_after_population_change(
                    _population_changed_cells, error)) {
                fail(error.empty() ? "building_employment_reconcile_failed" : error);
                break;
            }
            _deferred_population_reconcile_cells.clear();
            // Everything pushed so far is now reconciled; building_commit.finalize
            // only needs the tail appended after this point (e.g. investment
            // profession transitions via move_cohort_population).
            _structural_reconciled_upto =
                static_cast<int64_t>(_structural_touched_cells.size());
            publish_shadow_graph_stage_reference(
                RuntimeEconomyGraphStage::STRUCTURAL_COMMIT);
            _stage = Stage::BUILDING_COMMIT;
            continue;
        }
        if (_stage == Stage::WAIT_COMMIT) {
            // Kept only for v14 trace compatibility; rolling transactions never
            // wait for a global commit boundary.
            _stage = Stage::BUILDING_COMMIT;
            continue;
        }
        if (_stage == Stage::BUILDING_COMMIT) {
            const BuildingCommitChunkResult commit_result =
                advance_building_commit_chunk(
                    work_done, cursor_start, cursor_end, building_range_used,
                    error, /*yield_enabled=*/true, &chunks_completed,
                    MAX_CHUNKS_PER_SLICE, &phase_fusions, &yield_reason,
                    &slice_start, slice_budget_ms);
            if (commit_result == BuildingCommitChunkResult::Fatal) {
                break;
            }
            if (commit_result == BuildingCommitChunkResult::StopSlice) {
                break;
            }
            // ContinueFusing or LeftStage: re-enter the outer while so FISCAL
            // (or the next BUILDING_COMMIT chunk) can run in the same slice.
            continue;
        }
        if (_stage == Stage::FISCAL_SETTLEMENT) {
            _executed_stage = Stage::FISCAL_SETTLEMENT;
            _executed_substage = _fiscal_settlement_continuation.active
                ? "country_transactions" : "finalize";
            if (!advance_fiscal_settlement(error)) {
                fail(error.empty() ? "fiscal_settlement_failed" : error);
                break;
            }
            ++work_done;
            if (_fiscal_settlement_continuation.active) {
                // Keep one-country-per-compact-pulse yielding (continuation
                // contract / save barrier observability). pending_input is
                // attached below only when a peer request is actually parked;
                // otherwise Host must not treat this as an asset prepare wait.
                yield_reason = "fiscal_peer_results";
                break;
            }
            _stage = Stage::FAMILY_COMMIT;
            if (finish_chunk_and_should_yield()) break;
            ++_budgeted_building_commit_phase_fusions;
            continue;
        }
        if (_stage == Stage::FAMILY_COMMIT) {
            _executed_stage = Stage::FAMILY_COMMIT;
            _executed_substage = _family_commit_phase == 0 ? "normalize"
                : (_family_commit_phase == 1 ? "formation" : "lifecycle");
            if (!run_family_commit_slice(work_done, error)) {
                fail(error.empty() ? "family_commit_failed" : error);
                break;
            }
            if (_stage != Stage::FAMILY_COMMIT) {
                publish_shadow_graph_stage_reference(
                    RuntimeEconomyGraphStage::FAMILY_COMMIT);
            }
            if (_stage == Stage::FAMILY_COMMIT || finish_chunk_and_should_yield())
                break;
            continue;
        }
        if (_stage == Stage::PERSON_COMMIT) {
            _executed_stage = Stage::PERSON_COMMIT;
            _executed_substage = _person_commit_phase == 0 ? "snapshot"
                : (_person_commit_phase == 1 ? "reconcile_jobs"
                : (_person_commit_phase == 2 ? "wealth_equity"
                : (_person_commit_phase == 3 ? "promotion"
                                             : "index_finalize")));
            if (!run_person_commit_slice(work_done, error)) {
                fail(error.empty() ? "person_commit_failed" : error);
                break;
            }
            if (_stage != Stage::PERSON_COMMIT) {
                publish_shadow_graph_stage_reference(
                    RuntimeEconomyGraphStage::PERSON_COMMIT);
            }
            if (_stage == Stage::PERSON_COMMIT || finish_chunk_and_should_yield())
                break;
            continue;
        }
        if (_stage == Stage::AGGREGATE_PUBLISH) {
            _executed_stage = Stage::AGGREGATE_PUBLISH;
            while (_epoch_active && !_fatal &&
                   _stage == Stage::AGGREGATE_PUBLISH) {
                const PublishPhase previous_phase = _publish_phase;
                if (!publish_epoch_slice(work_done, error)) {
                    fail(error);
                    break;
                }
                // A single native call may cross cheap publish phase
                // boundaries, but never consumes two chunks from the same
                // phase. This preserves deterministic per-phase work bounds.
                if (_publish_phase == previous_phase ||
                    finish_chunk_and_should_yield()) break;
                ++_budgeted_publish_phase_fusions;
            }
            if (!_fatal && !_epoch_active) {
                publish_shadow_graph_stage_reference(
                    RuntimeEconomyGraphStage::AGGREGATE_PUBLISH);
            }
            break;
        }
        break;
    }
    out = compact ? compact_report() : report();
    if (_executed_stage == Stage::TRADE_PLANNING) {
        out["executed_stage"] = "trade_planning";
        out["executed_substage"] = out.get("trade_plan_substage", "");
    }
    out["done"] = !_epoch_active &&
        !_epoch_begin_post_fiscal_pending &&
        !_fiscal_reservation_continuation.active;
    out["work_done"] = work_done;
    out["cursor_start"] = cursor_start;
    out["cursor_end"] = cursor_end;
    out["elapsed_ms"] = elapsed_ms(slice_start);
    out["slice_budget_ms"] = slice_budget_ms;
    out["requested_slice_budget_ms"] = requested_slice_budget_ms;
    out["chunks_completed"] = chunks_completed;
    out["phase_fusions"] = phase_fusions;
    out["batch_multiplier"] = batch_multiplier;
    out["high_speed_market_dispatches_saved"] =
        _high_speed_market_dispatches_saved;
    out["high_speed_production_dispatches_saved"] =
        _high_speed_production_dispatches_saved;
    out["yield_reason"] = _fatal ? "fatal" :
        (!_epoch_active ? "epoch_complete" : yield_reason);
    // Economy→Country origin assets enqueued mid-slice must surface as
    // pending_input so Host prepare_economy_origin_country_assets can run
    // in the same day visit (see authority-migration D7 same-day prepare).
    // Only park when a wire request is outstanding; zero-amount countries
    // still yield one-per-pulse without forcing a prepare round-trip.
    if (!_fatal &&
        ((std::strcmp(yield_reason, "fiscal_peer_results") == 0 &&
          _fiscal_settlement_continuation.pending_request_id != 0) ||
         (std::strcmp(yield_reason, "fiscal_reserve_peer_results") == 0 &&
          _fiscal_reservation_continuation.pending_request_id != 0) ||
         (std::strcmp(yield_reason, "country_research_peer_results") == 0 &&
          (_country_research_procurement_continuation.pending_request_id != 0 ||
           era_procurement_parked())))) {
        out["pending_input"] = true;
    }
    // A ledger/structural command parked on the Country plan window. Nothing is
    // enqueued and no cursor advanced, so Host must park the day and replay the
    // same command after the next Country commit_day.
    if (country_asset_window_pending) {
        out["pending_input"] = true;
        out["yield_reason"] = "country_economy_asset_country_plan_pending";
    }
    out["budget_overrun_ms"] = std::max(
        0.0, elapsed_ms(slice_start) - slice_budget_ms);
    out["command_range_used"] = command_range_used;
    out["cell_range_used"] = cell_range_used;
    out["structural_range_used"] = structural_range_used;
    out["building_range_used"] = building_range_used;
    return out;
}

bool NativeEconomyRuntime::run_ledger_apply_drain(int64_t &work_done,
                                                   std::string &error) {
    error.clear();
    if (!_bootstrapped || _fatal) {
        return true;
    }
    const int32_t n = static_cast<int32_t>(_epoch_commands.size());
    if (_command_cursor < 0) {
        _command_cursor = 0;
    }
    constexpr int kMaxChunks = 1 << 20;
    for (int guard = 0; guard < kMaxChunks && !_fatal; ++guard) {
        if (_command_cursor >= n) {
            break;
        }
        const int32_t end = std::min<int32_t>(
            n, _command_cursor + _commands_per_slice);
        for (; _command_cursor < end; ++_command_cursor) {
            const Command &command =
                _epoch_commands[static_cast<size_t>(_command_cursor)];
            if (!apply_command(command, error)) {
                if (runtime_country_asset_pending_reason(error)) {
                    // Cursor stays on this command; it replays next pulse.
                    park_on_country_asset_pending("ledger_country_asset_pending");
                    return false;
                }
                if (command.effect_request_id != 0) {
                    EffectCommandResult &result =
                        _effect_command_results[command.effect_request_id];
                    result.complete = 1;
                    result.ok = 0;
                    result.reason = error.empty()
                                        ? "effect_economy_commit_failed"
                                        : error;
                }
                fail(error.empty() ? "ledger_apply_failed" : error);
                return false;
            }
            if (command.effect_request_id != 0) {
                EffectCommandResult &result =
                    _effect_command_results[command.effect_request_id];
                result.complete = 1;
                result.ok = 1;
                result.reason.clear();
            }
            ++_processed_commands;
            ++work_done;
        }
    }
    if (_fatal) {
        error = error.empty() ? "ledger_apply_fatal" : error;
        return false;
    }
    if (_command_cursor < n) {
        error = "ledger_apply_guard_exhausted";
        fail(error);
        return false;
    }
    publish_shadow_graph_stage_reference(
        RuntimeEconomyGraphStage::LEDGER_APPLY);
    if (_stage == Stage::LEDGER_APPLY || _stage == Stage::TRADE_SETTLE ||
        _stage == Stage::BUILDING_PLAN || _stage == Stage::EPOCH_BEGIN) {
        _stage = building_count() == 0 ? Stage::HOUSEHOLD_MARKET
                                    : Stage::BUILDING_EMPLOYMENT;
    }
    return true;
}

} // namespace pk
