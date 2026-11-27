#include "economy_runtime.h"

#include <algorithm>
#include <cmath>

namespace pk {

using namespace godot;

namespace {

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

void NativeEconomyRuntime::write_cadence_report(Dictionary &out) const {
    const int32_t n = locked_market_cycle_days();
    const int32_t p = locked_plan_cycle_days();
    const int32_t i = locked_investment_cycle_days();
    const int64_t day = _epoch_active ? _sample_day :
        (_current_day.get() >= 0 ? _current_day.get() : 0);
    const int32_t market_remaining = _cadence_initialized
        ? std::max(0, static_cast<int32_t>(
            _market_cycle_start_day.get() + n - day))
        : n;
    const int32_t plan_remaining = _cadence_initialized
        ? std::max(0, static_cast<int32_t>(
            _slow_cycle_start_day.get() + p - day))
        : p;
    const int32_t investment_remaining = _cadence_initialized
        ? std::max(0, static_cast<int32_t>(
            _investment_cycle_start_day.get() + i - day))
        : i;
    out["settlement_mode"] = "locked_cycle";
    out["market_cycle_days"] = n;
    out["epoch_days"] = _epoch_days.get();
    out["epoch_elapsed_days_max"] = _epoch_elapsed_days_max;
    out["epoch_elapsed_days_spread_cells"] = _epoch_elapsed_days_spread_cells;
    out["epoch_elapsed_days_lost"] = _epoch_elapsed_days_lost;
    out["total_elapsed_days_lost"] = _total_elapsed_days_lost;
    out["peak_elapsed_days_spread_cells"] = _peak_elapsed_days_spread_cells;
    out["tier_t0_cells"] = _tier_histogram[0];
    out["tier_t1_cells"] = _tier_histogram[1];
    out["tier_t2_cells"] = _tier_histogram[2];
    out["tier_t3_cells"] = _tier_histogram[3];
    out["tier_forced_wakes"] = _tier_forced_wakes;
    {
        static const char *kTierReasonNames[TIER_REASON_COUNT] = {
            "player_territory", "visible", "forced_wake", "effect_shortage",
            "essentials_shortage", "construction", "recent_change",
            "quiet_short", "quiet_with_buildings", "dormant", "out_of_range"};
        Dictionary reasons;
        for (int32_t i = 0; i < TIER_REASON_COUNT; ++i)
            reasons[String(kTierReasonNames[i])] = _tier_reason_histogram[i];
        out["tier_reasons"] = reasons;
    }
    out["tier_dormancy_cap_days"] = tier_review_period_days(3);
    out["market_configured_cycle_days"] = _configured_epoch_days;
    out["market_min_cycle_days"] = _min_epoch_days;
    out["market_max_cycle_days"] = _max_epoch_days;
    out["locked_market_cycle_days"] = n;
    out["market_cycle_start_day"] = _market_cycle_start_day.get();
    out["market_cycle_days_remaining"] = market_remaining;
    out["locked_slow_cycle_days"] = p;
    out["locked_plan_cycle_days"] = p;
    out["slow_cycle_start_day"] = _slow_cycle_start_day.get();
    out["plan_cycle_start_day"] = _slow_cycle_start_day.get();
    out["slow_cycle_days_remaining"] = plan_remaining;
    out["plan_cycle_days_remaining"] = plan_remaining;
    out["locked_investment_cycle_days"] = i;
    out["investment_cycle_start_day"] = _investment_cycle_start_day.get();
    out["investment_cycle_days_remaining"] = investment_remaining;
    out["building_plan_days"] = _building_plan_days.get();
    out["investment_review_days"] = _investment_review_days.get();
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
    out["cadence_policy"] = "fixed_game_days";
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
