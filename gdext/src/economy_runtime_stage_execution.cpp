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
#include "economy_runtime_stage_execution_section_epoch_stage_loop.inc"
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
