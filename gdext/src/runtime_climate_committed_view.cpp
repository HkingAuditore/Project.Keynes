#include "runtime_climate_authority.h"
#include <cassert>

namespace pk {
bool RuntimeClimateAuthority::copy_committed_view(
        int64_t day, uint32_t cells, size_t lane_size,
        RuntimeClimateCommittedView &out) const {
    const auto lane_ok = [lane_size](const auto &lane) { return lane.size() == lane_size; };
    if (_store.committed_day != day || _store.cell_count != cells ||
        !lane_ok(_store.temperature) || !lane_ok(_store.temperature_30d_ema) ||
        !lane_ok(_store.moisture) || !lane_ok(_store.plant_available_water) ||
        !lane_ok(_store.weather_precipitation) || !lane_ok(_store.snow_cover) ||
        !lane_ok(_store.weather_intensity) || !lane_ok(_store.temperature_365d_ema) ||
        !lane_ok(_store.weather_type) || !lane_ok(_store.cover)) return false;
    assert(!_plan_ready);
    out.generation = _store.generation;
    out.day = _store.committed_day;
    out.committed = !_plan_ready;
    out.fields[0] = _store.temperature;
    out.fields[1] = _store.temperature_30d_ema;
    out.fields[2] = _store.moisture;
    out.fields[3] = _store.plant_available_water;
    out.fields[4] = _store.weather_precipitation;
    out.fields[5] = _store.snow_cover;
    out.fields[6] = _store.weather_intensity;
    out.fields[7] = _store.temperature_365d_ema;
    out.categories[0] = _store.weather_type;
    out.categories[1] = _store.cover;
    if (lane_ok(_store.terrain)) out.categories[2] = _store.terrain;
    if (lane_ok(_store.vegetation)) out.categories[3] = _store.vegetation;
    return true;
}
} // namespace pk
