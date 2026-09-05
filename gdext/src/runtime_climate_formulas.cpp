#include "runtime_climate_formulas.h"

#include <cmath>

namespace pk::climate_formula {

bool self_test() noexcept {
    if (clamp01(-1.0f) != 0.0f || clamp01(2.0f) != 1.0f) return false;
    if (phase_progress(-1.0f) != 0.75f || phase_progress(4.0f) != 0.0f) return false;
    if (std::fabs(subsolar_lat_rad(0.0f, 23.5f) -
                  subsolar_lat_rad(2.0f, 23.5f)) < 1e-5f) return false;
    if (std::fabs(daily_insolation(0.5f, 0.0f, 23.5f) -
                  daily_insolation(0.5f, 2.0f, 23.5f)) > 1e-6f) return false;
    const float equator_day = day_length_norm(0.5f, 0.0f, 23.5f);
    if (equator_day <= 0.0f || equator_day >= 1.0f) return false;
    if (surface_absorbed_factor(false, 0.30f) != 1.0f ||
        surface_absorbed_factor(false, 0.0f) >= 1.0f ||
        surface_absorbed_factor(true, 0.0f) >= 1.0f) return false;
    if (compress_season_cooling(0.1f) != 0.1f) return false;
    if (compress_season_cooling(-0.13f) >= 0.0f) return false;
    if (signed_hydrology_contribution(-0.5f, 2.0f, 3.0f) != -1.5f ||
        signed_hydrology_contribution(0.5f, 2.0f, 3.0f) != 1.0f) return false;
    if (thermal_alpha_eff(0.0f, 10.0f) != 0.0f ||
        thermal_alpha_eff(1.0f, 10.0f) != 1.0f) return false;
    if (altitude_penalty(-1.0, 0.5) < 0.0 ||
        altitude_penalty(2.0, 0.5) > 1.0) return false;
    uint64_t rng = 0x243f6a8885a308d3ull;
    const float sample = normalized_rng(rng);
    return std::isfinite(sample) && sample >= 0.0f && sample <= 1.0f;
}

} // namespace pk::climate_formula
