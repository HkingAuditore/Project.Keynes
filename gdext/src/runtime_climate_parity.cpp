#include "runtime_climate_parity.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>

namespace pk {

namespace {

// The parity reduction is its own versioned contract, so it keeps a local
// mixing scheme rather than sharing the one behind state_hash(). Changing
// either must not silently change the other.
constexpr uint64_t PARITY_OFFSET = 1469598103934665603ull;
constexpr uint64_t PARITY_PRIME = 1099511628211ull;

uint64_t mix(uint64_t hash, uint64_t value) noexcept {
    hash ^= value + 0x9e3779b97f4a7c15ull + (hash << 6u) + (hash >> 2u);
    return hash * PARITY_PRIME;
}

uint32_t float_bits(float value) noexcept {
    // Normalise the two encodings of zero so that a field written as -0.0f on
    // one side and 0.0f on the other is not reported as a divergence.
    if (value == 0.0f) value = 0.0f;
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

template <typename T>
uint64_t mix_vector(uint64_t hash, const std::vector<T> &values) noexcept {
    hash = mix(hash, static_cast<uint64_t>(values.size()));
    for (const T &value : values) hash = mix(hash, static_cast<uint64_t>(value));
    return hash;
}

uint64_t mix_float_vector(uint64_t hash, const std::vector<float> &values) noexcept {
    hash = mix(hash, static_cast<uint64_t>(values.size()));
    for (const float value : values) hash = mix(hash, float_bits(value));
    return hash;
}

void write_text(char *destination, size_t capacity, const char *source) {
    if (capacity == 0) return;
    size_t index = 0;
    if (source != nullptr) {
        for (; index + 1u < capacity && source[index] != '\0'; ++index)
            destination[index] = source[index];
    }
    for (; index < capacity; ++index) destination[index] = '\0';
}

using Store = RuntimeClimateStore;
constexpr auto F32 = RuntimeClimateParityKind::F32;
constexpr auto I32 = RuntimeClimateParityKind::I32;
constexpr auto U8 = RuntimeClimateParityKind::U8;
constexpr auto OK = RuntimeClimateParityComparability::COMPARABLE;
constexpr auto EXACT = RuntimeClimateParityTolerance::BITWISE;
constexpr auto SLICED = RuntimeClimateParityTolerance::SLICED;
constexpr auto CHAINED = RuntimeClimateParityTolerance::CHAINED;
constexpr auto MISMATCH = RuntimeClimateParityComparability::TYPE_MISMATCH;
constexpr auto NO_REF = RuntimeClimateParityComparability::NO_REFERENCE;

using Stage = RuntimeClimateStage;

// Declaration order matches RuntimeClimateStore so the two can be diffed by
// eye. It is part of the hash framing: reordering changes the result.
//
// The stage column names the *last* pass that writes the field within one
// simulated day. A field can therefore only reach parity once every stage up
// to and including that one agrees, which is what makes the divergence report
// readable as an ordered extraction plan.
const RuntimeClimateParityField FIELDS[] = {
    {"temperature", "temp_arr", F32, OK, CHAINED, Stage::CLIMATE_FEEDBACK, "", &Store::temperature, nullptr, nullptr},
    {"temperature_30d_ema", "temp_30d_arr", F32, OK, EXACT, Stage::PASS_A, "", &Store::temperature_30d_ema, nullptr, nullptr},
    {"temperature_365d_ema", "temp_365d_arr", F32, OK, EXACT, Stage::PASS_A, "", &Store::temperature_365d_ema, nullptr, nullptr},
    {"temperature_baseline", "temp_baseline_arr", F32, OK, EXACT, Stage::PASS_A, "", &Store::temperature_baseline, nullptr, nullptr},
    {"thermal_energy", "thermal_energy_arr", F32, OK, EXACT, Stage::PASS_A, "", &Store::thermal_energy, nullptr, nullptr},
    // Four passes write moisture: pass_a's relaxation, weather's direct-moisture
    // path, hydrology's segment G (the moisture_target sweep) and the feedback
    // pass, which is the last of them. STAGE_B_AFTER_HYDROLOGY is only the node
    // that hosts feedback, not a writer of its own, so attributing the field to
    // it named a stage that can never be the culprit. The three earlier writers
    // are separated by the production/worker stage masks, not by this column.
    {"moisture", "moisture_arr", F32, OK, CHAINED, Stage::CLIMATE_FEEDBACK, "", &Store::moisture, nullptr, nullptr},
    {"plant_available_water", "plant_available_water_arr", F32, OK, CHAINED, Stage::RUNTIME_HYDROLOGY, "", &Store::plant_available_water, nullptr, nullptr},
    {"water_balance_30d", "water_balance_30d_arr", F32, OK, CHAINED, Stage::RUNTIME_HYDROLOGY, "", &Store::water_balance_30d, nullptr, nullptr},
    {"weather_precipitation", "weather_precip_arr", F32, OK, SLICED, Stage::WEATHER, "", &Store::weather_precipitation, nullptr, nullptr},
    {"weather_intensity", "weather_intensity_arr", F32, OK, SLICED, Stage::WEATHER, "", &Store::weather_intensity, nullptr, nullptr},
    {"vapor", "weather_vapor_arr", F32, OK, SLICED, Stage::WEATHER, "", &Store::vapor, nullptr, nullptr},
    {"cloud_water", "weather_cloud_water_arr", F32, OK, SLICED, Stage::WEATHER, "", &Store::cloud_water, nullptr, nullptr},
    {"cloud_cover", "weather_cloud_arr", F32, OK, SLICED, Stage::WEATHER, "", &Store::cloud_cover, nullptr, nullptr},
    {"convergence", "weather_convergence_arr", F32, OK, EXACT, Stage::WIND_AIR, "", &Store::convergence, nullptr, nullptr},
    {"instability", "weather_instability_arr", F32, OK, SLICED, Stage::WEATHER, "", &Store::instability, nullptr, nullptr},
    {"weather_type", "weather_type_arr", U8, OK, SLICED, Stage::WEATHER, "", nullptr, nullptr, &Store::weather_type},
    // The transition animation is three quantities, not one. The store used to
    // carry a single uint8 "did the type change" flag, which was not the same
    // quantity as any of them and could only ever be excluded from the hash.
    {"weather_prev_type", "weather_prev_type_arr", U8, OK, SLICED, Stage::WEATHER, "", nullptr, nullptr, &Store::weather_prev_type},
    {"weather_target_type", "weather_target_type_arr", U8, OK, SLICED, Stage::WEATHER, "", nullptr, nullptr, &Store::weather_target_type},
    {"weather_transition_alpha", "weather_transition_alpha_arr", F32, OK, SLICED, Stage::WEATHER, "", &Store::weather_transition_alpha, nullptr, nullptr},
    // snow_cover 归 WEATHER 而不是 SEA_ICE，与 snowpack 同一次订正：pass_b 与
    // weather_distribute 都写它，而 sea_ice pass 只读（cell_snow_cover 在
    // run_sea_ice_daily_pass 里根本没解引用）。归属按"当天最后一个写者"取，也就是
    // run_weather_distribute_pass（world_ext_weather.cpp 里 SC[i] = snow_cover_now）。
    // 挂在 SEA_ICE 上会把一条 weather 的缺口报成海冰算法分叉，而 sea_ice 与
    // temperature 读 snow_cover，于是分叉矩阵里三行都指错了地方。
    {"snow_cover", "snow_cover_arr", F32, OK, SLICED, Stage::WEATHER, "", &Store::snow_cover, nullptr, nullptr},
    // pass_a accumulates it and run_weather_distribute_pass is the last writer.
    // run_runtime_hydrology_pass takes it as a read-only melt input (a const
    // pointer), so hydrology could never be the stage to extract for it.
    {"snowpack", "snowpack_arr", F32, OK, SLICED, Stage::WEATHER, "", &Store::snowpack, nullptr, nullptr},
    {"sea_ice", "sea_ice_frac_arr", F32, OK, EXACT, Stage::SEA_ICE, "", &Store::sea_ice, nullptr, nullptr},
    {"runoff", "surface_runoff_arr", F32, OK, CHAINED, Stage::RUNTIME_HYDROLOGY, "", &Store::runoff, nullptr, nullptr},
    {"groundwater", "groundwater_storage_arr", F32, OK, CHAINED, Stage::RUNTIME_HYDROLOGY, "", &Store::groundwater, nullptr, nullptr},
    {"river_storage", "river_storage_arr", F32, OK, CHAINED, Stage::RUNTIME_HYDROLOGY, "", &Store::river_storage, nullptr, nullptr},
    {"river_discharge", "river_discharge_arr", F32, OK, CHAINED, Stage::RUNTIME_HYDROLOGY, "", &Store::river_discharge, nullptr, nullptr},
    // map_data.gd declares no riparian_moisture_arr; the production reference
    // path reads it as an optional array and yields an empty one.
    {"riparian_moisture", "riparian_moisture_arr", F32, NO_REF, CHAINED, Stage::RUNTIME_HYDROLOGY,
     "map_data.gd declares no riparian_moisture_arr",
     &Store::riparian_moisture, nullptr, nullptr},
    {"vegetation_vitality", "vegetation_vitality_arr", F32, OK, EXACT, Stage::VEGETATION_DYNAMICS, "", &Store::vegetation_vitality, nullptr, nullptr},
    {"vegetation_growth_pressure", "vegetation_growth_pressure_arr", F32, OK, CHAINED, Stage::TRANSPIRATION, "", &Store::vegetation_growth_pressure, nullptr, nullptr},
    {"vegetation_heat_stress", "vegetation_heat_stress_arr", F32, OK, EXACT, Stage::VEGETATION_DYNAMICS, "", &Store::vegetation_heat_stress, nullptr, nullptr},
    {"vegetation_drought_stress", "vegetation_drought_stress_arr", F32, OK, EXACT, Stage::VEGETATION_DYNAMICS, "", &Store::vegetation_drought_stress, nullptr, nullptr},
    {"vegetation_cold_stress", "vegetation_cold_stress_arr", F32, OK, EXACT, Stage::VEGETATION_DYNAMICS, "", &Store::vegetation_cold_stress, nullptr, nullptr},
    {"vegetation_growth_streak", "vitality_high_streak_arr", I32, OK, EXACT, Stage::VEGETATION_DYNAMICS, "", nullptr, &Store::vegetation_growth_streak, nullptr},
    {"vegetation_drought_streak", "vitality_low_streak_arr", I32, OK, EXACT, Stage::VEGETATION_DYNAMICS, "", nullptr, &Store::vegetation_drought_streak, nullptr},
    // The production side fills a continuous regeneration score, while the
    // worker keeps a boolean candidate flag. These are not the same quantity.
    {"vegetation_succession_candidate", "vegetation_regen_score_arr", U8, MISMATCH, EXACT, Stage::VEGETATION_DYNAMICS,
     "store is a uint8 flag but vegetation_regen_score_arr is a float score",
     nullptr, nullptr, &Store::vegetation_succession_candidate},
};

const char *const STAGE_NAMES[] = {
    "PASS_A",
    "PASS_B",
    "OCEAN_WATER",
    "OCEAN_LAND",
    "WIND_AIR",
    "WIND_SURFACE",
    "SEA_ICE",
    "TRANSPIRATION",
    "ALBEDO",
    "VEGETATION_DYNAMICS",
    "CLIMATE_FEEDBACK",
    "WEATHER",
    "RUNTIME_HYDROLOGY",
    "STAGE_B_AFTER_HYDROLOGY",
};

static_assert(sizeof(STAGE_NAMES) / sizeof(STAGE_NAMES[0]) ==
                  RUNTIME_CLIMATE_STAGE_COUNT,
              "climate stage name table is out of sync with RuntimeClimateStage");

constexpr size_t FIELD_COUNT = sizeof(FIELDS) / sizeof(FIELDS[0]);

} // namespace

const char *runtime_climate_stage_name(RuntimeClimateStage stage) {
    const size_t index = static_cast<size_t>(stage);
    return index < RUNTIME_CLIMATE_STAGE_COUNT ? STAGE_NAMES[index] : "UNKNOWN";
}

double runtime_climate_parity_tolerance_band(RuntimeClimateParityTolerance tol) {
    switch (tol) {
    case RuntimeClimateParityTolerance::SLICED:  return 1e-3;
    case RuntimeClimateParityTolerance::CHAINED: return 5e-3;
    case RuntimeClimateParityTolerance::BITWISE: break;
    }
    return 0.0;
}

size_t runtime_climate_parity_field_count() { return FIELD_COUNT; }

const RuntimeClimateParityField *runtime_climate_parity_fields() { return FIELDS; }

const RuntimeClimateParityField *runtime_climate_parity_field(const char *name) {
    if (name == nullptr) return nullptr;
    for (size_t i = 0; i < FIELD_COUNT; ++i) {
        if (std::strcmp(FIELDS[i].name, name) == 0) return &FIELDS[i];
    }
    return nullptr;
}

size_t runtime_climate_parity_comparable_count() {
    size_t count = 0;
    for (size_t i = 0; i < FIELD_COUNT; ++i) {
        if (FIELDS[i].comparability == RuntimeClimateParityComparability::COMPARABLE)
            ++count;
    }
    return count;
}

uint64_t runtime_climate_parity_hash(const RuntimeClimateStore &store) {
    uint64_t hash = mix(PARITY_OFFSET, RUNTIME_CLIMATE_PARITY_VERSION);
    hash = mix(hash, store.cell_count);
    hash = mix(hash, float_bits(store.climate_anomaly));
    for (size_t i = 0; i < FIELD_COUNT; ++i) {
        const RuntimeClimateParityField &field = FIELDS[i];
        if (field.comparability != RuntimeClimateParityComparability::COMPARABLE)
            continue;
        // Mix the field index so that moving a value between two same-typed
        // fields cannot leave the hash unchanged.
        hash = mix(hash, static_cast<uint64_t>(i));
        switch (field.kind) {
            case RuntimeClimateParityKind::F32:
                hash = mix_float_vector(hash, store.*(field.f32));
                break;
            case RuntimeClimateParityKind::I32:
                hash = mix_vector(hash, store.*(field.i32));
                break;
            case RuntimeClimateParityKind::U8:
                hash = mix_vector(hash, store.*(field.u8));
                break;
        }
    }
    return hash;
}

uint64_t RuntimeClimateStore::parity_hash() const {
    return runtime_climate_parity_hash(*this);
}

bool runtime_climate_parity_first_difference(
        const RuntimeClimateStore &reference,
        const RuntimeClimateStore &worker,
        RuntimeClimateParityReport &report) {
    const auto report_at = [&report](const char *name, size_t cell,
                                     const char *reference_bits,
                                     const char *worker_bits) {
        write_text(report.field, sizeof(report.field), name);
        report.cell = static_cast<uint32_t>(cell);
        write_text(report.reference_bits, sizeof(report.reference_bits), reference_bits);
        write_text(report.worker_bits, sizeof(report.worker_bits), worker_bits);
    };

    char reference_text[24];
    char worker_text[24];

    if (reference.cell_count != worker.cell_count) {
        std::snprintf(reference_text, sizeof(reference_text), "%u", reference.cell_count);
        std::snprintf(worker_text, sizeof(worker_text), "%u", worker.cell_count);
        report_at("cell_count", 0, reference_text, worker_text);
        return true;
    }
    if (float_bits(reference.climate_anomaly) != float_bits(worker.climate_anomaly)) {
        std::snprintf(reference_text, sizeof(reference_text), "%.9g",
                      static_cast<double>(reference.climate_anomaly));
        std::snprintf(worker_text, sizeof(worker_text), "%.9g",
                      static_cast<double>(worker.climate_anomaly));
        report_at("climate_anomaly", 0, reference_text, worker_text);
        return true;
    }

    for (size_t i = 0; i < FIELD_COUNT; ++i) {
        const RuntimeClimateParityField &field = FIELDS[i];
        if (field.comparability != RuntimeClimateParityComparability::COMPARABLE)
            continue;

        size_t reference_size = 0;
        size_t worker_size = 0;
        switch (field.kind) {
            case RuntimeClimateParityKind::F32:
                reference_size = (reference.*(field.f32)).size();
                worker_size = (worker.*(field.f32)).size();
                break;
            case RuntimeClimateParityKind::I32:
                reference_size = (reference.*(field.i32)).size();
                worker_size = (worker.*(field.i32)).size();
                break;
            case RuntimeClimateParityKind::U8:
                reference_size = (reference.*(field.u8)).size();
                worker_size = (worker.*(field.u8)).size();
                break;
        }
        if (reference_size != worker_size) {
            // A length difference is a structural divergence, not a value one;
            // point at the first index the shorter side cannot supply.
            std::snprintf(reference_text, sizeof(reference_text), "len=%zu", reference_size);
            std::snprintf(worker_text, sizeof(worker_text), "len=%zu", worker_size);
            report_at(field.name, reference_size < worker_size ? reference_size : worker_size,
                      reference_text, worker_text);
            return true;
        }

        for (size_t cell = 0; cell < reference_size; ++cell) {
            bool differs = false;
            switch (field.kind) {
                case RuntimeClimateParityKind::F32: {
                    const float a = (reference.*(field.f32))[cell];
                    const float b = (worker.*(field.f32))[cell];
                    differs = float_bits(a) != float_bits(b);
                    if (differs) {
                        std::snprintf(reference_text, sizeof(reference_text), "%.9g",
                                      static_cast<double>(a));
                        std::snprintf(worker_text, sizeof(worker_text), "%.9g",
                                      static_cast<double>(b));
                    }
                    break;
                }
                case RuntimeClimateParityKind::I32: {
                    const int32_t a = (reference.*(field.i32))[cell];
                    const int32_t b = (worker.*(field.i32))[cell];
                    differs = a != b;
                    if (differs) {
                        std::snprintf(reference_text, sizeof(reference_text), "%d", a);
                        std::snprintf(worker_text, sizeof(worker_text), "%d", b);
                    }
                    break;
                }
                case RuntimeClimateParityKind::U8: {
                    const uint8_t a = (reference.*(field.u8))[cell];
                    const uint8_t b = (worker.*(field.u8))[cell];
                    differs = a != b;
                    if (differs) {
                        std::snprintf(reference_text, sizeof(reference_text), "%u", a);
                        std::snprintf(worker_text, sizeof(worker_text), "%u", b);
                    }
                    break;
                }
            }
            if (differs) {
                report_at(field.name, cell, reference_text, worker_text);
                return true;
            }
        }
    }

    write_text(report.field, sizeof(report.field), "");
    write_text(report.reference_bits, sizeof(report.reference_bits), "");
    write_text(report.worker_bits, sizeof(report.worker_bits), "");
    report.cell = 0;
    return false;
}

namespace {
// Enabled with PK_CLIMATE_FIELD_DIAG=1 because it prints per compared day.
bool pk_field_diag_enabled() {
    static const bool on = [] {
        const char *v = std::getenv("PK_CLIMATE_FIELD_DIAG");
        return v != nullptr && v[0] == '1';
    }();
    return on;
}
} // namespace

size_t runtime_climate_parity_field_divergence(
        const RuntimeClimateStore &reference,
        const RuntimeClimateStore &worker,
        RuntimeClimateParityFieldDiff *out,
        size_t out_count) {
    if (out == nullptr || out_count < FIELD_COUNT) return 0;
    for (size_t i = 0; i < out_count; ++i) out[i] = RuntimeClimateParityFieldDiff{};

    size_t diverged_fields = 0;
    for (size_t i = 0; i < FIELD_COUNT; ++i) {
        const RuntimeClimateParityField &field = FIELDS[i];
        if (field.comparability != RuntimeClimateParityComparability::COMPARABLE)
            continue;
        RuntimeClimateParityFieldDiff &diff = out[i];

        size_t reference_size = 0;
        size_t worker_size = 0;
        switch (field.kind) {
            case RuntimeClimateParityKind::F32:
                reference_size = (reference.*(field.f32)).size();
                worker_size = (worker.*(field.f32)).size();
                break;
            case RuntimeClimateParityKind::I32:
                reference_size = (reference.*(field.i32)).size();
                worker_size = (worker.*(field.i32)).size();
                break;
            case RuntimeClimateParityKind::U8:
                reference_size = (reference.*(field.u8)).size();
                worker_size = (worker.*(field.u8)).size();
                break;
        }
        if (reference_size != worker_size) {
            // A shape difference is not a per-cell divergence: report it as the
            // whole field diverging so it cannot be mistaken for a near miss.
            diff.compared_cells = 0;
            diff.diverged_cells = static_cast<uint32_t>(
                reference_size > worker_size ? reference_size : worker_size);
            diff.out_of_band_cells = diff.diverged_cells;
            diff.first_cell = static_cast<uint32_t>(
                reference_size < worker_size ? reference_size : worker_size);
            std::snprintf(diff.reference_bits, sizeof(diff.reference_bits),
                          "len=%zu", reference_size);
            std::snprintf(diff.worker_bits, sizeof(diff.worker_bits),
                          "len=%zu", worker_size);
            ++diverged_fields;
            continue;
        }

        diff.compared_cells = static_cast<uint32_t>(reference_size);
        // Relative band, scaled by the larger of the two magnitudes so a field
        // that legitimately sits near zero is not held to an absolute epsilon
        // it can never meet. A band of 0 (BITWISE) falls through to plain
        // inequality, which is what we want for a shared kernel.
        const double band = runtime_climate_parity_tolerance_band(field.tolerance);
        bool first = true;
        bool first_out_of_band = true;
        for (size_t cell = 0; cell < reference_size; ++cell) {
            bool differs = false;
            double delta = 0.0;
            double reference_value = 0.0;
            double worker_value = 0.0;
            char reference_text[24];
            char worker_text[24];
            switch (field.kind) {
                case RuntimeClimateParityKind::F32: {
                    const float a = (reference.*(field.f32))[cell];
                    const float b = (worker.*(field.f32))[cell];
                    differs = float_bits(a) != float_bits(b);
                    reference_value = static_cast<double>(a);
                    worker_value = static_cast<double>(b);
                    if (differs) {
                        delta = std::fabs(static_cast<double>(a) -
                                          static_cast<double>(b));
                        std::snprintf(reference_text, sizeof(reference_text), "%.9g",
                                      static_cast<double>(a));
                        std::snprintf(worker_text, sizeof(worker_text), "%.9g",
                                      static_cast<double>(b));
                    }
                    break;
                }
                case RuntimeClimateParityKind::I32: {
                    const int32_t a = (reference.*(field.i32))[cell];
                    const int32_t b = (worker.*(field.i32))[cell];
                    differs = a != b;
                    reference_value = static_cast<double>(a);
                    worker_value = static_cast<double>(b);
                    if (differs) {
                        delta = std::fabs(static_cast<double>(a) -
                                          static_cast<double>(b));
                        std::snprintf(reference_text, sizeof(reference_text), "%d", a);
                        std::snprintf(worker_text, sizeof(worker_text), "%d", b);
                    }
                    break;
                }
                case RuntimeClimateParityKind::U8: {
                    const uint8_t a = (reference.*(field.u8))[cell];
                    const uint8_t b = (worker.*(field.u8))[cell];
                    differs = a != b;
                    reference_value = static_cast<double>(a);
                    worker_value = static_cast<double>(b);
                    if (differs) {
                        delta = std::fabs(static_cast<double>(a) -
                                          static_cast<double>(b));
                        std::snprintf(reference_text, sizeof(reference_text), "%u", a);
                        std::snprintf(worker_text, sizeof(worker_text), "%u", b);
                    }
                    break;
                }
            }
            if (!differs) continue;
            ++diff.diverged_cells;
            if (delta > diff.max_abs_delta) {
                diff.max_abs_delta = delta;
                diff.max_abs_delta_cell = static_cast<uint32_t>(cell);
            }
            if (first) {
                first = false;
                diff.first_cell = static_cast<uint32_t>(cell);
                write_text(diff.reference_bits, sizeof(diff.reference_bits), reference_text);
                write_text(diff.worker_bits, sizeof(diff.worker_bits), worker_text);
            }
            if (band > 0.0) {
                double scale = std::fabs(reference_value);
                const double worker_scale = std::fabs(worker_value);
                if (worker_scale > scale) scale = worker_scale;
                if (scale < 1.0) scale = 1.0;
                if (delta <= band * scale) continue;
            }
            ++diff.out_of_band_cells;
            if (first_out_of_band) {
                first_out_of_band = false;
                // A banded field reports the first cell that actually needs
                // explaining, not the first cell that merely differs.
                diff.first_cell = static_cast<uint32_t>(cell);
                write_text(diff.reference_bits, sizeof(diff.reference_bits), reference_text);
                write_text(diff.worker_bits, sizeof(diff.worker_bits), worker_text);
            }
        }
        if (diff.out_of_band_cells != 0) ++diverged_fields;
        // first_cell is often a rounding-level miss; the worst cell is what
        // says whether a branch went the other way. Print both so one run can
        // tell "everything drifted a little" apart from "some cells took a
        // different path".
        if (diff.out_of_band_cells != 0 && pk_field_diag_enabled()) {
            double worst_reference = 0.0;
            double worst_worker = 0.0;
            const size_t worst = diff.max_abs_delta_cell;
            switch (field.kind) {
                case RuntimeClimateParityKind::F32:
                    worst_reference = (reference.*(field.f32))[worst];
                    worst_worker = (worker.*(field.f32))[worst];
                    break;
                case RuntimeClimateParityKind::I32:
                    worst_reference = (reference.*(field.i32))[worst];
                    worst_worker = (worker.*(field.i32))[worst];
                    break;
                case RuntimeClimateParityKind::U8:
                    worst_reference = (reference.*(field.u8))[worst];
                    worst_worker = (worker.*(field.u8))[worst];
                    break;
            }
            std::fprintf(stderr,
                         "[field-diag] %-28s oob=%u/%u first=%u max_cell=%zu "
                         "ref=%.9g worker=%.9g delta=%.9g\n",
                         field.name, diff.out_of_band_cells, diff.compared_cells,
                         diff.first_cell, worst, worst_reference, worst_worker,
                         diff.max_abs_delta);
        }
    }
    if (pk_field_diag_enabled()) std::fflush(stderr);
    return diverged_fields;
}

bool runtime_climate_parity_adopt_comparable_fields(
        RuntimeClimateStore &target, const RuntimeClimateStore &reference) {
    if (target.cell_count != reference.cell_count) return false;
    target.climate_anomaly = reference.climate_anomaly;
    for (size_t i = 0; i < FIELD_COUNT; ++i) {
        const RuntimeClimateParityField &field = FIELDS[i];
        if (field.comparability != RuntimeClimateParityComparability::COMPARABLE)
            continue;
        switch (field.kind) {
            case RuntimeClimateParityKind::F32:
                target.*(field.f32) = reference.*(field.f32);
                break;
            case RuntimeClimateParityKind::I32:
                target.*(field.i32) = reference.*(field.i32);
                break;
            case RuntimeClimateParityKind::U8:
                target.*(field.u8) = reference.*(field.u8);
                break;
        }
    }
    return true;
}

bool runtime_climate_parity_self_test(std::string &error) {
    error.clear();
    const auto fail = [&error](const char *reason) {
        error = reason;
        return false;
    };

    // A fixed-size accumulator lives in the simulation host, so the table
    // outgrowing it must be caught here rather than by a silent truncation.
    if (FIELD_COUNT > RUNTIME_CLIMATE_PARITY_MAX_FIELDS)
        return fail("climate_parity_field_table_too_large");

    // The table must be internally consistent, because every consumer selects
    // a member pointer purely from `kind`.
    for (size_t i = 0; i < FIELD_COUNT; ++i) {
        const RuntimeClimateParityField &field = FIELDS[i];
        if (field.name == nullptr || field.name[0] == '\0')
            return fail("climate_parity_field_name_empty");
        if (static_cast<size_t>(field.stage) >= RUNTIME_CLIMATE_STAGE_COUNT)
            return fail("climate_parity_field_stage_invalid");
        if (field.map_data_array == nullptr)
            return fail("climate_parity_field_map_array_null");
        const int populated = (field.f32 != nullptr ? 1 : 0) +
                              (field.i32 != nullptr ? 1 : 0) +
                              (field.u8 != nullptr ? 1 : 0);
        if (populated != 1)
            return fail("climate_parity_field_pointer_ambiguous");
        const bool kind_matches =
            (field.kind == RuntimeClimateParityKind::F32 && field.f32 != nullptr) ||
            (field.kind == RuntimeClimateParityKind::I32 && field.i32 != nullptr) ||
            (field.kind == RuntimeClimateParityKind::U8 && field.u8 != nullptr);
        if (!kind_matches)
            return fail("climate_parity_field_kind_mismatch");
        if (field.comparability != RuntimeClimateParityComparability::COMPARABLE &&
            (field.note == nullptr || field.note[0] == '\0'))
            return fail("climate_parity_excluded_field_needs_note");
        for (size_t j = i + 1; j < FIELD_COUNT; ++j) {
            if (std::strcmp(FIELDS[i].name, FIELDS[j].name) == 0)
                return fail("climate_parity_field_name_duplicated");
        }
    }
    if (runtime_climate_parity_comparable_count() == 0)
        return fail("climate_parity_no_comparable_fields");
    if (runtime_climate_parity_field("temperature") == nullptr)
        return fail("climate_parity_lookup_failed");
    if (runtime_climate_parity_field("no_such_field") != nullptr)
        return fail("climate_parity_lookup_false_positive");

    constexpr uint32_t CELLS = 8;
    RuntimeClimateStore base;
    base.reset(CELLS);
    for (uint32_t i = 0; i < CELLS; ++i) {
        base.temperature[i] = 10.0f + static_cast<float>(i);
        base.moisture[i] = 0.25f * static_cast<float>(i);
        base.weather_type[i] = static_cast<uint8_t>(i % 4u);
        base.vegetation_growth_streak[i] = static_cast<int32_t>(i);
    }
    const uint64_t base_parity = base.parity_hash();
    if (base_parity == 0) return fail("climate_parity_hash_zero");
    if (base.parity_hash() != base_parity)
        return fail("climate_parity_hash_not_deterministic");

    // This is the property the whole comparison rests on: a worker that has
    // advanced its own bookkeeping must still hash equal to a reference that
    // has no such fields.
    RuntimeClimateStore bookkeeping = base;
    bookkeeping.generation = 4321;
    bookkeeping.climate_generation = 99;
    bookkeeping.committed_day = 77;
    bookkeeping.rng_state = 0xdeadbeefcafef00dull;
    bookkeeping.annual_rng_state = 0x0123456789abcdefull;
    bookkeeping.history_cursor = 3;
    bookkeeping.annual_temperature_drift = 1.5f;
    if (!bookkeeping.temperature_history.empty())
        bookkeeping.temperature_history[0] += 12.0f;
    if (bookkeeping.parity_hash() != base_parity)
        return fail("climate_parity_hash_includes_bookkeeping");
    if (bookkeeping.state_hash() == base.state_hash())
        return fail("climate_parity_state_hash_ignores_bookkeeping");

    // Fields excluded for a representation mismatch must not be able to force
    // a permanent mismatch either.
    RuntimeClimateStore excluded = base;
    excluded.vegetation_succession_candidate[0] = 1;
    excluded.riparian_moisture[0] = base.riparian_moisture[0] + 3.5f;
    if (excluded.parity_hash() != base_parity)
        return fail("climate_parity_hash_includes_excluded_field");

    RuntimeClimateStore mutated = base;
    mutated.temperature[3] += 0.5f;
    if (mutated.parity_hash() == base_parity)
        return fail("climate_parity_hash_ignores_temperature");
    RuntimeClimateStore anomaly = base;
    anomaly.climate_anomaly = base.climate_anomaly + 0.75f;
    if (anomaly.parity_hash() == base_parity)
        return fail("climate_parity_hash_ignores_anomaly");
    RuntimeClimateStore streak = base;
    streak.vegetation_growth_streak[2] += 1;
    if (streak.parity_hash() == base_parity)
        return fail("climate_parity_hash_ignores_int_field");
    RuntimeClimateStore weather = base;
    weather.weather_type[5] = static_cast<uint8_t>(weather.weather_type[5] + 1u);
    if (weather.parity_hash() == base_parity)
        return fail("climate_parity_hash_ignores_byte_field");

    RuntimeClimateParityReport report;
    if (runtime_climate_parity_first_difference(base, base, report))
        return fail("climate_parity_diff_false_positive");
    RuntimeClimateStore diverged = base;
    diverged.moisture[5] = base.moisture[5] + 0.125f;
    if (!runtime_climate_parity_first_difference(base, diverged, report))
        return fail("climate_parity_diff_missed");
    if (std::strcmp(report.field, "moisture") != 0)
        return fail("climate_parity_diff_wrong_field");
    if (report.cell != 5) return fail("climate_parity_diff_wrong_cell");
    if (report.reference_bits[0] == '\0' || report.worker_bits[0] == '\0')
        return fail("climate_parity_diff_missing_values");
    if (std::strcmp(report.reference_bits, report.worker_bits) == 0)
        return fail("climate_parity_diff_identical_values");

    // An excluded field diverging must not be reported as a difference,
    // otherwise the diagnosis would point at a known representation gap
    // instead of the real first divergence.
    RuntimeClimateStore excluded_diff = base;
    excluded_diff.vegetation_succession_candidate[1] = 1;
    if (runtime_climate_parity_first_difference(base, excluded_diff, report))
        return fail("climate_parity_diff_reports_excluded_field");

    RuntimeClimateStore resized;
    resized.reset(CELLS + 1);
    if (!runtime_climate_parity_first_difference(base, resized, report))
        return fail("climate_parity_diff_missed_cell_count");
    if (std::strcmp(report.field, "cell_count") != 0)
        return fail("climate_parity_diff_wrong_structural_field");

    // The per-field report is what the divergence matrix is built from, so it
    // must count every divergent cell rather than stopping at the first one,
    // and it must stay silent about excluded fields.
    RuntimeClimateStore matrix = base;
    matrix.moisture[1] = base.moisture[1] + 0.5f;
    matrix.moisture[6] = base.moisture[6] + 0.25f;
    matrix.sea_ice[2] = base.sea_ice[2] + 1.0f;
    matrix.riparian_moisture[0] = base.riparian_moisture[0] + 9.0f;
    std::vector<RuntimeClimateParityFieldDiff> diffs(FIELD_COUNT);
    const size_t diverged_field_count = runtime_climate_parity_field_divergence(
        base, matrix, diffs.data(), diffs.size());
    if (diverged_field_count != 2)
        return fail("climate_parity_matrix_field_count_wrong");
    for (size_t i = 0; i < FIELD_COUNT; ++i) {
        const RuntimeClimateParityField &field = FIELDS[i];
        const RuntimeClimateParityFieldDiff &diff = diffs[i];
        if (field.comparability != RuntimeClimateParityComparability::COMPARABLE) {
            if (diff.compared_cells != 0 || diff.diverged_cells != 0)
                return fail("climate_parity_matrix_reports_excluded_field");
            continue;
        }
        if (diff.compared_cells != CELLS)
            return fail("climate_parity_matrix_compared_cells_wrong");
        if (std::strcmp(field.name, "moisture") == 0) {
            if (diff.diverged_cells != 2 || diff.first_cell != 1)
                return fail("climate_parity_matrix_moisture_wrong");
            if (diff.max_abs_delta < 0.4)
                return fail("climate_parity_matrix_delta_wrong");
        } else if (std::strcmp(field.name, "sea_ice") == 0) {
            if (diff.diverged_cells != 1 || diff.first_cell != 2)
                return fail("climate_parity_matrix_sea_ice_wrong");
        } else if (diff.diverged_cells != 0) {
            return fail("climate_parity_matrix_false_positive");
        }
    }
    if (runtime_climate_parity_field_divergence(base, base, diffs.data(),
                                                diffs.size()) != 0)
        return fail("climate_parity_matrix_equal_states_diverged");
    if (runtime_climate_parity_field_divergence(base, matrix, diffs.data(),
                                                FIELD_COUNT - 1u) != 0)
        return fail("climate_parity_matrix_undersized_output_accepted");

    // Adoption must make the two sides parity-equal while leaving the worker's
    // bookkeeping alone; otherwise the measurement mode would silently rewrite
    // state the comparison is supposed to ignore.
    RuntimeClimateStore adopted = matrix;
    adopted.generation = 909;
    adopted.committed_day = 12;
    adopted.rng_state = 0x5555aaaa5555aaaaull;
    adopted.vegetation_succession_candidate[0] = 1;
    if (!runtime_climate_parity_adopt_comparable_fields(adopted, base))
        return fail("climate_parity_adopt_rejected_same_shape");
    if (adopted.parity_hash() != base_parity)
        return fail("climate_parity_adopt_did_not_converge");
    if (adopted.generation != 909 || adopted.committed_day != 12 ||
        adopted.rng_state != 0x5555aaaa5555aaaaull ||
        adopted.vegetation_succession_candidate[0] != 1)
        return fail("climate_parity_adopt_overwrote_bookkeeping");
    if (runtime_climate_parity_adopt_comparable_fields(adopted, resized))
        return fail("climate_parity_adopt_accepted_shape_mismatch");

    if (std::strcmp(runtime_climate_stage_name(RuntimeClimateStage::PASS_A),
                    "PASS_A") != 0 ||
        std::strcmp(runtime_climate_stage_name(RuntimeClimateStage::COUNT),
                    "UNKNOWN") != 0)
        return fail("climate_parity_stage_name_invalid");

    return true;
}

} // namespace pk
