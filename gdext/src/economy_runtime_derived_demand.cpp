#include "economy_runtime.h"
#include "economy_cost_probe.h"
#include "parallel_dispatcher.h"
#include "runtime_switch_registry.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <limits>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

namespace pk {
namespace {
using Clock = std::chrono::steady_clock;

#if defined(_WIN32)
int64_t startup_probe_thread_cpu_us() {
    FILETIME creation{}, exit{}, kernel{}, user{};
    if (!GetThreadTimes(GetCurrentThread(), &creation, &exit, &kernel, &user))
        return 0;
    ULARGE_INTEGER k{}, u{};
    k.LowPart = kernel.dwLowDateTime;
    k.HighPart = kernel.dwHighDateTime;
    u.LowPart = user.dwLowDateTime;
    u.HighPart = user.dwHighDateTime;
    return static_cast<int64_t>((k.QuadPart + u.QuadPart) / 10);
}
int64_t startup_probe_process_cpu_us() {
    FILETIME creation{}, exit{}, kernel{}, user{};
    if (!GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user))
        return 0;
    ULARGE_INTEGER k{}, u{};
    k.LowPart = kernel.dwLowDateTime;
    k.HighPart = kernel.dwHighDateTime;
    u.LowPart = user.dwLowDateTime;
    u.HighPart = user.dwHighDateTime;
    return static_cast<int64_t>((k.QuadPart + u.QuadPart) / 10);
}
#else
int64_t startup_probe_thread_cpu_us() { return 0; }
int64_t startup_probe_process_cpu_us() { return 0; }
#endif

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

// Derived business demand refresh scratch. One queue entry never outlives a
// single cell; one cell result is produced by a pure-read compute phase and
// merged serially afterwards so the parallel pass cannot mutate shared state.
struct DerivedQueueEntry {
    int32_t good = -1;
    int64_t needed = 0;
};

using DerivedCellWork = TrackBDerivedCellWork;

// Derived-demand price conduction is on by default. Setting
// PK_ECONOMY_DERIVED_PRICE_CONDUCTION=0 restores the old price formation;
// PK_ECONOMY_DERIVED_STARTUP=0 disables only the investment-side absorption.
// The two switches let a rerun separate "price did not rise" from "price rose
// but the producer still would not start".
bool derived_price_conduction_enabled() {
    static const bool value = [] {
        const char *flag = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_DERIVED_PRICE_CONDUCTION);
        return !(flag && std::strcmp(flag, "0") == 0);
    }();
    return value;
}

} // namespace

void NativeEconomyRuntime::refresh_derived_business_demand() {
    // Track B (user-approved): cadence-limited approximation. The derived
    // business demand is a slow-moving planning input; on non-refresh days it
    // reuses the previous computed vector instead of re-running the full
    // per-cell preview/BFS pass. PK_ECONOMY_TRACK_B=0 restores exact mode.
    static const bool track_b_enabled = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B);
        return !(value && std::strcmp(value, "0") == 0);
    }();
    static const int32_t track_b_derived_cadence = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_DERIVED_CADENCE);
        const int32_t parsed = value ? std::atoi(value) : 0;
        return parsed > 0 ? std::min<int32_t>(parsed, 30) : 5;
    }();
    // Spread mode (default): instead of one heavy full pass every N days,
    // recompute 1/N of the live cells each day and merge cached results for the
    // rest, flattening the per-day cost. Set to 1 to fall back to whole-pass
    // cadence; PK_ECONOMY_TRACK_B=0 restores the exact daily pass.
    static const int32_t track_b_derived_spread = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_TRACK_B_DERIVED_SPREAD);
        const int32_t parsed = value ? std::atoi(value) : 0;
        return parsed > 0 ? std::min<int32_t>(parsed, 32) : 4;
    }();
    // Coarse attribution for the once-per-epoch full pass. Per-call probes
    // under this function are aggregated by EconomyCostProbe; this one stays
    // a plain stage wall so the waterfall can be reconciled with epoch_vectors.
    EconomyCostProbe pass_cost("derived.pass", _current_day.get());
    _derived_business_demand_total = 0;
    _derived_business_demand_lanes = 0;
    _derived_business_demand_edges = 0;
    _epoch_derived_business_demand.assign(_market_signals.good_ids.size(), 0);
    _epoch_derived_anchor_price.assign(_market_signals.good_ids.size(), 0);
    if (track_b_enabled && track_b_derived_spread <= 1 &&
        track_b_derived_cadence > 1 &&
        !_track_b_derived_carry.empty() &&
        _track_b_derived_carry.size() <=
            _market_signals.good_ids.size() &&
        (_current_day.get() % track_b_derived_cadence) != 0) {
        std::copy(_track_b_derived_carry.begin(),
                  _track_b_derived_carry.end(),
                  _epoch_derived_business_demand.begin());
        if (_track_b_derived_anchor_carry.size() ==
                _epoch_derived_anchor_price.size()) {
            _epoch_derived_anchor_price = _track_b_derived_anchor_carry;
        }
        int64_t lane_count = 0;
        for (const int64_t quantity : _epoch_derived_business_demand) {
            if (quantity <= 0) continue;
            ++lane_count;
            _derived_business_demand_total = saturating_add(
                _derived_business_demand_total, quantity, _saturation_count);
        }
        _derived_business_demand_lanes = lane_count;
        ++_derived_snapshot_generation;
        uint64_t derived_hash = 14695981039346656037ull;
        auto mix = [&](uint64_t value) {
            derived_hash ^= value;
            derived_hash *= 1099511628211ull;
        };
        mix(static_cast<uint64_t>(_derived_snapshot_generation));
        mix(static_cast<uint64_t>(_derived_business_demand_total));
        mix(static_cast<uint64_t>(_derived_business_demand_lanes));
        for (size_t i = 0; i < _epoch_derived_business_demand.size(); ++i) {
            if (_epoch_derived_business_demand[i] == 0) continue;
            mix(static_cast<uint64_t>(i));
            mix(static_cast<uint64_t>(_epoch_derived_business_demand[i]));
        }
        _derived_snapshot_hash = derived_hash;
        EconomyCostProbe::record("derived.track_b_skip", _current_day.get(), 0.0,
                                 static_cast<uint64_t>(lane_count));
        return;
    }
    if (market_store().good_count.get() <= 0 || _cell_count.get() <= 0 ||
        _investment_good_type_offsets.size() != _good_ids.size() + 1 ||
        _economy_live_cells.empty()) return;
    if (_investment_good_stamp.size() != _good_ids.size())
        _investment_good_stamp.assign(_good_ids.size(), 0);
    const char *workset_disabled = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_ACTIVE_WORKSET_DISABLE);
    const bool use_snapshot = !(workset_disabled && std::strcmp(workset_disabled, "1") == 0);
    // capture_country_epoch 已完成，后面的派生传播不修改国家科技。这里可在
    // _epoch_active 置位之前复用同一冻结掩码，避免每个组件再查询国家运行时。
    LivingCostMemoScope memo(*this, false, use_snapshot);
    StartupProducerMemoScope startup_memo(*this);
    const int32_t cells = static_cast<int32_t>(_economy_live_cells.size());
    // Derived refresh is per-cell independent: household preview, seed scan and
    // the upstream producer propagation only read frozen epoch inputs. Missing
    // market-signal lanes are deferred to the ordered merge below, so the
    // parallel pass never mutates shared state.
    //
    // Parallel is the default production path with a hard task cap of two:
    // the 2026-10-19 task sweeps show per-cell slowdown under concurrency grows
    // faster than the extra workers help (T2 beats T3/T4 on wall clock), while
    // the ordered merge stays bit-identical regardless of task count.
    // PK_ECONOMY_DERIVED_PARALLEL=0 restores the serial reference path.
    static const bool derived_parallel_enabled = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_DERIVED_PARALLEL);
        return !(value && std::strcmp(value, "0") == 0);
    }();
    // Diagnostic-only override for task-count sweeps; task count never changes
    // simulation results (parallel and serial outputs are bit-identical).
    static const int32_t derived_forced_tasks = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_DERIVED_TASKS);
        if (value == nullptr || *value == '\0') return 0;
        const int32_t parsed = std::atoi(value);
        return parsed > 0 ? std::min<int32_t>(parsed, 32) : 0;
    }();
    const int32_t good_count = market_store().good_count.get();
    // Household demand can exist before the first building of a production
    // chain is installed.  In that cold-start state the sparse market-signal
    // CSR is empty for the finished good, so seeding only from signal lanes
    // would never reach its hard inputs.  Build the sorted producer-output
    // list once per refresh and use it as a bounded demand seed; the per-cell
    // `seed_good()` gate still drops goods with no actual deficit.
    std::vector<int32_t> producer_output_goods;
    if (good_count > 0 && _investment_good_type_offsets.size() ==
            static_cast<size_t>(good_count + 1)) {
        producer_output_goods.reserve(static_cast<size_t>(good_count));
        for (int32_t good = 0; good < good_count; ++good) {
            if (_investment_good_type_offsets[good] <
                    _investment_good_type_offsets[good + 1])
                producer_output_goods.push_back(good);
        }
    }
    const int32_t tasks = (derived_parallel_enabled && use_snapshot &&
            _worker_enabled && cells >= 2 && parallel_has_real_worker_threads())
        ? (derived_forced_tasks > 0
            ? std::min({cells, derived_forced_tasks, _worker_task_cap})
            : std::min({cells, static_cast<int32_t>(2), _worker_task_cap}))
        : 1;
    // Plain local: parallel tasks write disjoint elements of one vector.
    // A thread_local here would be resolved per executing thread inside the
    // lambda and the worker tasks would index an empty vector (crash seen
    // 2026-10-19). The caller frame stays alive across parallel_for_range.
    std::vector<DerivedCellWork> cell_work;
    cell_work.resize(static_cast<size_t>(cells));
    for (auto &work_item : cell_work) work_item.reset();
    // Spread mode: compute a deterministic 1/N slice of cells this day and seed
    // the rest from the previous day's cached per-cell results.
    const bool derived_spread_active =
        track_b_enabled && track_b_derived_spread > 1;
    int32_t derived_spread_phase = 0;
    bool derived_spread_refresh_all = false;
    if (derived_spread_active) {
        if (_track_b_derived_cell_cache_cells != cells ||
            _track_b_derived_cell_cache.size() != static_cast<size_t>(cells)) {
            _track_b_derived_cell_cache.assign(static_cast<size_t>(cells), {});
            _track_b_derived_cell_cache_cells = cells;
            _track_b_derived_cell_cache_day = -1000000;
        }
        derived_spread_refresh_all =
            _track_b_derived_cell_cache_day != _current_day.get() - 1;
        derived_spread_phase = static_cast<int32_t>(
            ((_current_day.get() % track_b_derived_spread) +
             track_b_derived_spread) % track_b_derived_spread);

    }
    // Diagnostics only: prove whether the parallel group really runs more than
    // one task at a time. Never feeds simulation state.
    static std::atomic<int32_t> derived_task_active{0};
    static std::atomic<int32_t> derived_task_max{0};
    // When PK_ECONOMY_DERIVED_TRACE=1, print one line per epoch to stderr so
    // probe-free runs (no PK_ECONOMY_COST_CSV) can still compare the derived
    // section wall clock against the sum of task wall clocks.
    static const bool derived_trace = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_DERIVED_TRACE);
        return value && std::strcmp(value, "1") == 0;
    }();
    static std::atomic<int64_t> derived_trace_task_us{0};
    static std::atomic<int64_t> derived_trace_task_cpu_us{0};
    static std::atomic<int32_t> derived_trace_max_conc{0};
    static std::atomic<int64_t> derived_trace_start_ns{0};
    static std::atomic<int64_t> derived_trace_start_max_ns{0};
    static std::atomic<int64_t> derived_trace_end_max_ns{0};
    const auto trace_now_ns = []() {
        return std::chrono::duration_cast<std::chrono::nanoseconds>(
            Clock::now().time_since_epoch()).count();
    };
    auto compute_range = [&](int32_t first, int32_t last) {
        const auto task_started = Clock::now();
        const int64_t task_cpu_started =
            derived_trace ? startup_probe_thread_cpu_us() : 0;
        if (derived_trace) {
            const int64_t start_ns = trace_now_ns();
            int64_t previous = derived_trace_start_ns.load();
            while ((previous == 0 || start_ns < previous) &&
                   !derived_trace_start_ns.compare_exchange_weak(
                       previous, start_ns)) {
            }
            previous = derived_trace_start_max_ns.load();
            while (start_ns > previous &&
                   !derived_trace_start_max_ns.compare_exchange_weak(
                       previous, start_ns)) {
            }
        }
        const int32_t task_active =
            derived_task_active.fetch_add(1, std::memory_order_relaxed) + 1;
        int32_t observed_max = derived_task_max.load(std::memory_order_relaxed);
        while (task_active > observed_max &&
               !derived_task_max.compare_exchange_weak(
                   observed_max, task_active, std::memory_order_relaxed)) {
        }
        LivingCostMemoScope worker_memo(*this, false, use_snapshot);
        StartupProducerMemoScope worker_startup_memo(*this);
        thread_local std::vector<int64_t> actor_preview;
        thread_local std::vector<int64_t> household_demand_by_good;
        thread_local std::vector<int64_t> substitute_demand_by_good;
        thread_local std::vector<uint32_t> seed_stamp;
        thread_local std::vector<uint32_t> visit_stamp;
        thread_local std::vector<DerivedQueueEntry> queue;
        thread_local InvestmentCandidatePlan producer_plan;
        if (static_cast<int32_t>(household_demand_by_good.size()) != good_count)
            household_demand_by_good.assign(static_cast<size_t>(good_count), 0);
        if (static_cast<int32_t>(seed_stamp.size()) != good_count)
            seed_stamp.assign(static_cast<size_t>(good_count), 0);
        if (static_cast<int32_t>(visit_stamp.size()) != good_count)
            visit_stamp.assign(static_cast<size_t>(good_count), 0);
        // Stamps are generation based; this task owns its arrays, so a single
        // zero fill per task keeps generations local and collision free.
        std::fill(seed_stamp.begin(), seed_stamp.end(), 0);
        std::fill(visit_stamp.begin(), visit_stamp.end(), 0);
        uint32_t visit = 0;
        for (int32_t relative = first; relative < last; ++relative) {
            if (derived_spread_active && !derived_spread_refresh_all &&
                (relative % track_b_derived_spread) != derived_spread_phase)
                continue;
            DerivedCellWork &out = cell_work[relative];
            const int32_t cell = _economy_live_cells[relative];
            if (cell < 0 || cell >= _cell_count.get()) continue;
            const int32_t market = market_store().cell_to_market[cell];
            if (market < 0) continue;
            bool has_seed = _market_signals.cell_offsets.size() ==
                    static_cast<size_t>(_cell_count.get() + 1) &&
                _market_signals.cell_offsets[cell] < _market_signals.cell_offsets[cell + 1];
            if (!has_seed) {
                const uint64_t first_key =
                    static_cast<uint64_t>(static_cast<uint32_t>(cell)) << 32;
                const auto key = std::lower_bound(
                    _trade_active_keys.begin(), _trade_active_keys.end(), first_key);
                has_seed = key != _trade_active_keys.end() &&
                    (*key >> 32) == static_cast<uint32_t>(cell);
            }
            // A market with no installed building signal can still have a
            // demanded finished good whose catalog producer has hard inputs.
            // Keep such cells alive for the cold-start output seed below.
            if (!has_seed && producer_output_goods.empty()) continue;
            // Same arithmetic as the retired parallel household prepare:
            // per-capita previews weighted by cohort population.
            std::fill(household_demand_by_good.begin(),
                      household_demand_by_good.end(), 0);
            int64_t preview_saturations = 0;
            const EnvironmentSample environment = environment_sample_for_cell(cell);
            population_store().for_each_in_cell(cell, [&](int32_t slot) {
                if (slot < 0 || slot >= static_cast<int32_t>(
                        population_store().population.size()) ||
                    population_store().population[slot] <= 0) return;
                int64_t actor_sat = 0;
                compute_cohort_demand_preview(slot, market, environment, nullptr,
                    population_store().funds[slot], actor_preview, actor_sat);
                for (size_t lane = 0; lane < actor_preview.size(); ++lane)
                    household_demand_by_good[lane] = saturating_add(
                        household_demand_by_good[lane],
                        saturating_mul(std::max<int64_t>(0, actor_preview[lane]),
                            population_store().population[slot],
                            preview_saturations),
                        preview_saturations);
            });
            int64_t sat = preview_saturations;
            substitute_demand_by_good.assign(static_cast<size_t>(good_count), 0);
            // 替代需求在生产后才写入当期临时列，下一次冻结前已清空。
            // 从既有建筑的真实企业需求 EMA 重建同槽替代报价，不能把
            // 界面可见的石器需求留在临时列、阻断其燧石投入的传导。
            if (_building_cell_offsets.size() ==
                    static_cast<size_t>(_cell_count.get() + 1)) {
                for (int32_t group = _building_cell_offsets[cell];
                     group < _building_cell_offsets[cell + 1]; ++group) {
                    const auto lot = building_view(static_cast<size_t>(group));
                    if (lot.count <= 0 ||
                        !building_available(cell, lot.type_id, true)) continue;
                    const BuildingType &type = _building_types[lot.type_id];
                    for (int32_t edge = 0; edge < type.input_count; ++edge) {
                        const ProductionInput &input =
                            _building_inputs[type.input_begin + edge];
                        if (input.required_q16 <= 0 || input.candidate_count <= 1)
                            continue;
                        int64_t effective_demand = 0;
                        for (int32_t c = input.candidate_begin;
                             c < input.candidate_begin + input.candidate_count; ++c) {
                            const InputCandidate &candidate = _building_input_candidates[c];
                            const int32_t signal = market_signal_index(cell, candidate.good_id);
                            if (signal < 0) continue;
                            effective_demand = std::max(effective_demand,
                                mul_div_sat(std::max<int64_t>(0,
                                    _market_signals.business_demand_ema[signal]),
                                    candidate.efficiency_q16, Q16_ONE, sat));
                        }
                        const int64_t intent_q16 = lot.operating_state == 1
                            ? Q16_ONE : std::clamp<int64_t>(
                                lot.purchase_intent_capacity_q16, 0, Q16_ONE);
                        const int64_t slot_demand = mul_div_sat(saturating_mul(
                            lot.count, input.quantity, sat), intent_q16, Q16_ONE, sat);
                        // 其他用途也可能购买同一 SKU；每槽最多转述自身活动
                        // 所需的日量，不能把整格需求复制到每一个配方槽。
                        effective_demand = std::min(effective_demand, slot_demand);
                        if (effective_demand <= 0) continue;
                        for (int32_t c = input.candidate_begin;
                             c < input.candidate_begin + input.candidate_count; ++c) {
                            const InputCandidate &candidate = _building_input_candidates[c];
                            if (!good_input_candidate_available(cell, candidate.good_id, true))
                                continue;
                            const int64_t physical = mul_div_sat(effective_demand,
                                Q16_ONE, std::max<int32_t>(1, candidate.efficiency_q16), sat);
                            substitute_demand_by_good[candidate.good_id] = saturating_add(
                                substitute_demand_by_good[candidate.good_id], physical, sat);
                        }
                    }
                }
            }
            ++visit;
            if (visit == 0) {
                std::fill(seed_stamp.begin(), seed_stamp.end(), 0);
                std::fill(visit_stamp.begin(), visit_stamp.end(), 0);
                visit = 1;
            }
            queue.clear();
            auto enqueue = [&](int32_t good, int64_t needed) {
                if (good < 0 || good >= good_count || needed <= 0) return;
                queue.push_back({good, needed});
            };
            auto seed_good = [&](int32_t good) {
                if (good >= 0 && good < good_count) {
                    if (seed_stamp[good] == visit) return;
                    seed_stamp[good] = visit;
                }
                const int64_t household_demand = good >= 0 && good < good_count
                    ? household_demand_by_good[good] : 0;
                const int64_t index = market >= 0
                    ? market_store().index(market, good) : -1;
                const int64_t stored_demand = index >= 0 && index <
                        static_cast<int64_t>(market_store().demand_ema.size())
                    ? std::max<int64_t>(0, market_store().demand_ema[index]) : 0;
                const int64_t preview_deficit = household_demand > stored_demand
                    ? household_demand - stored_demand : household_demand;
                const int32_t signal = market_signal_index(cell, good);
                const int64_t substitute_supply = signal >= 0
                    ? std::max<int64_t>(0, _market_signals.offered_supply_ema[signal]) : 0;
                const int64_t substitute_stock_daily = index >= 0
                    ? std::max<int64_t>(0, market_store().stock[index]) /
                        std::max(1, _epoch_days.get()) : 0;
                const int64_t substitute_deficit = std::max<int64_t>(0,
                    substitute_demand_by_good[good] - saturating_add(
                        substitute_supply, substitute_stock_daily, sat));
                const int64_t deficit = std::max({
                    market_flow_deficit_daily(cell, good, false, sat),
                    preview_deficit, substitute_deficit});
                if (deficit > 0) enqueue(good, deficit);
            };
            if (_market_signals.cell_offsets.size() ==
                    static_cast<size_t>(_cell_count.get() + 1)) {
                for (int32_t signal = _market_signals.cell_offsets[cell];
                     signal < _market_signals.cell_offsets[cell + 1]; ++signal) {
                    seed_good(_market_signals.good_ids[signal]);
                }
            }
            const uint64_t key_begin =
                static_cast<uint64_t>(static_cast<uint32_t>(cell)) << 32;
            const uint64_t key_end = key_begin | 0xffffffffULL;
            auto active = std::lower_bound(
                _trade_active_keys.begin(), _trade_active_keys.end(), key_begin);
            for (; active != _trade_active_keys.end() && *active <= key_end;
                 ++active) {
                seed_good(static_cast<int32_t>(*active & 0xffffffffULL));
            }
            if (_epoch_research_good_id >= 0) {
                const int64_t research = epoch_research_demand_daily(
                    cell, _epoch_research_good_id);
                if (research > 0) enqueue(_epoch_research_good_id, research);
            }
            // Do this after the existing sparse lanes so installed-building
            // demand keeps its stable ordering.  The producer-output list is
            // only a candidate set; `seed_good()` checks household demand,
            // inventory gap, business flow, and procurement before enqueueing.
            // This is the bridge that lets a demanded but unbuilt product
            // (for example chipped stone tools) conduct its hard flint input
            // upstream without manufacturing a producer owner or cashflow.
            for (const int32_t good : producer_output_goods)
                seed_good(good);
            if (queue.empty()) continue;
            out.seeded = true;
            out.enqueued_goods = queue.size();
            size_t cursor = 0;
            while (cursor < queue.size()) {
                const DerivedQueueEntry entry = queue[cursor++];
                if (entry.good < 0 || entry.good >= good_count ||
                    entry.needed <= 0) continue;
                if (visit_stamp[entry.good] == visit) continue;
                visit_stamp[entry.good] = visit;
                out.edges += static_cast<int64_t>(
                    _investment_good_type_offsets[entry.good + 1] -
                    _investment_good_type_offsets[entry.good]);
                // A good whose every candidate producer has no input edges can
                // never propagate derived demand upstream; the full startup
                // selection ranking is irrelevant then, so skip it.
                bool any_candidate_inputs = false;
                for (int32_t candidate_cursor =
                         _investment_good_type_offsets[entry.good];
                     candidate_cursor < _investment_good_type_offsets[entry.good + 1];
                     ++candidate_cursor) {
                    const int32_t candidate_type =
                        _investment_good_type_indices[candidate_cursor];
                    if (candidate_type >= 0 && candidate_type <
                            static_cast<int32_t>(_building_types.size()) &&
                        _building_types[candidate_type].input_count > 0) {
                        any_candidate_inputs = true;
                        break;
                    }
                }
                if (!any_candidate_inputs) continue;
                ++out.startup_calls;
                const int32_t type_id = select_startup_producer(
                    cell, entry.good, &producer_plan);
                if (type_id < 0) continue;
                const BuildingType &type = _building_types[type_id];
                const int64_t output_qty = producer_plan.planned_output_quantity;
                if (output_qty <= 0) continue;
                for (int32_t edge = 0; edge < type.input_count; ++edge) {
                    const ProductionInput &input =
                        _building_inputs[type.input_begin + edge];
                    ++out.edges;
                    if (input.required_q16 <= 0) continue;
                    int64_t physical = edge < static_cast<int32_t>(
                            producer_plan.input_quantities.size())
                        ? producer_plan.input_quantities[edge] : 0;
                    const int32_t input_good = edge < static_cast<int32_t>(
                            producer_plan.input_good_ids.size())
                        ? producer_plan.input_good_ids[edge] : -1;
                    int32_t derived_input_good = input_good;
                    // Shadow propagation must still expose the authored upstream
                    // requirement when the physical input lane is empty.
                    if (derived_input_good < 0 || physical <= 0) {
                        int64_t fallback_price = std::numeric_limits<int64_t>::max();
                        int64_t fallback_physical = 0;
                        for (int32_t candidate_index = input.candidate_begin;
                             candidate_index < input.candidate_begin +
                                 input.candidate_count;
                             ++candidate_index) {
                            const InputCandidate &candidate =
                                _building_input_candidates[candidate_index];
                            if (!good_input_candidate_available(
                                    cell, candidate.good_id, true)) continue;
                            const int64_t candidate_physical = mul_div_sat(
                                input.quantity, Q16_ONE,
                                std::max<int32_t>(1, candidate.efficiency_q16), sat);
                            const int64_t candidate_price = market_store().price[
                                market_store().index(market, candidate.good_id)];
                            if (candidate_price < fallback_price) {
                                fallback_price = candidate_price;
                                derived_input_good = candidate.good_id;
                                fallback_physical = std::max<int64_t>(
                                    1, candidate_physical);
                            }
                        }
                        physical = fallback_physical;
                    }
                    if (derived_input_good < 0 || physical <= 0) continue;
                    // 原料链可以回到工具等祖先商品；已展开的节点不能再次
                    // 形成需求，否则工具→燧石→工具会自我放大。
                    if (visit_stamp[derived_input_good] == visit) continue;
                    int64_t derived = mul_div_sat(
                        entry.needed, physical, output_qty, sat);
                    derived = mul_div_sat(derived,
                        std::clamp<int64_t>(input.required_q16, 0, Q16_ONE),
                        Q16_ONE, sat);
                    if (derived <= 0) continue;
                    out.goods.push_back(derived_input_good);
                    out.quantities.push_back(derived);
                    // Leontief shadow value: the downstream output price scaled
                    // by this input's share of the recipe. It is a damped
                    // price-adjustment reference for an input that has no
                    // producer (and hence no observed cost anchor), not a
                    // claim about the input's real production cost.
                    int64_t shadow_anchor = 0;
                    if (derived_price_conduction_enabled() &&
                        entry.good >= 0 && entry.good < good_count) {
                        const int64_t downstream_index =
                            market_store().index(market, entry.good);
                        if (downstream_index >= 0) {
                            const int64_t downstream_price = std::max<int64_t>(
                                1, market_store().price[downstream_index]);
                            shadow_anchor = mul_div_sat(
                                downstream_price, derived,
                                std::max<int64_t>(1, entry.needed), sat);
                            shadow_anchor = mul_div_sat(
                                shadow_anchor,
                                std::clamp<int64_t>(
                                    _derived_shadow_anchor_weight_q16, 0, Q16_ONE),
                                Q16_ONE, sat);
                            shadow_anchor = std::clamp<int64_t>(
                                shadow_anchor, 0,
                                static_cast<int64_t>(
                                    std::numeric_limits<int32_t>::max()));
                        }
                    }
                    out.anchors.push_back(shadow_anchor);
                    // 下游未建厂时也要继续展开原料配方；只写一层信号会
                    // 让采集→石器的需求永远到不了燧石。
                    enqueue(derived_input_good, derived);
                }
            }
        }
        EconomyCostProbe::record("derived.task_ms", _current_day.get(),
                                 elapsed_ms(task_started));
        if (derived_trace) {
            const int64_t end_ns = trace_now_ns();
            int64_t previous_end = derived_trace_end_max_ns.load();
            while (end_ns > previous_end &&
                   !derived_trace_end_max_ns.compare_exchange_weak(
                       previous_end, end_ns)) {
            }
            const auto task_us = std::chrono::duration_cast<std::chrono::microseconds>(
                Clock::now() - task_started).count();
            derived_trace_task_us.fetch_add(task_us, std::memory_order_relaxed);
            derived_trace_task_cpu_us.fetch_add(
                startup_probe_thread_cpu_us() - task_cpu_started,
                std::memory_order_relaxed);
            int32_t trace_max =
                derived_trace_max_conc.load(std::memory_order_relaxed);
            while (task_active > trace_max &&
                   !derived_trace_max_conc.compare_exchange_weak(
                       trace_max, task_active, std::memory_order_relaxed)) {
            }
        }
        derived_task_active.fetch_sub(1, std::memory_order_relaxed);
    };
    const auto derived_dispatch_started = Clock::now();
    const std::clock_t derived_trace_cpu_begin =
        derived_trace ? std::clock() : 0;
    if (derived_trace) {
        derived_trace_start_ns.store(0);
        derived_trace_start_max_ns.store(0);
        derived_trace_end_max_ns.store(0);
    }
    const int64_t derived_trace_pcpu_begin =
        derived_trace ? startup_probe_process_cpu_us() : 0;
    if (tasks > 1) {
        EconomyCostProbe parallel_probe("derived.parallel", _current_day.get(), cells);
        // Equal cell-count split measured best in the 2026-10-19 task sweeps
        // (weighted partitioning showed no reliable gain and was reverted).
        parallel_for_range("pk_economy_derived_refresh", cells, tasks, 2,
                           compute_range);
        EconomyCostProbe::record("derived.task_max_concurrency",
                                 _current_day.get(), 0.0,
                                 static_cast<uint64_t>(derived_task_max.load()));
    } else {
        EconomyCostProbe replay_probe("derived.replay", _current_day.get(), cells);
        compute_range(0, cells);
    }
    if (derived_trace) {
        const auto wall_us = std::chrono::duration_cast<std::chrono::microseconds>(
            Clock::now() - derived_dispatch_started).count();
        const double cpu_ms = static_cast<double>(
            std::clock() - derived_trace_cpu_begin) * 1000.0 /
            static_cast<double>(CLOCKS_PER_SEC);
        const double pcpu_ms = static_cast<double>(
            startup_probe_process_cpu_us() - derived_trace_pcpu_begin) / 1000.0;
        const double tcpu_ms = static_cast<double>(
            derived_trace_task_cpu_us.load(std::memory_order_relaxed)) / 1000.0;
        std::fprintf(stderr,
            "[derived-pass] day=%lld tasks=%d cells=%d max_conc=%d "
            "wall_us=%lld task_us=%lld cpu_ms=%.2f pcpu_ms=%.2f tcpu_ms=%.2f\n",
            static_cast<long long>(_current_day.get()), tasks, cells,
            derived_trace_max_conc.load(std::memory_order_relaxed),
            static_cast<long long>(wall_us),
            static_cast<long long>(derived_trace_task_us.load(
                std::memory_order_relaxed)),
            cpu_ms, pcpu_ms, tcpu_ms);
        const int64_t base_ns = derived_trace_start_ns.load();
        if (base_ns > 0) {
            std::fprintf(stderr,
                "[derived-timeline] day=%lld start_max_us=%lld end_max_us=%lld\\n",
                static_cast<long long>(_current_day.get()),
                static_cast<long long>(
                    (derived_trace_start_max_ns.load() - base_ns) / 1000),
                static_cast<long long>(
                    (derived_trace_end_max_ns.load() - base_ns) / 1000));
            std::fflush(stderr);
        }
        derived_trace_task_us.store(0, std::memory_order_relaxed);
        derived_trace_task_cpu_us.store(0, std::memory_order_relaxed);
        derived_trace_max_conc.store(0, std::memory_order_relaxed);
    }
    if (derived_spread_active) {
        int32_t refreshed_cells = 0;
        for (int32_t relative = 0; relative < cells; ++relative) {
            if (!derived_spread_refresh_all &&
                (relative % track_b_derived_spread) != derived_spread_phase)
                continue;
            const DerivedCellWork &work_item = cell_work[static_cast<size_t>(relative)];
            TrackBDerivedCellWork &cached =
                _track_b_derived_cell_cache[static_cast<size_t>(relative)];
            cached.goods = work_item.goods;
            cached.quantities = work_item.quantities;
            cached.anchors = work_item.anchors;
            cached.edges = work_item.edges;
            cached.startup_calls = work_item.startup_calls;
            cached.enqueued_goods = work_item.enqueued_goods;
            cached.seeded = work_item.seeded;
            ++refreshed_cells;
        }
        _track_b_derived_cell_cache_day = _current_day.get();
        EconomyCostProbe::record("derived.track_b_spread_cells",
                                 _current_day.get(), 0.0,
                                 static_cast<uint64_t>(refreshed_cells));
    }
    uint64_t derived_seed_cells = 0;
    uint64_t derived_enqueued_goods = 0;
    uint64_t derived_startup_calls = 0;
    {
        // Ordered merge: same cell order, same per-cell BFS order and the same
        // deferred ensure_market_signal_index call sequence as the serial
        // implementation, so the derived vector, lanes/total counters and the
        // appended signal lanes are bit-identical.
        EconomyCostProbe merge_probe("derived.merge", _current_day.get(), cells);
        for (int32_t relative = 0; relative < cells; ++relative) {
            const bool use_cached = derived_spread_active &&
                !derived_spread_refresh_all &&
                (relative % track_b_derived_spread) != derived_spread_phase;
            const DerivedCellWork &out = use_cached
                ? _track_b_derived_cell_cache[static_cast<size_t>(relative)]
                : cell_work[relative];
            if (!out.seeded) continue;
            ++derived_seed_cells;
            derived_enqueued_goods += out.enqueued_goods;
            derived_startup_calls += out.startup_calls;
            _derived_business_demand_edges = saturating_add(
                _derived_business_demand_edges, out.edges, _saturation_count);
            const int32_t cell = _economy_live_cells[relative];
            for (size_t index = 0; index < out.goods.size(); ++index) {
                const int32_t signal = ensure_market_signal_index(
                    cell, out.goods[index]);
                if (signal < 0) continue;
                if (signal >= static_cast<int32_t>(
                        _epoch_derived_business_demand.size())) {
                    _epoch_derived_business_demand.resize(
                        _market_signals.good_ids.size(), 0);
                }
                if (derived_price_conduction_enabled()) {
                    if (signal >= static_cast<int32_t>(
                            _epoch_derived_anchor_price.size())) {
                        _epoch_derived_anchor_price.resize(
                            _market_signals.good_ids.size(), 0);
                    }
                    if (index < out.anchors.size() && out.anchors[index] > 0) {
                        _epoch_derived_anchor_price[signal] = std::max(
                            _epoch_derived_anchor_price[signal],
                            out.anchors[index]);
                    }
                }
                const int64_t before = _epoch_derived_business_demand[signal];
                _epoch_derived_business_demand[signal] = saturating_add(
                    before, out.quantities[index], _saturation_count);
                if (before <= 0 &&
                    _epoch_derived_business_demand[signal] > 0) {
                    ++_derived_business_demand_lanes;
                }
                _derived_business_demand_total = saturating_add(
                    _derived_business_demand_total, out.quantities[index],
                    _saturation_count);
            }
        }
    }
    ++_derived_snapshot_generation;
    uint64_t derived_hash = 14695981039346656037ull;
    auto mix = [&](uint64_t value) {
        derived_hash ^= value;
        derived_hash *= 1099511628211ull;
    };
    mix(static_cast<uint64_t>(_derived_snapshot_generation));
    mix(static_cast<uint64_t>(_derived_business_demand_total));
    mix(static_cast<uint64_t>(_derived_business_demand_lanes));
    for (size_t i = 0; i < _epoch_derived_business_demand.size(); ++i) {
        if (_epoch_derived_business_demand[i] == 0) continue;
        mix(static_cast<uint64_t>(i));
        mix(static_cast<uint64_t>(_epoch_derived_business_demand[i]));
    }
    _derived_snapshot_hash = derived_hash;
    if (track_b_enabled && track_b_derived_spread <= 1 &&
        track_b_derived_cadence > 1) {
        _track_b_derived_carry = _epoch_derived_business_demand;
        _track_b_derived_anchor_carry = _epoch_derived_anchor_price;
    }
    // Deterministic work counters for the optimization gates. Aggregated by
    // EconomyCostProbe into one row per day, so this is cheap.
    EconomyCostProbe::record("derived.seed_cells", _current_day.get(), 0.0,
        derived_seed_cells);
    EconomyCostProbe::record("derived.enqueued_goods", _current_day.get(), 0.0,
        derived_enqueued_goods);
    EconomyCostProbe::record("derived.startup_calls", _current_day.get(), 0.0,
        derived_startup_calls);
}

} // namespace pk
