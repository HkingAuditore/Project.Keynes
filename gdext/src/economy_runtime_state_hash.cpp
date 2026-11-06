// NativeEconomyRuntime::state_hash_internal, extracted from economy_runtime.cpp; body is token-preserved.
#include "economy_cost_probe.h"
#include "economy_effect_forward.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "modifier_api.h"
#include "country_api.h"
#include "economy_runtime_internal_external_types.inc"
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
int32_t modifier_factor_q16(double factor) {
    if (!std::isfinite(factor) || factor <= 0.0) return 0;
    const double scaled = std::round(factor *
        static_cast<double>(NativeEconomyRuntime::Q16_ONE));
    return static_cast<int32_t>(std::clamp(
        scaled, 0.0, static_cast<double>(std::numeric_limits<int32_t>::max())));
}
} // namespace

namespace {

using Clock = std::chrono::steady_clock;

// effect_pod_upsert / effect_pod_metric / effect_pod_retire now live in
// economy_effect_forward.h: the family write points are split across
// economy_runtime.cpp and economy_runtime_family_buff.cpp, and both translation
// units have to funnel through the same routing decision.

constexpr int64_t price_adjustment_reference(
        int64_t current_price, int64_t adjustment_anchor_price,
        int64_t period_change_q16) {
    return period_change_q16 < 0
        ? std::max<int64_t>(NativeEconomyRuntime::PRICE_NUMERIC_GUARD_MIN,
                            current_price)
        : adjustment_anchor_price;
}

static_assert(price_adjustment_reference(100, 1000, -1) == 100);
static_assert(price_adjustment_reference(100, 1000, 1) == 1000);

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}


} // namespace

// ─── PopulationStore ───────────────────────────────────────────────────

// PopulationStore implementation moved to economy_runtime_storage.cpp.

// PopulationStore allocation and lookup implementation moved to
// economy_runtime_storage.cpp.

// PopulationStore::allocate_slot implementation moved to
// economy_runtime_storage.cpp.

// PopulationStore handle/release implementation moved to
// economy_runtime_storage.cpp.



NativeEconomyRuntime::HouseholdMarketChunkResult
NativeEconomyRuntime::advance_household_market_chunk(
        int64_t &work_done, int32_t &cursor_start, int32_t &cursor_end,
        bool &building_range_used, bool &cell_range_used, std::string &error,
        bool yield_enabled, int32_t batch_multiplier, int32_t *chunks_completed,
        int32_t max_chunks_per_slice, int32_t *phase_fusions,
        const char **yield_reason,
        const std::chrono::steady_clock::time_point *slice_start,
        double slice_budget_ms) {
    if (_stage != Stage::HOUSEHOLD_MARKET) {
        return HouseholdMarketChunkResult::LeftStage;
    }
    _executed_stage = Stage::HOUSEHOLD_MARKET;
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

    if (_household_market_phase == 1) {
        _executed_substage = "post_buildings";
        const auto phase_started = Clock::now();
        cursor_start = _household_post_cursor;
        const int32_t end =
            household_post_slice_end(_household_post_cursor);
        const int32_t begin = _household_post_cursor;
        const int32_t count = end - begin;
        _household_post_saturation_scratch.assign(count, 0);
        _household_post_restarted_scratch.assign(count, 0);
        _household_post_failed_scratch.assign(count, 0);
        const int32_t tasks = _worker_enabled && count >= 2 &&
                parallel_has_real_worker_threads()
            ? std::min(count, _worker_task_cap) : 1;
        auto finalize_cells = [&](int32_t relative_begin,
                                  int32_t relative_end) {
            for (int32_t relative = relative_begin;
                 relative < relative_end; ++relative) {
                finalize_household_building_cell(
                    _epoch_building_cells[begin + relative],
                    _household_post_saturation_scratch[relative],
                    _household_post_restarted_scratch[relative],
                    _household_post_failed_scratch[relative]);
            }
        };
        if (tasks > 1) {
            parallel_for_range("pk_economy_household_post", count,
                               tasks, 1, finalize_cells);
        } else {
            finalize_cells(0, count);
        }
        for (int32_t relative = 0; relative < count; ++relative) {
            _saturation_count = saturating_add(
                _saturation_count,
                _household_post_saturation_scratch[relative],
                _saturation_count);
            _recovery_restarted = saturating_add(
                _recovery_restarted,
                _household_post_restarted_scratch[relative],
                _saturation_count);
            _recovery_failed = saturating_add(
                _recovery_failed,
                _household_post_failed_scratch[relative],
                _saturation_count);
        }
        _household_post_cursor = end;
        work_done += end - cursor_start;
        cursor_end = _household_post_cursor;
        building_range_used = true;
        if (_household_post_cursor >= static_cast<int32_t>(
                _epoch_building_cells.size())) {
            _household_post_cursor = 0;
            _household_market_phase = 2;
        }
        _household_slice_phase_ms[HOUSEHOLD_POST_BUILDINGS] +=
            elapsed_ms(phase_started);
        _household_slice_phase_work[HOUSEHOLD_POST_BUILDINGS] +=
            end - begin;
        if (finish_chunk_and_should_yield()) {
            return HouseholdMarketChunkResult::StopSlice;
        }
        return HouseholdMarketChunkResult::ContinueFusing;
    }
    if (_household_market_phase == 2) {
        _executed_substage = "reserve_shortfall";
        const auto phase_started = Clock::now();
        cursor_start = _household_post_cursor;
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_epoch_settlement_cells.size()),
            _household_post_cursor + PUBLISH_ENTRIES_PER_SLICE);
        const int32_t begin = _household_post_cursor;
        const int32_t count = end - begin;
        _household_reserve_shortfall_scratch.assign(count, 0);
        _household_post_saturation_scratch.assign(count, 0);
        const int32_t tasks = _worker_enabled && count >= 2 &&
                parallel_has_real_worker_threads()
            ? std::min(count, _worker_task_cap) : 1;
        auto accumulate_cells = [&](int32_t relative_begin,
                                    int32_t relative_end) {
            for (int32_t relative = relative_begin;
                 relative < relative_end; ++relative) {
                _household_reserve_shortfall_scratch[relative] =
                    production_reserve_shortfall_cell(
                        _epoch_settlement_cells[begin + relative],
                        _household_post_saturation_scratch[relative]);
            }
        };
        if (tasks > 1) {
            parallel_for_range("pk_economy_household_reserve", count,
                               tasks, 1, accumulate_cells);
        } else {
            accumulate_cells(0, count);
        }
        for (int32_t relative = 0; relative < count; ++relative) {
            _saturation_count = saturating_add(
                _saturation_count,
                _household_post_saturation_scratch[relative],
                _saturation_count);
            _production_input_reserve_shortfall = saturating_add(
                _production_input_reserve_shortfall,
                _household_reserve_shortfall_scratch[relative],
                _saturation_count);
        }
        _household_post_cursor = end;
        work_done += end - cursor_start;
        cursor_end = _household_post_cursor;
        cell_range_used = true;
        if (_household_post_cursor >= static_cast<int32_t>(
                _epoch_settlement_cells.size())) {
            _household_post_cursor = 0;
            _household_market_phase = 3;
        }
        _household_slice_phase_ms[HOUSEHOLD_RESERVE_SHORTFALL] +=
            elapsed_ms(phase_started);
        _household_slice_phase_work[HOUSEHOLD_RESERVE_SHORTFALL] +=
            end - begin;
        if (finish_chunk_and_should_yield()) {
            return HouseholdMarketChunkResult::StopSlice;
        }
        return HouseholdMarketChunkResult::ContinueFusing;
    }
    if (_household_market_phase == 3) {
        _executed_substage = "income_subsidy";
        const auto phase_started = Clock::now();
        cursor_start = _household_post_cursor;
        const int32_t begin = _household_post_cursor;
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_epoch_settlement_cells.size()),
            _household_post_cursor + PUBLISH_ENTRIES_PER_SLICE);
        for (; _household_post_cursor < end;
             ++_household_post_cursor) {
            const int32_t cell = _epoch_settlement_cells[_household_post_cursor];
            if ((_epoch_negative_tax_mask & static_cast<uint8_t>(
                    1U << CountryApi::TAX_INCOME)) != 0)
                settle_income_subsidies_for_cell(cell, _saturation_count);
            if ((_epoch_absolute_tax_mask & static_cast<uint8_t>(
                    (1U << CountryApi::TAX_INCOME) |
                    (1U << CountryApi::TAX_BUSINESS))) != 0)
                settle_absolute_daily_taxes_for_cell(cell, _saturation_count);
            ++work_done;
        }
        cursor_end = _household_post_cursor;
        cell_range_used = true;
        if (_household_post_cursor >= static_cast<int32_t>(
                _epoch_settlement_cells.size())) {
            _household_post_cursor = 0;
            _household_market_phase = 4;
        }
        {
            const double subsidy_ms = elapsed_ms(phase_started);
            _household_slice_phase_ms[HOUSEHOLD_INCOME_SUBSIDY] += subsidy_ms;
            _income_subsidy_epoch_ms += subsidy_ms;
        }
        _household_slice_phase_work[HOUSEHOLD_INCOME_SUBSIDY] +=
            end - begin;
        if (finish_chunk_and_should_yield()) {
            return HouseholdMarketChunkResult::StopSlice;
        }
        return HouseholdMarketChunkResult::ContinueFusing;
    }
    if (_household_market_phase == 4) {
        _executed_substage = "structural_sort";
        const auto phase_started = Clock::now();
        if (_approximation_cooldown_epochs_left > 0) {
            --_approximation_cooldown_epochs_left;
        } else if (_accuracy_preset != 0 &&
                   _approximation_runtime_mode != 0 &&
                   _approximation_decisions > 0) {
            const bool low_prune_rate =
                _approximation_frontier_candidates <= 0 ||
                _approximation_frontier_pruned * 50 <
                    _approximation_frontier_candidates;
            _approximation_low_prune_epochs = low_prune_rate
                ? _approximation_low_prune_epochs + 1 : 0;
            const bool excessive_certificate_failures =
                _approximation_certificate_failures * 4 >
                    _approximation_decisions;
            if (_approximation_probe_violations > 0 ||
                excessive_certificate_failures ||
                _approximation_low_prune_epochs >= 2) {
                _approximation_cooldown_epochs_left =
                    _accuracy_fallback_cooldown_epochs;
                _approximation_low_prune_epochs = 0;
            }
        }
        _structural_commands.stable_sort(
                         [](const StructuralCommand &a, const StructuralCommand &b) {
            if (a.cell != b.cell) return a.cell < b.cell;
            const int32_t a_phase = a.opcode == STRUCTURAL_BIRTH ? 1 : 0;
            const int32_t b_phase = b.opcode == STRUCTURAL_BIRTH ? 1 : 0;
            if (a_phase != b_phase) return a_phase < b_phase;
            if (a.signature != b.signature) return a.signature < b.signature;
            if (a.sequence != b.sequence) return a.sequence < b.sequence;
            return a.source_slot < b.source_slot;
        });
        work_done += static_cast<int64_t>(_structural_commands.size());
        _household_slice_phase_ms[HOUSEHOLD_STRUCTURAL_SORT] +=
            elapsed_ms(phase_started);
        _household_slice_phase_work[HOUSEHOLD_STRUCTURAL_SORT] +=
            static_cast<int64_t>(_structural_commands.size());
        _household_market_phase = 0;
        publish_shadow_graph_stage_reference(
            RuntimeEconomyGraphStage::HOUSEHOLD_MARKET);
        _stage = Stage::GOVERNMENT_RESEARCH_PROCUREMENT;
        if (finish_chunk_and_should_yield()) {
            return HouseholdMarketChunkResult::StopSlice;
        }
        return HouseholdMarketChunkResult::LeftStage;
    }
    _executed_substage = "settle";
    const auto settle_started = Clock::now();
    cursor_start = _cell_cursor;
    const int32_t begin = _cell_cursor;
    int32_t end = begin;
    int64_t slice_cohorts = 0;
    if (_auto_slice_by_scale) {
        // Cohort count, not cell count, is the dominant cost. Stop at
        // a deterministic cohort budget so unevenly populated cells do
        // not create an accidental long slice.
        while (end < static_cast<int32_t>(_epoch_market_ids.size()) &&
               end - begin < _cells_per_slice * batch_multiplier &&
               (end == begin || slice_cohorts <
                    _target_cohorts_per_slice * batch_multiplier)) {
            const int32_t market = _epoch_market_ids[end];
            for (int32_t k = _market_cell_offsets[market];
                 k < _market_cell_offsets[market + 1]; ++k) {
                slice_cohorts += _committed_cells[_market_cells[k]].cohort_count;
            }
            ++end;
        }
    } else {
        end = std::min<int32_t>(static_cast<int32_t>(_epoch_market_ids.size()),
                                begin + _cells_per_slice *
                                    batch_multiplier);
    }
    if (batch_multiplier > 1) {
        int32_t base_end = begin;
        int64_t base_cohorts = 0;
        if (_auto_slice_by_scale) {
            while (base_end < static_cast<int32_t>(
                       _epoch_market_ids.size()) &&
                   base_end - begin < _cells_per_slice &&
                   (base_end == begin ||
                    base_cohorts < _target_cohorts_per_slice)) {
                const int32_t market = _epoch_market_ids[base_end];
                for (int32_t k = _market_cell_offsets[market];
                     k < _market_cell_offsets[market + 1]; ++k) {
                    base_cohorts +=
                        _committed_cells[_market_cells[k]].cohort_count;
                }
                ++base_end;
            }
        } else {
            base_end = std::min<int32_t>(
                static_cast<int32_t>(_epoch_market_ids.size()),
                begin + _cells_per_slice);
        }
        if (end > base_end)
            ++_high_speed_market_dispatches_saved;
    }
    const int32_t market_count = end - begin;
    if (begin < _workset_last_cursor || end <= begin ||
        end > static_cast<int32_t>(_epoch_market_ids.size())) {
        ++_duplicate_range_count;
    }
    if (_market_results_scratch.size() < static_cast<size_t>(market_count))
        _market_results_scratch.resize(static_cast<size_t>(market_count));
    for (int32_t relative = 0; relative < market_count; ++relative) {
        _market_results_scratch[relative].reset();
        _market_results_scratch[relative].market =
            _epoch_market_ids[begin + relative];
        if (_accuracy_preset != 0 &&
            _approximation_runtime_mode != 0 &&
            _approximation_cooldown_epochs_left == 0) {
            _market_results_scratch[relative].
                approximation_variant_active.assign(
                    _variants.size(), uint8_t{1});
        }
    }
    int64_t estimated_work = 0;
    _production_cell_weights_scratch.resize(
        static_cast<size_t>(market_count));
    for (int32_t relative = 0; relative < market_count; ++relative) {
        const int64_t market_work =
            _epoch_market_work_weights[begin + relative];
        _production_cell_weights_scratch[relative] = market_work;
        estimated_work += market_work;
    }
    const int32_t economy_default_tasks = _worker_task_cap <= 1
        ? 1
        : static_cast<int32_t>(std::clamp<int64_t>(
            (estimated_work + 1023) / 1024, 2,
            _worker_task_cap));
    _worker_tasks = _worker_enabled &&
                            market_count >= 2 &&
                            estimated_work >= 256 &&
                            parallel_has_real_worker_threads()
                        ? std::min({market_count, _worker_task_cap,
                                   _worker_tasks_hint > 0
                                       ? _worker_tasks_hint
                                       : economy_default_tasks})
                        : 1;
    _market_worker_tasks_max = std::max(
        _market_worker_tasks_max, _worker_tasks);
    _market_worker_task_sum += _worker_tasks;
    ++_market_worker_dispatches;
    auto run_markets = [&](int32_t range_begin, int32_t range_end) {
        for (int32_t relative = range_begin; relative < range_end; ++relative) {
            MarketResult &market_result = _market_results_scratch[relative];
            const int64_t capacity_before = market_result.capacity_bytes();
            std::string market_error;
            market_result.ok = process_market_cell(
                _epoch_market_ids[begin + relative], market_result, market_error);
            market_result.error = std::move(market_error);
            const int64_t capacity_after = market_result.capacity_bytes();
            if (capacity_after > capacity_before) {
                market_result.allocation_growth_count = 1;
                market_result.allocation_growth_bytes =
                    capacity_after - capacity_before;
            }
        }
    };
    {
        std::string merchant_error;
        int64_t slice_merchant_repairs = 0;
        for (int32_t relative = 0; relative < market_count; ++relative) {
            const int32_t market = _epoch_market_ids[begin + relative];
            if (!ensure_market_has_living_merchant(
                    market, slice_merchant_repairs, merchant_error)) {
                fail(merchant_error.empty()
                    ? "merchant_repair_before_household_failed"
                    : merchant_error);
                break;
            }
        }
        if (_fatal) {
            return HouseholdMarketChunkResult::Fatal;
        }
        _merchant_repairs = saturating_add(
            _merchant_repairs, slice_merchant_repairs, _saturation_count);
    }
    const double slice_prepare_ms = elapsed_ms(settle_started);
    _household_market_prepare_ms += slice_prepare_ms;
    _household_slice_phase_ms[HOUSEHOLD_PREPARE] += slice_prepare_ms;
    _household_slice_phase_work[HOUSEHOLD_PREPARE] += market_count;
    const auto worker_started = Clock::now();
    if (_worker_tasks > 1) {
        ++_market_worker_parallel_dispatches;
        _production_task_offsets_scratch.assign(
            static_cast<size_t>(_worker_tasks + 1), 0);
        _production_task_offsets_scratch[_worker_tasks] =
            market_count;
        int32_t previous = 0;
        int64_t prefix_work = 0;
        for (int32_t task = 1; task < _worker_tasks; ++task) {
            const int64_t target =
                (estimated_work * task + _worker_tasks - 1) /
                _worker_tasks;
            const int32_t last_allowed =
                market_count - (_worker_tasks - task);
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
        if (_staging_cell_generation.size() != _staging_cells.size())
            _staging_cell_generation.assign(_staging_cells.size(), 0);
        _staging_touched_task_scratch.resize(
            static_cast<size_t>(_worker_tasks));
        for (std::vector<int32_t> &buffer :
                 _staging_touched_task_scratch) {
            buffer.clear();
        }
        auto run_market_tasks = [&](int32_t task_begin,
                                    int32_t task_end) {
            // parallel_for_range may run tasks on the calling thread,
            // so restore rather than clear the sink on the way out.
            std::vector<int32_t> *const outer_sink =
                _staging_touched_sink;
            for (int32_t task = task_begin; task < task_end; ++task) {
                _staging_touched_sink =
                    &_staging_touched_task_scratch[task];
                run_markets(
                    _production_task_offsets_scratch[task],
                    _production_task_offsets_scratch[task + 1]);
            }
            _staging_touched_sink = outer_sink;
        };
        parallel_for_range("pk_economy_markets", _worker_tasks,
                           _worker_tasks, 1, run_market_tasks);
        for (std::vector<int32_t> &buffer :
                 _staging_touched_task_scratch) {
            _staging_touched_cells.insert(_staging_touched_cells.end(),
                                          buffer.begin(), buffer.end());
            buffer.clear();
        }
    } else {
        run_markets(0, market_count);
    }
    const double slice_worker_ms = elapsed_ms(worker_started);
    _market_worker_ms += slice_worker_ms;
    _household_slice_phase_ms[HOUSEHOLD_WORKER] += slice_worker_ms;
    _household_slice_phase_work[HOUSEHOLD_WORKER] += market_count;
    const auto merge_started = Clock::now();
    const auto trade_bulk_started = Clock::now();
    _trade_signal_bulk_keys_scratch.clear();
    for (int32_t relative = 0; relative < market_count; ++relative) {
        const int32_t market = _epoch_market_ids[begin + relative];
        const MarketResult &market_result = _market_results_scratch[relative];
        for (const int32_t good : market_result.trade_active_goods) {
            if (good < 0 || good >= market_store().good_count.get()) continue;
            _trade_signal_bulk_keys_scratch.push_back(
                (static_cast<uint64_t>(static_cast<uint32_t>(market)) << 32) |
                static_cast<uint32_t>(good));
        }
    }
    std::sort(_trade_signal_bulk_keys_scratch.begin(),
              _trade_signal_bulk_keys_scratch.end());
    _trade_signal_bulk_keys_scratch.erase(
        std::unique(_trade_signal_bulk_keys_scratch.begin(),
                    _trade_signal_bulk_keys_scratch.end()),
        _trade_signal_bulk_keys_scratch.end());
    ensure_trade_signal_clock_keys_bulk(_trade_signal_bulk_keys_scratch);
    double slice_trade_ms = elapsed_ms(trade_bulk_started);
    double slice_aggregate_ms = 0.0;
    for (int32_t relative = 0; relative < market_count; ++relative) {
        const int32_t market = _epoch_market_ids[begin + relative];
        MarketResult &market_result = _market_results_scratch[relative];
        const auto aggregate_merge_started = Clock::now();
        if (!market_result.ok) {
            fail(market_result.error.empty() ? "household_market_internal_failure"
                                             : market_result.error);
            break;
        }
        for (const MarketResult::FoodAccessEntry &entry :
                 market_result.food_access_by_cell) {
            if (entry.cell < 0 || entry.cell >= _cell_count.get()) continue;
            _cell_food_access_eq_period[static_cast<size_t>(entry.cell)] =
                saturating_add(
                    _cell_food_access_eq_period[static_cast<size_t>(entry.cell)],
                    entry.food_eq, _saturation_count);
        }
        _food_access_events = saturating_add(
            _food_access_events, market_result.food_access_events,
            _saturation_count);
        for (const size_t lane : market_result.audit_population_lanes)
            audit_touch_population_lane(static_cast<int32_t>(lane));
        for (const size_t lane : market_result.audit_market_lanes)
            audit_touch_market_lane(lane);
        merge_economy_worker_changes(market_result.market_changes);
        _processed_cells += _market_cell_offsets[market + 1] -
                            _market_cell_offsets[market];
        _processed_cohorts = saturating_add(_processed_cohorts,
                                            market_result.processed_cohorts,
                                            _saturation_count);
        _processed_rules = saturating_add(_processed_rules,
                                          market_result.processed_rules,
                                          _saturation_count);
        _saturation_count = saturating_add(_saturation_count,
                                           market_result.saturation_count,
                                           _saturation_count);
        _consumed_goods = saturating_add(_consumed_goods, market_result.consumed_goods,
                                         _saturation_count);
        _cycle_flow_consumed = saturating_add(
            _cycle_flow_consumed, market_result.cycle_flow_consumed,
            _saturation_count);
        _cycle_flow_discarded = saturating_add(
            _cycle_flow_discarded, market_result.cycle_flow_discarded,
            _saturation_count);
        _production_output_retained = saturating_add(
            _production_output_retained, market_result.retained_output_consumed,
            _saturation_count);
        _owner_output_consumed = saturating_add(
            _owner_output_consumed, market_result.retained_output_consumed,
            _saturation_count);
        _production_output_discarded = saturating_add(
            _production_output_discarded, market_result.retained_output_discarded,
            _saturation_count);
        _production_output_supported = saturating_add(
            _production_output_supported, market_result.supported_output,
            _saturation_count);
        _cycle_flow_produced = saturating_add(
            _cycle_flow_produced, market_result.supported_cycle_flow_output,
            _saturation_count);
        _production_output_stock = saturating_add(
            _production_output_stock, market_result.supported_output,
            _saturation_count);
        _producer_support_money_issued = saturating_add(
            _producer_support_money_issued, market_result.supported_money,
            _saturation_count);
        _explicit_money_mint = saturating_add(
            _explicit_money_mint, market_result.supported_money,
            _saturation_count);
        _producer_revenue = saturating_add(
            _producer_revenue, market_result.supported_money, _saturation_count);
        _bullion_money_issued = saturating_add(
            _bullion_money_issued, market_result.bullion_money, _saturation_count);
        _bullion_stock_consumed = saturating_add(
            _bullion_stock_consumed, market_result.bullion_stock, _saturation_count);
        _gold_accepted = saturating_add(
            _gold_accepted, market_result.gold_accepted, _saturation_count);
        _gold_money_issued = saturating_add(
            _gold_money_issued, market_result.gold_money, _saturation_count);
        _silver_accepted = saturating_add(
            _silver_accepted, market_result.silver_accepted, _saturation_count);
        _silver_money_issued = saturating_add(
            _silver_money_issued, market_result.silver_money, _saturation_count);
        _owner_working_capital_reserved = saturating_add(
            _owner_working_capital_reserved,
            market_result.owner_working_capital_reserved, _saturation_count);
        for (const BuildingInKindCredit &credit :
                market_result.building_in_kind_credits) {
            if (credit.building_group < 0 || credit.building_group >=
                    static_cast<int32_t>(_building_owner_livelihood_credit.size()))
                continue;
            _building_owner_livelihood_credit[credit.building_group] = saturating_add(
                _building_owner_livelihood_credit[credit.building_group],
                credit.frozen_value, _saturation_count);
        }
        if (market_result.births != 0 || market_result.deaths != 0) {
            const int32_t change_cell =
                _market_cell_offsets[market] < _market_cell_offsets[market + 1]
                ? _market_cells[_market_cell_offsets[market]] : -1;
            trace_append(EVENT_POPULATION_CHANGED,
                static_cast<int32_t>(Stage::HOUSEHOLD_MARKET), change_cell,
                SUBJECT_MARKET, static_cast<int64_t>(market), 0, 0,
                market_result.births, market_result.deaths, 0, 0);
        }
        _births = saturating_add(_births, market_result.births, _saturation_count);
        _deaths = saturating_add(_deaths, market_result.deaths, _saturation_count);
        if (_market_cell_offsets[market] < _market_cell_offsets[market + 1]) {
            const int32_t annual_cell = _market_cells[_market_cell_offsets[market]];
            record_annual_event(annual_cell, AnnualMetric::BIRTHS, market_result.births);
            record_annual_event(annual_cell, AnnualMetric::DEATHS, market_result.deaths);
        }
        for (const PersonMarketAttribution &attribution :
                market_result.person_attributions) {
            int32_t person = -1;
            if (!persons_store().valid_handle(attribution.person_handle, person)) continue;
            persons_store().epoch_consumption_expense.write_scalar(person, saturating_add(
                persons_store().epoch_consumption_expense[person],
                attribution.consumption_expense, _saturation_count), market_mutation_sink());
            persons_store().epoch_tax.write_scalar(person, saturating_add(
                persons_store().epoch_tax[person], attribution.consumption_tax,
                _saturation_count), market_mutation_sink());
            persons_store().needs_satisfaction.write_scalar(person, attribution.satisfaction_q16, market_mutation_sink());
            persons_store().worst_need_id.write_scalar(person, attribution.worst_need_id, market_mutation_sink());
        }
        _person_epoch_needs.insert(_person_epoch_needs.end(),
            market_result.person_needs.begin(),
            market_result.person_needs.end());
        for (const PersonDemographyEvent &event :
                market_result.person_demography) {
            int32_t cohort_slot = -1;
            if (population_store().valid_handle(event.cohort_handle, cohort_slot))
                record_person_demography(cohort_slot,
                    event.population_before, event.deaths);
        }
        for (const PersonDemographyEvent &event :
                market_result.family_demography) {
            int32_t cohort_slot = -1;
            if (population_store().valid_handle(event.cohort_handle, cohort_slot))
                apply_family_death_attribution(cohort_slot,
                    event.population_before, event.deaths);
        }
        _population_changed_cells.insert(_population_changed_cells.end(),
            market_result.population_changed_cells.begin(),
            market_result.population_changed_cells.end());
        _publish_accum.population = saturating_add(
            _publish_accum.population, market_result.closing_population, _saturation_count);
        _publish_accum.cohort_funds = saturating_add(
            _publish_accum.cohort_funds, market_result.closing_cohort_funds,
            _saturation_count);
        _publish_accum.goods_stock = saturating_add(
            _publish_accum.goods_stock, market_result.closing_goods_stock,
            _saturation_count);
        _formula_ms += market_result.formula_ms;
        _clear_ms += market_result.clear_ms;
        _processed_needs = saturating_add(_processed_needs, market_result.processed_needs,
                                          _saturation_count);
        _processed_variants = saturating_add(_processed_variants,
                                             market_result.processed_variants,
                                             _saturation_count);
        _processed_components = saturating_add(_processed_components,
                                               market_result.processed_components,
                                               _saturation_count);
        _fallback_ms += market_result.fallback_ms;
        _merchant_settle_ms += market_result.merchant_settle_ms;
        _price_ms += market_result.price_ms;
        _merchant_repairs = saturating_add(_merchant_repairs,
                                           market_result.merchant_repairs,
                                           _saturation_count);
        _price_cap_hits = saturating_add(_price_cap_hits,
                                         market_result.price_cap_hits,
                                         _saturation_count);
        _price_rate_clamp_hits = saturating_add(
            _price_rate_clamp_hits, market_result.price_rate_clamp_hits,
            _saturation_count);
        _epoch_price_ceiling_observations.insert(_epoch_price_ceiling_observations.end(),
            market_result.price_ceiling_observations.begin(), market_result.price_ceiling_observations.end());
        _price_ceiling_blocked_rises += market_result.price_ceiling_blocked_rises;
        _price_numeric_ceiling_hits = saturating_add(_price_numeric_ceiling_hits,
market_result.price_numeric_ceiling_hits, _saturation_count);
    _price_numeric_floor_hits = saturating_add(_price_numeric_floor_hits,
            market_result.price_numeric_floor_hits, _saturation_count);
        _price_min_tick_hits = saturating_add(_price_min_tick_hits,
            market_result.price_min_tick_hits, _saturation_count);
        _price_glut_cost_damp_hits = saturating_add(_price_glut_cost_damp_hits,
            market_result.price_glut_cost_damp_hits, _saturation_count);
        _small_payment_roundups = saturating_add(_small_payment_roundups,
            market_result.small_payment_roundups, _saturation_count);
        _price_rise_fade_hits = saturating_add(
            _price_rise_fade_hits, market_result.price_rise_fade_hits,
            _saturation_count);
        _price_headroom_damp_hits = saturating_add(
            _price_headroom_damp_hits,
            market_result.price_headroom_damp_hits, _saturation_count);
        _price_catalog_bound_hits = saturating_add(
            _price_catalog_bound_hits,
            market_result.price_catalog_bound_hits, _saturation_count);
        _price_cost_anchor_hits = saturating_add(
            _price_cost_anchor_hits, market_result.price_cost_anchor_hits,
            _saturation_count);
        _price_inactive_reversions = saturating_add(
            _price_inactive_reversions, market_result.price_inactive_reversions,
            _saturation_count);
        _market_result_allocation_growth_count = saturating_add(
            _market_result_allocation_growth_count,
            market_result.allocation_growth_count, _saturation_count);
        _market_result_allocation_growth_bytes = saturating_add(
            _market_result_allocation_growth_bytes,
            market_result.allocation_growth_bytes, _saturation_count);
        _approximation_decisions = saturating_add(
            _approximation_decisions,
            market_result.approximation_decisions, _saturation_count);
        _approximation_exact_probes = saturating_add(
            _approximation_exact_probes,
            market_result.approximation_exact_probes, _saturation_count);
        _approximation_certificate_failures = saturating_add(
            _approximation_certificate_failures,
            market_result.approximation_certificate_failures,
            _saturation_count);
        _approximation_exact_fallbacks = saturating_add(
            _approximation_exact_fallbacks,
            market_result.approximation_exact_fallbacks,
            _saturation_count);
        _approximation_frontier_candidates = saturating_add(
            _approximation_frontier_candidates,
            market_result.approximation_frontier_candidates,
            _saturation_count);
        _approximation_frontier_pruned = saturating_add(
            _approximation_frontier_pruned,
            market_result.approximation_frontier_pruned,
            _saturation_count);
        _approximation_max_observed_regret_q16 = std::max(
            _approximation_max_observed_regret_q16,
            market_result.approximation_max_certified_regret_q16);
        _approximation_probe_violations = saturating_add(
            _approximation_probe_violations,
            market_result.approximation_probe_violations,
            _saturation_count);
        _approximation_probe_max_spend_error_q16 = std::max(
            _approximation_probe_max_spend_error_q16,
            market_result.approximation_probe_max_spend_error_q16);
        _approximation_probe_max_demand_error_q16 = std::max(
            _approximation_probe_max_demand_error_q16,
            market_result.approximation_probe_max_demand_error_q16);
        _structural_commands.insert(_structural_commands.end(),
                                     market_result.structural_commands.begin(),
                                     market_result.structural_commands.end());
        const auto aggregate_finished = Clock::now();
        const double aggregate_ms =
            std::chrono::duration<double, std::milli>(
                aggregate_finished - aggregate_merge_started).count();
        _market_merge_aggregate_ms += aggregate_ms;
        slice_aggregate_ms += aggregate_ms;
        const auto trade_merge_started = Clock::now();
        for (const int32_t good : market_result.trade_active_goods) {
            add_trade_active_key(market, good);
            const int32_t signal_clock = ensure_trade_signal_clock_index(market, good);
            if (signal_clock < 0 || signal_clock >= static_cast<int32_t>(
                    _trade_signal_first_seen_day.size())) continue;
            int64_t signal_sat = 0;
            const int64_t target = trade_local_stock_target(
                market, good, signal_sat);
            const int64_t stock = market_store().stock[market_store().index(market, good)];
            const bool needs_trade = target > stock ||
                trade_relief_pressure_q16(market, good, signal_sat) > 0;
            _saturation_count = saturating_add(
                _saturation_count, signal_sat, _saturation_count);
            if (needs_trade) {
                if (_trade_signal_first_seen_day[signal_clock] < 0) {
                    _trade_signal_first_seen_day[signal_clock] = _sample_day;
                    ++_trade_deficit_episodes_started;
                    _trade_signal_first_dispatch_day[signal_clock] = -1;
                    _trade_signal_last_attempt_day[signal_clock] = -1;
                    _trade_signal_last_rejection_reason[signal_clock] =
                        TRADE_SIGNAL_DIAG_NONE;
                    _trade_signal_deadline_reported[signal_clock] = 0;
                }
            } else {
                if (_trade_signal_first_seen_day[signal_clock] >= 0)
                    ++_trade_deficit_episodes_resolved;
                _trade_signal_first_seen_day[signal_clock] = -1;
                _trade_signal_first_dispatch_day[signal_clock] = -1;
                _trade_signal_deadline_reported[signal_clock] = 0;
            }
        }
        slice_trade_ms += elapsed_ms(trade_merge_started);
        ++work_done;
    }
    double slice_trace_ms = 0.0;
    if (!_fatal && _trace_mode != TRACE_OFF) {
        const auto event_start = Clock::now();
        for (int32_t relative = 0; relative < market_count; ++relative) {
            const int32_t market = _epoch_market_ids[begin + relative];
            MarketResult &market_result = _market_results_scratch[relative];
            if (market == _staging_events.cashflow_cell) {
                for (const CashflowEntry &entry : market_result.cashflows) {
                    trace_record_cashflow(market, entry.cohort_handle,
                        entry.source, entry.income, entry.expense);
                }
                _staging_events.welfare_entries =
                    std::move(market_result.welfare_entries);
            }
            trace_append(EVENT_MARKET_SETTLED,
                         static_cast<int32_t>(Stage::HOUSEHOLD_MARKET), market,
                         SUBJECT_MARKET, market, -1, -1,
                         market_result.revenue, market_result.consumed_goods,
                         market_result.changed_prices,
                         static_cast<int64_t>(market_result.mutation_hash),
                         market_result.trace_legs.empty() ? nullptr :
                             &market_result.trace_legs);
        }
        slice_trace_ms = elapsed_ms(event_start);
        _event_summary_ms += slice_trace_ms;
    }
    const double slice_merge_ms = elapsed_ms(merge_started);
    _market_merge_ms += slice_merge_ms;
    _market_merge_trade_ms += slice_trade_ms;
    _household_slice_phase_ms[HOUSEHOLD_MERGE_AGGREGATE] +=
        slice_aggregate_ms;
    _household_slice_phase_work[HOUSEHOLD_MERGE_AGGREGATE] +=
        market_count;
    _household_slice_phase_ms[HOUSEHOLD_MERGE_TRADE] +=
        slice_trade_ms;
    _household_slice_phase_work[HOUSEHOLD_MERGE_TRADE] +=
        market_count;
    _household_slice_phase_ms[HOUSEHOLD_TRACE] += slice_trace_ms;
    _household_slice_phase_work[HOUSEHOLD_TRACE] +=
        _trace_mode == TRACE_OFF ? 0 : market_count;
    _household_slice_phase_ms[HOUSEHOLD_OTHER] += std::max(
        0.0, elapsed_ms(settle_started) - slice_prepare_ms -
            slice_worker_ms - slice_aggregate_ms -
            slice_trade_ms - slice_trace_ms);
    _household_slice_phase_work[HOUSEHOLD_OTHER] += market_count;
    _cell_cursor = end;
    _workset_last_cursor = _cell_cursor;
    // _processed_cells is advanced exactly once while merging each
    // market range, so it is the authoritative executed-cell count.
    _workset_cells_executed = _processed_cells;
    cursor_end = _cell_cursor;
    cell_range_used = true;
    if (_fatal) {
        return HouseholdMarketChunkResult::Fatal;
    }
    const bool market_range_incomplete =
        _cell_cursor < static_cast<int32_t>(_epoch_market_ids.size());
    if (!market_range_incomplete) {
        if (_merchant_repairs > 0 && !rebuild_merchant_ranges(error)) {
            fail(error.empty()
                ? "merchant_range_rebuild_after_household_failed"
                : error);
            return HouseholdMarketChunkResult::Fatal;
        }
        _household_post_cursor = 0;
        _household_market_phase = 1;
    }
    if (finish_chunk_and_should_yield()) {
        return HouseholdMarketChunkResult::StopSlice;
    }
    if (market_range_incomplete) {
        return HouseholdMarketChunkResult::ContinueFusing;
    }
    return HouseholdMarketChunkResult::ContinueFusing;
}

int64_t NativeEconomyRuntime::state_hash_internal(bool paged) const {
    EconomyCostProbe probe("native_hash", _current_day.get(), market_store().stock.size());
    uint64_t hash = 1469598103934665603ULL;
    auto mix_u64 = [&](uint64_t value) {
        hash = economy_hash_u64(hash, value);
    };
    auto mix_string = [&](const std::string &value) {
        mix_u64(value.size());
        for (unsigned char byte : value) {
            hash ^= byte;
            hash *= 1099511628211ULL;
        }
    };
    mix_u64(static_cast<uint64_t>(_trade_runtime_mode.get() != 2 &&
        _catalog_compat_hash_v10.get() != 0 ? _catalog_compat_hash_v10.get() : _catalog_hash.get()));
    mix_u64(static_cast<uint64_t>(_building_catalog_hash.get()));
    mix_u64(static_cast<uint64_t>(_prosperity_profile_hash.get()));
    mix_u64(static_cast<uint64_t>(_startup_demand_runtime_mode.get()));
    mix_u64(_price_ceiling_confirm_days.get()); mix_u64(_price_ceiling_expand_bp.get()); mix_u64(_price_ceiling_recover_bp.get());
    for (size_t market = 0; market < market_store().price_ceilings.size(); ++market) {
        for (const auto &state : market_store().price_ceilings[market]) {
            mix_u64(market); mix_u64(state.good); mix_u64(state.limit); mix_u64(state.confirmation_days);
        }
    }
    mix_u64(price_ceiling_state_count());
    mix_u64(static_cast<uint64_t>(_cell_count.get()));
    mix_u64(static_cast<uint64_t>(_epoch_id.get()));
    mix_u64(static_cast<uint64_t>(_epoch_days.get()));
    mix_u64(static_cast<uint64_t>(_locked_market_cycle_days.get()));
    mix_u64(static_cast<uint64_t>(_market_cycle_start_day.get()));
    mix_u64(static_cast<uint64_t>(_locked_slow_cycle_days.get()));
    mix_u64(static_cast<uint64_t>(_slow_cycle_start_day.get()));
    mix_u64(static_cast<uint64_t>(_locked_investment_cycle_days.get()));
    mix_u64(static_cast<uint64_t>(_investment_cycle_start_day.get()));
    // Employment mobility is configuration, not persisted cohort state, but
    // it changes the next deterministic transition plan. Include it in the
    // authoritative hash so save/restore and worker/scalar comparisons cannot
    // silently continue under a different policy.
    mix_u64(0x454d504c4f594346ULL); // "EMPLOYCF"
    mix_u64(static_cast<uint32_t>(_employment_mobility_daily_q16.get()));
    mix_u64(static_cast<uint32_t>(
        _employment_understaffed_reallocation_hurdle_mult_q16.get()));
    mix_u64(static_cast<uint32_t>(_employment_choice_temperature_q16.get()));
    mix_u64(static_cast<uint64_t>(_last_committed_day.get()));
    mix_u64(static_cast<uint64_t>(_environment_day.get()));
    mix_u64(static_cast<uint64_t>(_environment_hash.get()));
    mix_u64(static_cast<uint64_t>(_country_runtime == nullptr ? 0 : country_reads().state_hash()));
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        mix_u64(static_cast<uint64_t>(_cell_last_settlement_day[cell]));
        mix_u64(_cell_settlement_generation[cell]);
        mix_u64(_cell_price_stock_gen[cell]);
        mix_u64(_cell_owner_cash_gen[cell]);
        mix_u64(_cell_population_gen[cell]);
        mix_u64(_cell_building_structure_gen[cell]);
        mix_u64(_cell_technology_gen[cell]);
        mix_u64(_cell_resource_gen[cell]);
        mix_u64(_cell_trade_gen[cell]);
        mix_u64(_settlements.tier[cell]);
        mix_u64(_settlements.prosperity_generation[cell]);
        mix_u64(_settlements.name_roll_generation[cell]);
        mix_u64(static_cast<uint64_t>(_settlements.name_active[cell]));
        mix_u64(static_cast<uint64_t>(_settlements.name_forced[cell]));
        if (_settlements.name_active[cell] != 0) {
            mix_string(_settlement_name_pack_id.get());
            if (_settlements.root[cell] < 0) {
                mix_string(_settlement_full_name_ids[
                    _settlements.prefix[cell]]);
            } else {
                mix_string(_settlement_prefix_ids[_settlements.prefix[cell]]);
                mix_string(_settlement_root_ids[_settlements.root[cell]]);
                mix_string(_settlement_suffix_ids[_settlements.suffix[cell]]);
            }
        }
        mix_u64(_settlements.disambiguator[cell]);
        mix_u64(cell < static_cast<int32_t>(
            _fiscal_previous_country_handles.size())
            ? _fiscal_previous_country_handles[cell] : 0);
        for (int32_t kind = 0; kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
            const size_t lane = static_cast<size_t>(cell) *
                ACTIVE_TAX_KIND_COUNT + kind;
            mix_u64(static_cast<uint64_t>(
                lane < _fiscal_previous_requests.size()
                    ? _fiscal_previous_requests[lane] : 0));
        }
    }
    CountryReadView::Snapshot fiscal_country_snapshot;
    const size_t fiscal_hash_countries = _country_runtime != nullptr &&
        country_reads().copy_economy_snapshot(fiscal_country_snapshot)
        ? static_cast<size_t>(std::max(0,
            fiscal_country_snapshot.country_count))
        : _epoch_country_handles.size();
    const size_t fiscal_hash_lanes = fiscal_hash_countries *
        CountryApi::TAX_KIND_COUNT;
    const auto mix_fiscal_lanes = [&](const std::vector<int64_t> &values) {
        for (size_t lane = 0; lane < fiscal_hash_lanes; ++lane) {
            mix_u64(static_cast<uint64_t>(
                lane < values.size() ? values[lane] : 0));
        }
    };
    // PKEC persists one fixed tax-kind group per frozen country and fills
    // never-committed cumulative lanes with zero. Hash that same logical
    // shape so a cold bootstrap and its restore remain equivalent.
    mix_fiscal_lanes(_fiscal_cumulative_bases);
    mix_fiscal_lanes(_fiscal_cumulative_collected);
    mix_fiscal_lanes(_fiscal_cumulative_requests);
    mix_fiscal_lanes(_fiscal_cumulative_paid);
    for (size_t slot = 0; slot < population_store().active.size(); ++slot) {
        if (population_store().active[slot] == 0) continue;
        mix_u64(slot);
        mix_u64(population_store().generation[slot]);
        mix_u64(population_store().signature_id[slot]);
        mix_u64(static_cast<uint64_t>(population_store().population[slot]));
        mix_u64(static_cast<uint64_t>(population_store().funds[slot]));
        mix_u64(static_cast<uint64_t>(population_store().epoch_income[slot]));
        mix_u64(static_cast<uint64_t>(population_store().epoch_expense[slot]));
        mix_u64(static_cast<uint64_t>(population_store().income_ema[slot]));
        mix_u64(population_store().needs_satisfaction[slot]);
        mix_u64(population_store().worst_need_id[slot]);
        mix_u64(population_store().flags[slot]);
        mix_u64(static_cast<uint64_t>(population_store().demography_residual[slot]));
        mix_u64(static_cast<uint64_t>(population_store().owner_employed[slot]));
        mix_u64(static_cast<uint64_t>(population_store().employee_employed[slot]));
        mix_u64(population_store().composite_satisfaction[slot]);
        mix_u64(population_store().worst_dimension_id[slot]);
        const size_t dims_base = static_cast<size_t>(slot) *
            static_cast<size_t>(SAT_DIM_COUNT);
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
            mix_u64(population_store().satisfaction_dims[dims_base +
                                                  static_cast<size_t>(dim)]);
        mix_u64(static_cast<uint64_t>(population_store().income_baseline_ema[slot]));
        mix_u64(static_cast<uint64_t>(population_store().epoch_tax_paid[slot]));
        mix_u64(static_cast<uint64_t>(population_store().epoch_subsidy_received[slot]));
    }
    mix_u64(0x534f4350524553ULL); // "SOCPRES"
    hash = economy_hash_lanes<true>(hash, _cell_social_pressure_level);
    mix_u64(0x4249525448524553ULL); // "BIRTHRES"
    hash = economy_hash_lanes<true>(hash, _birth_residual_q32);
    mix_u64(0x53555050454d41ULL); // "SUPPEMA"
    hash = economy_hash_lanes<true>(hash, _cell_support_ema_q16);
    mix_u64(0x583133415354524dULL); // "X13ASTRM"
    hash = economy_hash_lanes<true>(hash, _cell_dry_streak_days);
    hash = economy_hash_lanes<true>(hash, _cell_days_since_hazard);
    hash = economy_hash_lanes<true>(hash, _cell_previous_hazard_mask);
    mix_u64(0x464f4f44464c4f57ULL); // "FOODFLOW"
    mix_u64(static_cast<uint32_t>(_food_flow_previous_period_days.get()));
    hash = economy_hash_lanes<true>(hash, _cell_food_flow_valid);
    for (const EconomyOwnedColumn<int64_t> *lane : {
             &_cell_food_output_eq_previous,
             &_cell_food_input_eq_previous,
             &_cell_food_import_eq_previous,
             &_cell_food_export_eq_previous,
             &_cell_food_access_eq_previous})
        hash = economy_hash_lanes<true>(hash, *lane);
    for (int32_t i = 0; i < static_cast<int32_t>(families_store().active.size()); ++i) {
        if (families_store().active[i] == 0) continue;
        mix_u64(0x46414d494c59ULL);
        mix_u64(static_cast<uint32_t>(i));
        mix_u64(families_store().generation[i]);
        mix_u64(static_cast<uint64_t>(families_store().stable_id[i]));
        mix_u64(static_cast<uint32_t>(families_store().surname_id[i]));
        mix_u64(families_store().surname_disambiguator[i]);
        mix_u64(static_cast<uint64_t>(families_store().founded_day[i]));
        mix_u64(static_cast<uint32_t>(families_store().home_cell[i]));
        mix_u64(static_cast<uint32_t>(families_store().origin_cell[i]));
        mix_u64(static_cast<uint32_t>(families_store().origin_ethnicity[i]));
        mix_u64(static_cast<uint32_t>(families_store().culture_group_id[i]));
        mix_u64(families_store().split_sequence[i]);
        mix_u64(families_store().decline_reviews[i]);
        mix_u64(families_store().flags[i]);
    }
    for (const FamilyMembershipEdge &edge : family_memberships()) {
        mix_u64(edge.family_handle); mix_u64(edge.cohort_handle);
        mix_u64(static_cast<uint64_t>(edge.people));
        mix_u64(static_cast<uint64_t>(edge.cash_claim));
        mix_u64(static_cast<uint64_t>(edge.population_basis));
        mix_u64(static_cast<uint64_t>(edge.funds_basis));
        mix_u64(static_cast<uint64_t>(edge.owner_employed));
        mix_u64(static_cast<uint64_t>(edge.employee_employed));
    }
    for (const FamilyBuildingOwnership &edge : family_ownerships()) {
        mix_u64(edge.family_handle); mix_u64(edge.building_handle);
        mix_u64(static_cast<uint64_t>(edge.owned_count));
        mix_u64(static_cast<uint64_t>(edge.filled_owner));
    }
    mix_u64(0x46414d5452414954ULL); // "FAMTRAIT"
    mix_u64(static_cast<uint32_t>(_family_trait_catalog_version.get()));
    mix_u64(static_cast<uint64_t>(_family_trait_catalog_hash.get()));
    for (const FamilyTraitRoll &roll : family_trait_rolls()) {
        mix_u64(roll.family_handle);
        mix_u64(static_cast<uint32_t>(roll.trait_id));
        mix_u64(static_cast<uint32_t>(roll.strength_q16));
        mix_u64(roll.core);
    }
    mix_u64(0x46414d4252414e43ULL); // "FAMBRANC"
    for (size_t i = 0; i < family_influences().active.size(); ++i) {
        mix_u64(i);
        mix_u64(family_influences().active[i]);
        mix_u64(family_influences().generation[i]);
        mix_u64(family_influences().family_handle[i]);
        mix_u64(static_cast<uint32_t>(family_influences().cell[i]));
        mix_u64(static_cast<uint64_t>(family_influences().stable_id[i]));
        mix_u64(static_cast<uint64_t>(family_influences().population[i]));
        mix_u64(static_cast<uint64_t>(family_influences().cash[i]));
        mix_u64(static_cast<uint64_t>(family_influences().building_asset[i]));
        mix_u64(static_cast<uint32_t>(
            family_influences().population_share_q16[i]));
        mix_u64(static_cast<uint32_t>(family_influences().cash_share_q16[i]));
        mix_u64(static_cast<uint32_t>(
            family_influences().building_share_q16[i]));
        mix_u64(static_cast<uint32_t>(family_influences().score_q16[i]));
        mix_u64(static_cast<uint32_t>(family_influences().satisfaction_q16[i]));
        mix_u64(family_influences().prestige_level[i]);
        mix_u64(family_influences().pending_target_level[i]);
        mix_u64(family_influences().review_streak[i]);
        mix_u64(static_cast<uint64_t>(family_influences().last_review_day[i]));
    }
    mix_u64(0x46414d434f4d4d44ULL); // "FAMCOMMD"
    for (const FamilyTraitCommand &command : _family_trait_commands) {
        mix_u64(static_cast<uint32_t>(command.operation));
        mix_u64(command.family_handle);
        mix_u64(static_cast<uint32_t>(command.trait_id));
        mix_u64(static_cast<uint32_t>(command.strength_q16));
        mix_u64(static_cast<uint64_t>(command.effective_day));
        mix_u64(static_cast<uint32_t>(command.priority));
        mix_u64(static_cast<uint64_t>(command.sequence));
        mix_u64(command.submit_order);
    }
    append_family_founding_hash(hash);
    mix_u64(0x455850454449544eULL); // "EXPEDITN"
    for (size_t i = 0; i < family_expeditions_store().active.size(); ++i) {
        mix_u64(i); mix_u64(family_expeditions_store().active[i]);
        mix_u64(family_expeditions_store().generation[i]);
        if (family_expeditions_store().active[i] == 0) continue;
        mix_u64(static_cast<uint64_t>(family_expeditions_store().stable_id[i]));
        mix_u64(family_expeditions_store().country_handle[i]);
        mix_u64(family_expeditions_store().family_handle[i]);
        mix_u64(static_cast<uint32_t>(family_expeditions_store().source_cell[i]));
        mix_u64(static_cast<uint32_t>(family_expeditions_store().target_cell[i]));
        mix_u64(static_cast<uint64_t>(family_expeditions_store().departure_day[i]));
        mix_u64(static_cast<uint64_t>(family_expeditions_store().due_day[i]));
        mix_u64(static_cast<uint32_t>(family_expeditions_store().route_cost[i]));
        mix_u64(static_cast<uint32_t>(family_expeditions_store().speed[i]));
        mix_u64(family_expeditions_store().state[i]);
        mix_u64(static_cast<uint64_t>(family_expeditions_store().population[i]));
        mix_u64(static_cast<uint64_t>(
            family_expeditions_store().kit_bridge_required_units[i]));
        mix_u64(static_cast<uint64_t>(
            family_expeditions_store().kit_material_required_units[i]));
        mix_u64(static_cast<uint64_t>(family_expeditions_store().effect_transaction_id[i]));
        mix_u64(family_expeditions_store().idempotency_key[i]);
        const uint32_t route_begin = family_expeditions_store().route_begin[i];
        const uint32_t route_count = family_expeditions_store().route_count[i];
        for (uint32_t r = 0; r < route_count; ++r) {
            mix_u64(static_cast<uint32_t>(family_expedition_route_cells()[route_begin + r]));
            mix_u64(static_cast<uint32_t>(family_expedition_route_costs()[route_begin + r]));
        }
        const uint32_t payload_begin = family_expeditions_store().payload_begin[i];
        const uint32_t payload_count = family_expeditions_store().payload_count[i];
        for (uint32_t p = 0; p < payload_count; ++p) {
            const FamilyExpeditionPayload &payload =
                family_expedition_payloads()[payload_begin + p];
            mix_u64(payload.source_cohort_handle);
            mix_u64(static_cast<uint32_t>(payload.signature));
            mix_u64(static_cast<uint64_t>(payload.people));
            mix_u64(static_cast<uint64_t>(payload.funds));
            mix_u64(static_cast<uint64_t>(payload.epoch_income));
            mix_u64(static_cast<uint64_t>(payload.epoch_expense));
            mix_u64(static_cast<uint64_t>(payload.epoch_in_kind_income));
            mix_u64(static_cast<uint64_t>(payload.income_ema));
            mix_u64(static_cast<uint64_t>(payload.epoch_tax_paid));
            mix_u64(static_cast<uint64_t>(payload.epoch_subsidy_received));
            mix_u64(static_cast<uint64_t>(payload.income_baseline_ema));
            mix_u64(static_cast<uint64_t>(payload.demography_residual));
            mix_u64(static_cast<uint64_t>(payload.cash_claim));
            mix_u64(static_cast<uint64_t>(payload.owner_employed));
            mix_u64(static_cast<uint64_t>(payload.employee_employed));
            mix_u64(payload.needs_satisfaction); mix_u64(payload.worst_need_id);
            mix_u64(payload.composite_satisfaction);
            for (uint16_t dimension : payload.satisfaction_dims) mix_u64(dimension);
            mix_u64(payload.worst_dimension_id);
            for (uint32_t person = 0; person < payload.person_count; ++person)
                mix_u64(family_expedition_person_handles()[payload.person_begin + person]);
        }
        const uint32_t cargo_begin = family_expeditions_store().cargo_begin[i];
        const uint32_t cargo_count = family_expeditions_store().cargo_count[i];
        mix_u64(cargo_count);
        for (uint32_t c = 0; c < cargo_count; ++c) {
            const FamilyExpeditionCargoLine &line =
                family_expedition_cargo()[cargo_begin + c];
            mix_u64(static_cast<uint32_t>(line.good_id));
            mix_u64(static_cast<uint64_t>(line.quantity));
            mix_u64(line.flags);
        }
        const uint32_t kit_begin = family_expeditions_store().kit_building_begin[i];
        const uint32_t kit_count = family_expeditions_store().kit_building_count[i];
        mix_u64(kit_count);
        for (uint32_t k = 0; k < kit_count; ++k) {
            const FamilyExpeditionKitBuilding &row =
                family_expedition_kit_buildings()[kit_begin + k];
            mix_u64(static_cast<uint32_t>(row.type_id));
            mix_u64(static_cast<uint64_t>(row.count));
        }
        mix_u64(family_expeditions_store().kit_missing_stock_identity[i]);
        const uint32_t missing_begin =
            family_expeditions_store().missing_good_begin[i];
        const uint32_t missing_count =
            family_expeditions_store().missing_good_count[i];
        mix_u64(missing_count);
        for (uint32_t m = 0; m < missing_count; ++m) {
            mix_u64(static_cast<uint32_t>(
                family_expedition_missing_good_ids()[missing_begin + m]));
            mix_u64(static_cast<uint64_t>(
                family_expedition_missing_good_quantities()[missing_begin + m]));
        }
    }
    for (int32_t i = 0; i < static_cast<int32_t>(persons_store().active.size()); ++i) {
        mix_u64(0x504552534f4eULL);
        mix_u64(static_cast<uint32_t>(i));
        mix_u64(persons_store().generation[i]);
        mix_u64(persons_store().active[i]);
        if (persons_store().active[i] == 0) continue;
        mix_u64(static_cast<uint64_t>(persons_store().stable_id[i]));
        mix_u64(persons_store().family_handle[i]); mix_u64(persons_store().cohort_handle[i]);
        mix_u64(static_cast<uint32_t>(persons_store().given_name_id[i]));
        mix_u64(persons_store().name_disambiguator[i]);
        mix_u64(static_cast<uint64_t>(persons_store().notable_since_day[i]));
        mix_u64(persons_store().flags[i]);
        mix_u64(static_cast<uint64_t>(persons_store().cash_claim[i]));
        mix_u64(static_cast<uint64_t>(persons_store().family_equity_share_q32[i]));
        mix_u64(static_cast<uint64_t>(persons_store().epoch_job_income[i]));
        mix_u64(static_cast<uint64_t>(persons_store().epoch_business_result[i]));
        mix_u64(static_cast<uint64_t>(persons_store().epoch_consumption_expense[i]));
        mix_u64(static_cast<uint64_t>(persons_store().epoch_tax[i]));
        mix_u64(static_cast<uint64_t>(persons_store().income_ema[i]));
        mix_u64(persons_store().needs_satisfaction[i]); mix_u64(persons_store().worst_need_id[i]);
        mix_u64(persons_store().building_handle[i]); mix_u64(persons_store().job_kind[i]);
        mix_u64(static_cast<uint32_t>(persons_store().employee_role_index[i]));
        mix_u64(static_cast<uint64_t>(persons_store().job_since_day[i]));
    }
    for (const PersonNeedState &state : person_needs()) {
        mix_u64(state.person_handle);
        mix_u64(static_cast<uint32_t>(state.stable_need_id));
        mix_u64(static_cast<uint64_t>(state.desired_period_units));
        mix_u64(state.satisfaction_q16);
        mix_u64(static_cast<uint64_t>(state.attributed_spend));
    }
    for (int32_t mapping : market_store().cell_to_market) mix_u64(static_cast<uint32_t>(mapping));
    if (paged) {
        auto &pages = _formula_owned != nullptr ? _formula_owned->market_hash_pages : _market_hash_pages;
        mix_u64(RuntimeChunkHash::VERSION);
        mix_u64(pages[0].update(market_store().stock, 1, 1));
        mix_u64(pages[1].update(market_store().price, 1, 2));
        mix_u64(pages[2].update(market_store().demand_ema, 1, 3));
        mix_u64(pages[3].update(market_store().last_shortage_q16, 1, 4));
    } else {
        hash = economy_hash_lanes<true>(hash, market_store().stock);
        for (int32_t value : market_store().price) mix_u64(static_cast<uint32_t>(value));
        hash = economy_hash_lanes<true>(hash, market_store().demand_ema);
        hash = economy_hash_lanes<true>(hash, market_store().last_shortage_q16);
    }
    for (const Command &cmd : _pending_commands) {
        mix_u64(static_cast<uint32_t>(cmd.opcode));
        mix_u64(static_cast<uint64_t>(cmd.effective_day));
        mix_u64(static_cast<uint64_t>(cmd.sequence));
        mix_u64(cmd.target_handle);
        mix_u64(static_cast<uint32_t>(cmd.i32_0));
        mix_u64(static_cast<uint32_t>(cmd.i32_1));
        mix_u64(static_cast<uint64_t>(cmd.i64_0));
        mix_u64(static_cast<uint64_t>(cmd.i64_1));
        mix_u64(static_cast<uint64_t>(cmd.effect_request_id));
        mix_u64(cmd.effect_idempotency_key);
    }
    for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
        const auto group = building_view(pk_row);
        mix_u64(static_cast<uint32_t>(group.cell));
        mix_u64(static_cast<uint32_t>(group.type_id));
        mix_u64(static_cast<uint32_t>(group.owner_signature_id));
        mix_u64(static_cast<uint64_t>(group.count));
        mix_u64(static_cast<uint64_t>(group.filled_owner));
        mix_u64(static_cast<uint64_t>(group.last_capacity_q16));
        mix_u64(static_cast<uint64_t>(group.last_temperature_fit_q16));
        mix_u64(static_cast<uint64_t>(group.last_water_fit_q16));
        mix_u64(static_cast<uint64_t>(group.last_climate_capacity_q16));
        mix_u64(static_cast<uint64_t>(group.last_climate_lost_output));
        mix_u64(static_cast<uint64_t>(group.last_input));
        mix_u64(static_cast<uint64_t>(group.last_output));
        mix_u64(static_cast<uint64_t>(group.last_sold));
        mix_u64(static_cast<uint64_t>(group.last_discarded));
        mix_u64(static_cast<uint64_t>(group.last_resource));
        mix_u64(static_cast<uint64_t>(group.last_resource_generated));
        mix_u64(static_cast<uint64_t>(group.last_revenue));
        mix_u64(static_cast<uint64_t>(group.last_input_cost));
        mix_u64(static_cast<uint64_t>(group.last_wages_paid));
        mix_u64(static_cast<uint64_t>(group.last_wages_due));
        mix_u64(static_cast<uint64_t>(group.last_expected_revenue));
        mix_u64(static_cast<uint64_t>(group.last_operating_cost));
        mix_u64(static_cast<uint32_t>(group.last_margin_gap_q16));
        mix_u64(static_cast<uint32_t>(group.planned_utilization_q16));
        mix_u64(static_cast<uint64_t>(group.last_base_wages_paid));
        mix_u64(static_cast<uint64_t>(group.last_base_wages_due));
        mix_u64(static_cast<uint64_t>(group.last_bonus_paid));
        mix_u64(static_cast<uint64_t>(group.last_bonus_due));
        mix_u64(group.wage_suspended);
        mix_u64(static_cast<uint64_t>(group.purchase_intent_capacity_q16));
        mix_u64(static_cast<uint32_t>(group.realized_profit_margin_q16));
        mix_u64(group.severe_loss_cycles);
        mix_u64(group.recovery_cycles);
        mix_u64(group.recovery_failed_reviews);
        mix_u64(group.merchant_debt_term_cycles_left);
        mix_u64(group.merchant_debt_delinquent_cycles);
        mix_u64(std::min<uint8_t>(group.operating_state, 1));
        mix_u64(group.pending_operating_state <= 1
            ? group.pending_operating_state : uint8_t{255});
        mix_u64(0);
        mix_u64(static_cast<uint64_t>(group.merchant_debt_principal));
        mix_u64(static_cast<uint64_t>(group.merchant_debt_premium));
        mix_u64(static_cast<uint64_t>(group.last_in_kind_livelihood_value));
        mix_u64(static_cast<uint64_t>(group.last_market_receipt));
        mix_u64(static_cast<uint64_t>(group.last_bullion_mint_receipt));
        mix_u64(static_cast<uint64_t>(group.last_producer_support_receipt));
        mix_u64(static_cast<uint64_t>(group.last_business_tax_paid));
        mix_u64(static_cast<uint64_t>(group.last_business_subsidy_received));
        mix_u64(static_cast<uint64_t>(group.last_maintenance_due));
        mix_u64(static_cast<uint64_t>(group.last_observed_capacity_days_q16));
        mix_u64(static_cast<uint64_t>(group.last_quoted_market_receipt));
        mix_u64(static_cast<uint64_t>(group.last_quoted_operating_cost));
    }
    // CSR offsets are reconstructed from the stable signal records and are not
    // persistent authority. Hash only the records so bootstrap and restore do
    // not diverge on an equivalent transient cache shape.
    for (size_t i = 0; i < _market_signals.good_ids.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_market_signals.good_ids[i]));
        mix_u64(static_cast<uint64_t>(_market_signals.business_demand_ema[i]));
        mix_u64(static_cast<uint64_t>(_market_signals.offered_supply_ema[i]));
        mix_u64(static_cast<uint64_t>(_market_signals.realized_withdrawal_ema[i]));
        mix_u64(static_cast<uint32_t>(_market_signals.cost_anchor_price[i]));
    }
    auto hash_building_role_lanes = [&](const std::vector<int64_t> &lanes) {
        for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
            const auto group = building_view(pk_row);
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t role = 0; role < type.employee_count; ++role) {
                mix_u64(static_cast<uint64_t>(
                    lanes[group.employee_fill_begin + role]));
            }
        }
    };
    hash_building_role_lanes(_building_employee_filled);
    hash_building_role_lanes(_building_role_contract_wage);
    hash_building_role_lanes(_building_role_base_living_cost);
    hash_building_role_lanes(_building_role_living_cost);
    hash_building_role_lanes(_building_role_local_average_wage);
    hash_building_role_lanes(_building_role_base_wage_due);
    hash_building_role_lanes(_building_role_base_wage_paid);
    hash_building_role_lanes(_building_role_bonus_due);
    hash_building_role_lanes(_building_role_bonus_paid);
    // Labor cell offsets are likewise a derived lookup cache.
    for (size_t i = 0; i < _labor_signals.profession_ids.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_labor_signals.profession_ids[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.base_living_cost[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.role_living_cost[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.contract_wage_ema[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.paid_wage_ema[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.job_days[i]));
        mix_u64(static_cast<uint32_t>(_labor_signals.pay_ratio_q16[i]));
    }
    for (const auto pending : pending_construction()) {
        mix_u64(static_cast<uint32_t>(pending.cell));
        mix_u64(static_cast<uint32_t>(pending.type_id));
        mix_u64(static_cast<uint32_t>(pending.owner_signature_id));
        mix_u64(static_cast<uint64_t>(pending.count));
        mix_u64(static_cast<uint64_t>(pending.ready_day));
        mix_u64(static_cast<uint64_t>(pending.sequence));
        mix_u64(static_cast<uint64_t>(pending.merchant_debt_principal));
        mix_u64(static_cast<uint64_t>(pending.merchant_debt_premium));
        mix_u64(pending.merchant_debt_term_cycles_left);
        mix_u64(pending.sponsor_family_handle);
    }
    if (_trade_runtime_mode.get() == 2 || !trade_orders_store().ids.empty() ||
        !_trade_flows.cells.empty()) {
    mix_u64(0x5452414445524556ULL); // "TRADEREV"
    mix_u64(_country_trade_revision.get());
    for (int32_t order = 0; order < trade_orders_store().size(); ++order) {
        mix_u64(static_cast<uint64_t>(trade_orders_store().ids[order]));
        mix_u64(static_cast<uint32_t>(trade_orders_store().sources[order]));
        mix_u64(static_cast<uint32_t>(trade_orders_store().destinations[order]));
        mix_u64(static_cast<uint32_t>(trade_orders_store().countries[order]));
        mix_u64(trade_orders_store().source_country_handles[order]);
        mix_u64(trade_orders_store().destination_country_handles[order]);
        mix_u64(static_cast<uint32_t>(trade_orders_store().source_country_slots[order]));
        mix_u64(static_cast<uint32_t>(trade_orders_store().destination_country_slots[order]));
        mix_u64(static_cast<uint64_t>(trade_orders_store().departure_days[order]));
        mix_u64(static_cast<uint64_t>(trade_orders_store().arrival_days[order]));
        mix_u64(static_cast<uint64_t>(trade_orders_store().cash_escrow[order]));
        mix_u64(static_cast<uint64_t>(trade_orders_store().capacity_work[order]));
        mix_u64(trade_orders_store().states[order]);
        mix_u64(trade_orders_store().cargo_delivered[order]);
        for (int32_t line = trade_orders_store().line_offsets[order];
             line < trade_orders_store().line_offsets[order + 1]; ++line) {
            mix_u64(static_cast<uint32_t>(trade_orders_store().line_goods[line]));
            mix_u64(static_cast<uint64_t>(trade_orders_store().line_quantities[line]));
            mix_u64(static_cast<uint32_t>(trade_orders_store().line_unit_prices[line]));
            mix_u64(static_cast<uint32_t>(trade_orders_store().line_destination_prices[line]));
            mix_u64(static_cast<uint64_t>(trade_orders_store().line_base_values[line]));
            mix_u64(static_cast<uint64_t>(trade_orders_store().line_retail_values[line]));
            mix_u64(static_cast<uint64_t>(trade_orders_store().line_import_transfers[line]));
            mix_u64(static_cast<uint64_t>(trade_orders_store().line_export_transfers[line]));
            mix_u64(static_cast<uint64_t>(
                trade_orders_store().line_transaction_transfers[line]));
            mix_u64(trade_orders_store().line_flags[line]);
        }
        for (int32_t seller = trade_orders_store().seller_offsets[order];
             seller < trade_orders_store().seller_offsets[order + 1]; ++seller) {
            mix_u64(trade_orders_store().seller_handles[seller]);
            mix_u64(static_cast<uint64_t>(trade_orders_store().seller_weights[seller]));
        }
    }
    mix_u64(static_cast<uint64_t>(trade_orders_store().next_id));
    for (size_t i = 0; i < _trade_flows.cells.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_trade_flows.cells[i]));
        mix_u64(static_cast<uint32_t>(_trade_flows.goods[i]));
        mix_u64(static_cast<uint64_t>(_trade_flows.import_ema[i]));
        mix_u64(static_cast<uint64_t>(_trade_flows.export_ema[i]));
    }
    }
    mix_u64(0x434f554e54525947ULL); // "COUNTRYG"
    for (size_t i = 0; i < _country_good_trade.countries.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_country_good_trade.countries[i]));
        mix_u64(static_cast<uint32_t>(_country_good_trade.goods[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.import_quantity[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.export_quantity[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.import_base[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.export_base[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.import_tariff[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.export_tariff[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.batch_epoch[i]));
        mix_u64(static_cast<uint64_t>(
            _country_good_trade.batch_import_quantity[i]));
        mix_u64(static_cast<uint64_t>(
            _country_good_trade.batch_export_quantity[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.batch_import_base[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.batch_export_base[i]));
        mix_u64(static_cast<uint64_t>(
            _country_good_trade.batch_import_tariff[i]));
        mix_u64(static_cast<uint64_t>(
            _country_good_trade.batch_export_tariff[i]));
    }
    mix_u64(0x434f554e54525950ULL); // "COUNTRYP"
    for (size_t i = 0; i < _country_partner_trade.countries.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_country_partner_trade.countries[i]));
        mix_u64(static_cast<uint32_t>(_country_partner_trade.partners[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.import_quantity[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.export_quantity[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.import_base[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.export_base[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.order_count[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.batch_epoch[i]));
        mix_u64(static_cast<uint64_t>(
            _country_partner_trade.batch_import_quantity[i]));
        mix_u64(static_cast<uint64_t>(
            _country_partner_trade.batch_export_quantity[i]));
        mix_u64(static_cast<uint64_t>(
            _country_partner_trade.batch_import_base[i]));
        mix_u64(static_cast<uint64_t>(
            _country_partner_trade.batch_export_base[i]));
        mix_u64(static_cast<uint64_t>(
            _country_partner_trade.batch_order_count[i]));
    }
    mix_u64(0x5441524946464849ULL); // "TARIFFHI"
    for (size_t i = 0; i < _tariff_history.countries.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_tariff_history.countries[i]));
        mix_u64(static_cast<uint32_t>(_tariff_history.kinds[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.bases[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.assessed[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.collected[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.requests[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.reserved[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.paid[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.cumulative_bases[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.cumulative_collected[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.cumulative_requests[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.cumulative_paid[i]));
    }
    mix_u64(0x46495343414c4556ULL); // "FISCALEV"
    // Restore materializes a dense zero-filled fiscal event group while a
    // never-committed bootstrap may still hold an empty vector. Hash the same
    // fixed logical country x tax-kind shape used by PKEC serialization.
    mix_fiscal_lanes(_fiscal_last_events);
    mix_u64(0x46495343455343ULL); // "FISCAESC"
    for (size_t country = 0; country < fiscal_hash_countries; ++country) {
        mix_u64(static_cast<uint64_t>(country <
            _fiscal_escrow_by_country.size()
                ? _fiscal_escrow_by_country[country] : 0));
    }
    mix_u64(0x46495343414c504aULL); // "FISCALPJ"
    if (paged) {
        if (_fiscal_digest_rebuild) {
            _fiscal_record_digests.clear();
            for (const auto &entry : _asset_peer_journal)
                _fiscal_record_digests.emplace(entry.first, fiscal_record_digest(entry.second));
            _fiscal_digest_rebuild = false;
            _fiscal_words_dirty = true;
        }
        if (_fiscal_words_dirty) {
            _fiscal_hash_words.clear();
            _fiscal_hash_words.reserve(_fiscal_record_digests.size() * 2);
            for (const auto &entry : _fiscal_record_digests) {
                _fiscal_hash_words.push_back(entry.first);
                _fiscal_hash_words.push_back(entry.second);
            }
            _fiscal_words_dirty = false;
            _fiscal_hash_dirty_from_word = 0;
        }
        const char *verify = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_HASH_VERIFY);
        if (verify && std::strcmp(verify, "1") == 0) {
            std::map<uint64_t, uint64_t> reference;
            for (const auto &entry : _asset_peer_journal)
                reference.emplace(entry.first, fiscal_record_digest(entry.second));
            if (reference != _fiscal_record_digests) {
                std::fprintf(stderr, "economy_fiscal_digest_mismatch day=%lld\n",
                    static_cast<long long>(_current_day.get()));
                std::abort();
            }
        }
        const size_t dirty_from = _fiscal_hash_dirty_from_word;
        _fiscal_hash_dirty_from_word = _fiscal_hash_words.size();
        mix_u64(_fiscal_hash_pages.update_tail(_fiscal_hash_words, 3, 1, dirty_from));
    } else {
    std::vector<uint64_t> fiscal_peer_ids;
    fiscal_peer_ids.reserve(_asset_peer_journal.size());
    for (const auto &entry : _asset_peer_journal)
        fiscal_peer_ids.push_back(entry.first);
    std::sort(fiscal_peer_ids.begin(), fiscal_peer_ids.end());
    for (const uint64_t request_id : fiscal_peer_ids) {
        const FiscalPeerJournalRecord &record =
            _asset_peer_journal.at(request_id);
        mix_u64(record.request_id);
        mix_u64(record.transaction_id);
        mix_u64(record.country_handle);
        mix_u64(record.country_generation);
        mix_u64(record.peer_generation);
        mix_u64(record.committed_peer_generation);
        mix_u64(static_cast<uint64_t>(record.day));
        mix_u64(record.operation_sequence);
        mix_u64(record.continuation_index);
        mix_u64(static_cast<uint64_t>(record.country_slot));
        mix_u64(static_cast<uint16_t>(record.operation));
        mix_u64(static_cast<uint8_t>(record.result_code));
        mix_u64(static_cast<uint8_t>(record.state));
        mix_u64(record.accepted);
        mix_u64(static_cast<uint64_t>(record.requested_quantity));
        mix_u64(static_cast<uint64_t>(record.requested_cash));
        mix_u64(static_cast<uint64_t>(record.committed_quantity));
        mix_u64(static_cast<uint64_t>(record.committed_cash));
        for (const char value : record.reason)
            mix_u64(static_cast<uint8_t>(value));
    }
    }
    // Canal quotes are read-side preview state and deliberately do not alter
    // the authoritative simulation hash.  Started projects do: they own paid
    // construction resources and the route that an Effect transaction will
    // atomically commit.
    if (!_canal_projects.empty()) {
        mix_u64(0x43414e414c50524aULL); // "CANALPRJ"
        mix_u64(static_cast<uint64_t>(_next_canal_project_id.get()));
        for (const CanalProject &project : _canal_projects) {
            mix_u64(project.handle);
            mix_u64(project.generation);
            mix_u64(project.country_handle);
            mix_u64(static_cast<uint64_t>(project.effective_day));
            mix_u64(static_cast<uint64_t>(project.sequence));
            mix_u64(static_cast<uint64_t>(project.ready_day));
            mix_u64(project.topology_hash);
            mix_u64(static_cast<uint64_t>(project.cash_paid));
            mix_u64(static_cast<uint64_t>(project.treasury_goods_used));
            mix_u64(static_cast<uint64_t>(project.market_goods_used));
            mix_u64(static_cast<uint64_t>(project.source_kind));
            mix_u64(static_cast<uint64_t>(project.state));
            mix_u64(static_cast<uint64_t>(project.effect_transaction_id));
            mix_u64(static_cast<uint64_t>(project.route_cells.size()));
            for (const int32_t cell : project.route_cells)
                mix_u64(static_cast<uint64_t>(cell));
            for (const int32_t direction : project.route_edge_dirs)
                mix_u64(static_cast<uint64_t>(direction));
        }
    }
    mix_u64(0x4d4f444946494552ULL); // "MODIFIER"
    if (_modifier_runtime != nullptr) {
        std::vector<uint8_t> modifier_bytes;
        std::string modifier_error;
        if (modifier_api::serialize_domain(*_modifier_runtime, ModifierApi::ECONOMY,
                                                modifier_bytes,
                                                modifier_error)) {
            // Modifier snapshot_version is a cache invalidation counter and
            // intentionally advances during restore; exclude that header lane
            // while retaining every persistent instance and identity byte.
            mix_u64(modifier_bytes.size());
            for (size_t byte_index = 0; byte_index < modifier_bytes.size();
                 ++byte_index) {
                if (byte_index >= 24 && byte_index < 32) continue;
                const uint8_t byte = modifier_bytes[byte_index];
                hash ^= byte;
                hash *= 1099511628211ULL;
            }
        } else {
            mix_u64(0xffffffffffffffffULL);
            mix_string(modifier_error);
        }
    } else {
        mix_u64(0);
    }
    return static_cast<int64_t>((hash & 0x7fffffffffffffffULL) | 1ULL);
}

} // namespace pk
