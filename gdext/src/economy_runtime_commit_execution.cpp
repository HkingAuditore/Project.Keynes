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
                _investment_review_cell_indices =
                    _track_b_investment_cells_pending;
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

bool NativeEconomyRuntime::run_family_commit_slice(int64_t &work_done,
                                                    std::string &error) {
    error.clear();
    // Phase-2.4.3.2 fail-closed: StageOps must not skip fiscal settlement.
    if (_stage == Stage::FISCAL_SETTLEMENT) {
        error = "family_commit_fiscal_unsettled";
        return false;
    }
    if (_stage != Stage::FAMILY_COMMIT &&
        _stage != Stage::WAIT_COMMIT) {
        // Already past family (or idle); treat as no-op like building slice.
        return true;
    }
    if (_stage == Stage::WAIT_COMMIT) {
        _stage = Stage::FAMILY_COMMIT;
    }
    if (_family_commit_phase == 0) {
        if (_family_runtime_mode.get() == 0 && families_store().active_count == 0) {
            _person_commit_phase = 0;
            _person_commit_cursor = 0;
            _stage = Stage::PERSON_COMMIT;
            ++work_done;
            return true;
        }
        _family_commit_normalize_ms = 0.0;
        _family_commit_attribution_ms = 0.0;
        _family_commit_form_ms = 0.0;
        _family_commit_index_ms = 0.0;
        _family_commit_lifecycle_ms = 0.0;
        _family_commit_influence_ms = 0.0;
        _family_behavior_cache_ms = 0.0;
        _family_behavior_cache_rebuilds = 0;
        _family_behavior_cache_skips = 0;
        _family_behavior_metric_contexts_built = 0;
        _family_behavior_condition_edges_evaluated = 0;
        _family_behavior_cache_last_reasons = 0;
        _rebuild_family_membership_ms = 0.0;
        _rebuild_family_ownership_ms = 0.0;
        _rebuild_family_csr_ms = 0.0;
        _rebuild_family_cellindex_ms = 0.0;
        const auto normalize_started = Clock::now();
        if (!_family_trait_behavior_condition_ops.empty())
            mark_family_behavior_cache_dirty(
                FAMILY_BEHAVIOR_DIRTY_CONDITION_METRICS);
        apply_due_family_trait_commands();
        apply_due_family_founding_choices();
        normalize_family_memberships(false, true);
        recruit_family_dependents();
        absorb_family_households();
        // Attribution walks cohort-contiguous edges; only edges created by
        // recruitment or same-day founding break that order.
        if (_family_indices_dirty) rebuild_family_indices(false);
        _family_commit_normalize_ms += elapsed_ms(normalize_started);
        const auto attribution_started = Clock::now();
        update_family_employment_attribution();
        _family_commit_attribution_ms += elapsed_ms(attribution_started);
        // 沿用活跃经济格；补入本轮新人口页和待处理 offer，避免空格扫描，
        // 同时不漏掉迁入、新建以及已经无人居住但仍需收尾的选择。
        auto &review_cells = _family_review_cells_scratch;
        review_cells.clear();
        const char *workset_disabled = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_ACTIVE_WORKSET_DISABLE);
        if (workset_disabled && std::strcmp(workset_disabled, "1") == 0) {
            review_cells.resize(static_cast<size_t>(_cell_count.get()));
            std::iota(review_cells.begin(), review_cells.end(), 0);
        } else {
            review_cells = _economy_live_cells;
            const auto append_cell = [&](int32_t cell) {
                if (cell >= 0 && cell < _cell_count.get()) review_cells.push_back(cell);
            };
            for (int32_t cell : population_store().page_cell) append_cell(cell);
            for (int32_t cell : _building_active_cells) append_cell(cell);
            for (const auto &offer : _family_founding_offers) append_cell(offer.cell);
            std::sort(review_cells.begin(), review_cells.end());
            review_cells.erase(std::unique(review_cells.begin(), review_cells.end()), review_cells.end());
        }
        if (_family_runtime_mode.get() == 2 && _family_milestones_reached.size() !=
                static_cast<size_t>(_cell_count.get()))
            _family_milestones_reached.resize(static_cast<size_t>(_cell_count.get()), 0);
        _family_commit_cursor = 0;
        _family_commit_phase = 1;
        ++work_done;
        return true;
    }
    if (_family_commit_phase == 1) {
        const auto form_started = Clock::now();
        const int32_t scan_budget = std::max(1,
            _family_cells_per_slice * _family_review_days.get());
        const int32_t begin = _family_commit_cursor;
        const int32_t end = std::min(static_cast<int32_t>(_family_review_cells_scratch.size()),
            _family_commit_cursor + scan_budget);
        for (; _family_commit_cursor < end; ++_family_commit_cursor) {
            const int32_t cell = _family_review_cells_scratch[_family_commit_cursor];
            // Opening founders are created only by bootstrap. An emptied
            // capital must not silently manufacture a replacement household.
            review_family_milestone(cell);
        }
        work_done += end - begin;
        EconomyCostProbe::record("family.review_cells", _current_day.get(), 0.0,
            static_cast<uint64_t>(end - begin));
        _family_commit_form_ms += elapsed_ms(form_started);
        if (_family_commit_cursor < static_cast<int32_t>(_family_review_cells_scratch.size())) return true;
        _family_commit_phase = 2;
        return true;
    }
    // Formation may have appended authoritative edges after the normalization
    // CSR was built. Absorb dependents before rebuild so the same-day founders
    // reach the cell household target from remaining anonymous people. Rebuild
    // before lifecycle so each review is O(edges-of-family), including families
    // formed in this same commit. When nothing was formed the flag stays clear
    // and the CSR is still exact.
    absorb_family_households();
    const auto first_index_started = Clock::now();
    bool structure_changed = _family_indices_dirty;
    if (_family_indices_dirty) rebuild_family_indices(false);
    _family_commit_index_ms += elapsed_ms(first_index_started);
    const int64_t families_before_split = families_store().active_count;
    split_family_branches();
    structure_changed = structure_changed || families_store().active_count != families_before_split ||
        _family_indices_dirty;
    if (_family_indices_dirty) rebuild_family_indices(false);
    const auto lifecycle_started = Clock::now();
    review_family_lifecycle();
    _family_commit_lifecycle_ms += elapsed_ms(lifecycle_started);
    const auto second_index_started = Clock::now();
    structure_changed = structure_changed || _family_indices_dirty;
    if (_family_indices_dirty) rebuild_family_indices(false);
    _family_commit_index_ms += elapsed_ms(second_index_started);
    // Derived caches are published once from the final canonical edge set.
    // Industry metrics must precede influence/effect reconciliation because
    // conditional Family metrics read them.
    bool has_influence = false;
    for (uint8_t flag : family_influences().active) {
        if (flag != 0) {
            has_influence = true;
            break;
        }
    }
    const bool refresh_influence = structure_changed ||
        (!family_memberships().empty() && !has_influence) ||
        (_epoch_id.get() % FAMILY_INFLUENCE_REFRESH_EPOCHS) == 0;
    if (refresh_influence || structure_changed)
        rebuild_family_industry_metrics();
    const auto influence_started = Clock::now();
    if (refresh_influence)
        rebuild_family_influences(false);
    _family_commit_influence_ms += elapsed_ms(influence_started);
    rebuild_family_behavior_cache();
    if (structure_changed || refresh_influence)
        rebuild_family_owned_output_csr();
    prune_family_founding_effects();
    _family_membership_edges_processed +=
        static_cast<int64_t>(family_memberships().size());
    _family_ownership_edges_processed +=
        static_cast<int64_t>(family_ownerships().size());
    _family_commit_phase = 0;
    _family_commit_cursor = 0;
    _person_commit_phase = 0;
    _person_commit_cursor = 0;
    _stage = Stage::PERSON_COMMIT;
    ++work_done;
    return true;
}

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
