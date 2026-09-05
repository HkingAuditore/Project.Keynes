#pragma once

// Deterministic, Godot-free climate math shared by the legacy native facade
// and the worker-side POD runtime. Keep operations in float where the
// production slot formula is float-based; callers that need double (for
// terrain generation) use the explicitly double helpers below.

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace pk::climate_formula {

constexpr float PI_F = 3.14159265358979323846f;
constexpr float TAU_F = 6.28318530717958647692f;

constexpr float ALBEDO_OCEAN = 0.08f;
constexpr float ALBEDO_LAND = 0.20f;
constexpr float ALBEDO_ICE = 0.62f;
constexpr float ICE_TEMP_LOW = 0.12f;
constexpr float ICE_TEMP_HIGH = 0.30f;
constexpr float WINTER_COOL_KNEE = 0.13f;
constexpr double ALT_PEN_LINEAR = 0.40;
constexpr double ALT_PEN_HIGH_LOW = 0.45;
constexpr double ALT_PEN_HIGH_HIGH = 1.00;
constexpr double ALT_PEN_HIGH_AMP = 0.22;
constexpr double ALT_PEN_ABS_ELEV_BLEND = 0.25;
constexpr double LAT_TEMP_CURVE_EXP = 1.3;

inline float clamp01(float value) noexcept {
    return value < 0.0f ? 0.0f : (value > 1.0f ? 1.0f : value);
}

inline float clamp(float value, float low, float high) noexcept {
    return value < low ? low : (value > high ? high : value);
}

inline float phase_progress(float season_phase) noexcept {
    float phase = std::fmod(season_phase, 4.0f);
    if (phase < 0.0f) phase += 4.0f;
    return phase * 0.25f;
}

inline float subsolar_lat_rad(float season_phase, float axial_tilt_deg) noexcept {
    return axial_tilt_deg * (PI_F / 180.0f) *
           std::cos(TAU_F * phase_progress(season_phase));
}

inline float sunset_hour_angle(float latitude_rad, float declination_rad) noexcept {
    if (std::fabs(declination_rad) <= 1e-6f) return PI_F * 0.5f;
    const float polar_test = -std::tan(latitude_rad) * std::tan(declination_rad);
    if (polar_test <= -1.0f) return PI_F;
    if (polar_test >= 1.0f) return 0.0f;
    return std::acos(polar_test);
}

// Production native Pass-A astronomical daily integral. The day-length
// amplitude parameter is retained for ABI compatibility because the existing
// formula intentionally does not use it.
inline float daily_insolation(float ny, float season_phase,
                              float axial_tilt_deg,
                              float day_length_amplitude = 0.35f) noexcept {
    (void)day_length_amplitude;
    const float latitude_rad = (ny - 0.5f) * PI_F;
    const float declination = subsolar_lat_rad(season_phase, axial_tilt_deg);
    const float hour_angle = sunset_hour_angle(latitude_rad, declination);
    if (hour_angle <= 1e-6f) return 0.0f;
    const float daily = hour_angle * std::sin(latitude_rad) * std::sin(declination) +
        std::cos(latitude_rad) * std::cos(declination) * std::sin(hour_angle);
    return clamp01(daily);
}

inline float day_length_norm(float ny, float season_phase,
                             float axial_tilt_deg) noexcept {
    const float latitude_rad = (ny - 0.5f) * PI_F;
    const float declination = subsolar_lat_rad(season_phase, axial_tilt_deg);
    return clamp01(sunset_hour_angle(latitude_rad, declination) / PI_F);
}

inline float annual_insolation_mean(float ny, float axial_tilt_deg,
                                    float day_length_amplitude = 0.35f) noexcept {
    constexpr int SAMPLES = 16;
    float sum = 0.0f;
    for (int sample = 0; sample < SAMPLES; ++sample) {
        const float phase = (static_cast<float>(sample) + 0.5f) *
            (4.0f / static_cast<float>(SAMPLES));
        sum += daily_insolation(ny, phase, axial_tilt_deg, day_length_amplitude);
    }
    return sum / static_cast<float>(SAMPLES);
}

inline float insolation_season_dev(float /*ny*/, float current,
                                   float annual_mean) noexcept {
    return current - annual_mean;
}

inline float smoothstep(float edge_low, float edge_high, float value) noexcept {
    // Preserve the conventional reversed-edge form used by the legacy
    // climate profile (smoothstep(high, low, value) means cold=1, warm=0).
    if (edge_high < edge_low)
        return 1.0f - smoothstep(edge_high, edge_low, value);
    if (edge_high == edge_low) return value < edge_low ? 0.0f : 1.0f;
    float t = (value - edge_low) / (edge_high - edge_low);
    t = clamp01(t);
    return t * t * (3.0f - 2.0f * t);
}

inline float surface_absorbed_factor(bool is_water, float annual_temperature) noexcept {
    const float base_albedo = is_water ? ALBEDO_OCEAN : ALBEDO_LAND;
    // Reverse smoothstep: cold annual climates are treated as persistently
    // ice-covered, while warm climates retain the base surface albedo.
    const float ice_weight = smoothstep(ICE_TEMP_HIGH, ICE_TEMP_LOW, annual_temperature);
    const float effective_albedo = base_albedo +
        (ALBEDO_ICE - base_albedo) * ice_weight;
    return (1.0f - effective_albedo) / (1.0f - ALBEDO_LAND);
}

inline float compress_season_cooling(float season_offset) noexcept {
    if (season_offset >= 0.0f) return season_offset;
    return -WINTER_COOL_KNEE *
        std::tanh(-season_offset / WINTER_COOL_KNEE);
}

inline float season_offset_continental(float insolation_amplitude_gain,
                                       bool is_water,
                                       float annual_temperature,
                                       float insolation_deviation,
                                       float land_continentality) noexcept {
    // Retained in the profile for compatibility; production deliberately does
    // not multiply the legacy season forcing by this parameter.
    (void)land_continentality;
    return compress_season_cooling(
        insolation_amplitude_gain *
        surface_absorbed_factor(is_water, annual_temperature) *
        insolation_deviation);
}

inline float thermal_alpha_eff(float alpha, float dt_days) noexcept {
    alpha = clamp(alpha, 0.0f, 1.0f);
    if (dt_days <= 1.0f) return alpha;
    return 1.0f - std::pow(1.0f - alpha, dt_days);
}

inline float signed_hydrology_contribution(float anomaly,
                                           float wet_weight,
                                           float dry_weight) noexcept {
    return anomaly * (anomaly < 0.0f ? dry_weight : wet_weight);
}

inline float plant_available_water(float moisture, float water_balance_30d,
                                   float soil_moisture,
                                   float water_balance_weight,
                                   float soil_buffer_weight,
                                   float drought_penalty) noexcept {
    return clamp(
        moisture + std::max(water_balance_30d, 0.0f) * water_balance_weight +
            std::max(soil_moisture, 0.0f) * soil_buffer_weight +
            std::min(water_balance_30d, 0.0f) * drought_penalty,
        0.0f, 1.0f);
}

inline double smoothstep_double(double edge_low, double edge_high,
                                double value) noexcept {
    if (edge_high <= edge_low) return value < edge_low ? 0.0 : 1.0;
    double t = (value - edge_low) / (edge_high - edge_low);
    if (t < 0.0) t = 0.0;
    else if (t > 1.0) t = 1.0;
    return t * t * (3.0 - 2.0 * t);
}

inline double clamp01_double(double value) noexcept {
    return value < 0.0 ? 0.0 : (value > 1.0 ? 1.0 : value);
}

inline double altitude_penalty_from_height(double height_norm) noexcept {
    const double h = clamp01_double(height_norm);
    return h * ALT_PEN_LINEAR +
        smoothstep_double(ALT_PEN_HIGH_LOW, ALT_PEN_HIGH_HIGH, h) * ALT_PEN_HIGH_AMP;
}

inline double land_height_for_temperature(double elevation,
                                           double sea_level) noexcept {
    const double denominator = (1.0 - sea_level) > 0.001
        ? (1.0 - sea_level) : 0.001;
    return clamp01_double((elevation - sea_level) / denominator);
}

inline double temperature_height_for_penalty(double elevation,
                                              double sea_level) noexcept {
    const double land_height = land_height_for_temperature(elevation, sea_level);
    const double absolute_elevation = clamp01_double(elevation);
    return land_height +
        (absolute_elevation - land_height) * ALT_PEN_ABS_ELEV_BLEND;
}

inline double altitude_penalty(double elevation, double sea_level) noexcept {
    return altitude_penalty_from_height(
        temperature_height_for_penalty(elevation, sea_level));
}

inline double lat_temp_bell(double lat_signed) noexcept {
    const double cosine = std::cos(lat_signed * 3.14159265358979323846 * 0.5);
    return std::pow(cosine < 0.0 ? 0.0 : cosine, LAT_TEMP_CURVE_EXP);
}

inline float normalized_rng(uint64_t &state) noexcept {
    state ^= state >> 12u;
    state ^= state << 25u;
    state ^= state >> 27u;
    const uint64_t value = state * 2685821657736338717ull;
    return static_cast<float>((value >> 40u) & 0xffffu) / 65535.0f;
}

bool self_test() noexcept;

} // namespace pk::climate_formula
