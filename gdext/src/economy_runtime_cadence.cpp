#include "economy_runtime.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;

namespace {

constexpr double kCadenceEmaAlpha = 0.35;
constexpr double kCadenceMsQuantum = 0.1;
constexpr double kColdStartKnivesPerDay = 64.0;
constexpr double kDenserSlack = 1.25;
constexpr int64_t kFixedStageMargin = 4;
constexpr int64_t kBuildingMarketScans = 2;

int64_t ceil_div_nonneg(int64_t value, int64_t divisor) {
    if (value <= 0) return 0;
    divisor = std::max<int64_t>(1, divisor);
    return (value + divisor - 1) / divisor;
}

int32_t clamp_i32(int64_t value, int32_t lo, int32_t hi) {
    return static_cast<int32_t>(std::clamp<int64_t>(value, lo, hi));
}

int64_t align_cycle_start(int64_t last_day, int32_t cycle) {
    cycle = std::max(1, cycle);
    if (last_day < 0) return 0;
    const int64_t phase = ((last_day % cycle) + cycle) % cycle;
    return last_day - phase;
}

const char *cadence_reason_name(int32_t reason) {
    switch (reason) {
    case 1: return "cold_start";
    case 2: return "workload";
    case 3: return "machine_timing";
    case 4: return "hysteresis";
    default: return "hold";
    }
}

} // namespace

int32_t NativeEconomyRuntime::locked_market_cycle_days() const {
    return std::clamp(_locked_market_cycle_days, _min_epoch_days, _max_epoch_days);
}

int32_t NativeEconomyRuntime::locked_slow_cycle_days() const {
    return locked_plan_cycle_days();
}

int32_t NativeEconomyRuntime::locked_plan_cycle_days() const {
    return std::clamp(_locked_slow_cycle_days, SLOW_CYCLE_MIN_DAYS,
                      SLOW_CYCLE_MAX_DAYS);
}

int32_t NativeEconomyRuntime::locked_investment_cycle_days() const {
    return std::clamp(_locked_investment_cycle_days, _invest_cycle_min_days,
                      _invest_cycle_max_days);
}

int32_t NativeEconomyRuntime::cycle_phase(int64_t day, int64_t start,
                                          int32_t cycle) const {
    cycle = std::max(1, cycle);
    int64_t delta = day - start;
    int64_t mod = delta % static_cast<int64_t>(cycle);
    if (mod < 0) mod += cycle;
    return static_cast<int32_t>(mod);
}

bool NativeEconomyRuntime::market_in_workset(int32_t market, int64_t day) const {
    const int32_t n = locked_market_cycle_days();
    const int32_t bucket = ((market % n) + n) % n;
    return bucket == cycle_phase(day, _market_cycle_start_day, n);
}

bool NativeEconomyRuntime::cell_in_market_workset(int32_t cell,
                                                  int64_t day) const {
    const int32_t n = locked_market_cycle_days();
    const int32_t bucket = ((cell % n) + n) % n;
    return bucket == cycle_phase(day, _market_cycle_start_day, n);
}

bool NativeEconomyRuntime::cell_due_slow_review(int32_t cell,
                                                int64_t day) const {
    return cell_due_plan_review(cell, day);
}

bool NativeEconomyRuntime::cell_due_plan_review(int32_t cell,
                                                int64_t day) const {
    const int32_t p = locked_plan_cycle_days();
    const int32_t bucket = ((cell % p) + p) % p;
    if (bucket != cycle_phase(day, _slow_cycle_start_day, p)) return false;
    return cell_in_market_workset(cell, day);
}

bool NativeEconomyRuntime::cell_due_investment_review(int32_t cell,
                                                      int64_t day) const {
    const int32_t i = locked_investment_cycle_days();
    const int32_t bucket = ((cell % i) + i) % i;
    if (bucket != cycle_phase(day, _investment_cycle_start_day, i))
        return false;
    return cell_in_market_workset(cell, day);
}

void NativeEconomyRuntime::rebuild_economy_live_cells() {
    _economy_live_cells.clear();
    const int32_t page_count = static_cast<int32_t>(_population.page_cell.size());
    for (int32_t page = 0; page < page_count; ++page) {
        const int32_t cell = _population.page_cell[page];
        if (cell < 0 || cell >= _cell_count) continue;
        bool any_population = false;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            if (_population.population[slot] > 0) any_population = true;
        });
        if (any_population) _economy_live_cells.push_back(cell);
    }
    for (const int32_t cell : _building_active_cells) {
        if (cell >= 0 && cell < _cell_count)
            _economy_live_cells.push_back(cell);
    }
    for (const PendingConstruction &pending : _pending_construction) {
        if (pending.count > 0 && pending.cell >= 0 && pending.cell < _cell_count)
            _economy_live_cells.push_back(pending.cell);
    }
    std::sort(_economy_live_cells.begin(), _economy_live_cells.end());
    _economy_live_cells.erase(
        std::unique(_economy_live_cells.begin(), _economy_live_cells.end()),
        _economy_live_cells.end());
}

PackedInt32Array NativeEconomyRuntime::economy_live_cells_query() {
    rebuild_economy_live_cells();
    PackedInt32Array out;
    out.resize(static_cast<int32_t>(_economy_live_cells.size()));
    for (int32_t i = 0; i < static_cast<int32_t>(_economy_live_cells.size()); ++i)
        out[i] = _economy_live_cells[static_cast<size_t>(i)];
    return out;
}

int32_t NativeEconomyRuntime::workset_elapsed_days(int64_t day_index) const {
    int32_t elapsed = 1;
    bool any = false;
    const int32_t cap = MARKET_CYCLE_MAX_DAYS;
    for (const int32_t cell : _epoch_settlement_cells) {
        if (cell < 0 || cell >= _cell_count) continue;
        const int64_t last = cell < static_cast<int32_t>(
            _cell_last_settlement_day.size())
            ? _cell_last_settlement_day[cell] : day_index - 1;
        const int32_t cell_elapsed = clamp_i32(day_index - last, 1, cap);
        if (!any || cell_elapsed < elapsed) elapsed = cell_elapsed;
        any = true;
    }
    return any ? elapsed : 1;
}

int32_t NativeEconomyRuntime::knives_per_day(double ms_per_knife) const {
    const double target = std::max(0.1, _cadence_target_ms);
    if (!(ms_per_knife > 0.0) || !std::isfinite(ms_per_knife)) {
        return clamp_i32(static_cast<int64_t>(std::lround(kColdStartKnivesPerDay)),
                         1, 1000000);
    }
    const double raw = target / ms_per_knife;
    if (!std::isfinite(raw) || raw >= 1000000.0) return 1000000;
    return clamp_i32(static_cast<int64_t>(std::max(1.0, std::floor(raw))),
                     1, 1000000);
}

double NativeEconomyRuntime::quantized_ms_per_knife(double cycle_ms,
                                                    int32_t knives) const {
    if (!(cycle_ms > 0.0) || !std::isfinite(cycle_ms) || knives <= 0)
        return 0.0;
    const double raw = cycle_ms / static_cast<double>(std::max(1, knives));
    if (!std::isfinite(raw) || raw <= 0.0) return 0.0;
    return std::max(kCadenceMsQuantum,
                    std::round(raw / kCadenceMsQuantum) * kCadenceMsQuantum);
}

int32_t NativeEconomyRuntime::apply_cadence_hysteresis(int32_t current,
                                                       int32_t raw) const {
    if (raw >= current) return raw;
    return current;
}

int32_t NativeEconomyRuntime::snap_cycle_days(int32_t value, int32_t n,
                                              int32_t lo, int32_t hi) const {
    n = std::max(1, n);
    lo = std::max(1, lo);
    hi = std::max(lo, hi);
    value = std::clamp(value, lo, hi);
    if (n <= 1) return value;
    int32_t snapped = ((value + n - 1) / n) * n;
    if (snapped > hi) snapped = (hi / n) * n;
    if (snapped < lo) {
        snapped = ((lo + n - 1) / n) * n;
        if (snapped > hi) snapped = hi;
    }
    return std::clamp(snapped, lo, hi);
}

int32_t NativeEconomyRuntime::snap_slow_days_to_market_multiple(
        int32_t s, int32_t n) const {
    return snap_cycle_days(s, n, _slow_cycle_min_days, _slow_cycle_max_days);
}

int32_t NativeEconomyRuntime::longer_investment_cycle_days(
        int32_t plan_days, int32_t n, int32_t candidate) const {
    const int32_t lo = std::min(_invest_cycle_max_days,
        std::max(_invest_cycle_min_days, plan_days + 1));
    if (candidate <= plan_days) candidate = lo;
    return snap_cycle_days(candidate, n, lo, _invest_cycle_max_days);
}

void NativeEconomyRuntime::refresh_cadence_estimates() {
    rebuild_economy_live_cells();
    int32_t populated_markets = 0;
    const int32_t populated_cells = static_cast<int32_t>(_economy_live_cells.size());
    const int32_t market_count = std::max(0, _market.market_count);
    std::vector<uint8_t> market_seen(static_cast<size_t>(market_count), 0);
    const bool have_market_map =
        _market.cell_to_market.size() == static_cast<size_t>(_cell_count);
    for (const int32_t cell : _economy_live_cells) {
        if (!have_market_map) continue;
        const int32_t market = _market.cell_to_market[cell];
        if (market < 0 || market >= market_count) continue;
        if (market_seen[static_cast<size_t>(market)] != 0) continue;
        market_seen[static_cast<size_t>(market)] = 1;
        ++populated_markets;
    }
    if (!have_market_map) populated_markets = populated_cells;

    const int64_t cohorts = std::max<int64_t>(0, _population.active_count);
    const int32_t market_cap = std::max(1, std::min(_cells_per_slice, 128));
    const int64_t market_cell_slices = ceil_div_nonneg(populated_markets, market_cap);
    const int64_t cohort_budget = std::max<int64_t>(1, _target_cohorts_per_slice);
    const int64_t market_cohort_slices = ceil_div_nonneg(cohorts, cohort_budget);
    const int64_t market_knives = std::max(market_cell_slices, market_cohort_slices);

    int32_t populated_building_cells = 0;
    int64_t populated_building_groups = 0;
    const bool have_offsets =
        _building_cell_offsets.size() == static_cast<size_t>(_cell_count) + 1;
    for (const int32_t cell : _building_active_cells) {
        if (cell < 0 || cell >= _cell_count) continue;
        ++populated_building_cells;
        if (have_offsets) {
            populated_building_groups +=
                _building_cell_offsets[cell + 1] - _building_cell_offsets[cell];
        }
    }
    const int64_t building_cell_cap = std::max(1, _building_cells_per_slice);
    const int64_t building_group_cap = std::max(1, _building_groups_per_slice);
    const int64_t building_ranges = std::max(
        ceil_div_nonneg(populated_building_cells, building_cell_cap),
        ceil_div_nonneg(populated_building_groups, building_group_cap));

    const int64_t raw_market = market_knives +
        building_ranges * kBuildingMarketScans + kFixedStageMargin;
    _estimated_populated_market_knives = clamp_i32(raw_market, 1,
        std::numeric_limits<int32_t>::max());

    const int32_t plan_cell_cap = _building_plan_cells_per_slice_override > 0
        ? _building_plan_cells_per_slice_override
        : std::min(65536, std::max(1, _building_cells_per_slice) * 2);
    const int32_t plan_group_cap = _building_plan_cells_per_slice_override > 0
        ? _building_groups_per_slice
        : std::min(65536, std::max(1, _building_groups_per_slice) * 2);
    const int64_t plan_ranges = std::max(
        ceil_div_nonneg(populated_building_cells, std::max(1, plan_cell_cap)),
        ceil_div_nonneg(populated_building_groups, std::max(1, plan_group_cap)));
    const int64_t invest_ranges = ceil_div_nonneg(
        populated_cells, std::max(1, _investment_cells_per_slice));
    _estimated_slow_knives = clamp_i32(plan_ranges, 1,
        std::numeric_limits<int32_t>::max());
    _estimated_investment_knives = clamp_i32(invest_ranges, 1,
        std::numeric_limits<int32_t>::max());

    const int32_t n = std::max(1, locked_market_cycle_days());
    const int32_t p = std::max(1, locked_plan_cycle_days());
    const int32_t i = std::max(1, locked_investment_cycle_days());
    _estimated_market_slices_per_epoch = clamp_i32(
        ceil_div_nonneg(_estimated_populated_market_knives, n), 1,
        std::numeric_limits<int32_t>::max());
    _estimated_building_slices_per_epoch = clamp_i32(
        ceil_div_nonneg(building_ranges * kBuildingMarketScans, n) +
            ceil_div_nonneg(_estimated_slow_knives, p) +
            ceil_div_nonneg(_estimated_investment_knives, i),
        0, std::numeric_limits<int32_t>::max());
    _estimated_total_slices_per_epoch = clamp_i32(
        static_cast<int64_t>(_estimated_market_slices_per_epoch) +
            _estimated_building_slices_per_epoch,
        1, std::numeric_limits<int32_t>::max());
    _workload_deadline_feasible = true;
    _workload_cycle_clamped = false;
}

int32_t NativeEconomyRuntime::choose_locked_market_cycle_days(
        int32_t current_n) const {
    const int32_t min_n = std::max(_min_epoch_days, MARKET_CYCLE_MIN_DAYS);
    const int32_t max_n = std::min(_max_epoch_days, MARKET_CYCLE_MAX_DAYS);
    const int32_t m = std::max(1, _estimated_populated_market_knives);
    double ms_per_knife = _market_ms_per_knife_ema;
    if (_injected_cycle_market_ms >= 0.0) {
        ms_per_knife = quantized_ms_per_knife(_injected_cycle_market_ms, m);
    }
    const int32_t capacity = knives_per_day(ms_per_knife);
    const int32_t raw = clamp_i32(
        ceil_div_nonneg(m, std::max(1, capacity)), min_n, max_n);
    if (raw >= current_n) return raw;
    const double target = std::max(0.1, _cadence_target_ms);
    const double denser_budget =
        target * static_cast<double>(std::max(1, current_n - 1));
    const double needed = static_cast<double>(m) *
        std::max(ms_per_knife, kCadenceMsQuantum) * kDenserSlack;
    if (ms_per_knife <= 0.0 || needed <= denser_budget) return raw;
    return current_n;
}

int32_t NativeEconomyRuntime::choose_locked_cycle_days(
        int32_t current, int32_t n, int32_t knives, double ema,
        double injected_ms, int32_t lo, int32_t hi) const {
    const int32_t b = std::max(1, knives);
    lo = std::max(1, lo);
    hi = std::max(lo, hi);
    double ms_per_knife = ema;
    if (injected_ms >= 0.0) {
        ms_per_knife = quantized_ms_per_knife(injected_ms, b);
    }
    const int32_t capacity = knives_per_day(ms_per_knife);
    int32_t best = hi;
    for (int32_t s = lo; s <= hi; ++s) {
        if (n > 1 && (s % n) != 0) continue;
        if (ceil_div_nonneg(b, s) <= std::max(1, capacity)) {
            best = s;
            break;
        }
    }
    best = snap_cycle_days(best, n, lo, hi);
    if (best >= current) return best;
    const double target = std::max(0.1, _cadence_target_ms);
    const double denser_budget =
        target * static_cast<double>(std::max(1, current / std::max(1, n)));
    const double daily_knives = static_cast<double>(b) /
        static_cast<double>(std::max(1, best));
    const double needed = daily_knives *
        std::max(ms_per_knife, kCadenceMsQuantum) * kDenserSlack;
    if (ms_per_knife <= 0.0 || needed <= denser_budget) return best;
    return snap_cycle_days(current, n, lo, hi);
}

int32_t NativeEconomyRuntime::choose_locked_slow_cycle_days(
        int32_t current_s, int32_t n) const {
    return choose_locked_cycle_days(
        current_s, n, _estimated_slow_knives, _slow_ms_per_knife_ema,
        _injected_cycle_slow_ms, PLAN_CYCLE_MIN_DAYS, PLAN_CYCLE_MAX_DAYS);
}

int32_t NativeEconomyRuntime::choose_locked_investment_cycle_days(
        int32_t current_i, int32_t n, int32_t plan_days) const {
    const int32_t lo = std::min(_invest_cycle_max_days,
        std::max(_invest_cycle_min_days, plan_days + 1));
    return choose_locked_cycle_days(
        current_i, n, _estimated_investment_knives,
        _investment_ms_per_knife_ema, _injected_cycle_investment_ms,
        lo, _invest_cycle_max_days);
}

void NativeEconomyRuntime::apply_locked_slow_days() {
    _building_plan_days = locked_plan_cycle_days();
    _investment_review_days = locked_investment_cycle_days();
}

void NativeEconomyRuntime::lock_market_cycle(int64_t day_index) {
    refresh_cadence_estimates();
    const int32_t current = std::clamp(_locked_market_cycle_days,
                                       MARKET_CYCLE_MIN_DAYS,
                                       MARKET_CYCLE_MAX_DAYS);
    const bool had_timing = _market_ms_per_knife_ema > 0.0 ||
        _injected_cycle_market_ms >= 0.0;
    if (_cycle_market_ms_accum > 0.0 && _injected_cycle_market_ms < 0.0) {
        const double sample = quantized_ms_per_knife(
            _cycle_market_ms_accum, _estimated_populated_market_knives);
        if (sample > 0.0) {
            _market_ms_per_knife_ema = _market_ms_per_knife_ema <= 0.0
                ? sample
                : _market_ms_per_knife_ema * (1.0 - kCadenceEmaAlpha) +
                    sample * kCadenceEmaAlpha;
        }
    }
    const int32_t next = _forced_market_cycle_days > 0
        ? std::clamp(_forced_market_cycle_days, _min_epoch_days, _max_epoch_days)
        : choose_locked_market_cycle_days(current);
    if (!_cadence_initialized) _cadence_change_reason = 1;
    else if (next == current) _cadence_change_reason = 0;
    else if (!had_timing) _cadence_change_reason = 1;
    else if (next > current) _cadence_change_reason = 2;
    else _cadence_change_reason = 3;
    if (next < current && next == choose_locked_market_cycle_days(next) &&
        apply_cadence_hysteresis(current, next) == current) {
        _cadence_change_reason = 4;
    }
    _locked_market_cycle_days = next;
    _market_cycle_start_day = day_index;
    _cadence_machine_knives_per_day = knives_per_day(
        _injected_cycle_market_ms >= 0.0
            ? quantized_ms_per_knife(_injected_cycle_market_ms,
                                     _estimated_populated_market_knives)
            : _market_ms_per_knife_ema);
    _cycle_market_ms_accum = 0.0;
    _commit_lag_budget_days = std::max(0, _locked_market_cycle_days - 1);
}

void NativeEconomyRuntime::lock_slow_cycle(int64_t day_index) {
    lock_plan_cycle(day_index);
}

void NativeEconomyRuntime::lock_plan_cycle(int64_t day_index) {
    refresh_cadence_estimates();
    const int32_t n = locked_market_cycle_days();
    const int32_t current = locked_plan_cycle_days();
    if (_cycle_slow_ms_accum > 0.0 && _injected_cycle_slow_ms < 0.0) {
        const double sample = quantized_ms_per_knife(
            _cycle_slow_ms_accum, _estimated_slow_knives);
        if (sample > 0.0) {
            _slow_ms_per_knife_ema = _slow_ms_per_knife_ema <= 0.0
                ? sample
                : _slow_ms_per_knife_ema * (1.0 - kCadenceEmaAlpha) +
                    sample * kCadenceEmaAlpha;
        }
    }
    _locked_slow_cycle_days = _forced_slow_cycle_days > 0
        ? snap_cycle_days(_forced_slow_cycle_days, n,
                          PLAN_CYCLE_MIN_DAYS, PLAN_CYCLE_MAX_DAYS)
        : choose_locked_slow_cycle_days(current, n);
    const int32_t phase = cycle_phase(day_index, _market_cycle_start_day, n);
    _slow_cycle_start_day = day_index - phase;
    apply_locked_slow_days();
    _cadence_slow_knives_per_day = knives_per_day(
        _injected_cycle_slow_ms >= 0.0
            ? quantized_ms_per_knife(_injected_cycle_slow_ms,
                                     _estimated_slow_knives)
            : _slow_ms_per_knife_ema);
    _cycle_slow_ms_accum = 0.0;
    if (_forced_investment_cycle_days <= 0 &&
        locked_investment_cycle_days() <= locked_plan_cycle_days()) {
        lock_investment_cycle(day_index);
    }
}

void NativeEconomyRuntime::lock_investment_cycle(int64_t day_index) {
    refresh_cadence_estimates();
    const int32_t n = locked_market_cycle_days();
    const int32_t plan_days = locked_plan_cycle_days();
    const int32_t current = locked_investment_cycle_days();
    if (_cycle_investment_ms_accum > 0.0 &&
        _injected_cycle_investment_ms < 0.0) {
        const double sample = quantized_ms_per_knife(
            _cycle_investment_ms_accum, _estimated_investment_knives);
        if (sample > 0.0) {
            _investment_ms_per_knife_ema = _investment_ms_per_knife_ema <= 0.0
                ? sample
                : _investment_ms_per_knife_ema * (1.0 - kCadenceEmaAlpha) +
                    sample * kCadenceEmaAlpha;
        }
    }
    _locked_investment_cycle_days = _forced_investment_cycle_days > 0
        ? snap_cycle_days(_forced_investment_cycle_days, n,
                          _invest_cycle_min_days, _invest_cycle_max_days)
        : choose_locked_investment_cycle_days(current, n, plan_days);
    const int32_t phase = cycle_phase(day_index, _market_cycle_start_day, n);
    _investment_cycle_start_day = day_index - phase;
    apply_locked_slow_days();
    _cadence_investment_knives_per_day = knives_per_day(
        _injected_cycle_investment_ms >= 0.0
            ? quantized_ms_per_knife(_injected_cycle_investment_ms,
                                     _estimated_investment_knives)
            : _investment_ms_per_knife_ema);
    _cycle_investment_ms_accum = 0.0;
}

void NativeEconomyRuntime::maybe_lock_cadence_cycles(int64_t day_index) {
    if (!_cadence_initialized) {
        lock_market_cycle(day_index);
        lock_plan_cycle(day_index);
        lock_investment_cycle(day_index);
        _cadence_initialized = true;
        return;
    }
    const int32_t n = locked_market_cycle_days();
    if (day_index >= _market_cycle_start_day + n) {
        lock_market_cycle(day_index);
    }
    const int32_t p = locked_plan_cycle_days();
    if (day_index >= _slow_cycle_start_day + p) {
        lock_plan_cycle(day_index);
    }
    const int32_t i = locked_investment_cycle_days();
    if (day_index >= _investment_cycle_start_day + i) {
        lock_investment_cycle(day_index);
    }
}

void NativeEconomyRuntime::note_completed_epoch_cadence_ms() {
    const CompletedEpochPerf &perf = _last_completed_perf;
    if (!perf.valid) return;
    const double market_ms =
        perf.building_employment_ms + perf.building_production_ms +
        perf.building_production_worker_ms + perf.building_production_merge_ms +
        perf.household_market_worker_ms + perf.household_market_prepare_ms +
        perf.household_market_merge_ms +
        perf.household_market_merge_aggregate_ms +
        perf.household_market_merge_trade_ms +
        perf.aggregate_publish_ms + perf.aggregate_audit_ms;
    const double plan_ms =
        perf.building_plan_ms + perf.building_plan_evaluate_ms +
        perf.building_plan_reserve_ms;
    const double investment_ms =
        perf.building_investment_ms + perf.investment_evaluate_ms +
        perf.investment_allocate_ms;
    if (std::isfinite(market_ms) && market_ms > 0.0)
        _cycle_market_ms_accum += market_ms;
    if (std::isfinite(plan_ms) && plan_ms > 0.0)
        _cycle_slow_ms_accum += plan_ms;
    if (std::isfinite(investment_ms) && investment_ms > 0.0)
        _cycle_investment_ms_accum += investment_ms;
}

void NativeEconomyRuntime::synthesize_cadence_locks_from_legacy_save() {
    _locked_market_cycle_days = MARKET_CYCLE_MAX_DAYS;
    _market_cycle_start_day = align_cycle_start(
        _last_committed_day, _locked_market_cycle_days);
    _locked_slow_cycle_days = snap_slow_days_to_market_multiple(
        std::clamp(_building_plan_days, _slow_cycle_min_days,
                   _slow_cycle_max_days),
        _locked_market_cycle_days);
    _slow_cycle_start_day = align_cycle_start(
        _last_committed_day, _locked_slow_cycle_days);
    _locked_investment_cycle_days = longer_investment_cycle_days(
        locked_plan_cycle_days(), _locked_market_cycle_days,
        _investment_review_days);
    _investment_cycle_start_day = align_cycle_start(
        _last_committed_day, _locked_investment_cycle_days);
    apply_locked_slow_days();
    _cadence_initialized = true;
    _cadence_change_reason = 0;
    _cycle_market_ms_accum = 0.0;
    _cycle_slow_ms_accum = 0.0;
    _cycle_investment_ms_accum = 0.0;
}

int32_t NativeEconomyRuntime::choose_epoch_days(int64_t cohorts) {
    (void)cohorts;
    refresh_cadence_estimates();
    if (!_cadence_initialized) {
        lock_market_cycle(std::max<int64_t>(0, _last_committed_day + 1));
        lock_plan_cycle(_market_cycle_start_day);
        lock_investment_cycle(_market_cycle_start_day);
        _cadence_initialized = true;
    }
    return locked_market_cycle_days();
}

void NativeEconomyRuntime::write_cadence_report(Dictionary &out) const {
    const int32_t n = locked_market_cycle_days();
    const int32_t p = locked_plan_cycle_days();
    const int32_t i = locked_investment_cycle_days();
    const int64_t day = _epoch_active ? _sample_day :
        (_current_day >= 0 ? _current_day : 0);
    const int32_t market_remaining = _cadence_initialized
        ? std::max(0, static_cast<int32_t>(
            _market_cycle_start_day + n - day))
        : n;
    const int32_t plan_remaining = _cadence_initialized
        ? std::max(0, static_cast<int32_t>(
            _slow_cycle_start_day + p - day))
        : p;
    const int32_t investment_remaining = _cadence_initialized
        ? std::max(0, static_cast<int32_t>(
            _investment_cycle_start_day + i - day))
        : i;
    out["settlement_mode"] = "locked_cycle";
    out["market_cycle_days"] = n;
    out["epoch_days"] = _epoch_days;
    out["market_configured_cycle_days"] = _configured_epoch_days;
    out["market_min_cycle_days"] = _min_epoch_days;
    out["market_max_cycle_days"] = _max_epoch_days;
    out["locked_market_cycle_days"] = n;
    out["market_cycle_start_day"] = _market_cycle_start_day;
    out["market_cycle_days_remaining"] = market_remaining;
    out["locked_slow_cycle_days"] = p;
    out["locked_plan_cycle_days"] = p;
    out["slow_cycle_start_day"] = _slow_cycle_start_day;
    out["plan_cycle_start_day"] = _slow_cycle_start_day;
    out["slow_cycle_days_remaining"] = plan_remaining;
    out["plan_cycle_days_remaining"] = plan_remaining;
    out["locked_investment_cycle_days"] = i;
    out["investment_cycle_start_day"] = _investment_cycle_start_day;
    out["investment_cycle_days_remaining"] = investment_remaining;
    out["building_plan_days"] = _building_plan_days;
    out["investment_review_days"] = _investment_review_days;
    out["settlement_phase"] = _rolling_phase;
    out["settlement_phase_count"] = n;
    out["cadence_populated_knives"] = _estimated_populated_market_knives;
    out["cadence_slow_knives"] = _estimated_slow_knives;
    out["cadence_plan_knives"] = _estimated_slow_knives;
    out["cadence_investment_knives"] = _estimated_investment_knives;
    out["cadence_target_ms"] = _cadence_target_ms;
    out["cadence_market_ms_per_knife"] =
        _injected_cycle_market_ms >= 0.0
            ? quantized_ms_per_knife(_injected_cycle_market_ms,
                                     _estimated_populated_market_knives)
            : _market_ms_per_knife_ema;
    out["cadence_slow_ms_per_knife"] =
        _injected_cycle_slow_ms >= 0.0
            ? quantized_ms_per_knife(_injected_cycle_slow_ms,
                                     _estimated_slow_knives)
            : _slow_ms_per_knife_ema;
    out["cadence_plan_ms_per_knife"] = out["cadence_slow_ms_per_knife"];
    out["cadence_investment_ms_per_knife"] =
        _injected_cycle_investment_ms >= 0.0
            ? quantized_ms_per_knife(_injected_cycle_investment_ms,
                                     _estimated_investment_knives)
            : _investment_ms_per_knife_ema;
    out["cadence_machine_knives_per_day"] = _cadence_machine_knives_per_day;
    out["cadence_slow_knives_per_day"] = _cadence_slow_knives_per_day;
    out["cadence_plan_knives_per_day"] = _cadence_slow_knives_per_day;
    out["cadence_investment_knives_per_day"] =
        _cadence_investment_knives_per_day;
    out["economy_live_cells"] = static_cast<int32_t>(_economy_live_cells.size());
    out["cadence_change_reason"] = cadence_reason_name(_cadence_change_reason);
    out["cadence_timing_injected"] = _injected_cycle_market_ms >= 0.0 ||
        _injected_cycle_slow_ms >= 0.0 ||
        _injected_cycle_investment_ms >= 0.0;
    out["cadence_forced"] = _forced_market_cycle_days > 0 ||
        _forced_slow_cycle_days > 0 ||
        _forced_investment_cycle_days > 0;
    out["estimated_market_slices_per_epoch"] =
        _estimated_market_slices_per_epoch;
    out["estimated_building_slices_per_epoch"] =
        _estimated_building_slices_per_epoch;
    out["estimated_total_slices_per_epoch"] =
        _estimated_total_slices_per_epoch;
}

Dictionary NativeEconomyRuntime::inject_cadence_timing(double market_cycle_ms,
                                                       double plan_cycle_ms,
                                                       double investment_cycle_ms) {
    Dictionary out;
    _injected_cycle_market_ms = std::isfinite(market_cycle_ms)
        ? market_cycle_ms : -1.0;
    _injected_cycle_slow_ms = std::isfinite(plan_cycle_ms)
        ? plan_cycle_ms : -1.0;
    if (std::isfinite(investment_cycle_ms) && investment_cycle_ms >= 0.0) {
        _injected_cycle_investment_ms = investment_cycle_ms;
    } else {
        _injected_cycle_investment_ms = _injected_cycle_slow_ms;
    }
    refresh_cadence_estimates();
    _cadence_machine_knives_per_day = knives_per_day(
        _injected_cycle_market_ms >= 0.0
            ? quantized_ms_per_knife(_injected_cycle_market_ms,
                                     _estimated_populated_market_knives)
            : _market_ms_per_knife_ema);
    _cadence_slow_knives_per_day = knives_per_day(
        _injected_cycle_slow_ms >= 0.0
            ? quantized_ms_per_knife(_injected_cycle_slow_ms,
                                     _estimated_slow_knives)
            : _slow_ms_per_knife_ema);
    _cadence_investment_knives_per_day = knives_per_day(
        _injected_cycle_investment_ms >= 0.0
            ? quantized_ms_per_knife(_injected_cycle_investment_ms,
                                     _estimated_investment_knives)
            : _investment_ms_per_knife_ema);
    out["ok"] = true;
    out["injected_market_cycle_ms"] = _injected_cycle_market_ms;
    out["injected_slow_cycle_ms"] = _injected_cycle_slow_ms;
    out["injected_plan_cycle_ms"] = _injected_cycle_slow_ms;
    out["injected_investment_cycle_ms"] = _injected_cycle_investment_ms;
    write_cadence_report(out);
    return out;
}

} // namespace pk
