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

NativeEconomyRuntime::BuildingCommitChunkResult
NativeEconomyRuntime::advance_building_commit_chunk(
        int64_t &work_done, int32_t &cursor_start, int32_t &cursor_end,
        bool &building_range_used, std::string &error, bool yield_enabled,
        int32_t *chunks_completed, int32_t max_chunks_per_slice,
        int32_t *phase_fusions, const char **yield_reason,
        const std::chrono::steady_clock::time_point *slice_start,
        double slice_budget_ms) {
    if (_stage != Stage::BUILDING_COMMIT) {
        return BuildingCommitChunkResult::LeftStage;
    }
    _executed_stage = Stage::BUILDING_COMMIT;
    // Phases fuse within one slice, so the mark and the attributed phase must
    // both advance at every phase boundary.
    auto commit_phase_started = Clock::now();
    int32_t commit_phase_active = _building_commit_phase;
    int64_t commit_phase_work_start = work_done;
    const auto record_commit_phase = [&](int64_t minimum_work) {
        const size_t index = static_cast<size_t>(std::clamp(
            commit_phase_active, 0,
            static_cast<int32_t>(BUILDING_COMMIT_PHASE_COUNT - 1)));
        const double phase_ms = elapsed_ms(commit_phase_started);
        _building_commit_slice_phase_ms[index] += phase_ms;
        _building_commit_slice_phase_work[index] +=
            std::max(minimum_work, work_done - commit_phase_work_start);
        if (index == 4 || index == 5) {
            _investment_ms += phase_ms;
        }
        commit_phase_started = Clock::now();
        commit_phase_active = _building_commit_phase;
        commit_phase_work_start = work_done;
    };
    const auto finish_chunk_and_should_yield = [&]() -> bool {
        if (!yield_enabled) {
            return false;
        }
        if (chunks_completed != nullptr) {
            ++(*chunks_completed);
            if (*chunks_completed >= max_chunks_per_slice) {
                if (yield_reason != nullptr) {
                    *yield_reason = "chunk_cap";
                }
                return true;
            }
        }
        if (slice_start != nullptr &&
            elapsed_ms(*slice_start) >= slice_budget_ms) {
            if (yield_reason != nullptr) {
                *yield_reason = "budget";
            }
            return true;
        }
        if (phase_fusions != nullptr) {
            ++(*phase_fusions);
        }
        return false;
    };

    if (_building_commit_phase == 0) {
        _executed_substage = "review_prepare";
        _investment_employment_cells.clear();
        prepare_investment_review_cells();
        _building_commit_cursor = 0;
        _building_finalize_phase = 0;
        _building_commit_phase = 1;
        record_commit_phase(1);
        if (finish_chunk_and_should_yield()) {
            return BuildingCommitChunkResult::StopSlice;
        }
        ++_budgeted_building_commit_phase_fusions;
        return BuildingCommitChunkResult::ContinueFusing;
    }
    if (_building_commit_phase == 1) {
        _executed_substage = "special_reset";
        cursor_start = _building_commit_cursor;
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_building_special_reset_group_indices.size()),
            _building_commit_cursor + BUILDING_REVIEW_GROUPS_PER_SLICE);
        for (; _building_commit_cursor < end; ++_building_commit_cursor) {
            const int32_t g =
                _building_special_reset_group_indices[_building_commit_cursor];
            if (g < 0 || g >= static_cast<int32_t>(building_count())) {
                continue;
            }
            {
                const auto view = building_view(static_cast<size_t>(g));
                if (view.count <= 0 || view.operating_state != 1) continue;
            }
            auto group = building_at(static_cast<size_t>(g));
            group.operating_state = 0;
            group.pending_operating_state = 255;
            group.recovery_cooldown_cycles = 0;
            group.severe_loss_cycles = 0;
            group.recovery_cycles = 0;
            group.recovery_failed_reviews = 0;
        }
        work_done += end - cursor_start;
        cursor_end = _building_commit_cursor;
        if (_building_commit_cursor >=
                static_cast<int32_t>(_building_special_reset_group_indices.size())) {
            _building_commit_cursor = 0;
            _building_commit_phase = 2;
        }
        record_commit_phase(0);
        if (_building_commit_phase == 1 || finish_chunk_and_should_yield()) {
            return BuildingCommitChunkResult::StopSlice;
        }
        ++_budgeted_building_commit_phase_fusions;
        return BuildingCommitChunkResult::ContinueFusing;
    }
    if (_building_commit_phase == 2) {
        _executed_substage = "recovery_review";
        // Track B (user-approved): recovery review is a slow-moving lifecycle
        // pass; review groups every N days and skip the scan in between.
        static const bool commit_track_b_enabled = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B);
            return !(value && std::strcmp(value, "0") == 0);
        }();
        static const int32_t commit_track_b_cadence = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_COMMIT_CADENCE);
            const int32_t parsed = value ? std::atoi(value) : 0;
            return parsed > 0 ? std::min<int32_t>(parsed, 30) : 4;
        }();
        static const int32_t commit_track_b_offset = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_RECOVERY_OFFSET);
            const int32_t parsed = value ? std::atoi(value) : 0;
            return parsed != 0 ? std::abs(parsed) : 1;
        }();
        const bool commit_due = ((_current_day.get() - commit_track_b_offset) %
            commit_track_b_cadence + commit_track_b_cadence) %
            commit_track_b_cadence == 0;
        const int32_t phase_end = _building_review_phase_offsets.size() >= 2
                                      ? _building_review_phase_offsets[1]
                                      : 0;
        const bool skip_throttled_commit = commit_track_b_enabled &&
            commit_track_b_cadence > 1 && !commit_due;
        if (skip_throttled_commit) {
            EconomyCostProbe::record("building_commit.track_b_recovery_skip",
                                     _current_day.get(), 0.0, 1u);
            _building_commit_cursor = phase_end;
        }
        cursor_start = _building_commit_cursor;
        const int32_t end = std::min(
            phase_end,
            _building_commit_cursor + BUILDING_REVIEW_GROUPS_PER_SLICE);
        for (; _building_commit_cursor < end; ++_building_commit_cursor) {
            review_recovery_building_group(
                _building_review_group_indices[_building_commit_cursor]);
        }
        work_done += end - cursor_start;
        cursor_end = _building_commit_cursor;
        if (_building_commit_cursor >= phase_end) {
            _building_commit_cursor = 0;
            _building_commit_phase = 3;
        }
        record_commit_phase(0);
        if (_building_commit_phase == 2 || finish_chunk_and_should_yield()) {
            return BuildingCommitChunkResult::StopSlice;
        }
        ++_budgeted_building_commit_phase_fusions;
        return BuildingCommitChunkResult::ContinueFusing;
    }
    if (_building_commit_phase == 3) {
        _executed_substage = "construction_commit";
        // Recovery tombstones remain addressable through the already baked
        // cell ranges during investment. Compact them together with any
        // post-investment additions in the final commit.
        commit_ready_construction(_investment_employment_cells, false);
        _building_cell_cursor = 0;
        _building_commit_phase = 4;
        record_commit_phase(1);
        if (finish_chunk_and_should_yield()) {
            return BuildingCommitChunkResult::StopSlice;
        }
        ++_budgeted_building_commit_phase_fusions;
        return BuildingCommitChunkResult::ContinueFusing;
    }
    if (_building_commit_phase == 4) {
        _executed_substage = "investment_prepare";
        static const bool commit_track_b_enabled4 = [] {
            const char *value = pk::runtime_switch_value(
                pk::RuntimeSwitch::PK_ECONOMY_TRACK_B);
            return !(value && std::strcmp(value, "0") == 0);
        }();
        static const int32_t commit_track_b_cadence4 = [] {
            const char *value = pk::runtime_switch_value(
                pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_COMMIT_CADENCE);
            const int32_t parsed = value ? std::atoi(value) : 0;
            return parsed > 0 ? std::min<int32_t>(parsed, 30) : 4;
        }();
        static const int32_t commit_track_b_offset4 = [] {
            const char *value = pk::runtime_switch_value(
                pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_INVESTMENT_OFFSET);
            const int32_t parsed = value ? std::atoi(value) : 0;
            return parsed != 0 ? std::abs(parsed) : 3;
        }();
        static const int32_t commit_track_b_spread4 = [] {
            const char *value = pk::runtime_switch_value(
                pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_COMMIT_SPREAD);
            const int32_t parsed = value ? std::atoi(value) : 0;
            return parsed > 0 ? std::min<int32_t>(parsed, 32) : 4;
        }();
        const bool commit_spread_active = commit_track_b_enabled4 &&
            commit_track_b_spread4 > 1;
        const bool investment_due = commit_track_b_enabled4 &&
            commit_track_b_cadence4 > 1 &&
            (((_current_day.get() - commit_track_b_offset4) %
              commit_track_b_cadence4 + commit_track_b_cadence4) %
             commit_track_b_cadence4) == 0;
        if (commit_spread_active) {
            if (!_track_b_investment_cells_pending.empty()) {
                const auto newly_due_cells = std::move(_investment_review_cell_indices);
                _investment_review_cell_indices =
                    _track_b_investment_cells_pending;
                // Finish older batches first while preserving every new review.
                std::unordered_set<int32_t> queued_cells(
                    _investment_review_cell_indices.begin(),
                    _investment_review_cell_indices.end());
                for (const int32_t cell : newly_due_cells) {
                    if (queued_cells.insert(cell).second) {
                        _investment_review_cell_indices.push_back(cell);
                    }
                }
                _building_cell_cursor = 0;
                _building_commit_phase = 5;
                record_commit_phase(0);
                if (finish_chunk_and_should_yield()) {
                    return BuildingCommitChunkResult::StopSlice;
                }
                ++_budgeted_building_commit_phase_fusions;
                return BuildingCommitChunkResult::ContinueFusing;
            }
            if (!investment_due) {
                EconomyCostProbe::record(
                    "building_commit.track_b_investment_skip",
                    _current_day.get(), 0.0, 1u);
                _building_commit_phase = 5;
                record_commit_phase(0);
                if (finish_chunk_and_should_yield()) {
                    return BuildingCommitChunkResult::StopSlice;
                }
                ++_budgeted_building_commit_phase_fusions;
                return BuildingCommitChunkResult::ContinueFusing;
            }
        } else if (!investment_due) {
            EconomyCostProbe::record("building_commit.track_b_investment_skip",
                                     _current_day.get(), 0.0, 1u);
            _building_commit_phase = 5;
            record_commit_phase(0);
            if (finish_chunk_and_should_yield()) {
                return BuildingCommitChunkResult::StopSlice;
            }
            ++_budgeted_building_commit_phase_fusions;
            return BuildingCommitChunkResult::ContinueFusing;
        }
        bool population_changed = false;
        if (!run_endogenous_building_investment(0, 0, true, population_changed,
                                                error)) {
            fail(error.empty() ? "building_investment_prepare_failed" : error);
            record_commit_phase(0);
            return BuildingCommitChunkResult::Fatal;
        }
        if (commit_spread_active) {
            _track_b_investment_cells_pending =
                _investment_review_cell_indices;
            _building_cell_cursor = 0;
        }
        _building_commit_phase = 5;
        record_commit_phase(1);
        if (finish_chunk_and_should_yield()) {
            return BuildingCommitChunkResult::StopSlice;
        }
        ++_budgeted_building_commit_phase_fusions;
        return BuildingCommitChunkResult::ContinueFusing;
    }
    if (_building_commit_phase == 5) {
        _executed_substage = "investment";
        static const bool commit_track_b_enabled5 = [] {
            const char *value = pk::runtime_switch_value(
                pk::RuntimeSwitch::PK_ECONOMY_TRACK_B);
            return !(value && std::strcmp(value, "0") == 0);
        }();
        static const int32_t commit_track_b_cadence5 = [] {
            const char *value = pk::runtime_switch_value(
                pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_COMMIT_CADENCE);
            const int32_t parsed = value ? std::atoi(value) : 0;
            return parsed > 0 ? std::min<int32_t>(parsed, 30) : 4;
        }();
        static const int32_t commit_track_b_offset5 = [] {
            const char *value = pk::runtime_switch_value(
                pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_INVESTMENT_OFFSET);
            const int32_t parsed = value ? std::atoi(value) : 0;
            return parsed != 0 ? std::abs(parsed) : 3;
        }();
        static const int32_t commit_track_b_spread5 = [] {
            const char *value = pk::runtime_switch_value(
                pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_COMMIT_SPREAD);
            const int32_t parsed = value ? std::atoi(value) : 0;
            return parsed > 0 ? std::min<int32_t>(parsed, 32) : 4;
        }();
        const bool commit_spread_active5 = commit_track_b_enabled5 &&
            commit_track_b_spread5 > 1;
        const bool skip_commit_investment5 = !commit_spread_active5 &&
            commit_track_b_enabled5 && commit_track_b_cadence5 > 1 &&
            (((_current_day.get() - commit_track_b_offset5) %
              commit_track_b_cadence5 + commit_track_b_cadence5) %
             commit_track_b_cadence5) != 0;
        if (skip_commit_investment5) {
            if (!flush_market_signal_overflow(error)) {
                fail(error.empty() ? "market_signal_overflow_flush_failed" : error);
                record_commit_phase(0);
                return BuildingCommitChunkResult::Fatal;
            }
            _building_cell_cursor = 0;
            _building_commit_phase = 6;
            record_commit_phase(1);
            if (finish_chunk_and_should_yield()) {
                return BuildingCommitChunkResult::StopSlice;
            }
            ++_budgeted_building_commit_phase_fusions;
            return BuildingCommitChunkResult::ContinueFusing;
        }
        const int32_t investment_cell_count =
            static_cast<int32_t>(_investment_review_cell_indices.size());
        int32_t daily_target = investment_cell_count;
        if (commit_spread_active5 && investment_cell_count > 0) {
            daily_target = std::max<int32_t>(1,
                (investment_cell_count + commit_track_b_spread5 - 1) /
                commit_track_b_spread5);
        }
        // The diagnostic is the number of cells scheduled for this commit,
        // rather than the size of a carried list that may span later epochs.
        // Under commit spread the list may be a carried tail, and only
        // daily_target cells run before the rest is carried again.
        if (_building_cell_cursor == 0)
            _investment_scheduled_review_cells = daily_target;
        cursor_start = _building_cell_cursor;
        int32_t end = std::min<int32_t>(
            investment_cell_count,
            _building_cell_cursor + _investment_cells_per_slice);
        if (commit_spread_active5) end = std::min(end, daily_target);
        bool population_changed = false;
        if (end > _building_cell_cursor && !run_endogenous_building_investment(
                _building_cell_cursor, end, false, population_changed, error)) {
            fail(error.empty() ? "building_investment_failed" : error);
            record_commit_phase(0);
            return BuildingCommitChunkResult::Fatal;
        }
        work_done += end - _building_cell_cursor;
        _building_cell_cursor = end;
        cursor_end = _building_cell_cursor;
        building_range_used = true;
        if (_building_cell_cursor < investment_cell_count) {
            if (commit_spread_active5 &&
                _building_cell_cursor >= daily_target) {
                _track_b_investment_cells_pending.assign(
                    _investment_review_cell_indices.begin() +
                        _building_cell_cursor,
                    _investment_review_cell_indices.end());
                if (!flush_market_signal_overflow(error)) {
                    fail(error.empty()
                        ? "market_signal_overflow_flush_failed" : error);
                    record_commit_phase(0);
                    return BuildingCommitChunkResult::Fatal;
                }
                _building_cell_cursor = 0;
                _building_commit_phase = 6;
                record_commit_phase(1);
                if (finish_chunk_and_should_yield()) {
                    return BuildingCommitChunkResult::StopSlice;
                }
                ++_budgeted_building_commit_phase_fusions;
                return BuildingCommitChunkResult::ContinueFusing;
            }
            record_commit_phase(0);
            return BuildingCommitChunkResult::StopSlice;
        }
        if (commit_spread_active5) _track_b_investment_cells_pending.clear();
        if (!flush_market_signal_overflow(error)) {
            fail(error.empty() ? "market_signal_overflow_flush_failed" : error);
            record_commit_phase(0);
            return BuildingCommitChunkResult::Fatal;
        }
        _building_commit_phase = 6;
        record_commit_phase(0);
        if (finish_chunk_and_should_yield()) {
            return BuildingCommitChunkResult::StopSlice;
        }
        ++_budgeted_building_commit_phase_fusions;
        return BuildingCommitChunkResult::ContinueFusing;
    }
    if (_building_commit_phase == 6) {
        _executed_substage = "finalize";
        if (_building_finalize_phase == 0) {
            const auto finalize_construction_started = Clock::now();
            commit_ready_construction(_investment_employment_cells);
            // structural_commit 已 reconcile 过前缀（_structural_reconciled_upto），
            // finalize 只补快照之后追加的尾部（投资 profession 迁移等），
            // 避免同一 epoch 内对整批 structural cell 双重 reconcile。
            _investment_employment_cells.insert(
                _investment_employment_cells.end(),
                _structural_touched_cells.begin() +
                    std::min<int64_t>(
                        _structural_reconciled_upto,
                        static_cast<int64_t>(_structural_touched_cells.size())),
                _structural_touched_cells.end());
            thread_local std::vector<int32_t> stable_finalize_cells;
            thread_local std::vector<uint32_t> stable_finalize_stamp;
            thread_local uint32_t stable_finalize_generation = 0;
            if (stable_finalize_stamp.size() < static_cast<size_t>(_cell_count.get())) {
                stable_finalize_stamp.resize(static_cast<size_t>(_cell_count.get()),
                                             0);
            }
            ++stable_finalize_generation;
            if (stable_finalize_generation == 0) {
                std::fill(stable_finalize_stamp.begin(),
                          stable_finalize_stamp.end(), 0);
                stable_finalize_generation = 1;
            }
            stable_finalize_cells.clear();
            for (const int32_t cell : _investment_employment_cells) {
                if (cell < 0 || cell >= _cell_count.get() ||
                    stable_finalize_stamp[cell] == stable_finalize_generation) {
                    continue;
                }
                stable_finalize_stamp[cell] = stable_finalize_generation;
                stable_finalize_cells.push_back(cell);
            }
            std::sort(stable_finalize_cells.begin(),
                      stable_finalize_cells.end());
            _investment_employment_cells.swap(stable_finalize_cells);
            publish_building_visual_changes(_investment_employment_cells);
            _building_commit_cursor = 0;
            _building_finalize_phase = 1;
            _finalize_construction_ms +=
                elapsed_ms(finalize_construction_started);
            record_commit_phase(1);
            if (finish_chunk_and_should_yield()) {
                return BuildingCommitChunkResult::StopSlice;
            }
            ++_budgeted_building_commit_phase_fusions;
            return BuildingCommitChunkResult::ContinueFusing;
        }
        if (_building_finalize_phase == 1) {
            const auto finalize_reconcile_started = Clock::now();
            cursor_start = _building_commit_cursor;
            const int32_t end = std::min<int32_t>(
                static_cast<int32_t>(_investment_employment_cells.size()),
                _building_commit_cursor + _building_finalize_cells_per_slice);
            if (!reconcile_building_employment_cells_range(
                    _investment_employment_cells, _building_commit_cursor, end,
                    error)) {
                fail(error.empty() ? "building_investment_reconcile_failed"
                                   : error);
                record_commit_phase(0);
                return BuildingCommitChunkResult::Fatal;
            }
            work_done += end - _building_commit_cursor;
            _building_commit_cursor = end;
            cursor_end = _building_commit_cursor;
            if (_building_commit_cursor >=
                static_cast<int32_t>(_investment_employment_cells.size())) {
                _building_finalize_phase = 2;
            }
            _finalize_reconcile_ms += elapsed_ms(finalize_reconcile_started);
            record_commit_phase(0);
            if (_building_finalize_phase == 1 ||
                finish_chunk_and_should_yield()) {
                return BuildingCommitChunkResult::StopSlice;
            }
            ++_budgeted_building_commit_phase_fusions;
            return BuildingCommitChunkResult::ContinueFusing;
        }
        _investment_pending_by_cell_type.clear();
        _investment_existing_by_cell_type.clear();
        _investment_prepared_epoch = -1;
        _investment_merchant_cash_by_cell.clear();
        _investment_outstanding_credit_by_cell.clear();
        _building_cell_cursor = 0;
        _building_commit_cursor = 0;
        _building_finalize_phase = 0;
        _building_commit_phase = 0;
        if (!commit_fiscal(error)) {
            fail(error.empty() ? "fiscal_commit_failed" : error);
            record_commit_phase(0);
            return BuildingCommitChunkResult::Fatal;
        }
        publish_shadow_graph_stage_reference(
            RuntimeEconomyGraphStage::BUILDING_COMMIT);
        _stage = Stage::FISCAL_SETTLEMENT;
        _family_commit_phase = 0;
        _family_commit_cursor = 0;
        record_commit_phase(1);
        if (finish_chunk_and_should_yield()) {
            return BuildingCommitChunkResult::StopSlice;
        }
        ++_budgeted_building_commit_phase_fusions;
        return BuildingCommitChunkResult::LeftStage;
    }
    return BuildingCommitChunkResult::ContinueFusing;
}

bool NativeEconomyRuntime::run_building_commit_slice(int64_t &work_done,
                                                     std::string &error) {
    struct DiagGuard { NativeEconomyRuntime *r; ~DiagGuard() { r->diag_stage_money_probe("building_commit"); } } diag_guard{this};
    error.clear();
    work_done = 0;
    if (!_bootstrapped || _fatal) {
        return true;
    }
    if (!_epoch_active) {
        return true;
    }
    if (_stage == Stage::WAIT_COMMIT) {
        _stage = Stage::BUILDING_COMMIT;
    }
    // StageOps may re-enter after a fiscal peer park with the formula stage
    // already advanced to FISCAL_SETTLEMENT. Keep draining that barrier here
    // instead of reporting BUILDING_COMMIT complete and skipping into FAMILY.
    if (_stage == Stage::FISCAL_SETTLEMENT) {
        return run_fiscal_settlement_drain(error);
    }
    if (_stage != Stage::BUILDING_COMMIT) {
        return true;
    }

    // Phase-2.4.3.1: drain via the shared phase driver. Never re-enter
    // run_slice_compact (which could overshoot into FISCAL/FAMILY).
    int32_t cursor_start = 0;
    int32_t cursor_end = 0;
    bool building_range_used = false;
    constexpr int kMaxPhaseChunks = 1 << 20;
    for (int guard = 0;
         guard < kMaxPhaseChunks && _stage == Stage::BUILDING_COMMIT && !_fatal;
         ++guard) {
        const BuildingCommitChunkResult result = advance_building_commit_chunk(
            work_done, cursor_start, cursor_end, building_range_used, error,
            /*yield_enabled=*/false, nullptr, 0, nullptr, nullptr, nullptr,
            0.0);
        if (result == BuildingCommitChunkResult::Fatal) {
            if (error.empty()) {
                error = "building_commit_fatal";
            }
            return false;
        }
        if (result == BuildingCommitChunkResult::LeftStage) {
            break;
        }
        // ContinueFusing / StopSlice (mid-cursor): keep draining.
    }
    if (_fatal) {
        error = error.empty() ? "building_commit_fatal" : error;
        return false;
    }
    if (_stage == Stage::BUILDING_COMMIT) {
        error = "building_commit_phase_guard_exhausted";
        fail(error);
        return false;
    }
    // Phase-2.4.3.2: graph has no FISCAL stage; settle before FAMILY_COMMIT.
    if (_stage == Stage::FISCAL_SETTLEMENT) {
        if (!run_fiscal_settlement_drain(error)) {
            return false;
        }
    }
    return true;
}

bool NativeEconomyRuntime::run_household_market_drain(int64_t &work_done,
                                                      std::string &error) {
    struct DiagGuard { NativeEconomyRuntime *r; ~DiagGuard() { r->diag_stage_money_probe("household_market"); } } diag_guard{this};
    error.clear();
    if (!_bootstrapped || _fatal) {
        return true;
    }
    if (!_epoch_active) {
        return true;
    }
    if (_stage == Stage::BUILDING_EMPLOYMENT ||
        _stage == Stage::BUILDING_PRODUCTION) {
        error = "household_prior_incomplete";
        return false;
    }
    if (_stage == Stage::GOVERNMENT_RESEARCH_PROCUREMENT ||
        _stage == Stage::TRADE_DISPATCH ||
        _stage == Stage::STRUCTURAL_COMMIT ||
        _stage == Stage::WAIT_COMMIT ||
        _stage == Stage::BUILDING_COMMIT ||
        _stage == Stage::FISCAL_SETTLEMENT ||
        _stage == Stage::FAMILY_COMMIT ||
        _stage == Stage::PERSON_COMMIT ||
        _stage == Stage::AGGREGATE_PUBLISH) {
        return true;
    }
    if (_stage != Stage::HOUSEHOLD_MARKET) {
        // StageOps graph sequencing can reach HOUSEHOLD while Native is still
        // on an earlier day stage after prelude/plan-only open.
        _stage = Stage::HOUSEHOLD_MARKET;
    }

    // Phase-2.4.4.3: drain via the shared phase driver. Never re-enter
    // run_slice_compact (which could overshoot into GOVERNMENT/TRADE).
    int32_t cursor_start = 0;
    int32_t cursor_end = 0;
    bool building_range_used = false;
    bool cell_range_used = false;
    constexpr int kMaxPhaseChunks = 1 << 20;
    for (int guard = 0;
         guard < kMaxPhaseChunks && _stage == Stage::HOUSEHOLD_MARKET && !_fatal;
         ++guard) {
        const HouseholdMarketChunkResult result = advance_household_market_chunk(
            work_done, cursor_start, cursor_end, building_range_used,
            cell_range_used, error, /*yield_enabled=*/false,
            _active_batch_multiplier, nullptr, 0, nullptr, nullptr, nullptr,
            0.0);
        if (result == HouseholdMarketChunkResult::Fatal) {
            if (error.empty()) {
                error = "household_market_fatal";
            }
            return false;
        }
        if (result == HouseholdMarketChunkResult::LeftStage) {
            break;
        }
        // ContinueFusing / StopSlice (mid-cursor): keep draining.
    }
    if (_fatal) {
        error = error.empty() ? "household_market_fatal" : error;
        return false;
    }
    if (_stage == Stage::HOUSEHOLD_MARKET) {
        error = "household_market_phase_guard_exhausted";
        fail(error);
        return false;
    }
    return true;
}

} // namespace pk
