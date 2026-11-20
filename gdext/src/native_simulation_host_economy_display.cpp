#include "runtime_economy_display.h"

#include "economy_api.h"
#include "native_simulation_host.h"
#include "runtime_day_tail.h"

#include <algorithm>
#include <limits>

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>

namespace pk {

godot::Dictionary RuntimeGdpDisplay::pack() const {
    godot::PackedInt32Array indices, days;
    godot::PackedInt64Array people;
    godot::PackedFloat64Array rate, total;
    godot::PackedFloat32Array series;
    for (const auto &[cell, value] : cells) {
        indices.push_back(cell);
        people.push_back(value.population);
        rate.push_back(value.per_day);
        total.push_back(value.accumulated);
    }
    for (const int32_t value : trend_days) days.push_back(value);
    for (const float value : trend) series.push_back(value);
    godot::Dictionary out;
    out["day"] = day;
    out["year_length"] = year_length;
    out["population"] = population;
    out["per_day"] = per_day;
    out["accumulated"] = accumulated;
    out["backfilled"] = backfilled;
    out["cells"] = indices;
    out["cell_population"] = people;
    out["cell_per_day"] = rate;
    out["cell_accumulated"] = total;
    out["trend_days"] = days;
    out["trend"] = series;
    return out;
}

std::shared_ptr<const RuntimeFiscalDisplay> NativeSimulationHost::capture_economy_display(
        int64_t day, int64_t year_length, RuntimeDayTail &tail,
        const RuntimeDayTail *previous) const {
    const auto handle = annual_country_handle();
    const auto slot = static_cast<uint32_t>(handle);
    const auto &country = tail.country.snapshot;
    if (handle == 0 || year_length <= 0 || _economy_production_runtime == nullptr ||
            !economy_worker_owns_execution() || !country ||
            slot >= country->country_cash.size() || slot >= country->country_generation.size() ||
            country->country_generation[slot] != static_cast<uint32_t>(handle >> 32u))
        return {};

    const auto prior = previous ? previous->gdp : nullptr;
    const bool same_history = prior && prior->country == handle && prior->year_length == year_length;
    auto gdp = same_history ? std::make_shared<RuntimeGdpDisplay>(*prior)
                            : std::make_shared<RuntimeGdpDisplay>();
    const auto year_start = day / year_length * year_length;
    const bool new_year = !same_history || gdp->day < year_start;
    const auto delta = day - (new_year ? year_start : gdp->day);
    if (new_year) {
        gdp->cells.clear();
        gdp->accumulated = 0.0;
        gdp->backfilled = delta > 1;
    }
    gdp->country = handle;
    gdp->day = day;
    gdp->year_length = year_length;
    gdp->population = 0;
    gdp->per_day = 0.0;
    for (auto &[cell, value] : gdp->cells) {
        value.population = 0;
        value.per_day = 0.0;
    }
    for (const auto &sample : economy_api::capture_settlement_output(
            *_economy_production_runtime, handle)) {
        auto &row = gdp->cells[sample.cell];
        row.population = sample.population;
        row.per_day = sample.per_day;
        row.accumulated += sample.per_day * double(delta);
        gdp->per_day += sample.per_day;
        gdp->population += sample.population;
    }
    gdp->accumulated += gdp->per_day * double(delta);
    gdp->trend_days.push_back(static_cast<int32_t>(day));
    gdp->trend.push_back(gdp->population > 0 ? float(gdp->per_day / double(gdp->population))
        : std::numeric_limits<float>::quiet_NaN());
    constexpr size_t trend_capacity = 60;
    if (gdp->trend.size() > trend_capacity) {
        gdp->trend.pop_front();
        gdp->trend_days.pop_front();
    }
    tail.gdp = std::move(gdp);

    auto fiscal = std::make_shared<RuntimeFiscalDisplay>();
    fiscal->cash = country->country_cash[slot];
    fiscal->fiscal = economy_api::fiscal_snapshot(*_economy_production_runtime, static_cast<int64_t>(handle));
    fiscal->fiscal["country_handle"] = static_cast<int64_t>(handle);
    return fiscal;
}

} // namespace pk
