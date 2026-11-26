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

#include "economy_runtime_state_hash_section_household_preparation.inc"
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
        const int32_t market = _epoch_market_ids[begin + relative];
        _market_results_scratch[relative].market = market;
        register_demand_basis_cell(market);
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
        // Merchant retail pool of the most recently settled day, market-keyed
        // because the settlement distribution is per market. Overwritten, not
        // accumulated: the projection wants today's pool at today's prices,
        // and an epoch running total would have to be re-divided by a day
        // count that is wrong for every day but the last. Sized lazily against
        // the live market handle so no second registry can drift.
        if (market >= 0) {
            const size_t market_index = static_cast<size_t>(market);
            if (_merchant_household_retail_by_market.size() <= market_index) {
                _merchant_household_retail_by_market.resize(market_index + 1, 0);
                _market_merchant_population.resize(market_index + 1, 0);
            }
            _merchant_household_retail_by_market[market_index] =
                market_result.merchant_household_retail;
            _market_merchant_population[market_index] =
                market_result.merchant_population;
        }
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

#include "economy_runtime_state_hash_section_deterministic_digest.inc"

} // namespace pk
